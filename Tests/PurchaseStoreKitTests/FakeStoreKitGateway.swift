import Foundation
import PurchaseCore
import StoreKit
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
        /// What the last purchase asked for, as it reached StoreKit.
        var purchaseOptions: PurchaseOptions?
        var sync: (any Error)?
        var finished: [ProductID] = []
        var updates: AsyncStream<TransactionSnapshot>.Continuation?
        var statuses: [SubscriptionGroupID: Result<[StatusSnapshot], any Error>] = [:]
        var statusUpdates: AsyncStream<StatusSnapshot>.Continuation?
        /// StoreKit's own answer about each group's introductory offer. Missing: eligible.
        var eligible: [SubscriptionGroupID: Bool] = [:]
        /// Every transaction the account has had in each group.
        var history: [SubscriptionGroupID: [TransactionSnapshot]] = [:]
        var intents: AsyncStream<IntentSnapshot>.Continuation?
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

    /// A subscription transaction, for a period from `start` to `end`.
    func subscription(
        _ id: ProductID, from start: Date, to end: Date, verification: TransactionSnapshot.Verification = .verified,
        revoked: Date? = nil, isUpgraded: Bool = false, ownership: Ownership = .purchased,
        offer: (StoreKit.Transaction.OfferType, String?, StoreKit.Transaction.Offer.PaymentMode)? = nil
    ) -> TransactionSnapshot {
        TransactionSnapshot(
            productID: id, originalPurchaseDate: start.addingTimeInterval(-86_400 * 90), purchaseDate: start,
            ownership: ownership, isRevoked: revoked != nil, verification: verification, environment: "Xcode",
            finish: { [weak self] in self?.state.withLock { $0.finished.append(id) } },
            expirationDate: end, revocationDate: revoked, isUpgraded: isUpgraded,
            offerType: offer?.0, offerID: offer?.1, offerPaymentMode: offer?.2)
    }

    func announce(_ status: StatusSnapshot) {
        state.withLock { $0.statusUpdates }?.yield(status)
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

    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws -> GatewayPurchaseResult? {
        try state.withLock { state in
            state.purchaseOptions = options
            return state.purchase
        }.get()
    }

    func sync() async throws {
        if let error = state.withLock({ $0.sync }) { throw error }
    }

    func updates() -> AsyncStream<TransactionSnapshot> {
        let (stream, continuation) = AsyncStream<TransactionSnapshot>.makeStream()
        state.withLock { $0.updates = continuation }
        return stream
    }

    /// As measured of the real store: asked from a cancelled task, it answers with nothing.
    func subscriptionStatuses(for group: SubscriptionGroupID) async throws -> [StatusSnapshot] {
        if Task.isCancelled { return [] }
        return try (state.withLock { $0.statuses[group] } ?? .success([])).get()
    }

    func isEligibleForIntroductoryOffer(in group: SubscriptionGroupID) async -> Bool {
        state.withLock { $0.eligible[group] ?? true }
    }

    func transactions(in group: SubscriptionGroupID) async -> [TransactionSnapshot] {
        // As the listing and the statuses are: a cancelled task is told nothing.
        if Task.isCancelled { return [] }
        return state.withLock { $0.history[group] ?? [] }
    }

    func purchaseIntents() -> AsyncStream<IntentSnapshot> {
        let (stream, continuation) = AsyncStream<IntentSnapshot>.makeStream()
        state.withLock { $0.intents = continuation }
        return stream
    }

    func request(_ intent: IntentSnapshot) {
        state.withLock { $0.intents }?.yield(intent)
    }

    func statusUpdates() -> AsyncStream<StatusSnapshot> {
        let (stream, continuation) = AsyncStream<StatusSnapshot>.makeStream()
        state.withLock { $0.statusUpdates = continuation }
        return stream
    }
}
