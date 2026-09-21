@testable import PurchaseCore
import Foundation
import Testing

/// A group with two plans at one level and one above them, as the spike's is.
private enum Plans {
    static let group: SubscriptionGroupID = "5B1F2A01"
    static let monthly: ProductID = "com.example.pro.monthly"
    static let yearly: ProductID = "com.example.pro.yearly"
    static let premium: ProductID = "com.example.premium.monthly"
    static let other: SubscriptionGroupID = "5B1F2A02"
    static let otherPlan: ProductID = "com.example.other.monthly"

    static let catalogue: Catalogue = [
        .unlock(Shop.pro),
        .subscription(monthly, in: group, level: 2),
        .subscription(yearly, in: group, level: 2),
        .subscription(premium, in: group, level: 1),
        .subscription(otherPlan, in: other, level: 1, familySharing: .ignored),
    ]
}

@Suite("Subscriptions: what a group amounts to")
struct SubscriptionStandingTests {
    private let resolver = StandingResolver()
    private let now = Shop.epoch

    private func held(
        _ state: HeldSubscription.State = .subscribed, product: ProductID = Plans.monthly,
        ownership: Ownership = .purchased, ends: TimeInterval = 86_400, willRenew: Bool? = true
    ) -> HeldSubscription {
        HeldSubscription(
            product: product, group: Plans.catalogue.entry(for: product)?.subscriptionTerms?.group ?? Plans.group,
            ownership: ownership, state: state, firstSubscribed: now.addingTimeInterval(-40 * 86_400),
            periodStarted: now.addingTimeInterval(ends - 30 * 86_400), periodEnds: now.addingTimeInterval(ends),
            renewal: willRenew.map { Renewal(willRenew: $0, nextProduct: $0 ? product : nil) })
    }

    private func group(
        statuses: [HeldSubscription]?, listed: [HeldSubscription] = [], in group: SubscriptionGroupID = Plans.group
    ) -> SubscriptionStanding {
        resolver.subscription(in: group, statuses: statuses, listed: listed, catalogue: Plans.catalogue)
    }

    @Test("on a commitment cancelled, it renews at every month's end but the last", arguments: [
        (5, false, true), (12, false, false), (12, true, true), (11, false, true),
    ])
    func willRenewOnACommitment(month: Int, commitmentRenews: Bool, renews: Bool) {
        let ends = now.addingTimeInterval(86_400)
        var status = held()
        status.commitment = SubscriptionCommitment(
            plan: .monthly, billingPeriod: month, billingPeriods: 12, endsAt: ends, price: 179.88)
        status.renewal?.commitment = CommitmentRenewal(
            willRenew: commitmentRenews, nextProduct: Plans.monthly, plan: .monthly, renewsAt: ends)
        #expect(status.willRenewAtPeriodEnd == renews)
    }

    // MARK: - The catalogue

    @Test("a subscription names its group and level, and the catalogue knows its groups")
    func catalogue() {
        #expect(Catalogue.problems(in: Plans.catalogue.entries).isEmpty)
        #expect(Plans.catalogue.subscriptionGroups == [Plans.group, Plans.other])
        #expect(Plans.catalogue.subscriptions(in: Plans.group).map(\.id) == [Plans.monthly, Plans.yearly, Plans.premium])
        #expect(Plans.catalogue.entry(for: Plans.premium)?.subscriptionTerms?.level == 1)
        #expect(Plans.catalogue.entry(for: Plans.monthly)?.subscriptionTerms?.familySharing == .honoured)
    }

    @Test("a level below 1, and a trial of a subscription, are problems")
    func catalogueProblems() {
        let problems = Catalogue.problems(in: [
            .subscription("s", in: "g", level: 0),
            .trial("t", of: ["s"], lasting: .seconds(1)),
        ])
        #expect(problems == [.trialTargetIsNotAnUnlock(trial: "t", target: "s"), .subscriptionLevelBelowOne("s")])
    }

