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
/// `isGranted` is as far as this goes: a `Bool?`, which still makes it say.
public enum ProductAccess: Hashable, Sendable {
    /// The store has not answered yet. **Not the same as `none`**: wait for the
    /// answer (`knownStanding()`) before judging anything by it.
    case unknown
    case owned(OwnedProduct)
    /// Lent by a trial that is still running.
    case onTrial(TrialPeriod, via: ProductID)
    case none
}

extension ProductAccess {
    /// Owned or lent by a running trial: true. Neither: false. **Not answered yet: nil.**
    ///
    /// Every app derives this, and the ones that derive a `Bool` have to put `unknown`
    /// somewhere — and put it under "no". An optional cannot be tested with `if` until
    /// somebody has decided what nil means for the thing being asked.
    public var isGranted: Bool? {
        switch self {
        case .owned, .onTrial: true
        case .none: false
        case .unknown: nil
        }
    }
}
