import Foundation
import PurchaseCore
import Testing

@Suite("Standing")
struct StandingTests {
    private let resolver = StandingResolver()
    private let now = Shop.epoch

    private func standing(_ owned: [OwnedProduct], catalogue: Catalogue = Shop.catalogue) -> Standing {
        resolver.standing(owned: owned, catalogue: catalogue, asOf: now)
    }

    @Test("before the store answers, access is UNKNOWN and never none")
    func unknown() {
        let standing = Standing.unknown(catalogue: Shop.catalogue)
        #expect(!standing.isKnown)
        #expect(standing.access(to: Shop.pro, at: now) == .unknown)
        #expect(standing.trial(Shop.trial, at: now) == .unknown)
        #expect(standing.nextExpiry == nil)
    }

    @Test("owning nothing is known, and is none")
    func nothing() {
        let standing = standing([])
        #expect(standing.isKnown)
        #expect(standing.access(to: Shop.pro) == .none)
        #expect(standing.trial(Shop.trial) == .available)
    }

    @Test("an unlock that is owned is owned, and its trial is no longer on offer")
    func owned() {
        let pro = OwnedProduct(id: Shop.pro, originalPurchaseDate: now)
        let standing = standing([pro])
        #expect(standing.access(to: Shop.pro) == .owned(pro))
        #expect(standing.trial(Shop.trial) == .notOffered)
    }

    @Test("the whole listing is read: a product listed FIRST does not hide the one after it")
    func wholeListing() {
        let catalogue: Catalogue = [.unlock("a"), .unlock("b")]
        let standing = standing(
            [
                OwnedProduct(id: "somebody.elses", originalPurchaseDate: now),
                OwnedProduct(id: "b", originalPurchaseDate: now),
                OwnedProduct(id: "a", originalPurchaseDate: now),
            ], catalogue: catalogue)
        #expect(standing.ownedProducts.map(\.id) == ["a", "b"])
    }

    @Test("a product the catalogue does not list is somebody else's and is not counted")
    func foreign() {
        let standing = standing([OwnedProduct(id: "somebody.elses", originalPurchaseDate: now)])
        #expect(standing.ownedProducts.isEmpty)
    }

    @Test("a running trial lends the unlock, and says through which product and until when")
    func runningTrial() {
        let started = now.addingTimeInterval(-86_400)
        let standing = standing([OwnedProduct(id: Shop.trial, originalPurchaseDate: started)])
        let period = TrialPeriod(startedAt: started, endsAt: started.addingTimeInterval(14 * 86_400))
        #expect(standing.access(to: Shop.pro) == .onTrial(period, via: Shop.trial))
        #expect(standing.trial(Shop.trial) == .running(period))
        #expect(standing.nextExpiry == period.endsAt)
    }

    @Test("the same standing answers differently for a later date, without reading any clock")
    func dateIsAParameter() {
        let standing = standing([OwnedProduct(id: Shop.trial, originalPurchaseDate: now)])
        let end = now.addingTimeInterval(14 * 86_400)
        #expect(standing.access(to: Shop.pro, at: end.addingTimeInterval(-1)) != .none)
        #expect(standing.access(to: Shop.pro, at: end) == .none)
    }

    @Test("a trial is over AT its end, not a moment after")
    func exclusiveEnd() {
        let period = TrialTerms(duration: .seconds(10), targets: [Shop.pro]).period(startingAt: now)
        #expect(period.isRunning(at: now.addingTimeInterval(9.999)))
        #expect(!period.isRunning(at: now.addingTimeInterval(10)))
    }

    @Test("a trial that has ended is used, remembers when, and lends nothing")
    func usedTrial() {
        let started = now.addingTimeInterval(-20 * 86_400)
        let standing = standing([OwnedProduct(id: Shop.trial, originalPurchaseDate: started)])
        let period = TrialPeriod(startedAt: started, endsAt: started.addingTimeInterval(14 * 86_400))
        #expect(standing.trial(Shop.trial) == .used(period))
        #expect(standing.access(to: Shop.pro) == .none)
        #expect(standing.nextExpiry == nil)
    }

    @Test("owning the unlock beats a trial, running or over")
    func unlockBeatsTrial() {
        let pro = OwnedProduct(id: Shop.pro, originalPurchaseDate: now)
        let standing = standing([OwnedProduct(id: Shop.trial, originalPurchaseDate: now), pro])
        #expect(standing.access(to: Shop.pro) == .owned(pro))
    }

    @Test("the next expiry after a moment is the next still to come, however long ago the standing was read")
    func nextExpiryAfter() {
        let catalogue: Catalogue = [
            .unlock("a"), .unlock("b"),
            .trial("short", of: ["a"], lasting: .seconds(10 * 86_400)),
            .trial("long", of: ["b"], lasting: .seconds(30 * 86_400)),
        ]
        let read = now.addingTimeInterval(-20 * 86_400)
        let standing = resolver.standing(
            owned: [
                OwnedProduct(id: "short", originalPurchaseDate: read), OwnedProduct(id: "long", originalPurchaseDate: read),
            ], catalogue: catalogue, asOf: read)
        #expect(standing.nextExpiry == read.addingTimeInterval(10 * 86_400))
        #expect(standing.nextExpiry(after: now) == read.addingTimeInterval(30 * 86_400))
        #expect(standing.nextExpiry(after: read.addingTimeInterval(30 * 86_400)) == nil)
    }

