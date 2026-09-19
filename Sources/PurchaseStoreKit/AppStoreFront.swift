//
//  AppStoreFront.swift
//  PurchaseStoreKit
//
//  The App Store, behind `PurchaseCore`'s ports.
//
//  All the decisions are here and none of the StoreKit calls are: those are in
//  `LiveStoreKitGateway`, which this holds behind a protocol. That is what lets the
//  finish policy, the error mapping and the whole-listing read be tested under plain
//  `swift test`, where real StoreKit is not available at all.
//

public import PurchaseCore

/// The App Store.
///
///     let store = PurchaseStore(catalogue: catalogue, front: AppStoreFront(catalogue: catalogue))
public struct AppStoreFront: StoreFront, StoreDiagnosing {
    public let catalogue: Catalogue
    private let gateway: any StoreKitGateway
    private let logger: any PurchaseLogging

    public init(catalogue: Catalogue, logger: any PurchaseLogging = SilentPurchaseLogger()) {
        self.init(catalogue: catalogue, gateway: LiveStoreKitGateway(logger: logger), logger: logger)
    }

    init(catalogue: Catalogue, gateway: any StoreKitGateway, logger: any PurchaseLogging = SilentPurchaseLogger()) {
        self.catalogue = catalogue
        self.gateway = gateway
        self.logger = logger
    }

    // MARK: - ProductCatalogueLoading

    /// **In a task nobody cancels.** StoreKit answers a *cancelled* request for
    /// products with an empty list — not an error: measured, 0 of 2, on the Mac and on
    /// iOS — and an empty list reads as "the store sells this build nothing". It is
    /// the products' twin of what a cancelled task reads from the listing, and SwiftUI
    /// cancels `.task` whenever a view goes away. `PurchaseStore` already asks from a
    /// task of its own; this is for whoever asks the front directly.
    public func products() async throws(PurchaseError) -> [StoreProduct] {
        let result = await Task { [catalogue, gateway] () -> Result<[StoreProduct], PurchaseError> in
            do {
                let products = try await gateway.products(for: catalogue.identifiers)
                return .success(products.filter { catalogue.contains($0.id) })
            } catch {
                switch StoreKitErrorMapping.verdict(for: error) {
                // Nobody backed out of anything: a request that was cancelled under
                // us is a request that failed, and must never pass for an answer.
                case .cancelled: return .failure(.system)
                case let .failure(failure): return .failure(failure)
                }
            }
        }.value
        return try result.get()
    }

    // MARK: - OwnershipReading

    /// The whole listing, and **nothing is finished here**: reading has no side
    /// effects. A transaction left unfinished reaches `transactionUpdates()`, which
    /// is listening from launch, and is finished there.
    ///
    /// An entitlement that does not verify is logged, every time it is read: this is
    /// the path on which an owner is locked out by it, and "why is a paying customer
    /// looking at the paywall" should not need a diagnosis to be run to answer.
    /// Somebody else's product is not logged — it is listed at every read, for good.
    public func ownedProducts() async -> [OwnedProduct] {
        var owned: [OwnedProduct] = []
        for snapshot in await gateway.currentEntitlements() {
            switch TransactionTriage.verdict(for: snapshot, catalogue: catalogue) {
            case let .adopt(product): owned.append(product)
            case .unverified: logger.log(.unverifiedTransactionIgnored(snapshot.productID))
            case .withdrawn, .foreign: break
            }
        }
        return owned
    }

    // MARK: - ProductPurchasing

    public func purchase(
        _ id: ProductID, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        guard catalogue.contains(id) else { throw .productUnavailable }
        let result: GatewayPurchaseResult?
        do {
            result = try await gateway.purchase(id, confirmation: confirmation)
        } catch {
            switch StoreKitErrorMapping.verdict(for: error) {
            case .cancelled: return .cancelled
            case let .failure(failure): throw failure
            }
        }
        switch result {
        case nil:
            throw .productUnavailable
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        case .unrecognised:
            // A failure, so that it is *said*: the person may have been charged, and
            // Restore Purchases is what finds out.
            throw .unknown(typeName: "Product.PurchaseResult")
        case let .success(snapshot):
            switch TransactionTriage.verdict(for: snapshot, catalogue: catalogue) {
            case let .adopt(product):
                await snapshot.finish()
                return .purchased(product)
            case .withdrawn:
                await snapshot.finish()
                throw .revoked
            case .unverified:
                // Not finished: nothing has been delivered for it, and the store
                // offers an unfinished transaction again. And never "cancelled" —
                // this person may have been charged.
                logger.log(.unverifiedTransactionIgnored(snapshot.productID))
                throw .unverified
            case .foreign:
                logger.log(.foreignTransactionIgnored(snapshot.productID))
                throw .productUnavailable
            }
        }
    }

