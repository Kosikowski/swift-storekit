// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

private let group: SubscriptionGroupID = "21900002"
private let monthly: ProductID = "com.example.pro.monthly"
private let yearly: ProductID = "com.example.pro.yearly"
private let premium: ProductID = "com.example.premium.monthly"
private let season: ProductID = "com.example.season"
private let catalogue: Catalogue = [
    .subscription(monthly, in: group, level: 2),
    .subscription(yearly, in: group, level: 2),
    .subscription(premium, in: group, level: 1),
    .nonRenewing(season, lasting: .seconds(30 * 86_400)),
]

private let introductory = OfferTerms(
    kind: .introductory, paymentMode: .payAsYouGo, period: .months(1), periodCount: 2, displayPrice: "10.99", price: 10.99)
private let winBack = OfferTerms(
    kind: .winBack, id: "winback", paymentMode: .payAsYouGo, period: .months(1), periodCount: 1, displayPrice: "9.99", price: 9.99)
private let planTrial = OfferTerms(
    kind: .introductory, paymentMode: .freeTrial, period: .weeks(1), periodCount: 1, displayPrice: "0.00", price: 0)
private let planPromotion = OfferTerms(
    kind: .promotional, id: "plan.promo", paymentMode: .payAsYouGo, period: .months(1), periodCount: 3, displayPrice: "9.99",
    price: 9.99)
private let products: [StoreProduct] = [
    StoreProduct(
        id: monthly, displayName: "Monthly", displayPrice: "15.99", price: 15.99,
        subscription: .init(group: group, period: .months(1), introductoryOffer: introductory, winBackOffers: [winBack])),
    StoreProduct(
        id: yearly, displayName: "Yearly", displayPrice: "149.99", price: 149.99,
        subscription: .init(
            group: group, period: .years(1),
            billingPlans: [
                BillingPlanTerms(
                    plan: .monthly, billingDisplayPrice: "14.99", billingPrice: 14.99, billingPeriod: .months(1),
                    commitmentDisplayPrice: "179.88", commitmentPrice: 179.88, commitmentPeriod: .years(1),
                    offers: [planTrial, planPromotion]),
            ])),
    StoreProduct(
        id: premium, displayName: "Premium", displayPrice: "25.99", price: 25.99,
        subscription: .init(group: group, period: .months(1))),
    StoreProduct(id: season, displayName: "Season", displayPrice: "4.99", price: 4.99),
]

@Suite("Simulated store: a subscription's life", .timeLimit(.minutes(1)))
struct SimulatedSubscriptionLifeTests {
    private let clock = ManualClock()
    private let period: TimeInterval = 60
    private let day: TimeInterval = 86_400

    private func store(_ configure: (inout SimulatedStoreFront.Behaviour) -> Void = { _ in }) -> SimulatedStoreFront {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.subscriptionPeriod = .seconds(period)
        behaviour.listsPurchasesAfterReads = 0
        behaviour.showsTheRenewalMoment = false
        configure(&behaviour)
        return SimulatedStoreFront(catalogue: catalogue, products: products, clock: clock, behaviour: behaviour)
    }

    private func own(_ product: ProductID, in store: SimulatedStoreFront) async -> HeldSubscription? {
        await store.subscriptionStatuses(in: [group])[group]?.first { $0.product == product && $0.ownership == .purchased }
    }

    private func onTheMonthlyPlan(_ store: SimulatedStoreFront) async throws {
        _ = try await store.purchase(yearly, options: PurchaseOptions(billingPlan: .monthly), confirmation: .automatic)
    }

    // MARK: - Commitments

    @Test("a cancelled commitment LAPSES at its end, however far the clock jumps past it")
    func commitmentCancelledJump() async throws {
        let store = store()
        let start = clock.now
        try await onTheMonthlyPlan(store)
        store.cancelAutoRenew(yearly)
        clock.advance(by: .seconds(15 * period))
        let held = try #require(await own(yearly, in: store))
        #expect(held.state == .expired(.autoRenewDisabled))
        #expect(held.commitment?.billingPeriod == 12)
        #expect(held.periodEnds == start.addingTimeInterval(12 * period))
    }

