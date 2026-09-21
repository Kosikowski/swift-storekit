//
//  WinBackOffer.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  A win-back offer Apple says this person may have.
//

/// A win-back offer Apple says this person may have now: for the plan they lapsed from, on
/// the terms the store states. Bought with `PurchaseOptions(offer: .winBack(id))`.
public struct WinBackOffer: Hashable, Sendable {
    /// The plan it is for: the one the person most recently lapsed from `[Apple]`.
    public let product: ProductID
    public let id: OfferID
    public let terms: OfferTerms

    public init(product: ProductID, id: OfferID, terms: OfferTerms) {
        self.product = product
        self.id = id
        self.terms = terms
    }
}
