//
//  ProductCatalogueLoading.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Asks the store what it sells.
///
/// This goes over the network, and offline it can take a long time to fail. Nothing
/// that decides what a person may *use* should ever wait on it: what is owned is a
/// different question (`OwnershipReading`), answered from the store's own cache.
public protocol ProductCatalogueLoading: Sendable {
    /// The catalogue's products as the store describes them. Fewer than were asked
    /// for is not an error — a product not yet approved is simply absent.
    func products() async throws(PurchaseError) -> [StoreProduct]
}
