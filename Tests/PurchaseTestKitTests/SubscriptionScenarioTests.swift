// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

private let pro: ProductID = "com.example.pro"
private let group: SubscriptionGroupID = "21900001"
private let monthly: ProductID = "com.example.pro.monthly"
private let yearly: ProductID = "com.example.pro.yearly"
private let premium: ProductID = "com.example.premium"
private let catalogue: Catalogue = [
    .unlock(pro),
    .subscription(monthly, in: group, level: 2),
    .subscription(yearly, in: group, level: 2),
    .subscription(premium, in: group, level: 1),
]

private func parse(_ text: String) throws(ScenarioError) -> Scenario {
    try Scenario(parsing: text, catalogue: catalogue)
}

@Suite("Scenario: subscriptions", .timeLimit(.minutes(1)))
struct SubscriptionScenarioTests {
    typealias Fault = ScenarioError.ScenarioFault

    @Test("a period of no length is refused: it would renew for ever")
    func periodOfNoLength() {
        #expect(throws: ScenarioError.invalidScenario(clause: "period=0s", reason: .invalidAge("0s"))) { try parse("period=0s") }
        #expect(throws: ScenarioError.invalidScenario(clause: "period=0d0h", reason: .invalidAge("0d0h"))) { try parse("period=0d0h") }
    }

