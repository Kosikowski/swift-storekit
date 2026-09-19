// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

private let group: SubscriptionGroupID = "21800001"
private let monthly: ProductID = "com.example.pro.monthly"
private let premium: ProductID = "com.example.premium.monthly"
private let catalogue: Catalogue = [
    .subscription(monthly, in: group, level: 2),
    .subscription(premium, in: group, level: 1),
]

@Suite("Simulated store: subscriptions", .timeLimit(.minutes(1)))
struct SimulatedSubscriptionTests {
    private let clock = ManualClock()
    private let period: Duration = .seconds(60)

    private func store(_ configure: (inout SimulatedStoreFront.Behaviour) -> Void = { _ in }) -> SimulatedStoreFront {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.subscriptionPeriod = period
        configure(&behaviour)
        return SimulatedStoreFront(catalogue: catalogue, clock: clock, behaviour: behaviour)
    }

    private func subscribed(_ product: ProductID = monthly, next: ProductID? = nil, willRenew: Bool = true) -> HeldSubscription {
        HeldSubscription(
            product: product, group: group, state: .subscribed, firstSubscribed: clock.now,
            periodStarted: clock.now, periodEnds: clock.now.addingTimeInterval(60),
            renewal: Renewal(willRenew: willRenew, nextProduct: willRenew ? next ?? product : nil))
    }

    private func statuses(_ store: SimulatedStoreFront) async -> [HeldSubscription] {
        await store.subscriptionStatuses(in: [group])[group] ?? []
    }

    // MARK: - Buying

    @Test("a subscription bought runs one period, is listed late, and its status is said once it is listed")
    func bought() async throws {
        let store = store()
        guard case let .purchased(owned) = try await store.purchase(monthly, confirmation: .automatic) else {
            Issue.record("expected a purchase")
            return
        }
        #expect(owned.expirationDate == clock.now.addingTimeInterval(60))
        #expect(await statuses(store).isEmpty)
        #expect(await store.ownedProducts().isEmpty)
        #expect(await store.ownedProducts() == [owned])
        #expect(await statuses(store).map(\.state) == [.subscribed])
    }

    // MARK: - Renewing

    /// Measured: at every renewal the status says expired and the listing has nothing,
    /// for a moment, and the renewal is announced before it is listed.
    @Test("at the period's end it RENEWS — announced first, with the moment the real store has: expired, and nothing listed")
    func renewsWithTheMoment() async {
        let store = store()
        store.seedSubscription(subscribed())
        var updates = store.transactionUpdates().makeAsyncIterator()
        clock.advance(by: period)

        #expect(await store.ownedProducts().isEmpty)
        guard case let .granted(renewal)? = await updates.next() else {
            Issue.record("the renewal should be announced")
            return
        }
        #expect(renewal.purchaseDate == clock.now)
        #expect(renewal.expirationDate == clock.now.addingTimeInterval(60))
        #expect(await statuses(store).map(\.state) == [.expired(.unstated)])
        #expect(await statuses(store).first?.renewal?.willRenew == false)

        _ = await store.ownedProducts()
        #expect(await statuses(store).map(\.state) == [.subscribed])
        #expect(await statuses(store).first?.periodEnds == renewal.expirationDate)
        #expect(await store.ownedProducts() == [renewal])
    }

    @Test("without the moment, a renewal is the status and the listing at once")
    func renewsPolitely() async {
        let store = store {
            $0.showsTheRenewalMoment = false
            $0.listsPurchasesAfterReads = 0
        }
        store.seedSubscription(subscribed())
        clock.advance(by: period)
        #expect(await store.ownedProducts().map(\.expirationDate) == [clock.now.addingTimeInterval(60)])
        #expect(await statuses(store).map(\.state) == [.subscribed])
    }

    /// Measured: renewals missed while nothing ran arrive at the next launch, newest first.
    @Test("renewals missed while nobody read are announced NEWEST FIRST")
    func missedRenewalsNewestFirst() async {
        let store = store()
        store.seedSubscription(subscribed())
        var updates = store.transactionUpdates().makeAsyncIterator()
        clock.advance(by: .seconds(200))
        _ = await store.ownedProducts()
        var starts: [Date] = []
        for _ in 0 ..< 3 {
            if case let .granted(owned)? = await updates.next() { starts.append(owned.purchaseDate) }
        }
        let start = clock.now.addingTimeInterval(-200)
        #expect(starts == [180, 120, 60].map { start.addingTimeInterval($0) })
    }

    @Test("a plan change waiting for the renewal takes effect WITH it")
    func planChangeAtRenewal() async {
        let store = store {
            $0.showsTheRenewalMoment = false
            $0.listsPurchasesAfterReads = 0
        }
        store.seedSubscription(subscribed(premium, next: monthly))
        clock.advance(by: period)
        #expect(await store.ownedProducts().map(\.id) == [monthly])
        #expect(await statuses(store).map(\.product) == [monthly])
    }

    // MARK: - Not renewing

    @Test("auto-renew switched off is announced; at the period's end it lapses, unlisted, and that is announced too")
    func cancelled() async {
        let store = store()
        store.seedSubscription(subscribed())
        var updates = store.transactionUpdates().makeAsyncIterator()
        store.cancelAutoRenew(monthly)
        guard case let .subscriptionChanged(off)? = await updates.next() else {
            Issue.record("the cancellation should be announced")
            return
        }
        #expect(off.renewal?.willRenew == false)
        #expect(off.state == .subscribed)

        clock.advance(by: period)
        #expect(await store.ownedProducts().isEmpty)
        guard case let .subscriptionChanged(lapsed)? = await updates.next() else {
            Issue.record("the lapse should be announced")
            return
        }
        #expect(lapsed.state == .expired(.autoRenewDisabled))
    }

