//
//  TrialStatus.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Where one trial stands for this account.
//

/// Where a trial stands.
///
/// An interface usually draws three things from this: a button that starts the trial
/// (`available`), the same button disabled and saying when the trial ended (`used` —
/// hiding it leaves people wondering where it went), and nothing (`notOffered`,
/// `running`, and `unknown`, which is every launch until the store has answered).
public enum TrialStatus: Hashable, Sendable {
    /// The store has not answered yet. Offer nothing and judge nothing by this.
    case unknown
    /// Never taken, and there is something it would lend that is not already owned.
    case available
    case running(TrialPeriod)
    /// Taken, and over. It cannot be taken again: buying an owned non-consumable
    /// hands back the original transaction, original date and all.
    case used(TrialPeriod)
    /// Not a trial this catalogue knows, or everything it stands in for is owned.
    case notOffered
}
