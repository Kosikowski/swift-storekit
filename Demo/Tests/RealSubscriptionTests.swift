//
//  RealSubscriptionTests.swift
//  DemoTests
//
//  Subscriptions through the real adapter, against real StoreKit: the habits phase 0
//  measured (spike/README.md), each held to what is written down per OS, so that StoreKit
//  changing fails a test rather than letting the simulated store drift from it; and the
//  store end to end — bought, renewed, lapsed, in billing retry and in a grace period.
//
//  A period lasts ten seconds (`SKTestSession.timeRate`), so a renewal is watched rather
//  than waited for. One test environment, shared and outliving the process: serial, each
//  test resetting it first, as the rest of this bundle does.
//

@testable import Demo
import Foundation
import PurchaseCore
@testable import PurchaseStoreKit
import PurchaseTestKit
import StoreKit
import StoreKitTest
import Testing

@MainActor
@Suite("Real StoreKit: subscriptions, through the real adapter", .serialized, .timeLimit(.minutes(3)))
struct RealSubscriptionTests {
    /// What phase 0 measured, per OS (spike/README.md). A test below measures each again.
    enum Measured {
        #if os(macOS)
        /// macOS 26.6: listed about 0.6 s after `purchase()` returns.
        static let listsASubscriptionLate = true
        /// macOS 26.6: announced on `Transaction.updates` half a second later, though made
        /// here — unlike a non-consumable.
        static let announcesASubscriptionBoughtHere = true
        /// macOS 26.6: not listed while in billing retry, as Apple documents.
        static let listsBillingRetry = false
        #else
        /// iOS 27.0 simulator.
        static let listsASubscriptionLate = false
        static let announcesASubscriptionBoughtHere = false
        /// iOS 27.0 simulator: a renewal transaction arrives for a failed charge, and is
        /// listed while the status says billing retry.
        static let listsBillingRetry = true
        #endif
    }

    private static func configurationURL() throws -> URL {
        let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
        return try #require(bundle.url(forResource: "Demo", withExtension: "storekit"))
    }

    private func session(rate: SKTestSession.TimeRate = .realTime) throws -> SKTestSession {
        let session = try SKTestSession(contentsOf: Self.configurationURL())
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.timeRate = rate
        return session
    }

    private var front: AppStoreFront { AppStoreFront(catalogue: Shop.catalogue) }

    private func store(logger: RecordingPurchaseLogger = RecordingPurchaseLogger()) -> PurchaseStore {
        PurchaseStore(catalogue: Shop.catalogue, front: front, logger: logger)
    }

    private func membership(_ store: PurchaseStore) -> SubscriptionStanding {
        store.standing.subscription(in: Shop.membership)
    }

    private func isListed(_ id: ProductID) async -> Bool {
        await front.ownedProducts().contains { $0.id == id }
    }

    private func latest(_ id: ProductID, in session: SKTestSession) -> UInt? {
        session.allTransactions().filter { $0.productIdentifier == id.rawValue }.max { $0.identifier < $1.identifier }?.identifier
    }

    // MARK: - The store, end to end

