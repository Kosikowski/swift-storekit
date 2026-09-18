//
//  ProductLoadState.swift
//  PurchaseCore
//
//  Layer: Application
//

/// Where the catalogue load stands. **Separate from whether the standing is known**,
/// and nothing about what a person may use waits on it: prices come over the
/// network, ownership does not.
public enum ProductLoadState: Hashable, Sendable {
    case notLoaded
    case loading
    case loaded
    /// The last load failed. Products from an earlier, successful load are kept.
    case failed(PurchaseError)
}
