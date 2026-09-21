// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Synchronization
import Testing

/// One group: a monthly plan with every kind of offer, a yearly one with an introductory
/// offer only, and Premium above them with none — the plan's example of 10.99 for two
/// months, then 15.99, and 10.99 for three months to come back.
private enum Offers {
    static let group: SubscriptionGroupID = "21700001"
    static let monthly: ProductID = "com.example.pro.monthly"
    static let yearly: ProductID = "com.example.pro.yearly"
    static let premium: ProductID = "com.example.premium.monthly"

    static let catalogue: Catalogue = [
        .subscription(monthly, in: group, level: 2),
        .subscription(yearly, in: group, level: 2),
        .subscription(premium, in: group, level: 1),
    ]

    static let introductory = terms(.introductory, nil, count: 2)
    static let yearlyIntroductory = OfferTerms(
        kind: .introductory, paymentMode: .freeTrial, period: .weeks(1), periodCount: 1, displayPrice: "Free", price: 0)
    static let returning = terms(.promotional, "promo.returning", count: 3)
    static let winBackThree = terms(.winBack, "winback.three", count: 3)
    static let winBackTwo = terms(.winBack, "winback.two", count: 2)

    static let products: [StoreProduct] = [
        StoreProduct(
            id: monthly, displayName: "Monthly", displayPrice: "£15.99", price: 15.99,
            subscription: StoreProduct.Subscription(
                group: group, period: .months(1), introductoryOffer: introductory, promotionalOffers: [returning],
                winBackOffers: [winBackThree, winBackTwo])),
        StoreProduct(
            id: yearly, displayName: "Yearly", displayPrice: "£149.99", price: 149.99,
            subscription: StoreProduct.Subscription(group: group, period: .years(1), introductoryOffer: yearlyIntroductory)),
        StoreProduct(
            id: premium, displayName: "Premium", displayPrice: "£25.99", price: 25.99,
            subscription: StoreProduct.Subscription(group: group, period: .months(1))),
    ]

    static func terms(_ kind: OfferKind, _ id: OfferID?, count: Int) -> OfferTerms {
        OfferTerms(
            kind: kind, id: id, paymentMode: .payAsYouGo, period: .months(1), periodCount: count,
            displayPrice: "£10.99", price: 10.99)
    }
}

/// The app's server, as a test plays it: every request kept, and a signature, or a failure.
private final class Signer: OfferSigning {
    struct Unreachable: Error {}

    private let fails: Bool
    private let asked = Mutex<[OfferSignatureRequest]>([])

    init(fails: Bool = false) { self.fails = fails }

    var requests: [OfferSignatureRequest] { asked.withLock { $0 } }

    func signature(for request: OfferSignatureRequest) async throws -> String {
        asked.withLock { $0.append(request) }
        if fails { throw Unreachable() }
        return "signed for \(request.product)"
    }
}

/// A status reader that says what it is given.
private struct Statuses: SubscriptionStatusReading {
    let said: [SubscriptionGroupID: [HeldSubscription]]

    func subscriptionStatuses(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: [HeldSubscription]] {
        said
    }
}

@MainActor
@Suite("Purchase store: offers", .timeLimit(.minutes(1)))
struct PurchaseStoreOfferTests {
    let clock = ManualClock(now: Shop.epoch)
    let front: SimulatedStoreFront
    private let signer = Signer()
    let store: PurchaseStore

    init() {
        front = SimulatedStoreFront(catalogue: Offers.catalogue, products: Offers.products, clock: clock)
        store = PurchaseStore(catalogue: Offers.catalogue, front: front, offerSigner: signer, clock: clock)
    }

    private var group: SubscriptionStanding { store.standing.subscription(in: Offers.group) }

    /// Subscribed to the monthly plan and lapsed from it, as `SKTestSession.expireSubscription`
    /// lapses one: Apple says the win-back offers may be had at once in Xcode's environment.
    private func lapsed() async throws {
        await store.start()
        await store.loadProducts()
        try await store.purchase(Offers.monthly)
        front.listUnlisted()
        front.lapse(Offers.monthly)
        await store.refresh()
    }

