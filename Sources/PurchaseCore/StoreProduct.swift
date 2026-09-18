//
//  StoreProduct.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What the store says about a product it sells: the words and the price.
//

public import Foundation

/// A product as the store describes it to this person, in their language and currency.
public struct StoreProduct: Hashable, Sendable, Identifiable {
    public let id: ProductID
    public let displayName: String
    public let description: String

    /// The price as the store spells it for this storefront. **Show this, and never
    /// a price formatted from a number of your own**: the currency, the rounding and
    /// the tax treatment are the store's to decide.
    public let displayPrice: String

    /// The same price as a number, for comparing with zero and nothing else.
    public let price: Decimal

    public let isFamilyShareable: Bool

    public init(
        id: ProductID, displayName: String, description: String = "", displayPrice: String,
        price: Decimal, isFamilyShareable: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.price = price
        self.isFamilyShareable = isFamilyShareable
    }
}
