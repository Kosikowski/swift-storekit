// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

private let group: SubscriptionGroupID = "21800002"
private let monthly: ProductID = "com.example.pro.monthly"
private let premium: ProductID = "com.example.premium.monthly"
private let pro: ProductID = "com.example.pro"
private let catalogue: Catalogue = [
    .unlock(pro),
    .subscription(monthly, in: group, level: 2),
    .subscription(premium, in: group, level: 1),
]

private let introductory = OfferTerms(
    kind: .introductory, paymentMode: .payAsYouGo, period: .months(1), periodCount: 2, displayPrice: "$10.99", price: 10.99)
private let returning = OfferTerms(
    kind: .promotional, id: "promo.returning", paymentMode: .payAsYouGo, period: .months(1), periodCount: 3,
    displayPrice: "$10.99", price: 10.99)
private let winBack = OfferTerms(
    kind: .winBack, id: "winback.three", paymentMode: .payAsYouGo, period: .months(1), periodCount: 3,
    displayPrice: "$10.99", price: 10.99)

private let products: [StoreProduct] = [
    StoreProduct(id: pro, displayName: "Pro", displayPrice: "$29.99", price: 29.99),
    StoreProduct(
        id: monthly, displayName: "Monthly", displayPrice: "$15.99", price: 15.99,
        subscription: StoreProduct.Subscription(
            group: group, period: .months(1), introductoryOffer: introductory, promotionalOffers: [returning],
            winBackOffers: [winBack])),
    StoreProduct(
        id: premium, displayName: "Premium", displayPrice: "$25.99", price: 25.99,
        subscription: StoreProduct.Subscription(group: group, period: .months(1))),
]

@Suite("Simulated store: offers", .timeLimit(.minutes(1)))
struct SimulatedOfferTests {
    private let clock = ManualClock()

    private func store(_ configure: (inout SimulatedStoreFront.Behaviour) -> Void = { _ in }) -> SimulatedStoreFront {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.subscriptionPeriod = .seconds(60)
        behaviour.listsPurchasesAfterReads = 0
        configure(&behaviour)
        return SimulatedStoreFront(catalogue: catalogue, products: products, clock: clock, behaviour: behaviour)
    }

    private func buy(
        _ store: SimulatedStoreFront, _ id: ProductID, _ offer: PurchaseOptions.Offer? = nil, signed: Bool = false
    ) async throws(PurchaseError) -> OwnedProduct? {
        var options = PurchaseOptions(offer: offer)
        if signed { options.signature = "signed" }
        guard case let .purchased(owned) = try await store.purchase(id, options: options, confirmation: .automatic) else {
            return nil
        }
        return owned
    }

    private func status(_ store: SimulatedStoreFront, _ id: ProductID = monthly) async -> HeldSubscription? {
        await store.subscriptionStatuses(in: [group])[group]?.first { $0.product == id }
    }

    // MARK: - Introductory

    @Test("a plain purchase applies the introductory offer, once per group")
    func introductory() async throws {
        let store = store()
        #expect(try await buy(store, monthly)?.offer == AppliedOffer(kind: .introductory, paymentMode: .payAsYouGo))
        store.lapse(monthly)
        #expect(try await buy(store, monthly)?.offer == nil)
    }

    /// Measured: StoreKit's `isEligibleForIntroOffer(for:)` keeps its first answer for the
    /// life of the process, before and after the offer is used.
    @Test("asked about introductory eligibility, the store KEEPS ITS FIRST ANSWER, as StoreKit does — unless told not to")
    func eligibilityKeepsItsFirstAnswer() async throws {
        let keeps = store()
        #expect(await keeps.introductoryEligibility(in: [group]) == [group: true])
        _ = try await buy(keeps, monthly)
        #expect(await keeps.introductoryEligibility(in: [group]) == [group: true])

        let truthful = store { $0.keepsFirstEligibilityAnswer = false }
        #expect(await truthful.introductoryEligibility(in: [group]) == [group: true])
        _ = try await buy(truthful, monthly)
        #expect(await truthful.introductoryEligibility(in: [group]) == [group: false])
    }

