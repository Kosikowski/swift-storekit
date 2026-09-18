//
//  OwnershipReading.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Asks the store what this account holds.
///
/// The contract every conformer keeps:
///
/// - **The whole listing, every time.** Never the first match.
/// - **Only what the store vouches for**: verified, and not taken back.
/// - **It does not throw.** The store answers this from its cache, offline included;
///   there is no failure a caller could act on, and "nothing" is a legitimate answer.
/// - **No side effects.** Reading finishes nothing.
///
/// One hazard the contract cannot remove: asked from a **cancelled task**, the real
/// store answers with nothing at all, which is indistinguishable from owning
/// nothing. `PurchaseStore` never asks from a task anything else can cancel.
public protocol OwnershipReading: Sendable {
    func ownedProducts() async -> [OwnedProduct]
}
