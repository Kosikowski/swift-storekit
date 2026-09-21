//
//  SubscriptionStanding.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What one subscription group amounts to for this account.
//

import Foundation

/// Where this account stands in one subscription group.
///
/// A group can have more than one status — the person's own and a family member's — and
/// every one is kept in `all`. The one that decides is the entitled status at the highest
/// level, the person's own before anybody else's, then the one that lasts longer; or, when
/// none is entitled, the most recent.
public enum SubscriptionStanding: Hashable, Sendable {
    /// The store has not answered yet. **Not the same as `none`**.
    case unknown
    /// Never subscribed in this group, as far as the store says.
    case none
    /// Entitled: subscribed, or in a grace period.
    case active(HeldSubscription, all: [HeldSubscription])
    /// Held once and not entitled now: lapsed, in billing retry, or taken back.
    case inactive(HeldSubscription, all: [HeldSubscription])

    /// The status that decides, if there is one.
    public var current: HeldSubscription? {
        switch self {
        case .unknown, .none: nil
        case let .active(held, _), let .inactive(held, _): held
        }
    }

    /// Entitled: true. Not: false. **Not answered yet: nil.**
    public var isActive: Bool? {
        switch self {
        case .unknown: nil
        case .none, .inactive: false
        case .active: true
        }
    }

    /// Every status the store reported for the group.
    public var all: [HeldSubscription] {
        switch self {
        case .unknown, .none: []
        case let .active(_, all), let .inactive(_, all): all
        }
    }
}

extension SubscriptionStanding {
    /// **A lapse at the end of a period is believed only when it lasts.**
    ///
    /// Measured: at every renewal, for up to 0.7 s on the Mac, the status says the
    /// subscription has expired, and in the iOS simulator also that it will not renew and
    /// is eligible for a win-back offer, with the listing empty — before the renewal
    /// arrives (spike/README.md). Believed at once, every subscriber would be locked out at
    /// every renewal, for a moment or, with nothing scheduled to look again, until the
    /// next launch.
    ///
    /// So a reading that says a subscription has ended is not believed yet when all of
    /// these hold, and `previous` stands instead:
    ///
    /// - `previous` was active, and the renewal it knew of was to happen (or it knew of
    ///   none: a status that could not be read is no evidence of a lapse) — the last month of
    ///   a commitment not to be renewed is not to happen, whatever `willRenew` says;
    /// - its period has ended, and less than `renewalGrace` ago — a reading that says
    ///   "ended" before the period is up is a real change, a refund say;
    /// - the reading says `expired`, or has nothing: billing retry and revocation are
    ///   definite, and are believed at once.
    func believed(over previous: SubscriptionStanding, at date: Date, renewalGrace: TimeInterval) -> SubscriptionStanding {
        guard case let .active(before, _) = previous, before.willRenewAtPeriodEnd != false else { return self }
        guard date >= before.periodEnds, date < before.periodEnds.addingTimeInterval(renewalGrace) else { return self }
        switch self {
        case .active, .unknown:
            return self
        case .none:
            return previous
        case let .inactive(now, _):
            if case .expired = now.state { return previous }
            return self
        }
    }
}
