//
//  TransactionUpdate.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What the store has just said about a product, **with the facts attached**.
//
//  The first design announced only *which* product had changed, and the listener read
//  the listing again to find out how. Measured against the real store, that is wrong
//  in one direction: when a purchase arrives on its own — an Ask to Buy approved — the
//  update comes *before* the listing has it. At the instant of the update the account
//  still lists nothing; half a second later it lists the product. A listener that
//  re-reads on the update finds nothing, and has no reason ever to look again.
//
//  A refund does not lag: at the instant its update arrives the listing is already
//  empty. So a grant carries its own facts and is believed for a moment, exactly as a
//  purchase made here is, and a withdrawal needs to carry nothing but the product.
//

/// A transaction that arrived on its own.
public enum TransactionUpdate: Hashable, Sendable {
    /// Verified, for a catalogue product, and standing. Whether it *counts* for this
    /// account is still `StandingResolver`'s decision.
    case granted(OwnedProduct)
    /// Taken back: a refund, or the end of Family Sharing.
    case withdrawn(ProductID)
    /// A subscription's status changed — renewed, cancelled, into a grace period or billing
    /// retry, lapsed — with the new status attached. An expiry sends no transaction at all
    /// (measured, spike/README.md), so this is how one is heard while the app runs.
    case subscriptionChanged(HeldSubscription)

    public var productID: ProductID {
        switch self {
        case let .granted(owned): owned.id
        case let .withdrawn(id): id
        case let .subscriptionChanged(held): held.product
        }
    }
}
