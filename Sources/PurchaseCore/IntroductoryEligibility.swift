//
//  IntroductoryEligibility.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Whether this person may have a subscription's introductory offer.
//
//  Four answers, not two, because others' two were wrong both ways: "eligible" assumed
//  when the product could not be fetched, "the product has a trial" taken for "this person
//  may have it", and "eligible" for a product with no introductory offer at all (plan).
//

/// Whether this person may have a subscription's introductory offer, and on what terms.
public enum IntroductoryEligibility: Hashable, Sendable {
    /// Not answered yet: the prices have not loaded, or the store has not said. **Show the
    /// regular price.** The payment sheet has the last word, and a plain purchase applies
    /// the offer if it is due.
    case unknown
    /// The product has no introductory offer.
    case noOffer
    /// Apple says this person may have it, and nothing the store has seen says they have
    /// used it in this group.
    case eligible(OfferTerms)
    /// Used already, on any plan in the group — one per group per account — or Apple says not.
    case ineligible
}
