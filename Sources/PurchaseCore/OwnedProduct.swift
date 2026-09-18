//
//  OwnedProduct.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  One thing the store says this account holds.
//

public import Foundation

/// A product the store vouches for this account holding, and since when.
///
/// Only ever built from a transaction the store has verified and has not taken back.
/// Whether it *counts* — a family-shared trial does not — is `StandingResolver`'s
/// decision, not a property of the value.
public struct OwnedProduct: Hashable, Sendable, Identifiable {
    public let id: ProductID

    /// When the account first bought this. For a non-consumable bought again — on
    /// another device, after a reinstall — this is still the first date, which is
    /// what makes a trial dated by it one trial and not one per device.
    public let originalPurchaseDate: Date

    public let purchaseDate: Date
    public let ownership: Ownership

    public init(
        id: ProductID, originalPurchaseDate: Date, purchaseDate: Date? = nil,
        ownership: Ownership = .purchased
    ) {
        self.id = id
        self.originalPurchaseDate = originalPurchaseDate
        self.purchaseDate = purchaseDate ?? originalPurchaseDate
        self.ownership = ownership
    }
}
