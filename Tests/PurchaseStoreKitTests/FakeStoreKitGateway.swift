import Foundation
import PurchaseCore
import Synchronization

@testable import PurchaseStoreKit

/// StoreKit, as far as `AppStoreFront` can tell. It records which transactions were
/// finished, because what is finished — and what pointedly is not — is most of what
/// the adapter decides.
final class FakeStoreKitGateway: StoreKitGateway {
    struct State {
        var products: Result<[StoreProduct], any Error> = .success([])
        var entitlements: [TransactionSnapshot] = []
        var unfinished: [TransactionSnapshot] = []
        var purchase: Result<GatewayPurchaseResult?, any Error> = .success(nil)
        var sync: (any Error)?
        var finished: [ProductID] = []
        var updates: AsyncStream<TransactionSnapshot>.Continuation?
    }

    let state = Mutex(State())

    var finished: [ProductID] { state.withLock { $0.finished } }

    /// A transaction whose `finish` is recorded here.
    func transaction(
        _ id: ProductID, verification: TransactionSnapshot.Verification = .verified, isRevoked: Bool = false,
        ownership: Ownership = .purchased, date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TransactionSnapshot {
        TransactionSnapshot(
            productID: id, originalPurchaseDate: date, purchaseDate: date, ownership: ownership,
            isRevoked: isRevoked, verification: verification, environment: "Xcode",
            finish: { [weak self] in self?.state.withLock { $0.finished.append(id) } })
    }

    func deliver(_ snapshot: TransactionSnapshot) {
        state.withLock { $0.updates }?.yield(snapshot)
    }

    // MARK: - StoreKitGateway

    func products(for identifiers: Set<ProductID>) async throws -> [StoreProduct] {
        try state.withLock { $0.products }.get()
    }

    func currentEntitlements() async -> [TransactionSnapshot] {
        state.withLock { $0.entitlements }
    }

    func unfinished() async -> [TransactionSnapshot] {
        state.withLock { $0.unfinished }
    }

    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws -> GatewayPurchaseResult? {
        try state.withLock { $0.purchase }.get()
    }

    func sync() async throws {
        if let error = state.withLock({ $0.sync }) { throw error }
    }

    func updates() -> AsyncStream<TransactionSnapshot> {
        let (stream, continuation) = AsyncStream<TransactionSnapshot>.makeStream()
        state.withLock { $0.updates = continuation }
        return stream
    }
}