    @Test("a subscription bought is subscribed at once, and the introductory offer is what the status says it was bought with")
    func bought() async throws {
        let session = try session()
        let store = store()
        await store.start()
        guard case let .subscribed(held) = try await store.purchase(Shop.monthly) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(held.product == Shop.monthly)
        #expect(membership(store).isActive == true)
        // The status catches up with the hold, and says what the hold could not.
        await store.refresh()
        #expect(await waitUntil(timeout: .seconds(10)) {
            await store.refresh()
            return membership(store).current?.offer?.kind == .introductory
        })
        #expect(membership(store).current?.renewal?.willRenew == true)
        withExtendedLifetime(session) {}
    }

    /// The moment at every renewal — the status saying expired, the listing empty — is
    /// what this is here to survive. Every read the store makes is in the log.
    @Test("through two renewals the member is never locked out, at any read")
    func renewals() async throws {
        let session = try session(rate: .oneRenewalEveryTenSeconds)
        let logger = RecordingPurchaseLogger()
        let store = store(logger: logger)
        await store.start()
        try await store.purchase(Shop.monthly)
        let first = try #require(membership(store).current?.periodEnds)
        let bought = logger.events.count
        #expect(await waitUntil(timeout: .seconds(40)) {
            (membership(store).current?.periodEnds ?? first) > first.addingTimeInterval(15)
        })
        let reads = logger.events.dropFirst(bought).compactMap { event -> Set<ProductID>? in
            if case let .standingResolved(owned) = event { owned } else { nil }
        }
        #expect(!reads.isEmpty)
        #expect(reads.allSatisfy { $0.contains(Shop.monthly) }, "a read granted no membership: \(reads)")
        withExtendedLifetime(session) {}
    }

    @Test("switched off, it lapses at the end of its period, and the store sees it with nothing announced")
    func lapses() async throws {
        let session = try session(rate: .oneRenewalEveryTenSeconds)
        let store = store()
        await store.start()
        try await store.purchase(Shop.monthly)
        let id = try #require(latest(Shop.monthly, in: session))
        try session.disableAutoRenewForTransaction(identifier: id)
        // The iOS simulator was measured to apply this only at the next renewal.
        #expect(await waitUntil(timeout: .seconds(45)) { membership(store).isActive == false })
        #expect(store.standing.access(to: Shop.monthly) == .none)
        withExtendedLifetime(session) {}
    }

    /// Measured in the iOS simulator: the failed renewal arrives as a transaction and is
    /// listed. The status decides, and billing retry is not access.
    @Test("a failed charge with no grace period is BILLING RETRY: said, and not access, on both platforms")
    func billingRetry() async throws {
        let session = try session(rate: .oneRenewalEveryTenSeconds)
        session.shouldEnterBillingRetryOnRenewal = true
        let store = store()
        await store.start()
        try await store.purchase(Shop.monthly)
        #expect(await waitUntil(timeout: .seconds(30)) {
            await store.refresh()
            return membership(store).current?.state == .inBillingRetry
        })
        #expect(membership(store).isActive == false)
        withExtendedLifetime(session) {}
    }

    @Test("a failed charge WITH a grace period is still access, until the grace period ends")
    func gracePeriod() async throws {
        let session = try session(rate: .oneRenewalEveryTenSeconds)
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = true
        let store = store()
        await store.start()
        try await store.purchase(Shop.monthly)
        #expect(await waitUntil(timeout: .seconds(30)) {
            await store.refresh()
            if case .inGracePeriod? = membership(store).current?.state { return true }
            return false
        })
        #expect(membership(store).isActive == true)
        withExtendedLifetime(session) {}
    }

    @Test("a DOWNGRADE is a plan change waiting for the renewal; an UPGRADE is at once")
    func planChanges() async throws {
        let session = try session()
        let store = store()
        await store.start()
        try await store.purchase(Shop.plus)
        let completion = try await store.purchase(Shop.monthly)
        guard case .planChangeScheduled(to: Shop.monthly, _) = completion else {
            Issue.record("expected a scheduled change, got \(completion)")
            return
        }
        #expect(membership(store).current?.product == Shop.plus)

        let session2 = try self.session()
        try await store.purchase(Shop.monthly)
        guard case let .subscribed(held) = try await store.purchase(Shop.plus) else {
            Issue.record("expected the upgrade to be subscribed")
            return
        }
        #expect(held.product == Shop.plus)
        withExtendedLifetime((session, session2)) {}
    }

    // MARK: - Habits, held to the simulated store

    @Test("HABIT: is a subscription listed the moment purchase() returns?")
    func habitListingLag() async throws {
        let session = try session()
        guard case .purchased = try await front.purchase(Shop.monthly, confirmation: .automatic) else {
            Issue.record("expected the purchase to go through")
            return
        }
        let listedAtOnce = await isListed(Shop.monthly)
        print("MEASURED subscriptionListedAtOnce:", listedAtOnce)
        #expect(listedAtOnce == !Measured.listsASubscriptionLate)
        #expect(await waitUntil(timeout: .seconds(10)) { await isListed(Shop.monthly) })
        withExtendedLifetime(session) {}
    }

    @Test("HABIT: is a subscription bought here also announced on the updates?")
    func habitBoughtHereAnnounced() async throws {
        let session = try session()
        let heard = Task { () -> String? in
            for await result in Transaction.updates { return result.unsafePayloadValue.productID }
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await front.purchase(Shop.monthly, confirmation: .automatic)
        try await Task.sleep(for: .seconds(3))
        heard.cancel()
        let announced = await heard.value == Shop.monthly.rawValue
        print("MEASURED subscriptionBoughtHereAnnounced:", announced)
        #expect(announced == Measured.announcesASubscriptionBoughtHere)
        withExtendedLifetime(session) {}
    }

    @Test("HABIT: at a renewal, does the status say EXPIRED for a moment before the renewal arrives?")
    func habitRenewalMoment() async throws {
        let session = try session(rate: .oneRenewalEveryTenSeconds)
        _ = try await front.purchase(Shop.monthly, confirmation: .automatic)
        var sawExpired = false
        let end = Date().addingTimeInterval(14)
        while Date() < end {
            let statuses = (try? await Product.SubscriptionInfo.status(for: Shop.membership.rawValue)) ?? []
            if statuses.contains(where: { $0.state == .expired }) { sawExpired = true }
            try await Task.sleep(for: .milliseconds(40))
        }
        print("MEASURED renewalMomentSeen:", sawExpired)
        // Seen every time on the Mac and in the simulator, but it lasts well under a second:
        // a race against the poll, so intermittent. The store is built for it either way.
        withKnownIssue("the moment can fall between two polls", isIntermittent: true) {
            #expect(sawExpired)
        }
        withExtendedLifetime(session) {}
    }

    @Test("HABIT: is a subscription in billing retry listed?")
    func habitBillingRetryListing() async throws {
        let session = try session(rate: .oneRenewalEveryTenSeconds)
        session.shouldEnterBillingRetryOnRenewal = true
        _ = try await front.purchase(Shop.monthly, confirmation: .automatic)
        #expect(await waitUntil(timeout: .seconds(25)) {
            let statuses = (try? await Product.SubscriptionInfo.status(for: Shop.membership.rawValue)) ?? []
            return statuses.contains { $0.state == .inBillingRetryPeriod }
        })
        try await Task.sleep(for: .seconds(1))
        let listed = await isListed(Shop.monthly)
        print("MEASURED billingRetryListed:", listed)
        #expect(listed == Measured.listsBillingRetry)
        withExtendedLifetime(session) {}
    }

    /// Once the first purchase is listed, as phase 0 asked it. Asked in the same instant as
    /// the first purchase — before StoreKit has listed it — a downgrade on the Mac came back
    /// as the new plan instead (seen once, and not pinned: no person downgrades within half a
    /// second of subscribing).
    @Test("HABIT: a downgrade comes back from purchase() as a success, with the plan already held")
    func habitDowngradeReturnsHeld() async throws {
        let session = try session()
        _ = try await front.purchase(Shop.plus, confirmation: .automatic)
        #expect(await waitUntil(timeout: .seconds(10)) { await isListed(Shop.plus) })
        guard case let .purchased(owned) = try await front.purchase(Shop.monthly, confirmation: .automatic) else {
            Issue.record("expected a success")
            return
        }
        print("MEASURED downgradeReturned:", owned.id)
        #expect(owned.id == Shop.plus)
        withExtendedLifetime(session) {}
    }

    @Test("CANARY: real StoreKit answers a status read from a cancelled task with an EMPTY array")
    func canaryCancelledStatusRead() async throws {
        let session = try session()
        _ = try await front.purchase(Shop.monthly, confirmation: .automatic)
        #expect(await waitUntil(timeout: .seconds(10)) {
            ((try? await Product.SubscriptionInfo.status(for: Shop.membership.rawValue)) ?? []).count == 1
        })
        let cancelled = await Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return ((try? await Product.SubscriptionInfo.status(for: Shop.membership.rawValue)) ?? []).count
        }.value
        print("MEASURED cancelledStatusCount:", cancelled)
        #expect(cancelled == 0)
        // And the adapter, which asks from a task of its own, is not fooled.
        let front = front
        let throughTheAdapter = await Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return await front.subscriptionStatuses(in: [Shop.membership])[Shop.membership]?.count ?? -1
        }.value
        #expect(throughTheAdapter == 1)
        withExtendedLifetime(session) {}
    }
}
