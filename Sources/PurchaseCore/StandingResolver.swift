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
    ///   ignored, in which case a shared one does not.
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
    public func standing(owned: [OwnedProduct], catalogue: Catalogue, asOf date: Date) -> Standing {
        var holdings: [ProductID: OwnedProduct] = [:]
        for candidate in owned where counts(candidate, in: catalogue) {
            guard let existing = holdings[candidate.id] else {
                holdings[candidate.id] = candidate
                continue
            }
            if Self.prefers(candidate, over: existing) { holdings[candidate.id] = candidate }
        }
        return Standing(phase: .known, asOf: date, catalogue: catalogue, holdings: holdings)
    }

    private static func prefers(_ candidate: OwnedProduct, over existing: OwnedProduct) -> Bool {
        let candidateIsOwn = candidate.ownership == .purchased
        let existingIsOwn = existing.ownership == .purchased
        if candidateIsOwn != existingIsOwn { return candidateIsOwn }
        return candidate.originalPurchaseDate < existing.originalPurchaseDate
    }
}
