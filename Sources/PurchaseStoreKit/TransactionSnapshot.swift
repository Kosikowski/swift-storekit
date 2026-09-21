//
//  TransactionSnapshot.swift
//  PurchaseStoreKit
//
//  A StoreKit transaction, as plain values.
//
//  A `Transaction` cannot be constructed outside StoreKit, so code that takes one
//  cannot be tested without a store behind it — and `SKTestSession` does not work in
//  a package test target at all. Everything that *decides* something about a
//  transaction therefore takes one of these instead, and the only code left
//  untested by `swift test` is the dozen lines that copy the fields across.
//

import Foundation
import PurchaseCore
import StoreKit

struct TransactionSnapshot: Sendable {
    enum Verification: Hashable, Sendable {
        case verified
        /// The signature does not check out. The fields are what the payload
        /// *claims*, and are good for nothing but saying which product it was.
        case unverified
    }

    let productID: ProductID
    let originalPurchaseDate: Date
    let purchaseDate: Date
    let ownership: Ownership
    /// The store has taken it back: a refund, or the end of Family Sharing.
    let isRevoked: Bool
    let verification: Verification
    /// "Xcode", "Sandbox" or "Production".
    let environment: String?
    /// Tells the store this transaction has been dealt with. Until it is called the
    /// store delivers the transaction again at every launch.
    let finish: @Sendable () async -> Void

    /// StoreKit's identifier for it.
    var id: UInt64? = nil
    /// For a subscription, when the period this transaction bought ends.
    var expirationDate: Date? = nil
    /// When the store took it back, if it has.
    var revocationDate: Date? = nil
    /// A subscription transaction the person has upgraded away from. Apple: look for the
    /// transaction with the higher level instead.
    var isUpgraded: Bool = false
    /// The offer this transaction was bought with, as StoreKit spells it.
    var offerType: StoreKit.Transaction.OfferType? = nil
    var offerID: String? = nil
    var offerPaymentMode: StoreKit.Transaction.Offer.PaymentMode? = nil
    /// On a 12-month commitment (26.4): which month of how many. Copied straight to the
    /// package's own value, since a field newer than the deployment target cannot be stored.
    var commitment: SubscriptionCommitment? = nil
}
