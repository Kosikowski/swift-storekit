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
}
