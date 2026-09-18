//
//  PurchaseRestoring.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Asks the store to bring this device up to date with the account.
///
/// On the App Store this prompts for a password, so it is for a Restore Purchases
/// button and nothing else. It is rarely *needed* — the store keeps itself current —
/// but App Review expects the button, and one case does need it: a non-consumable
/// whose Family Sharing was switched on after it was bought reaches the rest of the
/// family only through a restore.
public protocol PurchaseRestoring: Sendable {
    func restorePurchases() async throws(PurchaseError) -> RestoreOutcome
}
