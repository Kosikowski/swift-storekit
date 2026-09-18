//
//  TransactionObserving.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Reports transactions that arrive on their own: an Ask to Buy approved, a purchase
/// made on another device, an offer code redeemed in the App Store, a refund.
/// Purchases made through `ProductPurchasing` in this process are *not* repeated here.
///
/// The contract:
///
/// - **The stream yields the facts, not just a signal.** A grant arrives *before* the
///   store's own listing has it (see `TransactionUpdate`), so a listener told only
///   "something changed" reads the listing, finds nothing, and never looks again.
/// - **Registered by the time this returns.** An event the moment after must not be
///   lost to a subscription still being set up on another task.
/// - Each transaction announced has already been finished, where it should be:
///   verified, and for a catalogue product. Others are neither finished nor announced.
public protocol TransactionObserving: Sendable {
    func transactionUpdates() -> AsyncStream<TransactionUpdate>
}