    @Test("a commitment that renews begins again at month one, from where the last ended")
    func commitmentRenews() async throws {
        let store = store()
        let start = clock.now
        try await onTheMonthlyPlan(store)
        clock.advance(by: .seconds(12 * period))
        let held = try #require(await own(yearly, in: store))
        #expect(held.state == .subscribed)
        #expect(held.commitment?.billingPeriod == 1)
        #expect(held.commitment?.endsAt == start.addingTimeInterval(24 * period))
        #expect(held.renewal?.commitment?.willRenew == true)
    }

    @Test("a commitment's failed charge has no grace period, and is retried for 90 days")
    func commitmentRetried() async throws {
        let store = store {
            $0.renewal = .fails
            $0.gracePeriod = .seconds(16 * 86_400)
        }
        try await onTheMonthlyPlan(store)
        let ends = clock.now.addingTimeInterval(period)
        clock.advance(to: ends)
        #expect(await own(yearly, in: store)?.state == .inBillingRetry)
        clock.advance(to: ends.addingTimeInterval(89 * day))
        #expect(await own(yearly, in: store)?.state == .inBillingRetry)
        clock.advance(to: ends.addingTimeInterval(90 * day))
        #expect(await own(yearly, in: store)?.state == .expired(.billingError))
    }

    // MARK: - Renewing now

    @Test("renewed now, a commitment moves on a month and a cancellation stays cancelled")
    func renewNowCommitment() async throws {
        let store = store()
        try await onTheMonthlyPlan(store)
        store.cancelAutoRenew(yearly)
        store.renewNow(yearly)
        let held = try #require(await own(yearly, in: store))
        #expect(held.commitment?.billingPeriod == 2)
        #expect(held.renewal?.commitment?.willRenew == false)
        #expect(held.renewal?.willRenew == true)
    }

    @Test("renewed now, a plan change waiting for the renewal takes effect, and auto-renew switched off stays off")
    func renewNowWaiting() async throws {
        let store = store()
        _ = try await store.purchase(premium, confirmation: .automatic)
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.renewNow(premium)
        #expect(await own(monthly, in: store)?.state == .subscribed)
        store.cancelAutoRenew(monthly)
        store.renewNow(monthly)
        #expect(await own(monthly, in: store)?.renewal?.willRenew == false)
    }

    // MARK: - What a status keeps

    @Test("renewed, a bundle membership is kept, and the transaction is a new one")
    func renewalKeeps() async throws {
        let store = store()
        let bundle = BundleMembership(product: "com.example.bundle", group: "21900009", willLeave: false)
        store.seedSubscription(
            HeldSubscription(
                product: monthly, group: group, state: .subscribed, firstSubscribed: clock.now, periodStarted: clock.now,
                periodEnds: clock.now.addingTimeInterval(period), renewal: Renewal(willRenew: true, nextProduct: monthly),
                transactionID: 7, bundle: bundle))
        clock.advance(by: .seconds(period))
        let held = try #require(await own(monthly, in: store))
        #expect(held.bundle == bundle)
        #expect(held.transactionID != nil)
        #expect(held.transactionID != 7)
        store.lapse(monthly)
        let lapsed = try #require(await own(monthly, in: store))
        #expect(lapsed.bundle == bundle)
        #expect(lapsed.transactionID == held.transactionID)
    }

    @Test("switched off, a price rise awaiting consent is still awaiting it; a commitment cancelled stays so across a change of plan")
    func controlsKeep() async throws {
        let store = store()
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.raisePrice(monthly, needsConsent: true)
        store.cancelAutoRenew(monthly)
        #expect(await own(monthly, in: store)?.renewal?.priceIncrease == .awaitingConsent)

        let other = self.store()
        try await onTheMonthlyPlan(other)
        other.cancelAutoRenew(yearly)
        _ = try await other.purchase(monthly, confirmation: .automatic)
        let held = try #require(await own(yearly, in: other))
        #expect(held.renewal?.nextProduct == monthly)
        #expect(held.renewal?.commitment?.willRenew == false)
    }

    @Test("switched off and back on, a plan change waiting for the renewal is still waiting")
    func resumeKeepsTheChange() async throws {
        let store = store()
        _ = try await store.purchase(premium, confirmation: .automatic)
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.cancelAutoRenew(premium)
        store.resumeAutoRenew(premium)
        #expect(await own(premium, in: store)?.renewal?.nextProduct == monthly)
    }

