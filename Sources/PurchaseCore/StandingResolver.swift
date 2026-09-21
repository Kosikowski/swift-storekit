//
//  StandingResolver.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  From what the store lists to what counts.
//
//  The rule is one function, used for the listing and for a purchase's own
//  transaction alike, because the two must never disagree: a purchase that grants
//  this account nothing must not be held as though it had.
//

public import Foundation

/// Decides which of the store's transactions count for this account.
public struct StandingResolver: Sendable {
    public init() {}

    /// Whether `owned` counts towards what this account may use.
    ///
    /// - A product the catalogue does not list is someone else's and is ignored.
    /// - A trial counts only when this account bought it. Shared or assigned, its
    ///   date is somebody else's.
    /// - An unlock counts however it arrived, unless its entry says Family Sharing is
    ///   ignored, in which case a shared one does not. A subscription likewise.
    ///
    /// Revocation is not a parameter: a transaction the store has taken back never
    /// becomes an `OwnedProduct` in the first place.
    public func counts(_ owned: OwnedProduct, in catalogue: Catalogue) -> Bool {
        guard let entry = catalogue.entry(for: owned.id) else { return false }
        switch entry.kind {
        case .trial:
            return owned.ownership == .purchased
        case .unlock(.honoured):
            return true
        case .unlock(.ignored):
            return owned.ownership == .purchased || owned.ownership == .assigned
        case let .subscription(terms):
            return counts(owned.ownership, under: terms.familySharing)
        case .nonRenewing:
            // App Store Connect shares no non-renewing subscription with a family; one that
            // arrived shared anyway would carry somebody else's date, as a trial would.
            return owned.ownership == .purchased || owned.ownership == .assigned
        }
    }

    private func counts(_ ownership: Ownership, under familySharing: CatalogueEntry.FamilySharing) -> Bool {
        switch familySharing {
        case .honoured: true
        case .ignored: ownership == .purchased || ownership == .assigned
        }
    }

    /// The standing that `owned` amounts to.
    ///
    /// **Walks the whole list.** An earlier implementation elsewhere answered on the
    /// first match and "free" otherwise, which held for exactly as long as there was
    /// one product: a second one, listed first, silently revoked the first.
    ///
    /// Where the same product appears twice — a purchase carried from `purchase()`
    /// and the store's own listing of it, a moment apart — the one bought by this
    /// account wins, then the earlier.
    ///
    /// Subscriptions are not holdings: what a group amounts to is `subscriptions`, from
    /// `subscription(in:statuses:listed:catalogue:)`.
    public func standing(
        owned: [OwnedProduct], catalogue: Catalogue, asOf date: Date,
        subscriptions: [SubscriptionGroupID: SubscriptionStanding] = [:]
    ) -> Standing {
        var holdings: [ProductID: OwnedProduct] = [:]
        // Every purchase of a non-renewing subscription counts: each bought time. Measured,
        // the listing keeps every one (spike/README.md, n02), and a purchase held beside
        // the listing is the same one, a moment early: one date, one purchase.
        var nonRenewing: [ProductID: Set<Date>] = [:]
        for candidate in owned where catalogue.entry(for: candidate.id)?.subscriptionTerms == nil && counts(candidate, in: catalogue) {
            if catalogue.entry(for: candidate.id)?.nonRenewingTerms != nil {
                nonRenewing[candidate.id, default: []].insert(candidate.purchaseDate)
            }
            guard let existing = holdings[candidate.id] else {
                holdings[candidate.id] = candidate
                continue
            }
            if Self.prefers(candidate, over: existing, catalogue: catalogue) { holdings[candidate.id] = candidate }
        }
        return Standing(
            phase: .known, asOf: date, catalogue: catalogue, holdings: holdings, subscriptions: subscriptions,
            nonRenewing: nonRenewing.mapValues { $0.sorted() })
    }

    /// What one subscription group amounts to.
    ///
    /// **The status decides; the listing stands in only when no status could be read.**
    /// Measured, the listing cannot decide: the iOS simulator lists a subscription in
    /// billing retry, and at a renewal both platforms list nothing for a moment
    /// (spike/README.md). So `statuses` — what `status(for:)` said, nil if it could not be
    /// asked — is taken whenever there is one, and `listed` only when there is not.
    ///
    /// Only statuses for products the catalogue puts in this group are looked at, and
    /// only those that count by their entry's Family Sharing. Of the entitled, the highest
    /// level decides, the account's own before anybody else's, then the one that lasts
    /// longer: `statuses.first` was how other libraries lost a family member's
    /// subscription behind the person's own expired one.
    public func subscription(
        in group: SubscriptionGroupID, statuses: [HeldSubscription]?, listed: [HeldSubscription], catalogue: Catalogue
    ) -> SubscriptionStanding {
        let candidates = (statuses ?? listed).filter { held in
            guard let terms = catalogue.entry(for: held.product)?.subscriptionTerms, terms.group == group else { return false }
            return counts(held.ownership, under: terms.familySharing)
        }
        guard !candidates.isEmpty else { return .none }
        let level = { (held: HeldSubscription) in catalogue.entry(for: held.product)?.subscriptionTerms?.level ?? .max }
        let all = candidates.sorted { a, b in
            if a.isEntitled != b.isEntitled { return a.isEntitled }
            if level(a) != level(b) { return level(a) < level(b) }
            let aOwn = a.ownership == .purchased
            let bOwn = b.ownership == .purchased
            if aOwn != bOwn { return aOwn }
            if a.accessEnds != b.accessEnds { return a.accessEnds > b.accessEnds }
            return a.product < b.product
        }
        if let entitled = all.first(where: \.isEntitled) { return .active(entitled, all: all) }
        let latest = all.max { $0.periodEnds < $1.periodEnds } ?? all[0]
        return .inactive(latest, all: all)
    }

    /// Of two copies of a product: the account's own, then the earlier — or, for a
    /// non-renewing subscription, of which every purchase is a copy, the latest.
    private static func prefers(_ candidate: OwnedProduct, over existing: OwnedProduct, catalogue: Catalogue) -> Bool {
        let candidateIsOwn = candidate.ownership == .purchased
        let existingIsOwn = existing.ownership == .purchased
        if candidateIsOwn != existingIsOwn { return candidateIsOwn }
        if catalogue.entry(for: candidate.id)?.nonRenewingTerms != nil { return candidate.purchaseDate > existing.purchaseDate }
        return candidate.originalPurchaseDate < existing.originalPurchaseDate
    }
}
