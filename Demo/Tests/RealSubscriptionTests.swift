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

extension RealStoreKit {
    @MainActor
    @Suite("Real StoreKit: subscriptions, through the real adapter", .serialized, .timeLimit(.minutes(3)))
    struct RealSubscriptionTests {
        /// What phase 0 measured, per OS (spike/README.md). A test below measures each again.
        enum Measured {
            #if os(macOS)
            /// macOS 26.6 with Xcode 27.0: listed about 0.6 s after `purchase()` returns. With
            /// Xcode 26.6, on a hosted runner, seen both ways: a race, measured and not insisted
            /// on (nil).
            static let listsASubscriptionLate: Bool? = RealStoreKit.builtWithXcode27 ? true : nil
            /// macOS 26.6 with Xcode 27.0: announced on `Transaction.updates` half a second
            /// later, though made here — unlike a non-consumable. With Xcode 26.6: not
            /// announced within five seconds, in both runs.
            static let announcesASubscriptionBoughtHere = RealStoreKit.builtWithXcode27
            /// macOS 26.6: not listed while in billing retry, as Apple documents.
            static let listsBillingRetry = false
            #else
            /// iOS 27.0 simulator.
            static let listsASubscriptionLate: Bool? = false
            static let announcesASubscriptionBoughtHere = false
            /// iOS 27.0 simulator: a renewal transaction arrives for a failed charge, and is
            /// listed while the status says billing retry.
            static let listsBillingRetry = true
            #endif
        }

        static func configurationURL() throws -> URL {
            let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
            return try #require(bundle.url(forResource: "Demo", withExtension: "storekit"))
        }

        func session(rate: SKTestSession.TimeRate = .realTime) throws -> SKTestSession {
            let session = try SKTestSession(contentsOf: Self.configurationURL())
            session.resetToDefaultState()
            session.disableDialogs = true
            session.clearTransactions()
            session.timeRate = rate
            return session
        }

        var front: AppStoreFront { AppStoreFront(catalogue: Shop.catalogue) }

        func store(
            logger: RecordingPurchaseLogger = RecordingPurchaseLogger(), offerSigner: (any OfferSigning)? = nil
        ) -> PurchaseStore {
            PurchaseStore(catalogue: Shop.catalogue, front: front, offerSigner: offerSigner, logger: logger)
        }

        func membership(_ store: PurchaseStore) -> SubscriptionStanding {
            store.standing.subscription(in: Shop.membership)
        }

        private func isListed(_ id: ProductID) async -> Bool {
            await front.ownedProducts().contains { $0.id == id }
        }

        /// Whether StoreKit itself still holds Plus, to renew as Monthly.
        private func storeKitScheduledTheDowngrade() async throws -> Bool {
            try await Product.SubscriptionInfo.status(for: Shop.membership.rawValue).contains { status in
                status.state == .subscribed && status.transaction.unsafePayloadValue.productID == Shop.plus.rawValue
                    && status.renewalInfo.unsafePayloadValue.autoRenewPreference == Shop.monthly.rawValue
            }
        }

        /// Whether StoreKit itself says the membership renewed, and is in no grace period.
        private func storeKitRenewedInstead() async throws -> Bool {
            try await Product.SubscriptionInfo.status(for: Shop.membership.rawValue).contains { status in
                let transaction = status.transaction.unsafePayloadValue
                return status.state == .subscribed && status.renewalInfo.unsafePayloadValue.gracePeriodExpirationDate == nil
                    && transaction.purchaseDate > transaction.originalPurchaseDate
            }
        }

        /// Whether StoreKit itself says the membership is being retried with no grace period:
        /// in billing retry, or expired while still retrying, with no grace date.
        private func storeKitRetriedWithoutGrace() async throws -> Bool {
            try await Product.SubscriptionInfo.status(for: Shop.membership.rawValue).contains { status in
                let renewal = status.renewalInfo.unsafePayloadValue
                let retrying = status.state == .inBillingRetryPeriod || (status.state == .expired && renewal.isInBillingRetry)
                return retrying && renewal.gracePeriodExpirationDate == nil
            }
        }

