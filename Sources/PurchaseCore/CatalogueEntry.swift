//
//  CatalogueEntry.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  One product the app sells, and the one thing about it the store cannot tell us.
//

/// A product in the app's catalogue.
public struct CatalogueEntry: Hashable, Sendable, Identifiable {
    /// Whether a family member's purchase counts for this account.
    ///
    /// This restates a switch in App Store Connect, which cannot be turned off again
    /// once it is on. It is restated rather than read because nothing in a
    /// *transaction* says how its product is configured — `StoreProduct` reports it,
    /// but only once prices have loaded, and what is owned must never wait for
    /// prices. So the switch being set wrongly costs nothing: a transaction that
    /// arrives through Family Sharing for an entry that says `ignored` is not counted.
    public enum FamilySharing: Hashable, Sendable {
        case honoured
        case ignored
    }

    public enum Kind: Hashable, Sendable {
        /// A one-time purchase that is kept.
        case unlock(familySharing: FamilySharing)
        /// A free non-consumable standing in for other unlocks for a while.
        ///
        /// A trial **never** honours Family Sharing, and there is no option to make
        /// it: a shared trial carries the purchaser's start date, so it would hand
        /// the whole family a trial that is probably already over and take away
        /// their own.
        case trial(TrialTerms)
        /// An auto-renewable subscription, in a group, at a level. What it is worth while
        /// it runs is the store's to say, not the clock's: see `SubscriptionStanding`.
        case subscription(SubscriptionTerms)
        /// A non-renewing subscription: bought for a length of time, and bought again to
        /// go on. Its end is the app's to say, as a trial's is: the store gives it none.
        case nonRenewing(NonRenewingTerms)
    }

    public let id: ProductID
    public let kind: Kind

    public init(id: ProductID, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// A one-time unlock. Family Sharing is honoured unless you say otherwise, which
    /// is what most people selling an unlock intend.
    public static func unlock(_ id: ProductID, familySharing: FamilySharing = .honoured) -> CatalogueEntry {
        CatalogueEntry(id: id, kind: .unlock(familySharing: familySharing))
    }

    /// A trial of one or more unlocks, running for `duration` from its purchase.
    public static func trial(_ id: ProductID, of targets: Set<ProductID>, lasting duration: Duration) -> CatalogueEntry {
        CatalogueEntry(id: id, kind: .trial(TrialTerms(duration: duration, targets: targets)))
    }

    /// An auto-renewable subscription in `group`, at `level` as App Store Connect ranks it:
    /// 1 is the highest. Family Sharing is honoured unless you say otherwise.
    public static func subscription(
        _ id: ProductID, in group: SubscriptionGroupID, level: Int, familySharing: FamilySharing = .honoured
    ) -> CatalogueEntry {
        CatalogueEntry(id: id, kind: .subscription(SubscriptionTerms(group: group, level: level, familySharing: familySharing)))
    }

    /// A non-renewing subscription, each purchase lasting `duration`. Purchases made while
    /// one runs extend it (`.consecutive`) unless the terms say otherwise.
    public static func nonRenewing(
        _ id: ProductID, lasting duration: Duration, stacking: NonRenewingTerms.Stacking = .consecutive
    ) -> CatalogueEntry {
        CatalogueEntry(id: id, kind: .nonRenewing(NonRenewingTerms(duration: duration, stacking: stacking)))
    }

    /// The terms, if this is a non-renewing subscription.
    public var nonRenewingTerms: NonRenewingTerms? {
        if case let .nonRenewing(terms) = kind { terms } else { nil }
    }

    /// The terms, if this is a subscription.
    public var subscriptionTerms: SubscriptionTerms? {
        if case let .subscription(terms) = kind { terms } else { nil }
    }

    /// Whether this is an unlock: a one-time purchase that is kept.
    public var isUnlock: Bool {
        if case .unlock = kind { true } else { false }
    }

    /// The terms, if this is a trial.
    public var trialTerms: TrialTerms? {
        if case let .trial(terms) = kind { terms } else { nil }
    }
}
