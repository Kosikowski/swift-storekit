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
                price: product.price, isFamilyShareable: product.isFamilyShareable)
        }
    }

    func currentEntitlements() async -> [TransactionSnapshot] {
        var snapshots: [TransactionSnapshot] = []
        for await result in Transaction.currentEntitlements {
            snapshots.append(Self.snapshot(of: result))
        }
        return snapshots
    }

    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws -> GatewayPurchaseResult? {
        guard let product = try await product(id) else { return nil }
        let result = try await purchase(product, anchoredTo: confirmation.anchor)
        switch result {
        case let .success(verification): return .success(Self.snapshot(of: verification))
        case .pending: return .pending
        case .userCancelled: return .userCancelled
        // Never `.userCancelled`. A cancellation is answered with silence, and silence
        // is the wrong answer to someone a future kind of result may have charged.
        @unknown default: return .unrecognised
        }
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
    private func purchase(_ product: Product, anchoredTo anchor: (any Sendable)?) async throws -> Product.PurchaseResult {
        if let action = anchor as? PurchaseAction {
            return try await action(product)
        }
        #if os(macOS)
        if let window = anchor as? NSWindow {
            return try await product.purchase(confirmIn: window)
        }
        #elseif canImport(UIKit)
        if let controller = anchor as? UIViewController {
            return try await product.purchase(confirmIn: controller)
        }
        if let scene = anchor as? UIScene {
            return try await product.purchase(confirmIn: scene)
        }
        #endif
        if let anchor {
            logger.log(.unrecognisedConfirmationAnchor(typeName: String(reflecting: type(of: anchor))))
        }
        return try await product.purchase()
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
            finish: { await transaction.finish() })
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
