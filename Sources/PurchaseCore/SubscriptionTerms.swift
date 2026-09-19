//
//  SubscriptionTerms.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What the catalogue says of an auto-renewable subscription: its group and its level.
//
//  Both are restated from App Store Connect. The group is what StoreKit is asked for
//  statuses by, with nothing loaded first. The level is what chooses between two
//  statuses in one group — the person's own and a family member's — with no prices
//  loaded either. A transaction carries neither reliably.
//

/// The terms of an auto-renewable subscription.
public struct SubscriptionTerms: Hashable, Sendable {
    public let group: SubscriptionGroupID

    /// Its rank in the group, as App Store Connect numbers it: **1 is the highest**.
    /// Measured: moving from level 2 to level 1 is an upgrade, at once, and the
    /// transaction left behind is marked upgraded (spike/README.md).
    public let level: Int

    /// Whether a family member's subscription counts for this account.
    public let familySharing: CatalogueEntry.FamilySharing

    public init(group: SubscriptionGroupID, level: Int, familySharing: CatalogueEntry.FamilySharing = .honoured) {
        self.group = group
        self.level = level
        self.familySharing = familySharing
    }
}