    /// The monthly plan, lapsed a month ago, with the win-back offers Apple says it allows.
    private func lapsedMonthly(
        winBack: [OfferID], ownership: Ownership = .purchased, transactionID: UInt64? = nil
    ) -> HeldSubscription {
        HeldSubscription(
            product: Offers.monthly, group: Offers.group, ownership: ownership, state: .expired(.autoRenewDisabled),
            firstSubscribed: clock.now.addingTimeInterval(-90 * 86_400), periodStarted: clock.now.addingTimeInterval(-60 * 86_400),
            periodEnds: clock.now.addingTimeInterval(-30 * 86_400),
            renewal: Renewal(willRenew: false, nextProduct: nil, winBackOffers: winBack), transactionID: transactionID)
    }

    // MARK: - Terms

    @Test("a subscription's offers come with its price, as the store states them")
    func terms() async {
        await store.loadProducts()
        let monthly = store.products.first { $0.id == Offers.monthly }?.subscription
        #expect(monthly?.introductoryOffer == Offers.introductory)
        #expect(monthly?.promotionalOffers == [Offers.returning])
        #expect(monthly?.winBackOffers == [Offers.winBackThree, Offers.winBackTwo])
        #expect(monthly?.period == .months(1))
    }

    // MARK: - Introductory

    @Test("the introductory offer is UNKNOWN until the prices have loaded; then eligible, with its terms")
    func introductoryEligible() async {
        await store.start()
        #expect(store.introductoryOffer(for: Offers.monthly) == .unknown)
        await store.loadProducts()
        #expect(store.introductoryOffer(for: Offers.monthly) == .eligible(Offers.introductory))
        #expect(store.introductoryOffer(for: Offers.premium) == .noOffer)
    }

    /// Measured: StoreKit's answer keeps its first value for the life of the process, and
    /// the simulated store keeps it too. Taken at its word after a purchase, the paywall
    /// goes on offering 10.99 to someone who has just had it.
    @Test("a plain purchase APPLIES the introductory offer, and then it is used, on every plan in the group")
    func introductoryUsed() async throws {
        await store.start()
        await store.loadProducts()
        guard case let .subscribed(held) = try await store.purchase(Offers.monthly) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(held.offer == AppliedOffer(kind: .introductory, paymentMode: .payAsYouGo))
        #expect(await front.introductoryEligibility(in: [Offers.group]) == [Offers.group: true])
        #expect(store.introductoryOffer(for: Offers.monthly) == .ineligible)
        #expect(store.introductoryOffer(for: Offers.yearly) == .ineligible)
    }

    /// Upgraded, the status is Premium's, bought with no offer, and says nothing of the
    /// introductory one; StoreKit's answer is still its first. Only the store remembers.
    @Test("the introductory offer stays used once the plan bought with it is left behind")
    func introductoryUsedThenUpgraded() async throws {
        await store.start()
        await store.loadProducts()
        try await store.purchase(Offers.monthly)
        front.listUnlisted()
        guard case let .subscribed(premium) = try await store.purchase(Offers.premium) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(premium.offer == nil)
        #expect(group.all.allSatisfy { $0.offer == nil })
        #expect(store.introductoryOffer(for: Offers.yearly) == .ineligible)
    }

    @Test("used before, as Apple says, it is ineligible; a status bought with it says so too")
    func introductoryUsedElsewhere() async {
        front.useIntroductoryOffer(in: Offers.group)
        await store.loadProducts()
        #expect(store.introductoryOffer(for: Offers.monthly) == .ineligible)

        let fresh = SimulatedStoreFront(catalogue: Offers.catalogue, products: Offers.products, clock: clock)
        fresh.seedSubscription(
            HeldSubscription(
                product: Offers.yearly, group: Offers.group, state: .subscribed, firstSubscribed: clock.now,
                periodStarted: clock.now, periodEnds: clock.now.addingTimeInterval(7 * 86_400),
                offer: AppliedOffer(kind: .introductory, paymentMode: .freeTrial)))
        let other = PurchaseStore(catalogue: Offers.catalogue, front: fresh, clock: clock)
        await other.start()
        await other.loadProducts()
        #expect(await fresh.introductoryEligibility(in: [Offers.group]) == [Offers.group: true])
        #expect(other.introductoryOffer(for: Offers.monthly) == .ineligible)
    }

