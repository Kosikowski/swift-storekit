// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

/// A yearly plan with a monthly billing plan and a 12-month commitment, and a monthly plan
/// with none.
private enum Plans {
    static let group: SubscriptionGroupID = "21700009"
    static let yearly: ProductID = "com.example.pro.yearly"
    static let monthly: ProductID = "com.example.pro.monthly"

    static let catalogue: Catalogue = [
        .subscription(yearly, in: group, level: 1),
        .subscription(monthly, in: group, level: 1),
    ]

    static let products: [StoreProduct] = [
        StoreProduct(
            id: yearly, displayName: "Yearly", displayPrice: "£149.99", price: 149.99,
            subscription: StoreProduct.Subscription(
                group: group, period: .years(1),
                billingPlans: [
                    BillingPlanTerms(
                        plan: .upFront, billingDisplayPrice: "£149.99", billingPrice: 149.99, billingPeriod: .years(1),
                        commitmentDisplayPrice: "£149.99", commitmentPrice: 149.99, commitmentPeriod: .years(1)),
                    BillingPlanTerms(
                        plan: .monthly, billingDisplayPrice: "£14.99", billingPrice: 14.99, billingPeriod: .months(1),
                        commitmentDisplayPrice: "£179.88", commitmentPrice: 179.88, commitmentPeriod: .years(1)),
                ])),
        StoreProduct(
            id: monthly, displayName: "Monthly", displayPrice: "£15.99", price: 15.99,
            subscription: StoreProduct.Subscription(group: group, period: .months(1))),
    ]
}

@MainActor
@Suite("Purchase store: monthly billing with a 12-month commitment", .timeLimit(.minutes(1)))
struct PurchaseStoreCommitmentTests {
    let clock = ManualClock(now: Shop.epoch)
    let front: SimulatedStoreFront
    let store: PurchaseStore
    private let month: TimeInterval = 30 * 86_400

    init() {
        front = SimulatedStoreFront(catalogue: Plans.catalogue, products: Plans.products, clock: clock)
        front.behaviour.showsTheRenewalMoment = false
        store = PurchaseStore(catalogue: Plans.catalogue, front: front, clock: clock)
    }

    private var current: HeldSubscription? { store.standing.subscription(in: Plans.group).current }

    @Test("bought on the monthly plan, it is month 1 of 12, and the commitment will renew")
    func bought() async throws {
        await store.start()
        guard case let .subscribed(held) = try await store.purchase(Plans.yearly, options: PurchaseOptions(billingPlan: .monthly)) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(front.lastPurchaseOptions?.billingPlan == .monthly)
        #expect(held.periodEnds == Shop.epoch.addingTimeInterval(month))
        front.listUnlisted()
        await store.refresh()
        let commitment = try #require(current?.commitment)
        #expect(commitment.plan == .monthly)
        #expect(commitment.billingPeriod == 1)
        #expect(commitment.billingPeriods == 12)
        #expect(commitment.endsAt == Shop.epoch.addingTimeInterval(12 * month))
        #expect(commitment.price == Decimal(string: "179.88"))
        #expect(current?.renewal?.commitment?.willRenew == true)
    }

    /// Apple's trap: cancelled during a commitment, `willAutoRenew` stays true — the monthly
    /// billing goes on — and only the commitment's own renewal says it ends.
    @Test("CANCELLED during the commitment, the months are still billed; only the commitment says it ends, and then it lapses")
    func cancelled() async throws {
        await store.start()
        try await store.purchase(Plans.yearly, options: PurchaseOptions(billingPlan: .monthly))
        front.listUnlisted()
        await store.refresh()
        front.cancelAutoRenew(Plans.yearly)
        #expect(await waitUntil { current?.renewal?.commitment?.willRenew == false })
        #expect(current?.renewal?.willRenew == true)

        clock.advance(by: .seconds(Int64(11 * month)))
        #expect(await waitUntil { current?.commitment?.billingPeriod == 12 })
        #expect(store.standing.subscription(in: Plans.group).isActive == true)
        clock.advance(to: Shop.epoch.addingTimeInterval(12 * month))
        #expect(await waitUntil { store.standing.subscription(in: Plans.group).isActive == false })
        #expect(current?.state == .expired(.autoRenewDisabled))
    }

    @Test("cancelled, it lapses at the commitment's end however far the clock jumps past it")
    func cancelledThenAYearOn() async throws {
        await store.start()
        try await store.purchase(Plans.yearly, options: PurchaseOptions(billingPlan: .monthly))
        front.listUnlisted()
        await store.refresh()
        front.cancelAutoRenew(Plans.yearly)
        #expect(await waitUntil { current?.renewal?.commitment?.willRenew == false })
        clock.advance(by: .seconds(Int64(13 * month)))
        #expect(await waitUntil { store.standing.subscription(in: Plans.group).isActive == false })
        #expect(current?.state == .expired(.autoRenewDisabled))
        #expect(current?.periodEnds == Shop.epoch.addingTimeInterval(12 * month))
    }

    /// The months go on renewing after a cancellation, so each renewal's moment is doubted as
    /// any renewal's is (D36): only the last month's end is believed.
    @Test("CANCELLED during the commitment, a month's renewal is never taken for the end: no read locks the subscriber out")
    func cancelledMonthRenews() async throws {
        let front = SimulatedStoreFront(catalogue: Plans.catalogue, products: Plans.products, clock: clock)
        let logger = RecordingPurchaseLogger()
        let store = PurchaseStore(catalogue: Plans.catalogue, front: front, clock: clock, logger: logger)
        let group = { store.standing.subscription(in: Plans.group) }
        await store.start()
        try await store.purchase(Plans.yearly, options: PurchaseOptions(billingPlan: .monthly))
        front.listUnlisted()
        await store.refresh()
        front.cancelAutoRenew(Plans.yearly)
        #expect(await waitUntil { group().current?.renewal?.commitment?.willRenew == false })
        let ends = try #require(group().current?.periodEnds)
        let from = logger.events.count
        clock.advance(to: ends)
        #expect(await waitUntil { (group().current?.periodEnds ?? ends) > ends })
        let reads = logger.events.dropFirst(from).compactMap { event -> Set<ProductID>? in
            if case let .standingResolved(owned) = event { owned } else { nil }
        }
        #expect(!reads.isEmpty)
        #expect(reads.allSatisfy { $0.contains(Plans.yearly) })
    }

    @Test("a plan the product does not have is refused as unsupported, and nothing is bought")
    func planNotOffered() async {
        await store.start()
        await #expect(throws: PurchaseError.unsupported) {
            try await store.purchase(Plans.monthly, options: PurchaseOptions(billingPlan: .monthly))
        }
        #expect(store.standing.subscription(in: Plans.group).isActive == false)
    }

    @Test("a monthly plan's terms are the store's, beside the up-front one")
    func terms() async {
        await store.loadProducts()
        let plans = store.products.first { $0.id == Plans.yearly }?.subscription?.billingPlans ?? []
        #expect(plans.map(\.plan) == [.upFront, .monthly])
        #expect(plans.last?.billingDisplayPrice == "£14.99")
        #expect(plans.last?.commitmentDisplayPrice == "£179.88")
    }
}

#endif
