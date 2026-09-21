//
//  NonRenewingTerms.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What the catalogue says of a non-renewing subscription: how long each purchase lasts,
//  and how purchases add up.
//
//  **The store gives a non-renewing subscription no end.** Measured, its transaction has
//  no expiration date, the product has no subscription info, and every purchase stays in
//  the listing for good (spike/README.md, n01–n02). How long one lasts is the app's to
//  say, as a trial's is, and it is said here, once.
//

public import Foundation

/// The terms of a non-renewing subscription.
public struct NonRenewingTerms: Hashable, Sendable {
    /// How purchases made while one is running add up. Policy, and the app's: both are
    /// common, and each is fair to someone.
    public enum Stacking: Hashable, Sendable {
        /// A purchase made while one runs begins when it ends: three months bought twice
        /// is six. Nothing paid for is lost.
        case consecutive
        /// Each purchase runs from its own date, overlapping any that runs: Apple's own
        /// sample does this.
        case fromEachPurchase
    }

    /// How long one purchase lasts. A fixed length, as a trial's is, so that a test can
    /// run one in seconds against the real clock.
    public let duration: Duration
    public let stacking: Stacking

    public init(duration: Duration, stacking: Stacking = .consecutive) {
        self.duration = duration
        self.stacking = stacking
    }

    /// The periods `purchases` amount to, oldest first, joined wherever they meet or
    /// overlap, so that the one running is one period however many purchases made it.
    public func periods(of purchases: [Date]) -> [NonRenewingPeriod] {
        let length = duration.timeInterval
        var periods: [NonRenewingPeriod] = []
        for date in purchases.sorted() {
            guard let last = periods.last, date <= last.endsAt else {
                periods.append(NonRenewingPeriod(startedAt: date, endsAt: date.addingTimeInterval(length)))
                continue
            }
            let endsAt =
                switch stacking {
                case .consecutive: last.endsAt.addingTimeInterval(length)
                case .fromEachPurchase: max(last.endsAt, date.addingTimeInterval(length))
                }
            periods[periods.count - 1] = NonRenewingPeriod(startedAt: last.startedAt, endsAt: endsAt)
        }
        return periods
    }
}

/// A stretch of time a non-renewing subscription runs, from one or more purchases.
public struct NonRenewingPeriod: Hashable, Sendable {
    public let startedAt: Date
    public let endsAt: Date

    public init(startedAt: Date, endsAt: Date) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    /// Whether it runs at `date`. The end is exclusive, as a trial's is: a look scheduled
    /// for `endsAt` finds it over.
    public func isRunning(at date: Date) -> Bool {
        date >= startedAt && date < endsAt
    }
}

/// Where a non-renewing subscription stands.
public enum NonRenewingStatus: Hashable, Sendable {
    /// The store has not answered yet.
    case unknown
    /// Never bought, or every purchase taken back.
    case none
    case active(NonRenewingPeriod)
    /// Bought, and over: the last period, ended.
    case ended(NonRenewingPeriod)
}
