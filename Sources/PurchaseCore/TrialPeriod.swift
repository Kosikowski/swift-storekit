//
//  TrialPeriod.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  When a trial began and when it ends.
//
//  **A trial ends at an instant, not on a day.** "Until 30 September" is wrong by
//  evening for someone who started in the evening, so whoever words this for a
//  person should show the time as well. The wording is the app's; the instant is
//  here.
//

public import Foundation

/// The span of one trial.
public struct TrialPeriod: Hashable, Sendable {
    /// The trial transaction's original purchase date, as the App Store has it.
    public let startedAt: Date
    public let endsAt: Date

    public init(startedAt: Date, endsAt: Date) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    /// Whether the trial is still running at `date`.
    ///
    /// The end is exclusive: at `endsAt` exactly the trial is over. That is what
    /// lets a re-read scheduled *for* `endsAt` find it over, rather than finding it
    /// running for one more instant and having to be scheduled again.
    ///
    /// The date is a parameter and never the clock. A check that reads the clock
    /// itself cannot be tested for expiry without waiting for it.
    public func isRunning(at date: Date) -> Bool {
        date < endsAt
    }
}