    @Test("each subscription clause holds its products in its state, with an age and an ownership")
    func clauses() throws {
        let scenario = try parse("subscribed=monthly@10d/family; grace=yearly@2d; lapsed=premium@40d")
        #expect(scenario.subscriptions == [
            .init(monthly, .subscribed, age: .seconds(10 * 86_400), ownership: .familyShared),
            .init(yearly, .inGracePeriod, age: .seconds(2 * 86_400)),
            .init(premium, .lapsed, age: .seconds(40 * 86_400)),
        ])
        #expect(try parse("cancelled=monthly").subscriptions == [.init(monthly, .cancelled)])
        #expect(try parse("retry=monthly@1h").subscriptions == [.init(monthly, .inBillingRetry, age: .seconds(3_600))])
    }

    @Test("the period, and what a renewal comes to, are behaviour")
    func behaviour() throws {
        #expect(try parse("period=30s").behaviour.subscriptionPeriod == .seconds(30))
        #expect(try parse("renewal=renews").behaviour.renewal == .renews)
        let failing = try parse("renewal=fails").behaviour
        #expect(failing.renewal == .fails)
        #expect(failing.gracePeriod == nil)
        let graced = try parse("renewal=fails:16d").behaviour
        #expect(graced.renewal == .fails)
        #expect(graced.gracePeriod == .seconds(16 * 86_400))
    }

    @Test("offers: an introductory offer eligible or used, win-back and promotional offers by identifier, and signatures")
    func offers() throws {
        #expect(try parse("intro=eligible").introductoryOffer == .eligible)
        #expect(try parse("intro=used").introductoryOffer == .used)
        #expect(try parse("winback=come-back, come_back.long").winBackOffers == ["come-back", "come_back.long"])
        #expect(try parse("promo=returning").promotionalOffers == ["returning"])
        #expect(try parse("signatures=rejected").behaviour.acceptsOfferSignatures == false)
        #expect(try parse("signatures=accepted").behaviour.acceptsOfferSignatures == true)
        #expect(try parse("").introductoryOffer == nil)
    }

    @Test("a slip is an error naming its clause", arguments: [
        ("subscribed=pro", "subscribed=pro", Fault.notASubscription(pro)),
        ("owns=monthly", "owns=monthly", .subscriptionHeldAsPurchase(monthly)),
        ("subscribed=monthly; grace=monthly", "grace=monthly", .repeatedProduct(monthly)),
        ("renewal=maybe", "renewal=maybe", .unknownValue("maybe")),
        ("renewal=fails:soon", "renewal=fails:soon", .invalidAge("soon")),
        ("period=monthly", "period=monthly", .invalidAge("monthly")),
        ("intro=maybe", "intro=maybe", .unknownValue("maybe")),
        ("winback=a,,b", "winback=a,,b", .invalidOffer("")),
        ("winback=a b", "winback=a b", .invalidOffer("a b")),
        ("promo=x,x", "promo=x,x", .repeatedOffer("x")),
        ("signatures=sometimes", "signatures=sometimes", .unknownValue("sometimes")),
    ])
    func slips(text: String, clause: String, fault: Fault) {
        #expect(throws: ScenarioError.invalidScenario(clause: clause, reason: fault)) { try parse(text) }
    }

    @Test("every new fault is said in words")
    func words() {
        #expect(Fault.notASubscription(pro).description.contains("not a subscription"))
        #expect(Fault.subscriptionHeldAsPurchase(monthly).description.contains("subscribed="))
        #expect(Fault.invalidOffer("a b").description.contains("not an offer identifier"))
        #expect(Fault.repeatedOffer("x").description.contains("more than once"))
    }

    // MARK: - Applied

    @Test("applied, each state is a status by the store's clock, and only the entitled are listed")
    func applied() async throws {
        let clock = ManualClock()
        let store = SimulatedStoreFront(catalogue: catalogue, clock: clock)
        store.apply(try parse("period=30d; subscribed=monthly@10d; grace=yearly@2d; lapsed=premium@40d"))
        let statuses = await store.subscriptionStatuses(in: [group])[group] ?? []
        let byProduct = Dictionary(uniqueKeysWithValues: statuses.map { ($0.product, $0) })
        let day: TimeInterval = 86_400

        let subscribed = try #require(byProduct[monthly])
        #expect(subscribed.state == .subscribed)
        #expect(subscribed.periodStarted == clock.now.addingTimeInterval(-10 * day))
        #expect(subscribed.periodEnds == clock.now.addingTimeInterval(20 * day))
        #expect(subscribed.renewal?.willRenew == true)

        let grace = try #require(byProduct[yearly])
        #expect(grace.periodEnds == clock.now.addingTimeInterval(-2 * day))
        #expect(grace.state == .inGracePeriod(until: clock.now.addingTimeInterval(14 * day)))

        let lapsed = try #require(byProduct[premium])
        #expect(lapsed.state == .expired(.autoRenewDisabled))
        #expect(lapsed.periodEnds == clock.now.addingTimeInterval(-40 * day))

        #expect(Set(await store.ownedProducts().map(\.id)) == [monthly, yearly])
    }

    @Test("cancelled is subscribed and not renewing; retry is not listed")
    func cancelledAndRetry() async throws {
        let store = SimulatedStoreFront(catalogue: catalogue, clock: ManualClock())
        store.apply(try parse("cancelled=monthly@1d; retry=premium@1d"))
        let statuses = await store.subscriptionStatuses(in: [group])[group] ?? []
        #expect(statuses.first { $0.product == monthly }?.renewal?.willRenew == false)
        #expect(statuses.first { $0.product == monthly }?.state == .subscribed)
        #expect(statuses.first { $0.product == premium }?.state == .inBillingRetry)
        #expect(await store.ownedProducts().map(\.id) == [monthly])
    }

    @Test("applied, offers go on every subscription with plausible terms; a lapse makes the win-back ones eligible")
    func appliedOffers() async throws {
        let store = SimulatedStoreFront(catalogue: catalogue, clock: ManualClock())
        store.apply(try parse("intro=used; winback=come-back; promo=returning; lapsed=monthly@40d"))
        let monthlyTerms = try #require(store.productsOnSale.first { $0.id == monthly }?.subscription)
        #expect(monthlyTerms.introductoryOffer?.paymentMode == .freeTrial)
        #expect(monthlyTerms.winBackOffers.map(\.id) == ["come-back"])
        #expect(monthlyTerms.promotionalOffers.map(\.id) == ["returning"])
        #expect(store.productsOnSale.first { $0.id == pro }?.subscription == nil)
        #expect(await store.introductoryEligibility(in: [group]) == [group: false])
        let lapsed = await store.subscriptionStatuses(in: [group])[group]?.first { $0.product == monthly }
        #expect(lapsed?.renewal?.winBackOffers == ["come-back"])
    }

    @Test("a lapsed member offered a win-back, the whole way, through PurchaseStore")
    @MainActor
    func winBackThroughTheStore() async throws {
        let clock = ManualClock()
        let store = SimulatedStoreFront(catalogue: catalogue, clock: clock)
        store.apply(try parse("winback=come-back; lapsed=monthly@40d"))
        let purchases = PurchaseStore(catalogue: catalogue, front: store, clock: clock)
        await purchases.start()
        await purchases.loadProducts()
        #expect(purchases.winBackOffers(in: group).map(\.id) == ["come-back"])
        #expect(try await purchases.purchase(monthly, options: PurchaseOptions(offer: .winBack("come-back"))) != .cancelled)
        #expect(purchases.standing.subscription(in: group).current?.offer?.kind == .winBack)
    }

    @Test("a store launched subscribed is known as one: the whole way, through PurchaseStore")
    @MainActor
    func throughTheStore() async throws {
        let clock = ManualClock()
        let store = SimulatedStoreFront(catalogue: catalogue, clock: clock)
        store.apply(try parse("subscribed=monthly@3d"))
        let purchases = PurchaseStore(catalogue: catalogue, front: store, clock: clock)
        await purchases.start()
        #expect(purchases.standing.subscription(in: group).isActive == true)
        #expect(purchases.standing.access(to: monthly).isGranted == true)
    }
}

#endif
