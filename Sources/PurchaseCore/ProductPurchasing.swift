//
//  ProductPurchasing.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Buys a product.
///
/// A conformer finishes the transaction it returns, and only that one: a verified
/// transaction for a product in the catalogue. One that does not verify is left
/// unfinished — nothing has been delivered for it, and the store offers an
/// unfinished transaction again — and surfaces as `PurchaseError.unverified`.
///
/// `options` are handed to the store as they are: the offer, with the signature the store
/// has already set for it, the billing plan, and an account token untouched.
public protocol ProductPurchasing: Sendable {
    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome
}

extension ProductPurchasing {
    /// A plain purchase: the product's price, and no account token.
    public func purchase(
        _ id: ProductID, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        try await purchase(id, options: PurchaseOptions(), confirmation: confirmation)
    }
}