    @Test("an introductory offer seen only on a status stays used once that status is replaced by an upgrade")
    func introductorySeenOnStatusThenUpgraded() async throws {
        front.seedSubscription(
            HeldSubscription(
                product: Offers.monthly, group: Offers.group, state: .subscribed, firstSubscribed: clock.now,
                periodStarted: clock.now, periodEnds: clock.now.addingTimeInterval(30 * 86_400),
                offer: AppliedOffer(kind: .introductory, paymentMode: .payAsYouGo)))
        await store.start()
        await store.loadProducts()
        #expect(store.introductoryOffer(for: Offers.yearly) == .ineligible)
        try await store.purchase(Offers.premium)
        front.listUnlisted()
        await store.refresh()
        #expect(group.all.allSatisfy { $0.offer == nil })
        #expect(store.introductoryOffer(for: Offers.yearly) == .ineligible)
    }

    /// Apple's eligibility is the Apple Account's own [Apple].
    @Test("an introductory offer a FAMILY MEMBER bought with does not use up this account's")
    func introductorySharedNotUsed() async throws {
        await store.start()
        await store.loadProducts()
        front.deliver(
            OwnedProduct(
                id: Offers.monthly, originalPurchaseDate: clock.now, ownership: .familyShared,
                expirationDate: clock.now.addingTimeInterval(30 * 86_400),
                offer: AppliedOffer(kind: .introductory, paymentMode: .payAsYouGo)))
        #expect(await waitUntil { group.isActive == true })
        #expect(store.introductoryOffer(for: Offers.yearly) == .eligible(Offers.yearlyIntroductory))
    }

    @Test("with nothing to say who may have it, the introductory offer is unknown: show the regular price")
    func introductoryUnknown() async {
        let quiet = PurchaseStore(
            catalogue: Offers.catalogue, catalogueLoader: front, ownership: front, purchaser: front, restorer: front,
            observer: front, subscriptionStatuses: front, clock: clock)
        await quiet.loadProducts()
        #expect(quiet.introductoryOffer(for: Offers.monthly) == .unknown)
        #expect(quiet.introductoryOffer(for: Offers.premium) == .noOffer)
    }

    // MARK: - Win-back

