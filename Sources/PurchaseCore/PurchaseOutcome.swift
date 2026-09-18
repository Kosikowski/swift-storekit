//
//  PurchaseOutcome.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  How a purchase ended, as a store reports it.
//
//  Three ways of *ending*; what went wrong is a thrown `PurchaseError`. The split is
//  deliberate. A cancellation is something the person chose and wants no words
//  about; a failure is something that happened to them and needs saying. Folding
//  the two together is how someone who has just approved a payment ends up looking
//  at a sheet that closed and said nothing.
//

/// How a purchase ended.
public enum PurchaseOutcome: Hashable, Sendable {
    /// The store vouches for it. Carried rather than read back: the store lists a
    /// purchase only a moment *after* this returns, and a reader who asks at once is
    /// told the account owns nothing.
    case purchased(OwnedProduct)
    /// Ask to Buy: someone else has to approve it, and the store will say when they
    /// do. Not a failure, and not silence either — "waiting for approval".
    case pending
    /// The person backed out. Say nothing.
    case cancelled
}