    @Test("used elsewhere, the offer is not applied, and the store says so from the first question")
    func usedElsewhere() async throws {
        let store = store()
        store.useIntroductoryOffer(in: group)
        #expect(await store.introductoryEligibility(in: [group]) == [group: false])
        #expect(try await buy(store, monthly)?.offer == nil)
        store.lapse(monthly)
        #expect(try await buy(store, monthly, .introductoryOverride, signed: true)?.offer?.kind == .introductory)
    }

    // MARK: - Win-back

    @Test("a LAPSE makes the product's win-back offers eligible at once, as in Xcode's environment, and one can be bought")
    func winBack() async throws {
        let store = store()
        _ = try await buy(store, monthly)
        store.cancelAutoRenew(monthly)
        clock.advance(by: .seconds(61))
        let lapsed = await status(store)
        #expect(lapsed?.isEntitled == false)
        #expect(lapsed?.renewal?.winBackOffers == ["winback.three"])
        let back = try await buy(store, monthly, .winBack("winback.three"))
        #expect(back?.offer == AppliedOffer(kind: .winBack, id: "winback.three", paymentMode: .payAsYouGo))
    }

    @Test("a family member's lapse makes no win-back offer eligible for this account")
    func winBackNotShared() async throws {
        let store = store()
        store.deliverSubscription(monthly, ownership: .familyShared)
        store.lapse(monthly)
        #expect(await status(store)?.renewal?.winBackOffers == [])
    }

    // MARK: - Promotional

    @Test("a promotional offer bought by a CURRENT subscriber waits for the renewal, and the renewal carries it")
    func promotionalAtRenewal() async throws {
        let store = store()
        _ = try await buy(store, monthly)
        let held = try await buy(store, monthly, .promotional("promo.returning"), signed: true)
        #expect(held?.offer?.kind == .introductory)
        let promotional = AppliedOffer(kind: .promotional, id: "promo.returning", paymentMode: .payAsYouGo)
        #expect(await status(store)?.renewal?.offer == promotional)
        clock.advance(by: .seconds(61))
        // The renewal happens at the next read, in its moment; then the listing catches up.
        _ = await status(store)
        store.listUnlisted()
        #expect(await status(store)?.offer == promotional)
        #expect(await status(store)?.renewal?.offer == nil)
    }

    @Test("a former subscriber's promotional offer is applied at once")
    func promotionalForFormer() async throws {
        let store = store()
        _ = try await buy(store, monthly)
        store.lapse(monthly)
        let back = try await buy(store, monthly, .promotional("promo.returning"), signed: true)
        #expect(back?.offer == AppliedOffer(kind: .promotional, id: "promo.returning", paymentMode: .payAsYouGo))
    }

    // MARK: - Refused

    @Test("an offer is refused, with StoreKit's reason, and nothing is bought", arguments: [
        (PurchaseOptions.Offer.winBack("winback.none"), true, PurchaseError.OfferRefusal.unknownOffer),
        (.winBack("winback.three"), true, .notEligible),
        (.promotional("promo.none"), true, .unknownOffer),
        (.promotional("promo.returning"), false, .missingParameters),
        (.promotional("promo.returning"), true, .notEligible),
        (.introductoryOverride, false, .missingParameters),
    ])
    func refused(offer: PurchaseOptions.Offer, signed: Bool, reason: PurchaseError.OfferRefusal) async {
        let store = store()
        await #expect(throws: PurchaseError.offerRefused(reason)) { try await buy(store, monthly, offer, signed: signed) }
        #expect(store.snapshot.listed.isEmpty)
    }

    @Test("a signature the store is told not to accept is refused as invalid; an offer on an unlock is unknown")
    func refusedSignatureAndUnlock() async throws {
        let store = store { $0.acceptsOfferSignatures = false }
        _ = try await buy(store, monthly)
        store.lapse(monthly)
        await #expect(throws: PurchaseError.offerRefused(.invalidSignature)) {
            try await buy(store, monthly, .promotional("promo.returning"), signed: true)
        }
        await #expect(throws: PurchaseError.offerRefused(.unknownOffer)) {
            try await buy(store, pro, .winBack("winback.three"))
        }
    }

    @Test("a reset forgets the introductory offer used, and what was answered about it")
    func reset() async throws {
        let store = store()
        _ = try await buy(store, monthly)
        _ = await store.introductoryEligibility(in: [group])
        store.reset()
        store.behaviour.keepsFirstEligibilityAnswer = false
        #expect(await store.introductoryEligibility(in: [group]) == [group: true])
    }
}

#endif