    @Test("a non-renewing subscription dated ahead of the clock is looked at when it begins, and when it ends")
    func nextExpiryNonRenewing() {
        let catalogue: Catalogue = [.nonRenewing("season", lasting: .seconds(30 * 86_400))]
        let starts = now.addingTimeInterval(60)
        let standing = resolver.standing(
            owned: [OwnedProduct(id: "season", originalPurchaseDate: starts)], catalogue: catalogue, asOf: now)
        #expect(standing.access(to: "season") == .none)
        #expect(standing.nextExpiry == starts)
        #expect(standing.nextExpiry(after: starts) == starts.addingTimeInterval(30 * 86_400))
    }

    @Test("a sub-second trial keeps its fraction")
    func subSecond() {
        let period = TrialTerms(duration: .milliseconds(300), targets: [Shop.pro]).period(startingAt: now)
        #expect(abs(period.endsAt.timeIntervalSince(now) - 0.3) < 0.000_001)
    }
}

@Suite("Access, as a yes, a no, or not yet")
struct ProductAccessTests {
    private let owned = OwnedProduct(id: Shop.pro, originalPurchaseDate: Shop.epoch)
    private let period = TrialPeriod(startedAt: Shop.epoch, endsAt: Shop.epoch.addingTimeInterval(60))

    /// Three answers, because the third is the one that matters: a `Bool` has nowhere to
    /// put "the store has not answered", and read as "no" it shows a paying customer the
    /// paywall at every launch.
    @Test("granted is true when owned or on trial, false when not, and NIL until the store has answered")
    func isGranted() {
        #expect(ProductAccess.owned(owned).isGranted == true)
        #expect(ProductAccess.onTrial(period, via: Shop.trial).isGranted == true)
        #expect(ProductAccess.none.isGranted == false)
        #expect(ProductAccess.unknown.isGranted == nil)
    }
}

@Suite("What counts")
struct OwnershipRuleTests {
    private let resolver = StandingResolver()
    private let now = Shop.epoch

    @Test("a trial counts only when this account bought it", arguments: [
        (Ownership.purchased, true), (.familyShared, false), (.assigned, false), (.unrecognised, false),
    ])
    func trial(ownership: Ownership, counts: Bool) {
        let owned = OwnedProduct(id: Shop.trial, originalPurchaseDate: now, ownership: ownership)
        #expect(resolver.counts(owned, in: Shop.catalogue) == counts)
    }

    @Test("an unlock that honours Family Sharing counts however it arrived", arguments: [
        Ownership.purchased, .familyShared, .assigned, .unrecognised,
    ])
    func sharedUnlock(ownership: Ownership) {
        let owned = OwnedProduct(id: Shop.pro, originalPurchaseDate: now, ownership: ownership)
        #expect(resolver.counts(owned, in: Shop.catalogue))
    }

    @Test("an unlock that ignores Family Sharing does not count when shared", arguments: [
        (Ownership.purchased, true), (.assigned, true), (.familyShared, false), (.unrecognised, false),
    ])
    func unsharedUnlock(ownership: Ownership, counts: Bool) {
        let catalogue: Catalogue = [.unlock(Shop.pro, familySharing: .ignored)]
        let owned = OwnedProduct(id: Shop.pro, originalPurchaseDate: now, ownership: ownership)
        #expect(resolver.counts(owned, in: catalogue) == counts)
    }

    @Test("a non-renewing subscription counts when bought, or assigned as a seat, and not when shared", arguments: [
        (Ownership.purchased, true), (.assigned, true), (.familyShared, false), (.unrecognised, false),
    ])
    func nonRenewing(ownership: Ownership, counts: Bool) {
        let catalogue: Catalogue = [.nonRenewing("season", lasting: .seconds(60))]
        let owned = OwnedProduct(id: "season", originalPurchaseDate: now, ownership: ownership)
        #expect(resolver.counts(owned, in: catalogue) == counts)
    }

    @Test("listed twice, this account's own purchase wins, then the earlier")
    func duplicates() {
        let shared = OwnedProduct(id: Shop.pro, originalPurchaseDate: now.addingTimeInterval(-100), ownership: .familyShared)
        let own = OwnedProduct(id: Shop.pro, originalPurchaseDate: now)
        let standing = resolver.standing(owned: [shared, own], catalogue: Shop.catalogue, asOf: now)
        #expect(standing.ownership(of: Shop.pro) == own)
        let later = OwnedProduct(id: Shop.pro, originalPurchaseDate: now.addingTimeInterval(100), ownership: .familyShared)
        #expect(resolver.standing(owned: [later, shared], catalogue: Shop.catalogue, asOf: now).ownership(of: Shop.pro) == shared)
    }

    @Test("a non-renewing subscription bought twice is held as its latest purchase, and both count")
    func nonRenewingTwice() {
        let catalogue: Catalogue = [.nonRenewing("season", lasting: .seconds(60))]
        let first = OwnedProduct(id: "season", originalPurchaseDate: now)
        let second = OwnedProduct(id: "season", originalPurchaseDate: now.addingTimeInterval(30))
        let standing = resolver.standing(owned: [second, first], catalogue: catalogue, asOf: now)
        #expect(standing.ownership(of: "season") == second)
        #expect(standing.nonRenewing("season", at: now) == .active(NonRenewingPeriod(startedAt: now, endsAt: now.addingTimeInterval(120))))
    }
}
