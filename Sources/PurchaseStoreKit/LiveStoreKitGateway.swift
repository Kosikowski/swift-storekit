//
//  LiveStoreKitGateway.swift
//  PurchaseStoreKit
//
//  The only file in the package that makes a static StoreKit call.
//
//  Kept thin on purpose: it is the one part `swift test` cannot reach, because
//  StoreKit's test environment needs an app to attach to. It is exercised instead by
//  the hosted suite in `Demo/`. Anything that could be got wrong belongs one layer up.
//

import Foundation
import PurchaseCore
import StoreKit
import SwiftUI
import Synchronization
// `PurchaseAction` lives in the overlay that joins StoreKit to SwiftUI. Xcode loads it
// unasked when a file imports both; SwiftPM does not, so it is named.
import _StoreKit_SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class LiveStoreKitGateway: StoreKitGateway {
    private let logger: any PurchaseLogging
    /// `Product` values, kept so that Buy does not go back to the network for
    /// something the paywall has just loaded.
    private let cache = Mutex<[ProductID: Product]>([:])

    init(logger: any PurchaseLogging) {
        self.logger = logger
    }

    func products(for identifiers: Set<ProductID>) async throws -> [StoreProduct] {
        let products = try await Product.products(for: identifiers.map(\.rawValue))
        cache.withLock { cache in
            for product in products { cache[ProductID(product.id)] = product }
        }
        return products.map { product in
            StoreProduct(
                id: ProductID(product.id), displayName: product.displayName,
                description: product.description, displayPrice: product.displayPrice,
                price: product.price, isFamilyShareable: product.isFamilyShareable,
                subscription: product.subscription.map(Self.subscription(of:)))
        }
    }

    func currentEntitlements() async -> [TransactionSnapshot] {
        var snapshots: [TransactionSnapshot] = []
        for await result in Transaction.currentEntitlements {
            snapshots.append(Self.snapshot(of: result))
        }
        return snapshots
    }

    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws -> GatewayPurchaseResult? {
        guard let product = try await product(id) else { return nil }
        var storeOptions: Set<Product.PurchaseOption> = []
        if let token = options.appAccountToken { storeOptions.insert(.appAccountToken(token)) }
        switch options.offer {
        case nil:
            break
        case let .winBack(offer)?:
            // Bought with the offer itself, which only the product has.
            guard let found = product.subscription?.winBackOffers.first(where: { $0.id == offer.rawValue }) else {
                throw Product.PurchaseError.invalidOfferIdentifier
            }
            storeOptions.insert(.winBackOffer(found))
        case let .promotional(offer)?:
            guard let signature = options.signature else { throw Product.PurchaseError.missingOfferParameters }
            storeOptions.formUnion(Product.PurchaseOption.promotionalOffer(offer.rawValue, compactJWS: signature))
        case .introductoryOverride?:
            guard let signature = options.signature else { throw Product.PurchaseError.missingOfferParameters }
            storeOptions.insert(.introductoryOfferEligibility(compactJWS: signature))
        }
        return Self.result(of: try await purchase(product, options: storeOptions, anchoredTo: confirmation.anchor))
    }

    /// StoreKit's result as plain values: from `purchase()` here, or handed to an app by
    /// one of Apple's views.
    static func result(of result: Product.PurchaseResult) -> GatewayPurchaseResult {
        switch result {
        case let .success(verification): .success(snapshot(of: verification))
        case .pending: .pending
        case .userCancelled: .userCancelled
        // Never `.userCancelled`. A cancellation is answered with silence, and silence
        // is the wrong answer to someone a future kind of result may have charged.
        @unknown default: .unrecognised
        }
    }

    func unfinished() async -> [TransactionSnapshot] {
        var snapshots: [TransactionSnapshot] = []
        for await result in Transaction.unfinished {
            snapshots.append(Self.snapshot(of: result))
        }
        return snapshots
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    /// StoreKit holds a transaction until it is finished, so one that arrives in the
    /// instant before this task begins iterating is delivered when it does.
    func updates() -> AsyncStream<TransactionSnapshot> {
        let (stream, continuation) = AsyncStream<TransactionSnapshot>.makeStream()
        let task = Task {
            for await result in Transaction.updates {
                continuation.yield(Self.snapshot(of: result))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func subscriptionStatuses(for group: SubscriptionGroupID) async throws -> [StatusSnapshot] {
        try await Product.SubscriptionInfo.status(for: group.rawValue).map(Self.snapshot(of:))
    }

    func isEligibleForIntroductoryOffer(in group: SubscriptionGroupID) async -> Bool {
        await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group.rawValue)
    }

    func transactions(in group: SubscriptionGroupID) async -> [TransactionSnapshot] {
        var snapshots: [TransactionSnapshot] = []
        for await result in Transaction.all where result.unsafePayloadValue.subscriptionGroupID == group.rawValue {
            snapshots.append(Self.snapshot(of: result))
        }
        return snapshots
    }

    func statusUpdates() -> AsyncStream<StatusSnapshot> {
        let (stream, continuation) = AsyncStream<StatusSnapshot>.makeStream()
        let task = Task {
            for await status in Product.SubscriptionInfo.Status.updates {
                continuation.yield(Self.snapshot(of: status))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Private

    private func product(_ id: ProductID) async throws -> Product? {
        if let cached = cache.withLock({ $0[id] }) { return cached }
        let fetched = try await Product.products(for: [id.rawValue]).first
        if let fetched { cache.withLock { $0[id] = fetched } }
        return fetched
    }

    /// With several windows open StoreKit has to be told which one the payment sheet
    /// belongs over; left to guess, it may pick another. SwiftUI's `PurchaseAction`
    /// is Apple's recommended route on every platform, and knows its own scene.
    private func purchase(
        _ product: Product, options: Set<Product.PurchaseOption>, anchoredTo anchor: (any Sendable)?
    ) async throws -> Product.PurchaseResult {
        if let action = anchor as? PurchaseAction {
            return try await action(product, options: options)
        }
        #if os(macOS)
        if let window = anchor as? NSWindow {
            return try await product.purchase(confirmIn: window, options: options)
        }
        #elseif canImport(UIKit)
        if let controller = anchor as? UIViewController {
            return try await product.purchase(confirmIn: controller, options: options)
        }
        if let scene = anchor as? UIScene {
            return try await product.purchase(confirmIn: scene, options: options)
        }
        #endif
        if let anchor {
            logger.log(.unrecognisedConfirmationAnchor(typeName: String(reflecting: type(of: anchor))))
        }
        return try await product.purchase(options: options)
    }

    private static func snapshot(of result: VerificationResult<StoreKit.Transaction>) -> TransactionSnapshot {
        // Read either way: an unverified payload is still good for saying which
        // product it claims to be, and the snapshot says it is not to be trusted.
        let transaction = result.unsafePayloadValue
        let verification: TransactionSnapshot.Verification =
            if case .verified = result { .verified } else { .unverified }
        return TransactionSnapshot(
            productID: ProductID(transaction.productID),
            originalPurchaseDate: transaction.originalPurchaseDate,
            purchaseDate: transaction.purchaseDate,
            ownership: ownership(transaction.ownershipType),
            isRevoked: transaction.revocationDate != nil,
            verification: verification,
            environment: transaction.environment.rawValue,
            finish: { await transaction.finish() },
            id: transaction.id,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            offerType: transaction.offer?.type,
            offerID: transaction.offer?.id,
            offerPaymentMode: transaction.offer?.paymentMode)
    }

    private static func snapshot(of status: Product.SubscriptionInfo.Status) -> StatusSnapshot {
        let renewal: RenewalSnapshot? =
            if case let .verified(info) = status.renewalInfo {
                RenewalSnapshot(
                    willAutoRenew: info.willAutoRenew, autoRenewPreference: info.autoRenewPreference,
                    expirationReason: info.expirationReason, isInBillingRetry: info.isInBillingRetry,
                    gracePeriodExpirationDate: info.gracePeriodExpirationDate,
                    priceIncreaseStatus: info.priceIncreaseStatus, renewalPrice: info.renewalPrice,
                    currencyCode: info.currency?.identifier, eligibleWinBackOfferIDs: info.eligibleWinBackOfferIDs,
                    offerType: info.offer?.type, offerID: info.offer?.id, offerPaymentMode: info.offer?.paymentMode)
            } else {
                nil
            }
        return StatusSnapshot(state: status.state, transaction: snapshot(of: status.transaction), renewal: renewal)
    }

    private static func subscription(of info: Product.SubscriptionInfo) -> StoreProduct.Subscription {
        StoreProduct.Subscription(
            group: SubscriptionGroupID(info.subscriptionGroupID), period: period(info.subscriptionPeriod),
            introductoryOffer: info.introductoryOffer.map(terms(of:)),
            promotionalOffers: info.promotionalOffers.map(terms(of:)),
            winBackOffers: info.winBackOffers.map(terms(of:)))
    }

    static func terms(of offer: Product.SubscriptionOffer) -> OfferTerms {
        OfferTerms(
            kind: kind(offer.type), id: offer.id.map(OfferID.init(rawValue:)), paymentMode: paymentMode(offer.paymentMode),
            period: period(offer.period), periodCount: offer.periodCount, displayPrice: offer.displayPrice,
            price: offer.price)
    }

    /// Open sets, as every StoreKit one is (D40): what StoreKit adds later is `unrecognised`.
    static func kind(_ type: Product.SubscriptionOffer.OfferType) -> OfferKind {
        switch type {
        case .introductory: .introductory
        case .promotional: .promotional
        case .winBack: .winBack
        default: .unrecognised
        }
    }

    static func paymentMode(_ mode: Product.SubscriptionOffer.PaymentMode) -> OfferPaymentMode {
        switch mode {
        case .freeTrial: .freeTrial
        case .payAsYouGo: .payAsYouGo
        case .payUpFront: .payUpFront
        default: .unrecognised
        }
    }

    static func period(_ period: Product.SubscriptionPeriod) -> BillingPeriod {
        let unit: BillingPeriod.Unit =
            switch period.unit {
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            @unknown default: .unrecognised
            }
        return BillingPeriod(value: period.value, unit: unit)
    }

    /// `.assigned` is matched by its raw value. The *name* arrived with the 27 SDK — back
    /// deployed, so the value is as old as the type — and spelt out, this file did not
    /// compile with Xcode 26, which the first run on a hosted runner was the first to
    /// find out: nothing on the machine it was written on had the older SDK.
    static func ownership(_ type: StoreKit.Transaction.OwnershipType) -> Ownership {
        switch type {
        case .purchased: .purchased
        case .familyShared: .familyShared
        case StoreKit.Transaction.OwnershipType(rawValue: "ASSIGNED"): .assigned
        default: .unrecognised
        }
    }
}
