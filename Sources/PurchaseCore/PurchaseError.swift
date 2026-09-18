//
//  PurchaseError.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What can go wrong that the person did not choose.
//
//  **Typed, and with no text in it.** Two reasons. The wording belongs to the app,
//  in the app's languages. And the store's own `localizedDescription` is not safe to
//  show or to log: some of its error variants echo App Store account identifiers.
//  So nothing from the store's error crosses this boundary except which kind it was
//  — and, for one the package does not recognise, the name of its type.
//

/// A failure of a store action.
public enum PurchaseError: Error, Hashable, Sendable {
    /// The store has no such product for this account: not in the catalogue, not
    /// sold in this storefront's configuration, or not yet approved for sale.
    case productUnavailable
    /// Purchases are switched off on this device (Screen Time, a managed profile),
    /// or this store does not sell anything.
    case purchaseNotAllowed
    case notAvailableInStorefront
    case network
    /// The system failed in a way that is nobody's fault here. Trying again is fair.
    case system
    /// The store says the purchase was made and its signature does not check out.
    /// Nothing is unlocked and the transaction is left unfinished, so the store
    /// offers it again. **Never report this as a cancellation**: the person may have
    /// been charged. "Could not be verified; try Restore Purchases, and contact
    /// support if you were charged."
    case unverified
    /// The store completed the purchase and has already taken it back.
    case revoked
    /// A purchase or restore is already under way from somewhere else.
    case alreadyInProgress
    /// The window or scene the payment sheet was to appear over is not usable.
    case invalidConfirmation
    case unsupported
    /// Something this package does not recognise. The associated value is the
    /// error's *type name* and nothing else — never its description.
    case unknown(typeName: String)
}
