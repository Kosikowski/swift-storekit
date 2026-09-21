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
import Synchronization

/// The App Store.
///
///     let store = PurchaseStore(catalogue: catalogue, front: AppStoreFront(catalogue: catalogue))
public struct AppStoreFront: StoreFront, StoreDiagnosing, SubscriptionStatusReading, IntroductoryEligibilityReading {
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
            // Upgraded away from, it is the higher plan's transaction that counts.
            case .withdrawn, .pastPeriodWithdrawn, .superseded, .foreign: break
            }
        }
        return owned
    }

    // MARK: - ProductPurchasing

    public func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        guard catalogue.contains(id) else { throw .productUnavailable }
        let result: GatewayPurchaseResult?
        do {
            result = try await gateway.purchase(id, options: options, confirmation: confirmation)
        } catch {
            switch StoreKitErrorMapping.verdict(for: error) {
            case .cancelled: return .cancelled
            case let .failure(failure): throw failure
            }
        }
        guard let result else { throw .productUnavailable }
        return try await Self.outcome(of: result, catalogue: catalogue, logger: logger)
    }

    /// What a purchase came to, from what StoreKit handed back: to `purchase()` here, or
    /// to one of Apple's views (`PurchaseStore.takePurchase(_:of:)`). One judgement for
    /// both, so a purchase made in Apple's view is finished, and refused, as one made here.
    static func outcome(
        of result: GatewayPurchaseResult, catalogue: Catalogue, logger: any PurchaseLogging
    ) async throws(PurchaseError) -> PurchaseOutcome {
        switch result {
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
            case let .adopt(product), let .superseded(product):
                await snapshot.finish()
                return .purchased(product)
            case .withdrawn, .pastPeriodWithdrawn:
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
        // Three sources, and the stream ends only when all of them have.
        let sources = Countdown(3) { continuation.finish() }
        let task = Task { [catalogue, logger, gateway] in
            func take(_ snapshot: TransactionSnapshot) async {
                switch TransactionTriage.verdict(for: snapshot, catalogue: catalogue) {
                case let .adopt(product):
                    await snapshot.finish()
                    continuation.yield(.granted(product))
                case .withdrawn:
                    await snapshot.finish()
                    continuation.yield(.withdrawn(snapshot.productID))
                case .pastPeriodWithdrawn, .superseded:
                    // Dealt with, and nothing to announce: a period long over, or a plan
                    // the person moved up from. The status says the rest.
                    await snapshot.finish()
                case .unverified:
                    logger.log(.unverifiedTransactionIgnored(snapshot.productID))
                case .foreign:
                    logger.log(.foreignTransactionIgnored(snapshot.productID))
                }
            }
            for snapshot in await gateway.unfinished() { await take(snapshot) }
            for await snapshot in source { await take(snapshot) }
            sources.end()
        }
        // An expiry sends no transaction at all, and a cancellation or a grace period
        // none either (measured, spike/README.md): a status change is how they are heard.
        let statuses = gateway.statusUpdates()
        let statusTask = Task { [catalogue, logger] in
            for await status in statuses {
                switch SubscriptionTriage.verdict(for: status, catalogue: catalogue) {
                case let .status(held): continuation.yield(.subscriptionChanged(held))
                case .unverified: logger.log(.unverifiedTransactionIgnored(status.transaction.productID))
                case .foreign: break
                }
            }
            sources.end()
        }
        // A purchase asked for outside the app: a request, for the app to act on. Only a
        // catalogue product's.
        let intents = gateway.purchaseIntents()
        let intentTask = Task { [catalogue, logger] in
            for await intent in intents where catalogue.contains(intent.productID) {
                continuation.yield(.purchaseRequested(Self.request(from: intent, logger: logger)))
            }
            sources.end()
        }
        continuation.onTermination = { _ in
            task.cancel()
            statusTask.cancel()
            intentTask.cancel()
        }
        return stream
    }

    /// The offer the person chose goes with the request, so that buying it never charges the
    /// regular price in its place. An introductory offer needs no asking.
    static func request(from intent: IntentSnapshot, logger: any PurchaseLogging) -> RequestedPurchase {
        guard let type = intent.offerType else { return RequestedPurchase(product: intent.productID) }
        let kind = LiveStoreKitGateway.kind(type)
        switch (kind, intent.offerID.map { OfferID(rawValue: $0) }) {
        case (.introductory, _):
            return RequestedPurchase(product: intent.productID)
        case let (.winBack, id?):
            return RequestedPurchase(product: intent.productID, offer: .winBack(id))
        case let (.promotional, id?):
            return RequestedPurchase(product: intent.productID, offer: .promotional(id))
        default:
            logger.log(.requestedOfferUnrecognised(intent.productID))
            return RequestedPurchase(product: intent.productID)
        }
    }

    // MARK: - SubscriptionStatusReading

    /// Every status for each group, **in a task nobody cancels**: asked from a cancelled
    /// task StoreKit answers with an empty array (measured, spike/README.md), which reads
    /// as "never subscribed". A group StoreKit could not be asked about is left out, and
    /// logged — never answered empty.
    public func subscriptionStatuses(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: [HeldSubscription]] {
        await Task { [catalogue, gateway, logger] () -> [SubscriptionGroupID: [HeldSubscription]] in
            var answer: [SubscriptionGroupID: [HeldSubscription]] = [:]
            for group in groups.sorted() {
                do {
                    var held: [HeldSubscription] = []
                    for status in try await gateway.subscriptionStatuses(for: group) {
                        switch SubscriptionTriage.verdict(for: status, catalogue: catalogue) {
                        case let .status(subscription) where subscription.group == group: held.append(subscription)
                        case .unverified: logger.log(.unverifiedTransactionIgnored(status.transaction.productID))
                        case .status, .foreign: break
                        }
                    }
                    answer[group] = held
                } catch {
                    logger.log(.subscriptionStatusUnavailable(group))
                }
            }
            return answer
        }.value
    }

    // MARK: - IntroductoryEligibilityReading

    /// StoreKit's answer, **unless the group's own transactions say the offer was used.**
    /// Measured, `isEligibleForIntroOffer(for:)` keeps its first answer for the life of the
    /// process: true before a purchase with the offer and still true after it
    /// (spike/README.md). A verified transaction bought with it is the better witness.
    ///
    /// In a task nobody cancels: a cancelled read of the transactions would find none, and
    /// "none" would offer again an introductory offer already used.
    public func introductoryEligibility(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: Bool] {
        await Task { [gateway] () -> [SubscriptionGroupID: Bool] in
            var answer: [SubscriptionGroupID: Bool] = [:]
            for group in groups.sorted() {
                // The Apple Account's own: a family member's purchase uses up nothing of this one's [Apple].
                let used = await gateway.transactions(in: group).contains { snapshot in
                    snapshot.verification == .verified && snapshot.ownership == .purchased
                        && SubscriptionTriage.offer(of: snapshot)?.kind == .introductory
                }
                answer[group] = used ? false : await gateway.isEligibleForIntroductoryOffer(in: group)
            }
            return answer
        }.value
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

/// Calls `done` when the last of `count` things has ended.
private final class Countdown: Sendable {
    private let left: Mutex<Int>
    private let done: @Sendable () -> Void

    init(_ count: Int, then done: @escaping @Sendable () -> Void) {
        left = Mutex(count)
        self.done = done
    }

    func end() {
        let last = left.withLock { left in
            left -= 1
            return left == 0
        }
        if last { done() }
    }
}
