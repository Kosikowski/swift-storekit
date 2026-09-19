//
//  SubscriptionStatusReading.swift
//  PurchaseCore
//
//  Layer: Port
//
//  What the store says of each subscription group.
//

/// Reads subscription statuses, group by group.
///
/// A role of its own, and optional: a store that sells no subscriptions, or cannot say,
/// need not play it, and then the listing stands in for every group.
///
/// **The contract a conformer keeps.** Every status the store has for each group asked
/// about — the account's own and a family member's are two. A group that **could not be
/// read is left out**, never answered with an empty array: empty means "never subscribed",
/// and to be told that of a paying subscriber is to be locked out. Never throws; no side
/// effects. Measured, a status read from a cancelled task answers with an empty array
/// (spike/README.md), so the store asks from a task nobody cancels, as it reads ownership.
public protocol SubscriptionStatusReading: Sendable {
    func subscriptionStatuses(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: [HeldSubscription]]
}
