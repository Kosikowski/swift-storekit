// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Synchronization
import Testing

/// A group with two plans at one level and one above them.
private enum Plans {
    static let group: SubscriptionGroupID = "21600001"
    static let monthly: ProductID = "com.example.pro.monthly"
    static let yearly: ProductID = "com.example.pro.yearly"
    static let premium: ProductID = "com.example.premium.monthly"

    static let catalogue: Catalogue = [
        .unlock(Shop.pro),
        .subscription(monthly, in: group, level: 2),
        .subscription(yearly, in: group, level: 2),
        .subscription(premium, in: group, level: 1),
    ]
}

/// Statuses as a test says them, and nothing more: no clock, no renewals.
private final class SaidStatuses: SubscriptionStatusReading {
    private let said: Mutex<[HeldSubscription]>

    init(_ statuses: HeldSubscription...) { said = Mutex(statuses) }

    func say(_ statuses: HeldSubscription...) { said.withLock { $0 = statuses } }

    func subscriptionStatuses(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: [HeldSubscription]] {
        let statuses = said.withLock { $0 }
        return Dictionary(uniqueKeysWithValues: groups.map { group in (group, statuses.filter { $0.group == group }) })
    }
}

/// The store against the simulated store and a clock that moves only when told to.
@MainActor
@Suite("Purchase store: subscriptions", .timeLimit(.minutes(1)))
struct PurchaseStoreSubscriptionTests {
    let clock = ManualClock(now: Shop.epoch)
    let front: SimulatedStoreFront
    let store: PurchaseStore

    init() {
        front = SimulatedStoreFront(catalogue: Plans.catalogue, clock: clock)
        store = PurchaseStore(catalogue: Plans.catalogue, front: front, clock: clock)
    }

    private var group: SubscriptionStanding { store.standing.subscription(in: Plans.group) }

    private func status(
        _ state: HeldSubscription.State = .subscribed, product: ProductID = Plans.monthly,
        ends: TimeInterval = 10 * 86_400, willRenew: Bool = true
    ) -> HeldSubscription {
        HeldSubscription(
            product: product, group: Plans.group, state: state, firstSubscribed: clock.now.addingTimeInterval(-40 * 86_400),
            periodStarted: clock.now.addingTimeInterval(ends - 30 * 86_400), periodEnds: clock.now.addingTimeInterval(ends),
            renewal: Renewal(willRenew: willRenew, nextProduct: willRenew ? product : nil))
    }

    // MARK: - At launch

    @Test("a subscriber is known as one at launch, by the status, and the plan held is subscribed")
    func subscriberAtLaunch() async {
        let current = status()
        front.seedSubscription(current)
        await store.start()
        #expect(group.isActive == true)
        #expect(store.standing.access(to: Plans.monthly) == .subscribed(current))
        #expect(store.standing.access(to: Plans.yearly) == .none)
    }

    @Test("billing retry is not access, and is said; a grace period is access though its period has ended")
    func retryAndGrace() async {
        front.seedSubscription(status(.inBillingRetry, ends: -3_600))
        await store.start()
        #expect(group.isActive == false)
        #expect(group.current?.state == .inBillingRetry)
        #expect(store.standing.access(to: Plans.monthly) == .none)

        let grace = status(.inGracePeriod(until: clock.now.addingTimeInterval(3 * 86_400)), ends: -3_600)
        front.changeSubscription(grace)
        #expect(await waitUntil { group.isActive == true })
        #expect(store.standing.access(to: Plans.monthly) == .subscribed(grace))
        #expect(store.standing.nextExpiry == clock.now.addingTimeInterval(3 * 86_400))
    }

    // MARK: - Buying

