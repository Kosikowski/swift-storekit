//
//  PurchaseEvent.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What happened, in a form that is safe to write down.
//
//  Identifiers, counts, typed errors and type names only. No transaction, no
//  description string from the store, nothing an account could be recognised by.
//

/// Something worth logging.
public enum PurchaseEvent: Hashable, Sendable {
    case standingResolved(owned: Set<ProductID>)
    case catalogueLoaded(Set<ProductID>)
    /// The store returned **no products at all** for the identifiers asked for.
    ///
    /// Nearly always a development build the App Store has never heard of — ad-hoc
    /// signed, no team — launched without a StoreKit configuration on the scheme's
    /// Run action. Such a build also owns nothing and cannot buy anything, and what
    /// the developer sees is a Buy button that does nothing.
    case catalogueLoadedEmpty(requested: Set<ProductID>)
    case catalogueLoadFailed(PurchaseError)
    case purchaseStarted(ProductID)
    case purchased(ProductID)
    case purchasePending(ProductID)
    case purchaseCancelled(ProductID)
    case purchaseFailed(ProductID, PurchaseError)
    /// Completed by the store, and not counted for this account.
    case purchaseNotCounted(ProductID)
    case restoreCompleted
    case restoreCancelled
    case restoreFailed(PurchaseError)
    /// A transaction arrived on its own: approved, bought elsewhere, or refunded.
    case transactionUpdated(ProductID)
    /// A transaction whose signature does not check out, bought, arriving on its own
    /// or read from the listing. Not counted; and, where it was handed over to be
    /// finished, left unfinished on purpose, so the store offers it again.
    case unverifiedTransactionIgnored(ProductID)
    /// For a product this catalogue does not list. Left alone: it is whoever owns
    /// that product's to finish.
    case foreignTransactionIgnored(ProductID)
    case unrecognisedConfirmationAnchor(typeName: String)
    /// A subscription group's statuses could not be read. The listing stands in for it,
    /// and nothing is known of its renewals until the next read.
    case subscriptionStatusUnavailable(SubscriptionGroupID)
}
