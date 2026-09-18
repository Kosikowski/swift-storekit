//
//  PurchaseActivity.swift
//  PurchaseCore
//
//  Layer: Application
//

/// What the store is in the middle of. One thing at a time: a second purchase begun
/// while one is under way throws `alreadyInProgress` rather than queueing a second
/// payment sheet behind the first.
public enum PurchaseActivity: Hashable, Sendable {
    case idle
    case purchasing(ProductID)
    case restoring

    public var isBusy: Bool { self != .idle }
}