    @Test("a subscription in a group with no identifier is a problem: its status could never be asked for")
    func catalogueGroupless() {
        #expect(Catalogue.problems(in: [.subscription("s", in: "", level: 1), .subscription("t", in: " ", level: 1)])
            == [.subscriptionWithoutGroup("s"), .subscriptionWithoutGroup("t")])
        #expect(Catalogue.problems(in: [.subscription("s", in: "g", level: 1)]).isEmpty)
    }

    // MARK: - Access follows Apple's rule

    @Test("subscribed is active; so is a GRACE PERIOD whose period has already ended")
    func entitledStates() {
        #expect(group(statuses: [held()]).isActive == true)
        // The trap: in grace the period's end is past, and the person must still be served.
        let grace = held(.inGracePeriod(until: now.addingTimeInterval(86_400)), ends: -3_600)
        let standing = group(statuses: [grace])
        #expect(standing.isActive == true)
        #expect(standing.current?.accessEnds == now.addingTimeInterval(86_400))
        #expect(standing.current?.periodEnds == now.addingTimeInterval(-3_600))
    }

    @Test("billing retry, expired, revoked and a state StoreKit added later are NOT access, and are reported", arguments: [
        HeldSubscription.State.inBillingRetry, .expired(.autoRenewDisabled), .expired(.unstated), .revoked, .unrecognised,
    ])
    func notEntitled(state: HeldSubscription.State) {
        let standing = group(statuses: [held(state, ends: -60)])
        #expect(standing.isActive == false)
        #expect(standing.current?.state == state)
    }

    @Test("never subscribed is none; a group the store says nothing of is none")
    func none() {
        #expect(group(statuses: []) == SubscriptionStanding.none)
        #expect(group(statuses: nil, listed: []) == SubscriptionStanding.none)
    }

    // MARK: - The status decides

    /// Measured: the iOS simulator lists a subscription in billing retry, with a renewal
    /// transaction of its own. The listing cannot decide.
    @Test("the STATUS decides: a listed subscription the status says is in billing retry is not access")
    func statusDecides() {
        let standing = group(statuses: [held(.inBillingRetry, ends: -60)], listed: [held()])
        #expect(standing.isActive == false)
    }

    @Test("the listing stands in only when NO STATUS could be read, and then knows nothing of the renewal")
    func listingStandsIn() {
        let listed = held(willRenew: nil)
        let standing = group(statuses: nil, listed: [listed])
        #expect(standing.isActive == true)
        #expect(standing.current?.renewal == nil)
    }

    // MARK: - Choosing between statuses

    @Test("of two statuses, the ENTITLED one decides, though the other is the account's own")
    func familyBesideOwnExpired() {
        let own = held(.expired(.autoRenewDisabled), ends: -86_400)
        let shared = held(ownership: .familyShared)
        let standing = group(statuses: [own, shared])
        #expect(standing.isActive == true)
        #expect(standing.current == shared)
        #expect(Set(standing.all) == [own, shared])
    }

    @Test("a family member's subscription does not count where the entry ignores Family Sharing")
    func familySharingIgnored() {
        let shared = held(product: Plans.otherPlan, ownership: .familyShared)
        #expect(group(statuses: [shared], in: Plans.other) == SubscriptionStanding.none)
        let assigned = held(product: Plans.otherPlan, ownership: .assigned)
        #expect(group(statuses: [assigned], in: Plans.other).isActive == true)
    }

    @Test("of two entitled, the HIGHER LEVEL decides (level 1 is the highest)")
    func higherLevel() {
        let premium = held(product: Plans.premium, ownership: .familyShared, ends: 60)
        let monthly = held(product: Plans.monthly, ends: 86_400)
        #expect(group(statuses: [monthly, premium]).current == premium)
    }

    @Test("at one level, the account's OWN decides, then the one that lasts longer")
    func ownThenLonger() {
        let shared = held(product: Plans.yearly, ownership: .familyShared, ends: 300 * 86_400)
        let own = held(product: Plans.monthly, ends: 86_400)
        #expect(group(statuses: [shared, own]).current == own)
        let sooner = held(product: Plans.monthly, ends: 60)
        let later = held(product: Plans.yearly, ends: 86_400)
        #expect(group(statuses: [sooner, later]).current == later)
    }

    @Test("with none entitled, the MOST RECENT is the one reported")
    func mostRecentLapse() {
        let older = held(.expired(.billingError), product: Plans.yearly, ends: -90 * 86_400)
        let newer = held(.expired(.autoRenewDisabled), product: Plans.monthly, ends: -86_400)
        #expect(group(statuses: [older, newer]).current == newer)
    }

    @Test("a status for another group, or for somebody else's product, is not this group's")
    func foreign() {
        let foreign = HeldSubscription(
            product: "somebody.elses", group: Plans.group, state: .subscribed, firstSubscribed: now,
            periodStarted: now, periodEnds: now.addingTimeInterval(60))
        #expect(group(statuses: [foreign, held(product: Plans.otherPlan)]) == SubscriptionStanding.none)
    }

    // MARK: - A lapse at a period's end is believed only when it lasts

    private let grace: TimeInterval = 30

    /// Measured: at every renewal StoreKit says for a moment that the subscription has
    /// expired — on iOS also "will not renew" — before the renewal arrives.
    @Test("an EXPIRED reading just after the period ends, for a subscription that was renewing, is not believed yet")
    func renewalMoment() {
        let before = SubscriptionStanding.active(held(ends: 0), all: [held(ends: 0)])
        let reading = group(statuses: [held(.expired(.unstated), ends: 0, willRenew: false)])
        #expect(reading.believed(over: before, at: now.addingTimeInterval(0.5), renewalGrace: grace) == before)
        // And an empty listing, with no status to be had, likewise.
        #expect(SubscriptionStanding.none.believed(over: before, at: now.addingTimeInterval(0.5), renewalGrace: grace) == before)
    }

    @Test("the same reading is believed once renewalGrace has passed")
    func renewalGraceRunsOut() {
        let before = SubscriptionStanding.active(held(ends: 0), all: [held(ends: 0)])
        let reading = group(statuses: [held(.expired(.unstated), ends: 0, willRenew: false)])
        #expect(reading.believed(over: before, at: now.addingTimeInterval(grace), renewalGrace: grace) == reading)
    }

    @Test("a lapse is believed AT ONCE when it was not renewing, or is definite, or comes before the period's end")
    func believedAtOnce() {
        let expired = group(statuses: [held(.expired(.autoRenewDisabled), ends: 0, willRenew: false)])
        let cancelled = SubscriptionStanding.active(held(ends: 0, willRenew: false), all: [])
        #expect(expired.believed(over: cancelled, at: now.addingTimeInterval(0.5), renewalGrace: grace) == expired)

        let renewing = SubscriptionStanding.active(held(ends: 0), all: [])
        for state in [HeldSubscription.State.inBillingRetry, .revoked] {
            let definite = group(statuses: [held(state, ends: 0)])
            #expect(definite.believed(over: renewing, at: now.addingTimeInterval(0.5), renewalGrace: grace) == definite)
        }

        let early = SubscriptionStanding.active(held(ends: 3_600), all: [])
        #expect(expired.believed(over: early, at: now, renewalGrace: grace) == expired)
    }

    @Test("a renewing subscription whose renewal was never read is doubted too: an unread status is no evidence of a lapse")
    func unknownRenewal() {
        let before = SubscriptionStanding.active(held(ends: 0, willRenew: nil), all: [])
        let reading = group(statuses: [held(.expired(.unstated), ends: 0)])
        #expect(reading.believed(over: before, at: now.addingTimeInterval(1), renewalGrace: grace) == before)
    }

    // MARK: - The standing

    private func standing(_ groups: [SubscriptionGroupID: SubscriptionStanding], owned: [OwnedProduct] = []) -> Standing {
        resolver.standing(owned: owned, catalogue: Plans.catalogue, asOf: now, subscriptions: groups)
    }

    @Test("access to the plan HELD is subscribed; to another plan in the group, none; before the store answers, unknown")
    func access() {
        let current = held()
        let standing = standing([Plans.group: .active(current, all: [current])])
        #expect(standing.access(to: Plans.monthly) == .subscribed(current))
        #expect(standing.access(to: Plans.monthly).isGranted == true)
        #expect(standing.access(to: Plans.yearly) == .none)
        #expect(standing.subscription(in: Plans.group) == .active(current, all: [current]))
        #expect(standing.subscription(in: Plans.other) == SubscriptionStanding.none)
        let unknown = Standing.unknown(catalogue: Plans.catalogue)
        #expect(unknown.access(to: Plans.monthly) == .unknown)
        #expect(unknown.subscription(in: Plans.group) == .unknown)
        #expect(unknown.subscription(in: Plans.group).isActive == nil)
    }

    @Test("an inactive subscription is no access")
    func inactiveAccess() {
        let lapsed = held(.inBillingRetry, ends: -60)
        #expect(standing([Plans.group: .inactive(lapsed, all: [lapsed])]).access(to: Plans.monthly) == .none)
    }

    @Test("the next look is when access by the store's last word ends: the grace period's end, not the period's")
    func nextLook() {
        let grace = held(.inGracePeriod(until: now.addingTimeInterval(7_200)), ends: -3_600)
        #expect(standing([Plans.group: .active(grace, all: [grace])]).nextExpiry == now.addingTimeInterval(7_200))
        let lapsed = held(.expired(.billingError), ends: -60)
        #expect(standing([Plans.group: .inactive(lapsed, all: [lapsed])]).nextExpiry == nil)
    }

    @Test("a subscription transaction in the listing is not a holding: groups are answered by the status")
    func notAHolding() {
        let listed = OwnedProduct(id: Plans.monthly, originalPurchaseDate: now)
        let pro = OwnedProduct(id: Shop.pro, originalPurchaseDate: now)
        #expect(standing([:], owned: [listed, pro]).ownedProducts == [pro])
    }

    @Test("a change in a group is news; the same group read again is not")
    func news() {
        let current = held()
        let a = standing([Plans.group: .active(current, all: [current])])
        let b = standing([Plans.group: .active(current, all: [current])])
        let renewedOff = held(willRenew: false)
        let c = standing([Plans.group: .active(renewedOff, all: [renewedOff])])
        #expect(a.saysTheSame(as: b))
        #expect(!a.saysTheSame(as: c))
    }
}
