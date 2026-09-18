//
//  ProductAccess.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Whether this account has the use of one product right now, and by what right.
//

/// What an account's standing amounts to for one product.
///
/// There is deliberately no `Bool` here. Collapsing this to "is it unlocked" throws
/// away `unknown`, and `unknown` read as "no" is the bug where a paying customer
/// meets the paywall at every launch. An app that wants a `Bool` should decide what
/// `unknown` means for the thing being asked — usually "wait" — and say so itself.
public enum ProductAccess: Hashable, Sendable {
    /// The store has not answered yet. **Not the same as `none`**: wait for the
    /// answer (`knownStanding()`) before judging anything by it.
    case unknown
    case owned(OwnedProduct)
    /// Lent by a trial that is still running.
    case onTrial(TrialPeriod, via: ProductID)
    case none
}