    @Test("lapsed, the win-back offers Apple allows are there, with their terms, for the plan lapsed from")
    func winBackOffered() async throws {
        try await lapsed()
        #expect(group.isActive == false)
        #expect(store.winBackOffers(in: Offers.group) == [
            WinBackOffer(product: Offers.monthly, id: "winback.three", terms: Offers.winBackThree),
            WinBackOffer(product: Offers.monthly, id: "winback.two", terms: Offers.winBackTwo),
        ])
    }

    @Test("win-back offers come in APPLE'S order, best first, whatever order the product lists them in")
    func winBackOrder() async {
        front.seedSubscription(lapsedMonthly(winBack: ["winback.two", "winback.three"]))
        await store.start()
        await store.loadProducts()
        #expect(store.winBackOffers(in: Offers.group).map(\.id) == ["winback.two", "winback.three"])
    }

    @Test("no win-back offers for a member, for a family member's lapse, or before the prices have loaded")
    func winBackNotOffered() async throws {
        front.seedSubscription(lapsedMonthly(winBack: ["winback.three"], ownership: .familyShared))
        await store.start()
        #expect(store.winBackOffers(in: Offers.group).isEmpty)
        await store.loadProducts()
        #expect(store.winBackOffers(in: Offers.group).isEmpty)
        try await store.purchase(Offers.monthly)
        #expect(group.isActive == true)
        #expect(store.winBackOffers(in: Offers.group).isEmpty)
    }

    @Test("a win-back offer bought is applied, and is not offered again")
    func winBackBought() async throws {
        try await lapsed()
        let offer = try #require(store.winBackOffers(in: Offers.group).first)
        guard case let .subscribed(held) = try await store.purchase(offer.product, options: PurchaseOptions(offer: .winBack(offer.id))) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(held.offer == AppliedOffer(kind: .winBack, id: "winback.three", paymentMode: .payAsYouGo))
        #expect(group.isActive == true)
        #expect(store.winBackOffers(in: Offers.group).isEmpty)
    }

    @Test("a win-back offer Apple has not allowed is refused, and nothing is bought")
    func winBackRefused() async throws {
        await store.start()
        await store.loadProducts()
        try await store.purchase(Offers.monthly)
        await #expect(throws: PurchaseError.offerRefused(.notEligible)) {
            try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .winBack("winback.three")))
        }
    }

    // MARK: - Promotional

    /// Promotional offers are for current and former subscribers [Apple]. Asking the
    /// server for a signature for anyone else is a request it should never get.
    @Test("a promotional offer for someone who has NEVER SUBSCRIBED is refused before the signer is asked")
    func promotionalNeverSubscribed() async {
        await store.start()
        await store.loadProducts()
        await #expect(throws: PurchaseError.offerRefused(.notEligible)) {
            try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .promotional("promo.returning")))
        }
        #expect(signer.requests.isEmpty)
        #expect(front.lastPurchaseOptions == nil)
    }

    @Test("a promotional offer for a former subscriber is signed by the app's server, and the signature is what the store gets")
    func promotionalSigned() async throws {
        try await lapsed()
        let lapsedTransaction = try #require(group.current?.transactionID)
        let token = UUID()
        let options = PurchaseOptions(offer: .promotional("promo.returning"), appAccountToken: token)
        guard case let .subscribed(held) = try await store.purchase(Offers.monthly, options: options) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(signer.requests == [
            OfferSignatureRequest(
                product: Offers.monthly, kind: .promotional("promo.returning"), appAccountToken: token,
                transactionID: String(lapsedTransaction))
        ])
        #expect(front.lastPurchaseOptions?.signature == "signed for \(Offers.monthly)")
        #expect(held.offer == AppliedOffer(kind: .promotional, id: "promo.returning", paymentMode: .payAsYouGo))
    }

    /// A promotional offer bought by a current subscriber takes effect at the next billing
    /// event [Apple]. It was applied, and must not be reported as not.
    @Test("a promotional offer for a CURRENT subscriber waits for the renewal, is said as applied, and the renewal carries it")
    func promotionalAtRenewal() async throws {
        await store.start()
        await store.loadProducts()
        try await store.purchase(Offers.monthly)
        front.listUnlisted()
        let completion = try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .promotional("promo.returning")))
        guard case let .subscribed(held) = completion else {
            Issue.record("expected subscribed, got \(completion)")
            return
        }
        let promotional = AppliedOffer(kind: .promotional, id: "promo.returning", paymentMode: .payAsYouGo)
        #expect(held.renewal?.offer == promotional)
        let ends = held.periodEnds
        clock.advance(to: ends)
        #expect(await waitUntil { group.current?.periodStarted == ends })
        #expect(group.current?.offer == promotional)
    }

    /// Apple's signature creators take the customer's transaction, and the override's
    /// requires one [Apple]: the server is handed the account's latest in the group.
    @Test("the signer is given the account's own latest transaction in the group")
    func signerGivenTransaction() async throws {
        front.seedSubscription(lapsedMonthly(winBack: [], transactionID: 4_242))
        await store.start()
        try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .introductoryOverride))
        #expect(signer.requests.map(\.transactionID) == ["4242"])
    }

    @Test("the signer is given the transaction even when nothing has been read yet")
    func signerGivenTransactionBeforeStart() async throws {
        front.seedSubscription(lapsedMonthly(winBack: [], transactionID: 4_242))
        try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .introductoryOverride))
        #expect(signer.requests.map(\.transactionID) == ["4242"])
    }

    @Test("the signer is given a transaction the account has, not a status that names none")
    func signerGivenTransactionThatIsThere() async throws {
        let current = HeldSubscription(
            product: Offers.premium, group: Offers.group, state: .subscribed, firstSubscribed: clock.now,
            periodStarted: clock.now, periodEnds: clock.now.addingTimeInterval(30 * 86_400))
        let statuses = Statuses(said: [Offers.group: [current, lapsedMonthly(winBack: [], transactionID: 4_242)]])
        let store = PurchaseStore(
            catalogue: Offers.catalogue, catalogueLoader: front, ownership: front, purchaser: front, restorer: front,
            observer: front, subscriptionStatuses: statuses, offerSigner: signer, clock: clock)
        await store.start()
        try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .introductoryOverride))
        #expect(signer.requests.map(\.transactionID) == ["4242"])
    }

    @Test("a promotional offer or the override on something that is not a subscription is refused, and nobody is asked")
    func signedNotASubscription() async {
        let catalogue = Catalogue(Offers.catalogue.entries + [.unlock(Shop.pro)])
        let front = SimulatedStoreFront(catalogue: catalogue, products: Offers.products, clock: clock)
        let store = PurchaseStore(catalogue: catalogue, front: front, offerSigner: signer, clock: clock)
        await store.start()
        for offer in [PurchaseOptions.Offer.promotional("promo.returning"), .introductoryOverride] {
            await #expect(throws: PurchaseError.offerRefused(.unknownOffer)) {
                try await store.purchase(Shop.pro, options: PurchaseOptions(offer: offer))
            }
        }
        #expect(signer.requests.isEmpty)
    }

    @Test("where the group's statuses could not be read, 'never subscribed' is only the listing's word: nobody is refused")
    func signedStatusesUnread() async throws {
        let store = PurchaseStore(
            catalogue: Offers.catalogue, catalogueLoader: front, ownership: front, purchaser: front, restorer: front,
            observer: front, subscriptionStatuses: Statuses(said: [:]), offerSigner: signer, clock: clock)
        await store.start()
        _ = try? await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .promotional("promo.returning")))
        #expect(signer.requests.map(\.product) == [Offers.monthly])
    }

    @Test("the signer is given the account's own transaction before a family member's")
    func signerGivenOwnTransaction() async throws {
        let shared = HeldSubscription(
            product: Offers.premium, group: Offers.group, ownership: .familyShared, state: .subscribed,
            firstSubscribed: clock.now, periodStarted: clock.now, periodEnds: clock.now.addingTimeInterval(30 * 86_400),
            transactionID: 1)
        let own = lapsedMonthly(winBack: [], transactionID: 2)
        let store = PurchaseStore(
            catalogue: Offers.catalogue, catalogueLoader: front, ownership: front, purchaser: front, restorer: front,
            observer: front, subscriptionStatuses: Statuses(said: [Offers.group: [shared, own]]), offerSigner: signer,
            clock: clock)
        await store.start()
        _ = try? await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .introductoryOverride))
        #expect(signer.requests.map(\.transactionID) == ["2"])
    }

    @Test("an introductory offer seen on an ANNOUNCED purchase stays used once nothing shows it any more")
    func introductoryAnnounced() async throws {
        await store.start()
        await store.loadProducts()
        front.announceWithoutListing(
            OwnedProduct(
                id: Offers.monthly, originalPurchaseDate: clock.now, expirationDate: clock.now.addingTimeInterval(30 * 86_400),
                offer: AppliedOffer(kind: .introductory, paymentMode: .payAsYouGo)))
        #expect(await waitUntil { group.isActive == true })
        clock.advance(by: .seconds(31))
        #expect(await waitUntil { group.isActive == false })
        #expect(store.introductoryOffer(for: Offers.yearly) == .ineligible)
    }

    @Test("a signer that fails is logged with the type of what it threw, and nothing more")
    func signerFailureLogged() async throws {
        front.seedSubscription(lapsedMonthly(winBack: []))
        let logger = RecordingPurchaseLogger()
        let store = PurchaseStore(catalogue: Offers.catalogue, front: front, offerSigner: Signer(fails: true), clock: clock, logger: logger)
        await store.start()
        await #expect(throws: PurchaseError.offerNotSigned) {
            try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .promotional("promo.returning")))
        }
        #expect(logger.events.contains(.offerSignerFailed(Offers.monthly, typeName: String(reflecting: Signer.Unreachable.self))))
    }

    @Test("a signer that fails, or none at all, is offerNotSigned — and the store is NEVER ASKED")
    func notSigned() async throws {
        front.seedSubscription(lapsedMonthly(winBack: []))
        let options = PurchaseOptions(offer: .promotional("promo.returning"))
        for signer in [Signer(fails: true), nil] {
            let store = PurchaseStore(catalogue: Offers.catalogue, front: front, offerSigner: signer, clock: clock)
            await store.start()
            await #expect(throws: PurchaseError.offerNotSigned) { try await store.purchase(Offers.monthly, options: options) }
        }
        #expect(front.lastPurchaseOptions == nil)
    }

    @Test("a signature the store does not accept is refused as such, apart from a person it is not for")
    func signatureRejected() async throws {
        try await lapsed()
        front.behaviour.acceptsOfferSignatures = false
        await #expect(throws: PurchaseError.offerRefused(.invalidSignature)) {
            try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .promotional("promo.returning")))
        }
    }

    @Test("a signature put in the options by anybody but the store is not what is sent")
    func signatureIsTheStores() async throws {
        try await lapsed()
        var options = PurchaseOptions(offer: .winBack("winback.three"))
        options.signature = "forged"
        try await store.purchase(Offers.monthly, options: options)
        #expect(front.lastPurchaseOptions?.signature == nil)
    }

    // MARK: - Not applied

    /// Measured, right after a lapse: StoreKit handed back the old transaction, and the
    /// override asked for looked applied, because that transaction had been bought with the
    /// introductory offer a month before.
    @Test("a subscription handed back ALREADY OVER bought nothing: a failure, not 'subscribed', and nothing is held")
    func handedBackOver() async throws {
        try await lapsed()
        front.behaviour.handsBackTheLapsedTransaction = true
        await #expect(throws: PurchaseError.system) {
            try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: .introductoryOverride))
        }
        #expect(group.isActive == false)
    }

    /// Measured: an introductory override StoreKit could not check went through at the full
    /// price, and said nothing.
    @Test("an offer asked for and NOT APPLIED is said so: bought, at the regular price")
    func notApplied() async throws {
        await store.start()
        await store.loadProducts()
        let completion = try await store.purchase(Offers.premium, options: PurchaseOptions(offer: .introductoryOverride))
        guard case let .offerNotApplied(held) = completion else {
            Issue.record("expected offerNotApplied, got \(completion)")
            return
        }
        #expect(held.product == Offers.premium)
        #expect(held.offer == nil)
        #expect(signer.requests.map(\.kind) == [.introductoryOverride])
    }

    @Test("bought with ANOTHER offer than the one asked for, the one asked for was not applied")
    func otherOfferNotApplied() async throws {
        let cases: [(PurchaseOptions.Offer, AppliedOffer)] = [
            (.winBack("winback.three"), AppliedOffer(kind: .winBack, id: "winback.two", paymentMode: .payAsYouGo)),
            (.promotional("promo.returning"), AppliedOffer(kind: .promotional, id: "promo.other", paymentMode: .payAsYouGo)),
        ]
        for (asked, got) in cases {
            let bought = OwnedProduct(
                id: Offers.monthly, originalPurchaseDate: clock.now, expirationDate: clock.now.addingTimeInterval(30 * 86_400),
                offer: got)
            let store = PurchaseStore(
                catalogue: Offers.catalogue, catalogueLoader: front, ownership: front, purchaser: Sells(product: bought),
                restorer: front, observer: front, offerSigner: signer, clock: clock)
            await store.start()
            let completion = try await store.purchase(Offers.monthly, options: PurchaseOptions(offer: asked))
            guard case .offerNotApplied = completion else {
                Issue.record("expected offerNotApplied for \(asked), got \(completion)")
                continue
            }
        }
    }
}

/// A store that sells `product`, whatever was asked for.
private struct Sells: ProductPurchasing {
    let product: OwnedProduct

    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        .purchased(product)
    }
}

#endif