    @Test("a subscription that is over is left as it is: no auto-renew to switch, and its win-back offers kept")
    func overIsOver() async throws {
        let store = store()
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.lapse(monthly)
        let lapsed = try #require(await own(monthly, in: store))
        #expect(lapsed.renewal?.winBackOffers == ["winback"])
        store.resumeAutoRenew(monthly)
        #expect(await own(monthly, in: store) == lapsed)
        store.raisePrice(monthly, needsConsent: true)
        #expect(await own(monthly, in: store) == lapsed)
    }

    @Test("switched off at the renewal moment, the renewal already made stands, and will not renew again")
    func cancelledAtTheMoment() async throws {
        let store = store { $0.showsTheRenewalMoment = true }
        _ = try await store.purchase(monthly, confirmation: .automatic)
        clock.advance(by: .seconds(period))
        #expect(await own(monthly, in: store)?.state == .expired(.unstated))
        store.cancelAutoRenew(monthly)
        let held = try #require(await own(monthly, in: store))
        #expect(held.state == .subscribed)
        #expect(held.periodEnds == clock.now.addingTimeInterval(period))
        #expect(held.renewal?.willRenew == false)
        #expect(await store.ownedProducts().map(\.id) == [monthly])
    }

    // MARK: - Renewals

    @Test("a price rise NOT AGREED lapses at the end of the period; one agreed renews")
    func priceRise() async throws {
        let store = store()
        _ = try await store.purchase(monthly, confirmation: .automatic)
        _ = try await store.purchase(premium, confirmation: .automatic)
        store.raisePrice(premium, needsConsent: true)
        clock.advance(by: .seconds(period))
        #expect(await own(premium, in: store)?.state == .expired(.didNotConsentToPriceIncrease))

        let agreed = self.store()
        _ = try await agreed.purchase(premium, confirmation: .automatic)
        agreed.raisePrice(premium, needsConsent: false)
        clock.advance(by: .seconds(period))
        #expect(await own(premium, in: agreed)?.state == .subscribed)
    }

    @Test("an introductory offer paid as you go runs for as many periods as it says, and then the price is the regular one")
    func introductoryPeriods() async throws {
        let store = store()
        _ = try await store.purchase(monthly, confirmation: .automatic)
        #expect(await own(monthly, in: store)?.offer?.kind == .introductory)
        clock.advance(by: .seconds(period))
        #expect(await own(monthly, in: store)?.offer?.kind == .introductory)
        clock.advance(by: .seconds(period))
        #expect(await own(monthly, in: store)?.offer == nil)
    }

    // MARK: - Buying

    @Test("bought again after a lapse nobody has read yet, it is a new subscription, and still the one first subscribed")
    func boughtAfterUnreadLapse() async throws {
        let store = store()
        let first = clock.now
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.cancelAutoRenew(monthly)
        clock.advance(by: .seconds(period + 1))
        guard case let .purchased(owned) = try await store.purchase(monthly, confirmation: .automatic) else {
            Issue.record("expected a purchase")
            return
        }
        #expect(owned.expirationDate == clock.now.addingTimeInterval(period))
        #expect(owned.originalPurchaseDate == first)
    }