    @Test("a failed charge with NO grace period is billing retry, unlisted, and then expired")
    func billingRetry() async {
        let store = store {
            $0.renewal = .fails
            $0.billingRetryPeriod = .seconds(600)
        }
        store.seedSubscription(subscribed())
        clock.advance(by: period)
        #expect(await statuses(store).map(\.state) == [.inBillingRetry])
        #expect(await store.ownedProducts().isEmpty)
        clock.advance(by: .seconds(600))
        #expect(await statuses(store).map(\.state) == [.expired(.billingError)])
    }

    @Test("a failed charge WITH a grace period stays listed until the grace ends, then is billing retry")
    func gracePeriod() async {
        let store = store {
            $0.renewal = .fails
            $0.gracePeriod = .seconds(300)
        }
        let status = subscribed()
        store.seedSubscription(status)
        clock.advance(by: period)
        #expect(await statuses(store).map(\.state) == [.inGracePeriod(until: status.periodEnds.addingTimeInterval(300))])
        #expect(await store.ownedProducts().map(\.id) == [monthly])
        clock.advance(by: .seconds(300))
        #expect(await statuses(store).map(\.state) == [.inBillingRetry])
        #expect(await store.ownedProducts().isEmpty)
    }

    @Test("a charge that finally goes through starts a new period now, announced")
    func recovered() async {
        let store = store { $0.renewal = .fails }
        store.seedSubscription(subscribed())
        clock.advance(by: period)
        _ = await statuses(store)
        var updates = store.transactionUpdates().makeAsyncIterator()
        store.recoverBilling(monthly)
        guard case let .granted(renewal)? = await updates.next() else {
            Issue.record("the recovery should be announced")
            return
        }
        #expect(renewal.purchaseDate == clock.now)
        #expect(await statuses(store).map(\.state) == [.subscribed])
    }

    @Test("a lapse now, and a price rise awaiting consent, are each announced")
    func lapseAndPriceRise() async {
        let store = store()
        store.seedSubscription(subscribed())
        var updates = store.transactionUpdates().makeAsyncIterator()
        store.raisePrice(monthly, needsConsent: true)
        guard case let .subscriptionChanged(rising)? = await updates.next() else {
            Issue.record("the price rise should be announced")
            return
        }
        #expect(rising.renewal?.priceIncrease == .awaitingConsent)
        store.lapse(monthly)
        guard case let .subscriptionChanged(lapsed)? = await updates.next() else {
            Issue.record("the lapse should be announced")
            return
        }
        #expect(lapsed.state == .expired(.autoRenewDisabled))
        #expect(await store.ownedProducts().isEmpty)
    }

    @Test("a subscription from outside the app is announced, listed late, and its status said once listed")
    func deliveredFromOutside() async {
        let store = store()
        var updates = store.transactionUpdates().makeAsyncIterator()
        store.deliverSubscription(monthly, ownership: .familyShared)
        guard case let .granted(owned)? = await updates.next() else {
            Issue.record("the subscription should be announced")
            return
        }
        #expect(owned.ownership == .familyShared)
        #expect(owned.expirationDate == clock.now.addingTimeInterval(60))
        #expect(await statuses(store).isEmpty)
        #expect(await store.ownedProducts().isEmpty)
        #expect(await statuses(store).map(\.ownership) == [.familyShared])
    }
}

/// The store and the simulated store together, over a year.
@MainActor
@Suite("Purchase store over a year of renewals", .timeLimit(.minutes(1)))
struct YearOfRenewalsTests {
    @Test("a year of monthly renewals — twelve renewal moments — and the subscriber is never locked out")
    func aYear() async throws {
        let clock = ManualClock()
        let front = SimulatedStoreFront(catalogue: catalogue, clock: clock)
        let logger = RecordingPurchaseLogger()
        let store = PurchaseStore(catalogue: catalogue, front: front, clock: clock, logger: logger)
        try await store.purchase(monthly)
        var ends = try #require(store.standing.subscription(in: group).current?.periodEnds)
        var lockedOut: [Int] = []
        for month in 1 ... 12 {
            clock.advance(to: ends)
            // Watched while it renews, not only once it has: a moment's lock-out is one.
            await waitUntil {
                let standing = store.standing.subscription(in: group)
                if standing.isActive != true { lockedOut.append(month) }
                return standing.current?.periodEnds ?? ends > ends
            }
            #expect(store.standing.subscription(in: group).isActive == true, "locked out at renewal \(month)")
            ends = try #require(store.standing.subscription(in: group).current?.periodEnds)
        }
        #expect(lockedOut.isEmpty)
        // Every read the store made, not only the ones a poll happened to see: a store that
        // published "not subscribed" and corrected it a read later is caught here.
        let reads = logger.events.compactMap { event -> Set<ProductID>? in
            if case let .standingResolved(owned) = event { owned } else { nil }
        }
        #expect(reads.count > 12)
        #expect(reads.allSatisfy { $0.contains(monthly) })
        #expect(ends == clock.now.addingTimeInterval(30 * 86_400))
    }
}

#endif
