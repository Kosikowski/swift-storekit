// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

/// A season of thirty days that stacks, and a pass of thirty days that does not.
private enum Seasons {
    static let season: ProductID = "com.example.season"
    static let pass: ProductID = "com.example.pass"
    static let days: Duration = .seconds(30 * 86_400)

    static let catalogue: Catalogue = [
        .unlock(Shop.pro),
        .nonRenewing(season, lasting: days),
        .nonRenewing(pass, lasting: days, stacking: .fromEachPurchase),
    ]
}

private let day: TimeInterval = 86_400

@Suite("Non-renewing subscriptions: what purchases amount to")
struct NonRenewingTermsTests {
    private let start = Shop.epoch

    @Test("purchases made while one runs are consecutive: three months bought twice is six")
    func consecutive() {
        let terms = NonRenewingTerms(duration: Seasons.days)
        let periods = terms.periods(of: [start.addingTimeInterval(10 * day), start])
        #expect(periods == [NonRenewingPeriod(startedAt: start, endsAt: start.addingTimeInterval(60 * day))])
    }

    @Test("from each purchase, a second overlaps the first and adds only what reaches past it")
    func fromEachPurchase() {
        let terms = NonRenewingTerms(duration: Seasons.days, stacking: .fromEachPurchase)
        let periods = terms.periods(of: [start, start.addingTimeInterval(10 * day)])
        #expect(periods == [NonRenewingPeriod(startedAt: start, endsAt: start.addingTimeInterval(40 * day))])
    }

    @Test("a purchase after one has ended starts a period of its own; one bought at the instant it ends joins it")
    func gaps() {
        let terms = NonRenewingTerms(duration: Seasons.days)
        let periods = terms.periods(of: [start, start.addingTimeInterval(45 * day), start.addingTimeInterval(75 * day)])
        #expect(periods == [
            NonRenewingPeriod(startedAt: start, endsAt: start.addingTimeInterval(30 * day)),
            NonRenewingPeriod(startedAt: start.addingTimeInterval(45 * day), endsAt: start.addingTimeInterval(105 * day)),
        ])
        #expect(terms.periods(of: []).isEmpty)
    }

    @Test("a non-renewing subscription that lasts no time is a problem in the catalogue")
    func problem() {
        #expect(Catalogue.problems(in: [.nonRenewing("s", lasting: .zero)]) == [.nonRenewingWithoutDuration("s")])
    }
}

@MainActor
@Suite("Purchase store: non-renewing subscriptions", .timeLimit(.minutes(1)))
struct PurchaseStoreNonRenewingTests {
    let clock = ManualClock(now: Shop.epoch)
    let front: SimulatedStoreFront
    let store: PurchaseStore

    init() {
        front = SimulatedStoreFront(catalogue: Seasons.catalogue, clock: clock)
        store = PurchaseStore(catalogue: Seasons.catalogue, front: front, clock: clock)
    }

    private func running(_ id: ProductID = Seasons.season) -> NonRenewingPeriod? {
        if case let .active(period) = store.standing.nonRenewing(id, at: clock.now) { return period }
        return nil
    }