    // MARK: - PurchaseRestoring

    public func restorePurchases() async throws(PurchaseError) -> RestoreOutcome {
        do {
            try await gateway.sync()
            return .completed
        } catch {
            // Dismissing the store's sign-in prompt is thrown, not returned.
            switch StoreKitErrorMapping.verdict(for: error) {
            case .cancelled: return .cancelled
            case let .failure(failure): throw failure
            }
        }
    }

    // MARK: - TransactionObserving

    /// Every transaction that arrives on its own, finished where it should be and
    /// announced with its facts.
    ///
    /// **What was left unfinished is asked for, not waited for.** Apple says the updates
    /// sequence hands over unfinished transactions once, as the app launches `[Apple]`.
    /// This listener starts with the first command and not with the process, and a
    /// listener started a moment after an unfinished purchase was handed nothing in six
    /// seconds while `Transaction.unfinished` still held it `[ran]`. So the backlog is
    /// read once, after subscribing, and a purchase approved or made while the app was
    /// not running is not left hanging on when the app happened to call `start()`. One
    /// that turns up both ways is finished twice and announced twice, which costs
    /// nothing.
    ///
    /// A grant is announced with its dates because it arrives *before* the listing has
    /// it; a withdrawal, because a refund is exactly what a listener holding an
    /// unlisted purchase needs to hear about.
    public func transactionUpdates() -> AsyncStream<TransactionUpdate> {
        // Subscribed first, so nothing falls between the backlog and the stream.
        let source = gateway.updates()
        let (stream, continuation) = AsyncStream<TransactionUpdate>.makeStream()
        let task = Task { [catalogue, logger, gateway] in
            func take(_ snapshot: TransactionSnapshot) async {
                switch TransactionTriage.verdict(for: snapshot, catalogue: catalogue) {
                case let .adopt(product):
                    await snapshot.finish()
                    continuation.yield(.granted(product))
                case .withdrawn:
                    await snapshot.finish()
                    continuation.yield(.withdrawn(snapshot.productID))
                case .unverified:
                    logger.log(.unverifiedTransactionIgnored(snapshot.productID))
                case .foreign:
                    logger.log(.foreignTransactionIgnored(snapshot.productID))
                }
            }
            for snapshot in await gateway.unfinished() { await take(snapshot) }
            for await snapshot in source { await take(snapshot) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - StoreDiagnosing

    /// In a task nobody cancels, like every other read here: asked from a cancelled
    /// task, StoreKit returns no products and no entitlements, and this would diagnose
    /// "the store sells nothing to this build" — and advise attaching a `.storekit`
    /// file — for no better reason than that a view went away.
    public func diagnose() async -> StoreDiagnosis {
        await Task { await diagnoseNow() }.value
    }

    private func diagnoseNow() async -> StoreDiagnosis {
        // A store that could not be *asked* is not a store that sells nothing, and the
        // advice for the two is opposite: check the network, or fix the scheme.
        var received: [StoreProduct] = []
        var failure: PurchaseError?
        do throws(PurchaseError) {
            received = try await products()
        } catch {
            failure = error
        }
        let entitlements = await gateway.currentEntitlements()
        let ours = entitlements.filter { catalogue.contains($0.productID) }
        return StoreDiagnosis(
            requested: catalogue.identifiers,
            received: Set(received.map(\.id)),
            catalogueFailure: failure,
            verifiedEntitlements: ours.filter { $0.verification == .verified }.count,
            unverifiedEntitlements: ours.filter { $0.verification == .unverified }.count,
            foreignEntitlements: entitlements.count - ours.count,
            environment: entitlements.compactMap(\.environment).first)
    }
}
