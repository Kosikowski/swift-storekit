//
//  EverythingOwnedStoreFront.swift
//  PurchaseDirectDistribution
//
//  A store for builds that are sold some other way.
//
//  A Developer ID build, a Setapp build, an enterprise build: there is no App Store
//  behind them, so the real store lists nothing, and a build that *is* the paid
//  edition would lock its own buyers out. The answer is a different store at the
//  composition root — not an `#if` buried inside the one that talks to StoreKit.
//
//  **This ships in release builds, by design**, unlike the simulated store. It cannot
//  be switched on by an argument or a preference; it is what the app was built with.
//
//  In a product of its own, so that only a build that is sold some other way links
//  it. An App Store build has no use for a store in which everything is owned, and
//  while this lived in PurchaseCore every App Store build carried one all the same.
//

import Foundation
public import PurchaseCore

/// A store in which every unlock is already owned and nothing is for sale.
public struct EverythingOwnedStoreFront: StoreFront {
    public let catalogue: Catalogue

    public init(catalogue: Catalogue) {
        self.catalogue = catalogue
    }

    public func products() async throws(PurchaseError) -> [StoreProduct] { [] }

    /// Every unlock, owned since long ago. Trials are left out, so none is on offer:
    /// everything a trial would lend is already held.
    public func ownedProducts() async -> [OwnedProduct] {
        catalogue.entries
            .filter { $0.trialTerms == nil }
            .map { OwnedProduct(id: $0.id, originalPurchaseDate: .distantPast) }
    }

    public func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        throw .purchaseNotAllowed
    }

    public func restorePurchases() async throws(PurchaseError) -> RestoreOutcome { .completed }

    public func transactionUpdates() -> AsyncStream<TransactionUpdate> {
        AsyncStream { $0.finish() }
    }
}
