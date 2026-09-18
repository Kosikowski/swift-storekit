//
//  GatewayPurchaseResult.swift
//  PurchaseStoreKit
//

/// `Product.PurchaseResult`, with the transaction as a snapshot.
enum GatewayPurchaseResult: Sendable {
    case success(TransactionSnapshot)
    case pending
    case userCancelled
    /// A result StoreKit has added since this was written. **Not a cancellation**: it
    /// may be a new way of having paid, and what it is cannot be known from here.
    case unrecognised
}
