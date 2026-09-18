//
//  TrialTerms.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What a trial product is a trial *of*, and for how long.
//
//  The trial here is the shape App Review guideline 3.1.1 accepts for an app that
//  does not sell a subscription: a free non-consumable, named for what it is
//  ("14-day Trial"), bought like anything else. Its start is not recorded by the
//  app at all. It is the transaction's original purchase date, which the App Store
//  keeps against the account — so it is the same trial on every device, survives a
//  reinstall, cannot be edited, and carries on rather than restarting when the
//  product is bought again.
//

public import Foundation

/// The terms of a trial product.
public struct TrialTerms: Hashable, Sendable {
    /// How long the trial runs from its purchase. A `Duration` rather than a number
    /// of days so that a test can run a whole trial in a third of a second against
    /// the real clock, which is the only way to see the scheduled re-read fire.
    public let duration: Duration

    /// The unlocks this trial stands in for while it runs.
    ///
    /// The one relation between products this package knows about, and it is here
    /// because a store fact depends on it: a trial is not on offer to someone who
    /// already owns everything it would lend them.
    public let targets: Set<ProductID>

    public init(duration: Duration, targets: Set<ProductID>) {
        self.duration = duration
        self.targets = targets
    }

    /// The period of a trial bought at `start`.
    public func period(startingAt start: Date) -> TrialPeriod {
        TrialPeriod(startedAt: start, endsAt: start.addingTimeInterval(duration.timeInterval))
    }
}