        /// StoreKit's own statuses for the membership, in words, for a failure message: so a
        /// failure says what StoreKit said, and not only what the store made of it.
        private func storeKitSays() async -> String {
            guard let statuses = try? await Product.SubscriptionInfo.status(for: Shop.membership.rawValue) else {
                return "no status could be read"
            }
            return statuses.map { status in
                let transaction = status.transaction.unsafePayloadValue
                let renewal = status.renewalInfo.unsafePayloadValue
                return "\(status.state.localizedDescription): \(transaction.productID), renewed \(transaction.purchaseDate > transaction.originalPurchaseDate), "
                    + "retrying \(renewal.isInBillingRetry), grace until \(renewal.gracePeriodExpirationDate.map { "\($0)" } ?? "nil")"
            }.joined(separator: "; ")
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
            // The status catches up with the hold, and says what the hold could not: the renewal.
            #expect(held.offer?.kind == .introductory)
            #expect(await waitUntil(timeout: .seconds(10)) {
                await store.refresh()
                return membership(store).current?.renewal != nil
            })
            #expect(membership(store).current?.offer?.kind == .introductory)
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
            let retried = await waitUntil(timeout: .seconds(30)) {
                await store.refresh()
                return membership(store).current?.state == .inBillingRetry
            }
            // With Xcode 26.6 the test environment renewed instead, in every run on the hosted
            // runner: `shouldEnterBillingRetryOnRenewal` alone was not honoured. Decided by
            // StoreKit's own status, and only with those tools.
            if !retried, !RealStoreKit.builtWithXcode27, try await storeKitRenewedInstead() {
                withKnownIssue("Xcode 26.6's test environment renewed instead of failing the charge", isIntermittent: true) {
                    Issue.record("renewed; the store saw \(membership(store))")
                }
                #expect(membership(store).isActive == true, "StoreKit renewed it, so it is access")
            } else {
                let says = await storeKitSays()
                #expect(retried, "never in billing retry; last seen \(membership(store)); StoreKit says \(says)")
                #expect(membership(store).isActive == false)
            }
            withExtendedLifetime(session) {}
        }

        @Test("a failed charge WITH a grace period is still access, in the grace period")
        func gracePeriod() async throws {
            let session = try session(rate: .oneRenewalEveryTenSeconds)
            session.shouldEnterBillingRetryOnRenewal = true
            session.billingGracePeriodIsEnabled = true
            let store = store()
            await store.start()
            try await store.purchase(Shop.monthly)
            let graced = await waitUntil(timeout: .seconds(30)) {
                await store.refresh()
                if case .inGracePeriod? = membership(store).current?.state { return true }
                return false
            }
            // Seen now and then in a full run, and never alone: StoreKit's test environment
            // RENEWED the subscription, ignoring `shouldEnterBillingRetryOnRenewal` for that
            // renewal. That is the environment's fault, and intermittent — and it is decided by
            // StoreKit's own status, never by what the store made of it.
            if !graced, try await storeKitRenewedInstead() {
                withKnownIssue("StoreKit's test environment renewed instead of failing the charge", isIntermittent: true) {
                    Issue.record("renewed; the store saw \(membership(store))")
                }
                #expect(membership(store).isActive == true)
            } else if !graced, !RealStoreKit.builtWithXcode27, try await storeKitRetriedWithoutGrace() {
                // With Xcode 26.6, in every run on the hosted runner, the test environment went
                // into billing retry and gave no grace period, though told to. The store is held
                // to what StoreKit said: billing retry is not access.
                withKnownIssue("Xcode 26.6's test environment gave no grace period, and went into billing retry", isIntermittent: true) {
                    Issue.record("no grace period; the store saw \(membership(store))")
                }
                #expect(membership(store).current?.state == .inBillingRetry)
                #expect(membership(store).isActive == false)
            } else {
                let says = await storeKitSays()
                #expect(graced, "never in a grace period; last seen \(membership(store)); StoreKit says \(says)")
                #expect(membership(store).isActive == true)
            }
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
            if let late = Measured.listsASubscriptionLate {
                #expect(listedAtOnce == !late)
            }
            #expect(await waitUntil(timeout: .seconds(10)) { await isListed(Shop.monthly) })
            withExtendedLifetime(session) {}
        }

        @Test("HABIT: is a subscription bought here also announced on the updates?")
        func habitBoughtHereAnnounced() async throws {
            let session = try session()
            let heard = Heard()
            let listening = Task {
                for await result in Transaction.updates { heard.product = result.unsafePayloadValue.productID }
            }
            // Nothing says when the iteration has begun; a purchase before it would be missed.
            try await Task.sleep(for: .milliseconds(300))
            _ = try await front.purchase(Shop.monthly, confirmation: .automatic)
            // Half a second on the Mac; waited for ten times as long, so that a slow run is not a change of habit.
            let announced = await waitUntil(timeout: .seconds(5)) { heard.product == Shop.monthly.rawValue }
            listening.cancel()
            print("MEASURED subscriptionBoughtHereAnnounced:", announced)
            #expect(announced == Measured.announcesASubscriptionBoughtHere)
            withExtendedLifetime(session) {}
        }

        @Test("HABIT: is a subscription in billing retry listed?")
        func habitBillingRetryListing() async throws {
            let session = try session(rate: .oneRenewalEveryTenSeconds)
            session.shouldEnterBillingRetryOnRenewal = true
            _ = try await front.purchase(Shop.monthly, confirmation: .automatic)
            let retried = await waitUntil(timeout: .seconds(25)) {
                let statuses = (try? await Product.SubscriptionInfo.status(for: Shop.membership.rawValue)) ?? []
                return statuses.contains { $0.state == .inBillingRetryPeriod }
            }
            // As in `billingRetry`: with Xcode 26.6 the environment renewed instead, so there is
            // no billing retry to measure.
            if !retried, !RealStoreKit.builtWithXcode27, try await storeKitRenewedInstead() {
                withKnownIssue("Xcode 26.6's test environment renewed instead of failing the charge", isIntermittent: true) {
                    Issue.record("renewed, so billing retry could not be measured")
                }
                withExtendedLifetime(session) {}
                return
            }
            let says = await storeKitSays()
            #expect(retried, "never in billing retry; StoreKit says \(says)")
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
            // In a full run on the Mac it has, now and then, come back as the new plan, and never
            // alone (D37). Excused only where StoreKit itself still holds the plan and has
            // scheduled the change: the returned transaction was the environment's, and the
            // habit stood. The plan changed at once is a change of habit, and fails.
            #if os(macOS)
            if owned.id == Shop.monthly, try await storeKitScheduledTheDowngrade() {
                withKnownIssue("a downgrade came back as the new plan (D37)", isIntermittent: true) {
                    Issue.record("came back as \(owned.id)")
                }
                withExtendedLifetime(session) {}
                return
            }
            #endif
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
}

/// What a listener heard, for a test to wait on.
@MainActor
private final class Heard {
    var product: String?
}