    /// Measured on the Mac: straight after `purchase()` neither the listing nor the status
    /// has the subscription. Read back then, Subscribe "did nothing".
    @Test("a subscription BOUGHT is subscribed at once, though neither the listing nor the status has it yet")
    func boughtIsSubscribed() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        let completion = try await store.purchase(Plans.monthly)
        guard case let .subscribed(held) = completion else {
            Issue.record("expected subscribed, got \(completion)")
            return
        }
        #expect(held.product == Plans.monthly)
        #expect(held.periodEnds == clock.now.addingTimeInterval(30 * 86_400))
        #expect(front.snapshot.listed.isEmpty)
        #expect(group.isActive == true)
    }

    /// Measured: a downgrade comes back from `purchase()` as a success with the plan
    /// already held. Taken at its word, it says the cheaper plan was bought.
    @Test("a DOWNGRADE is a plan change waiting for the renewal, and nothing changes until then")
    func downgrade() async throws {
        let premium = status(product: Plans.premium)
        front.seedSubscription(premium)
        await store.start()
        let completion = try await store.purchase(Plans.monthly)
        #expect(completion == .planChangeScheduled(to: Plans.monthly, at: premium.periodEnds))
        #expect(group.current?.product == Plans.premium)
        #expect(group.current?.renewal?.nextProduct == Plans.monthly)
    }

    @Test("a crossgrade at the same level likewise waits for the renewal")
    func crossgrade() async throws {
        front.seedSubscription(status(product: Plans.monthly))
        await store.start()
        let completion = try await store.purchase(Plans.yearly)
        guard case .planChangeScheduled(to: Plans.yearly, _) = completion else {
            Issue.record("expected a scheduled change, got \(completion)")
            return
        }
        #expect(group.current?.product == Plans.monthly)
    }

    @Test("an UPGRADE is at once: the higher plan is subscribed, keeping the first date")
    func upgrade() async throws {
        let monthly = status(product: Plans.monthly)
        front.seedSubscription(monthly)
        await store.start()
        let completion = try await store.purchase(Plans.premium)
        guard case let .subscribed(held) = completion else {
            Issue.record("expected subscribed, got \(completion)")
            return
        }
        #expect(held.product == Plans.premium)
        #expect(held.firstSubscribed == monthly.firstSubscribed)
        #expect(group.current?.product == Plans.premium)
        #expect(store.standing.access(to: Plans.monthly) == .none)
    }

    @Test("buying the plan already held hands it back, subscribed")
    func buyingWhatIsHeld() async throws {
        let monthly = status()
        front.seedSubscription(monthly)
        await store.start()
        #expect(try await store.purchase(Plans.monthly) == .subscribed(monthly))
    }

    // MARK: - Bought in Apple's views

    /// Measured in the iOS simulator: a purchase made in `SubscriptionStoreView` is never
    /// announced, and the store hears of it only at its next read. Buying on the front
    /// directly is what the view does: bought, listed late, and announced to nobody.
    @Test("a subscription bought in APPLE'S VIEW and handed over is subscribed at once, unlisted")
    func boughtInAppleView() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        let outcome = try await front.purchase(Plans.monthly, confirmation: .automatic)
        #expect(group.isActive == false)
        let completion = try await store.takePurchase(outcome, of: Plans.monthly)
        guard case let .subscribed(held) = completion else {
            Issue.record("expected subscribed, got \(completion)")
            return
        }
        #expect(held.product == Plans.monthly)
        #expect(front.snapshot.listed.isEmpty)
        #expect(group.isActive == true)
    }

    @Test("a downgrade in Apple's view, handed over, is a change of plan waiting for the renewal")
    func downgradeInAppleView() async throws {
        let premium = status(product: Plans.premium)
        front.seedSubscription(premium)
        await store.start()
        let outcome = try await front.purchase(Plans.monthly, confirmation: .automatic)
        #expect(try await store.takePurchase(outcome, of: Plans.monthly) == .planChangeScheduled(to: Plans.monthly, at: premium.periodEnds))
        #expect(group.current?.product == Plans.premium)
    }

    @Test("an Ask to Buy in Apple's view, handed over, is pending until approved")
    func askToBuyInAppleView() async throws {
        await store.start()
        #expect(try await store.takePurchase(.pending, of: Plans.monthly) == .pending)
        #expect(store.pendingApprovals == [Plans.monthly])
        #expect(try await store.takePurchase(.cancelled, of: Plans.yearly) == .cancelled)
        #expect(store.pendingApprovals == [Plans.monthly])
    }

    @Test("a subscription handed back ALREADY OVER in Apple's view bought nothing: a failure, as from purchase()")
    func handedBackInAppleView() async throws {
        await store.start()
        let over = OwnedProduct(
            id: Plans.monthly, originalPurchaseDate: clock.now.addingTimeInterval(-60 * 86_400),
            expirationDate: clock.now.addingTimeInterval(-30 * 86_400))
        await #expect(throws: PurchaseError.system) { try await store.takePurchase(.purchased(over), of: Plans.monthly) }
        #expect(group.isActive == false)
    }

    @Test("an Ask to Buy for a subscription stops being pending when the subscription is active")
    func askToBuy() async throws {
        front.behaviour.purchase = .pending
        await store.start()
        #expect(try await store.purchase(Plans.monthly) == .pending)
        #expect(store.pendingApprovals == [Plans.monthly])
        front.approvePending(Plans.monthly)
        #expect(await waitUntil { group.isActive == true })
        #expect(store.pendingApprovals.isEmpty)
    }

    /// Approved, a downgrade hands back the plan already held (measured) and waits for the
    /// renewal, so the plan asked for is not active for up to a whole period. Pending till
    /// then, "waiting for approval" stayed on screen long after the approval.
    @Test("an Ask to Buy for a downgrade stops being pending when it is approved, not at the renewal")
    func askToBuyDowngrade() async throws {
        front.seedSubscription(status(product: Plans.premium))
        front.behaviour.purchase = .pending
        await store.start()
        #expect(try await store.purchase(Plans.monthly) == .pending)
        #expect(store.pendingApprovals == [Plans.monthly])
        front.approvePending(Plans.monthly)
        #expect(await waitUntil { group.current?.renewal?.nextProduct == Plans.monthly })
        #expect(await waitUntil { store.pendingApprovals.isEmpty })
        #expect(store.pendingApprovals.isEmpty)
        #expect(group.current?.product == Plans.premium)
    }

    // MARK: - The moment at a renewal

    /// Measured: at every renewal, for up to 0.7 s on the Mac, the status says the
    /// subscription has expired — on iOS also that it will not renew — before the renewal
    /// arrives. A store that believed it would lock every subscriber at every renewal.
    @Test("at the period's end a renewing subscription SAYING it has expired keeps its access while the store looks again")
    func renewalMomentDoubted() async {
        let renewing = status(ends: 60)
        front.seedSubscription(renewing)
        await store.start()
        #expect(store.standing.nextExpiry == renewing.periodEnds)
        #expect(await waitUntil { clock.sleeperCount == 1 })

        // What the real store says in that moment: expired, will not renew, no reason.
        front.seedSubscription(status(.expired(.unstated), ends: 60, willRenew: false))
        clock.advance(by: .seconds(60))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        #expect(clock.deadlines == [clock.now.addingTimeInterval(2)])
        #expect(group.isActive == true)
        #expect(group.current == renewing)

        // The renewal arrives, as a transaction on the stream before the status has it.
        let renewal = OwnedProduct(
            id: Plans.monthly, originalPurchaseDate: renewing.firstSubscribed, purchaseDate: clock.now,
            expirationDate: clock.now.addingTimeInterval(30 * 86_400))
        front.deliver(renewal)
        #expect(await waitUntil { group.current?.periodEnds == renewal.expirationDate })
        #expect(group.isActive == true)
    }

    @Test("a lapse that LASTS past renewalGrace is believed, and the doubting look was what found it")
    func lastingLapseBelieved() async {
        front.seedSubscription(status(ends: 60))
        await store.start()
        #expect(await waitUntil { clock.sleeperCount == 1 })
        front.seedSubscription(status(.expired(.unstated), ends: 60, willRenew: false))
        clock.advance(by: .seconds(60))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        #expect(group.isActive == true)

        // Nothing is announced: only the store's own looks can find the lapse.
        clock.advance(by: .seconds(30))
        #expect(await waitUntil { group.isActive == false })
        #expect(group.current?.state == .expired(.unstated))
        #expect(store.standing.access(to: Plans.monthly) == .none)
    }

    @Test("a subscription CANCELLED before its end lapses at its end, at once")
    func cancelledLapsesAtOnce() async {
        front.seedSubscription(status(ends: 60, willRenew: false))
        await store.start()
        #expect(await waitUntil { clock.sleeperCount == 1 })
        front.seedSubscription(status(.expired(.autoRenewDisabled), ends: 60, willRenew: false))
        clock.advance(by: .seconds(60))
        #expect(await waitUntil { group.isActive == false })
        #expect(group.current?.state == .expired(.autoRenewDisabled))
    }

    /// Measured: renewals missed while nothing ran arrive at the next launch newest first,
    /// the oldest last. The oldest, held, would be a period long over — and where no
    /// status has anything newer to say, nothing else would stop it being believed.
    @Test("a renewal that arrives with its period ALREADY OVER is not held")
    func staleRenewalNotHeld() async {
        let logger = RecordingPurchaseLogger()
        let store = PurchaseStore(catalogue: Plans.catalogue, front: front, clock: clock, logger: logger)
        // Before the listing has it: the moment a hold is for.
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        front.deliver(OwnedProduct(
            id: Plans.monthly, originalPurchaseDate: clock.now.addingTimeInterval(-90 * 86_400),
            purchaseDate: clock.now.addingTimeInterval(-61 * 86_400), expirationDate: clock.now.addingTimeInterval(-31 * 86_400)))
        #expect(await waitUntil { logger.events.contains(.transactionUpdated(Plans.monthly)) })
        await store.refresh()
        #expect(store.standing.subscription(in: Plans.group).isActive == false)
    }

    /// A doubted lapse leaves the standing as it was, so it is not republished and its next
    /// expiry is a moment already gone. A look scheduled for that moment woke at once, and
    /// again, for ever.
    @Test("a lapse being doubted does not make the store read over and over")
    func doubtDoesNotSpin() async {
        let logger = RecordingPurchaseLogger()
        let store = PurchaseStore(catalogue: Plans.catalogue, front: front, clock: clock, logger: logger)
        front.seedSubscription(status(ends: 60))
        await store.start()
        #expect(await waitUntil { clock.sleeperCount == 1 })
        front.seedSubscription(status(.expired(.unstated), ends: 60, willRenew: false))
        clock.advance(by: .seconds(60))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        #expect(clock.deadlines.allSatisfy { $0 > clock.now })
        let reads = logger.events.filter { if case .standingResolved = $0 { true } else { false } }.count
        #expect(reads == 2)
        #expect(store.standing.subscription(in: Plans.group).isActive == true)
    }

    /// Measured in the iOS simulator: a renewal in billing retry arrives as a transaction of
    /// its own, while the status says billing retry. The status decides.
    @Test("a renewal transaction whose status says BILLING RETRY does not grant access")
    func renewalInRetry() async {
        front.seedSubscription(status(ends: 60))
        await store.start()
        clock.advance(by: .seconds(60))
        let renewal = OwnedProduct(
            id: Plans.monthly, originalPurchaseDate: clock.now.addingTimeInterval(-40 * 86_400), purchaseDate: clock.now,
            expirationDate: clock.now.addingTimeInterval(30 * 86_400))
        front.deliver(renewal)
        let retrying = HeldSubscription(
            product: Plans.monthly, group: Plans.group, state: .inBillingRetry, firstSubscribed: renewal.originalPurchaseDate,
            periodStarted: renewal.purchaseDate, periodEnds: renewal.expirationDate!,
            renewal: Renewal(willRenew: true, nextProduct: Plans.monthly))
        front.changeSubscription(retrying)
        #expect(await waitUntil { group.isActive == false })
        #expect(group.current?.state == .inBillingRetry)
    }

    /// Nothing is announced when a subscription the store still called subscribed at its
    /// end lapses later: only a look of the store's own can find it.
    ///
    /// The status is said by the test, not the simulated store, which renews what it holds
    /// by its clock: "subscribed" after the end is a renewal the store has not synced.
    @Test("still said to be subscribed after its end, a subscription is looked at again a minute later")
    func staleSubscribedLookedAtAgain() async {
        let said = SaidStatuses(status(ends: 60))
        let store = PurchaseStore(
            catalogue: Plans.catalogue, catalogueLoader: front, ownership: front, purchaser: front,
            restorer: front, observer: front, subscriptionStatuses: said, clock: clock)
        let group = { store.standing.subscription(in: Plans.group) }
        await store.start()
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(61))
        #expect(await waitUntil { clock.sleeperCount == 1 && group().current?.accessEnds ?? .distantFuture <= clock.now })
        #expect(group().isActive == true)
        said.say(status(.expired(.autoRenewDisabled), ends: -1, willRenew: false))
        clock.advance(by: .seconds(60))
        #expect(await waitUntil { group().isActive == false })
        #expect(group().isActive == false)
    }

    /// On the Mac the listing and the status are both empty for about 0.6 s after a purchase
    /// (measured), and nothing says which catches up first. With the listing first, the hold
    /// used to go the moment the listing had it — and the status, still empty, said "never
    /// subscribed" to someone who had just paid (D36).
    @Test("a subscription bought is not lost in the moment the listing has it and its STATUS DOES NOT YET")
    func statusLaggingTheListing() async throws {
        let logger = RecordingPurchaseLogger()
        let store = PurchaseStore(catalogue: Plans.catalogue, front: front, clock: clock, logger: logger)
        front.behaviour.saysStatusAfterReads = 2
        await store.start()
        try await store.purchase(Plans.monthly)
        let bought = logger.events.count
        for _ in 0 ..< 5 { await store.refresh() }
        #expect(front.snapshot.listed.map(\.id) == [Plans.monthly])
        let reads = logger.events.dropFirst(bought).compactMap { event -> Set<ProductID>? in
            if case let .standingResolved(owned) = event { owned } else { nil }
        }
        #expect(reads.count >= 5)
        #expect(reads.allSatisfy { $0.contains(Plans.monthly) }, "a read granted nothing: \(reads)")
        #expect(store.standing.subscription(in: Plans.group).current?.renewal != nil)
    }
}

#endif
