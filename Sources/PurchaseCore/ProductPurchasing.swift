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
public protocol ProductPurchasing: Sendable {
    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws(PurchaseError) -> PurchaseOutcome
}
