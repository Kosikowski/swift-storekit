//
//  TransactionTriage.swift
//  PurchaseStoreKit
//
//  What to do with a transaction, decided in one place.
//
//  Apple documents neither case that matters here — what to do with a transaction
//  that does not verify, or with one for a product the app does not recognise — so
//  these are this package's decisions, and the reasons are written down:
//
//  · **Foreign** (not in the catalogue): leave it alone. Finishing removes a
//    transaction from the store's redelivery queue for good, so finishing someone
//    else's means *their* handler never sees it. An unfinished foreign transaction
//    turning up again at every launch is the correct behaviour; it is waiting for
//    whoever owns that product.
//  · **Unverified**: unlock nothing and do not finish. Nothing has been delivered
//    for it, and the store offers an unfinished transaction again. This is also what
//    Apple's own samples do, without saying so.
//  · **Withdrawn** (verified, ours, and revoked): finish it — it has been dealt with —
//    and count nothing.
//  · **A past period withdrawn** (a subscription transaction refunded after its period
//    had ended): finish it, count nothing, and take nothing away. Measured, refunding the
//    first period of a subscription that has renewed revokes that transaction only, and
//    the subscription carries on (spike/README.md). Announced as a withdrawal of the
//    *product*, it would drop the hold on the renewal that is current.
//  · **Superseded** (a subscription transaction upgraded away from): finish it and count
//    nothing: the transaction for the higher level is the one that counts `[Apple]`.
//

import PurchaseCore

enum TransactionTriage {
    enum Verdict: Hashable, Sendable {
        /// Verified, ours, and standing. Finish it and count it.
        case adopt(OwnedProduct)
        case withdrawn
        case pastPeriodWithdrawn
        case superseded(OwnedProduct)
        case unverified
        case foreign
    }

    static func verdict(for snapshot: TransactionSnapshot, catalogue: Catalogue) -> Verdict {
        // Foreign first: whether somebody else's transaction verifies is not our business.
        guard catalogue.contains(snapshot.productID) else { return .foreign }
        guard snapshot.verification == .verified else { return .unverified }
        let isSubscription = catalogue.entry(for: snapshot.productID)?.subscriptionTerms != nil
        if snapshot.isRevoked {
            if isSubscription, let ended = snapshot.expirationDate, let revoked = snapshot.revocationDate, revoked >= ended {
                return .pastPeriodWithdrawn
            }
            return .withdrawn
        }
        let product = OwnedProduct(
            id: snapshot.productID, originalPurchaseDate: snapshot.originalPurchaseDate,
            purchaseDate: snapshot.purchaseDate, ownership: snapshot.ownership,
            expirationDate: isSubscription ? snapshot.expirationDate : nil,
            offer: isSubscription ? SubscriptionTriage.offer(of: snapshot) : nil)
        if isSubscription, snapshot.isUpgraded { return .superseded(product) }
        return .adopt(product)
    }
}
