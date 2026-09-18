//
//  StoreKitGateway.swift
//  PurchaseStoreKit
//
//  The static StoreKit calls, behind something a test can stand in for.
//
//  Deliberately dumb. A gateway fetches, forwards and copies fields; it finishes
//  nothing, filters nothing and maps no errors — it throws whatever StoreKit threw.
//  Every decision is `AppStoreFront`'s, above it, where a fake gateway can reach it.
//

import PurchaseCore

protocol StoreKitGateway: Sendable {
    /// Throws StoreKit's own error, untouched.
    func products(for identifiers: Set<ProductID>) async throws -> [StoreProduct]

    /// Every current entitlement, verified or not, catalogue or not.
    func currentEntitlements() async -> [TransactionSnapshot]

    /// Nil when the store has no such product. Throws StoreKit's own error.
    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws -> GatewayPurchaseResult?

    func sync() async throws

    /// Transactions arriving on their own, verified or not, catalogue or not.
    func updates() -> AsyncStream<TransactionSnapshot>
}
