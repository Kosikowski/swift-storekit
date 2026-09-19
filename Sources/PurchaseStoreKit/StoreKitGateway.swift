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
    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws -> GatewayPurchaseResult?

    func sync() async throws

    /// Everything not yet finished, verified or not, catalogue or not.
    func unfinished() async -> [TransactionSnapshot]

    /// Transactions arriving on their own, verified or not, catalogue or not.
    func updates() -> AsyncStream<TransactionSnapshot>

    /// Every status StoreKit has for the group. Throws StoreKit's own error.
    func subscriptionStatuses(for group: SubscriptionGroupID) async throws -> [StatusSnapshot]

    /// Statuses as they change, for any group.
    func statusUpdates() -> AsyncStream<StatusSnapshot>

    /// StoreKit's own answer, which keeps its first value for the life of the process.
    func isEligibleForIntroductoryOffer(in group: SubscriptionGroupID) async -> Bool

    /// Every transaction the account has had in the group, verified or not.
    func transactions(in group: SubscriptionGroupID) async -> [TransactionSnapshot]
}