    /// Measured on the Mac: listed about 0.4 s after `purchase()` returns.
    @Test("bought, it runs AT ONCE, from its purchase, though the store has not listed it")
    func bought() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        let completion = try await store.purchase(Seasons.season)
        let period = NonRenewingPeriod(startedAt: clock.now, endsAt: clock.now.addingTimeInterval(30 * day))
        #expect(completion == .nonRenewing(period))
        #expect(front.snapshot.listed.isEmpty)
        #expect(store.standing.access(to: Seasons.season, at: clock.now) == .nonRenewing(period))
        #expect(store.standing.access(to: Seasons.season, at: clock.now).isGranted == true)
    }

    /// Measured: bought again, a new transaction, and the listing keeps both (n02).
    @Test("bought AGAIN while it runs, the time is added: the second purchase is held beside the first")
    func boughtAgain() async throws {
        await store.start()
        try await store.purchase(Seasons.season)
        front.listUnlisted()
        front.behaviour.listsPurchasesAfterReads = 5
        clock.advance(by: .seconds(10 * day))
        let completion = try await store.purchase(Seasons.season)
        let doubled = NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(60 * day))
        #expect(completion == .nonRenewing(doubled))
        #expect(front.snapshot.listed.count == 1)
        #expect(front.snapshot.unlisted.count == 1)
        front.listUnlisted()
        await store.refresh()
        #expect(front.snapshot.listed.count == 2)
        #expect(running() == doubled)
    }

    @Test("bought twice at the same instant, both purchases count")
    func boughtTwiceAtOnce() async throws {
        await store.start()
        try await store.purchase(Seasons.season)
        #expect(try await store.purchase(Seasons.season)
            == .nonRenewing(NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(60 * day))))
    }

    @Test("it ends BY ITSELF at the end of its period, and says when it ended")
    func endsByItself() async throws {
        await store.start()
        try await store.purchase(Seasons.season)
        front.listUnlisted()
        // Listed, so the hold is let go, and nothing but the period's end is left to wake the store.
        await store.refresh()
        let ends = Shop.epoch.addingTimeInterval(30 * day)
        clock.advance(to: ends)
        #expect(await waitUntil { store.standing.access(to: Seasons.season) == .none })
        #expect(store.standing.nonRenewing(Seasons.season) == .ended(NonRenewingPeriod(startedAt: Shop.epoch, endsAt: ends)))
    }

    /// Measured: refunding one of two purchases takes that one out, and the other stays (n03).
    @Test("one purchase of two refunded, the time it bought is taken back, and the rest stays")
    func refundOne() async throws {
        await store.start()
        try await store.purchase(Seasons.season)
        front.listUnlisted()
        clock.advance(by: .seconds(10 * day))
        try await store.purchase(Seasons.season)
        front.listUnlisted()
        #expect(await waitUntil { running()?.endsAt == Shop.epoch.addingTimeInterval(60 * day) })
        front.revoke(Seasons.season)
        #expect(await waitUntil { running() == NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(30 * day)) })
    }

    @Test("bought again and waiting for APPROVAL, it stays pending, though an earlier purchase is owned, until approved")
    func pendingAgain() async throws {
        await store.start()
        try await store.purchase(Seasons.season)
        front.listUnlisted()
        clock.advance(by: .seconds(10 * day))
        front.behaviour.purchase = .pending
        #expect(try await store.purchase(Seasons.season) == .pending)
        await store.refresh()
        #expect(store.pendingApprovals == [Seasons.season])
        front.approvePending(Seasons.season)
        #expect(await waitUntil { store.pendingApprovals.isEmpty })
        #expect(running()?.endsAt == Shop.epoch.addingTimeInterval(60 * day))
    }

    @Test("bought, and read again with it counted before purchase() returns, it is time bought and no failure")
    func countedBeforeReturn() async throws {
        let bought = OwnedProduct(id: Seasons.season, originalPurchaseDate: Shop.epoch)
        let later = Later()
        let purchaser = Meanwhile(product: bought) { @MainActor in
            front.seed(bought)
            await later.store?.refresh()
        }
        let store = PurchaseStore(
            catalogue: Seasons.catalogue, catalogueLoader: front, ownership: front, purchaser: purchaser, restorer: front,
            observer: front, clock: clock)
        later.store = store
        await store.start()
        #expect(try await store.purchase(Seasons.season)
            == .nonRenewing(NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(30 * day))))
    }

    @Test("a purchase HANDED BACK in Apple's view that was already counted bought nothing: a failure")
    func handedBackInAppleView() async throws {
        let bought = OwnedProduct(id: Seasons.season, originalPurchaseDate: Shop.epoch)
        front.seed(bought)
        await store.start()
        await #expect(throws: PurchaseError.system) { try await store.takePurchase(.purchased(bought), of: Seasons.season) }
    }

    /// On the Mac, Apple's views announce what they sell (spike/README.md, q12), so the store
    /// can count a purchase before the view hands it over.
    @Test("bought in Apple's view and ANNOUNCED before it is handed over, it is time bought and no failure")
    func announcedInAppleView() async throws {
        await store.start()
        try await store.purchase(Seasons.season)
        front.listUnlisted()
        clock.advance(by: .seconds(10 * day))
        let again = OwnedProduct(id: Seasons.season, originalPurchaseDate: clock.now)
        front.deliver(again)
        let doubled = NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(60 * day))
        #expect(await waitUntil { running() == doubled })
        #expect(try await store.takePurchase(.purchased(again), of: Seasons.season) == .nonRenewing(doubled))
    }

    /// The purchase date is the App Store's, and this device's clock can be behind it.
    @Test("a purchase dated AHEAD of this device's clock is its own period, and runs when the clock reaches it")
    func aheadOfTheClock() async throws {
        let ahead = OwnedProduct(id: Seasons.season, originalPurchaseDate: Shop.epoch.addingTimeInterval(60))
        let purchaser = Meanwhile(product: ahead) { @MainActor in front.seed(ahead) }
        let store = PurchaseStore(
            catalogue: Seasons.catalogue, catalogueLoader: front, ownership: front, purchaser: purchaser, restorer: front,
            observer: front, clock: clock, listingGrace: .seconds(1))
        await store.start()
        let period = NonRenewingPeriod(startedAt: ahead.purchaseDate, endsAt: ahead.purchaseDate.addingTimeInterval(30 * day))
        #expect(try await store.purchase(Seasons.season) == .nonRenewing(period))
        clock.advance(by: .seconds(1))
        await store.refresh()
        #expect(store.standing.access(to: Seasons.season, at: clock.now) == .none)
        clock.advance(to: ahead.purchaseDate)
        #expect(await waitUntil { store.standing.access(to: Seasons.season) == .nonRenewing(period) })
    }

    @Test("from each purchase, a second adds only what reaches past the first")
    func fromEachPurchase() async throws {
        await store.start()
        try await store.purchase(Seasons.pass)
        front.listUnlisted()
        clock.advance(by: .seconds(10 * day))
        #expect(try await store.purchase(Seasons.pass) == .nonRenewing(
            NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(40 * day))))
    }

    @Test("one that arrived through Family Sharing is not counted: its date is somebody else's")
    func shared() async {
        front.seed(Seasons.season, ownership: .familyShared)
        await store.start()
        #expect(store.standing.nonRenewing(Seasons.season) == NonRenewingStatus.none)
        #expect(store.standing.access(to: Seasons.season) == ProductAccess.none)
    }

    /// Measured in the iOS simulator: bought again, the purchase before was handed back, and
    /// nothing was bought, in two runs of three (n03).
    @Test("a purchase HANDED BACK that was already counted bought nothing: a failure, and no time added")
    func handedBack() async throws {
        let bought = OwnedProduct(id: Seasons.season, originalPurchaseDate: Shop.epoch)
        front.seed(bought)
        let store = PurchaseStore(
            catalogue: Seasons.catalogue, catalogueLoader: front, ownership: front,
            purchaser: HandsBack(product: bought), restorer: front, observer: front, clock: clock)
        await store.start()
        await #expect(throws: PurchaseError.system) { try await store.purchase(Seasons.season) }
        #expect(store.standing.nonRenewing(Seasons.season, at: clock.now)
            == .active(NonRenewingPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(30 * day))))
    }
}

/// A store that does something else while it sells, and then sells `product`.
private struct Meanwhile: ProductPurchasing {
    let product: OwnedProduct
    let meanwhile: @Sendable () async -> Void

    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        await meanwhile()
        return .purchased(product)
    }
}

@MainActor
private final class Later {
    var store: PurchaseStore?
}

/// A store that hands back what the account already has, as the iOS simulator did.
private struct HandsBack: ProductPurchasing {
    let product: OwnedProduct

    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        .purchased(product)
    }
}

#endif