    @Test("a plan's own offers are the ones a purchase on it has; without the plan they are not the product's")
    func planOffers() async throws {
        let store = store()
        guard case let .purchased(owned) = try await store.purchase(
            yearly, options: PurchaseOptions(billingPlan: .monthly), confirmation: .automatic)
        else {
            Issue.record("expected a purchase")
            return
        }
        #expect(owned.offer == AppliedOffer(kind: .introductory, paymentMode: .freeTrial))
        store.lapse(yearly)
        var promotional = PurchaseOptions(offer: .promotional("plan.promo"))
        promotional.signature = "signed"
        await #expect(throws: PurchaseError.offerRefused(.unknownOffer)) {
            try await store.purchase(yearly, options: promotional, confirmation: .automatic)
        }
        var onThePlan = PurchaseOptions(offer: .promotional("plan.promo"), billingPlan: .monthly)
        onThePlan.signature = "signed"
        guard case let .purchased(again) = try await store.purchase(yearly, options: onThePlan, confirmation: .automatic) else {
            Issue.record("expected a purchase")
            return
        }
        #expect(again.offer?.id == "plan.promo")
    }

    @Test("Ask to Buy is refused as a purchase would be, and approved, buys what was asked for")
    func askToBuy() async throws {
        let store = store { $0.purchase = .pending }
        await #expect(throws: PurchaseError.offerRefused(.unknownOffer)) {
            try await store.purchase(monthly, options: PurchaseOptions(offer: .winBack("none")), confirmation: .automatic)
        }
        await #expect(throws: PurchaseError.unsupported) {
            try await store.purchase(monthly, options: PurchaseOptions(billingPlan: .monthly), confirmation: .automatic)
        }
        #expect(store.snapshot.pending.isEmpty)
        #expect(try await store.purchase(yearly, options: PurchaseOptions(billingPlan: .monthly), confirmation: .automatic) == .pending)
        #expect(store.approvePending(yearly))
        #expect(await own(yearly, in: store)?.commitment?.billingPeriod == 1)
    }

    @Test("a non-renewing subscription bought twice at one instant is two purchases, and a refund takes one")
    func sameInstant() async throws {
        let store = store()
        _ = try await store.purchase(season, confirmation: .automatic)
        _ = try await store.purchase(season, confirmation: .automatic)
        let bought = store.snapshot.listed.filter { $0.id == season }
        #expect(bought.count == 2)
        #expect(Set(bought.map(\.purchaseDate)).count == 2)
        store.revoke(season)
        #expect(store.snapshot.listed.filter { $0.id == season } == [bought.min { $0.purchaseDate < $1.purchaseDate }])
    }

    // MARK: - Family Sharing

    @Test("the controls act on the account's own subscription, and a refund leaves a family member's")
    func ownFirst() async throws {
        let store = store()
        store.deliverSubscription(monthly, ownership: .familyShared)
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.cancelAutoRenew(monthly)
        let statuses = await store.subscriptionStatuses(in: [group])[group] ?? []
        #expect(statuses.first { $0.ownership == .purchased }?.renewal?.willRenew == false)
        #expect(statuses.first { $0.ownership == .familyShared }?.renewal?.willRenew == true)
        store.revoke(monthly)
        let after = await store.subscriptionStatuses(in: [group])[group] ?? []
        #expect(after.first { $0.ownership == .purchased }?.state == .revoked)
        #expect(after.first { $0.ownership == .familyShared }?.state == .subscribed)
    }

    @Test("a family member's subscription arriving does not put aside the account's own listed copy")
    func familyDeliveryKeepsOwn() async throws {
        let store = store()
        _ = try await store.purchase(monthly, confirmation: .automatic)
        store.deliverSubscription(monthly, ownership: .familyShared)
        #expect(store.snapshot.listed.contains { $0.id == monthly && $0.ownership == .purchased })
    }

    // MARK: - Asked for outside the app

    @Test("a purchase asked for before anything listens reaches the first to listen")
    func requestBeforeListening() async {
        let store = store()
        store.requestPurchase(monthly)
        var updates = store.transactionUpdates().makeAsyncIterator()
        #expect(await updates.next() == .purchaseRequested(RequestedPurchase(product: monthly)))
    }

    // MARK: - Products

    @Test("products made up from the catalogue follow the subscription period; products given are kept as given")
    func madeUpProductsFollow() async throws {
        let madeUp = SimulatedStoreFront(catalogue: catalogue, clock: clock)
        madeUp.behaviour.subscriptionPeriod = .seconds(7 * 86_400)
        #expect(try await madeUp.products().first { $0.id == monthly }?.subscription?.period == .weeks(1))
        let given = store()
        given.behaviour.subscriptionPeriod = .seconds(7 * 86_400)
        #expect(try await given.products().first { $0.id == monthly }?.subscription?.period == .months(1))
    }

    @Test("a subscription period of no length is refused: it would renew for ever")
    func noLength() async {
        await #expect(processExitsWith: .failure) {
            var behaviour = SimulatedStoreFront.Behaviour()
            behaviour.subscriptionPeriod = .zero
        }
    }
}

#endif
