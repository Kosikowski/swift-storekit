//
//  StatusSnapshot.swift
//  PurchaseStoreKit
//
//  A subscription status's fields, copied out of StoreKit.
//
//  StoreKit's own values are kept as they are — the renewal state, the expiration reason —
//  because what they *mean* is decided one layer up, in `SubscriptionTriage`, where a test
//  can reach it. A `Product.SubscriptionInfo.Status` cannot be made outside StoreKit; its
//  parts can.
//

import Foundation
import StoreKit

struct StatusSnapshot: Sendable {
    let state: Product.SubscriptionInfo.RenewalState
    /// The latest transaction in the group. Never finished from here: it is only read.
    let transaction: TransactionSnapshot
    /// Nil when the renewal info did not verify: then nothing is known of what comes next.
    let renewal: RenewalSnapshot?
}

struct RenewalSnapshot: Sendable {
    let willAutoRenew: Bool
    let autoRenewPreference: String?
    let expirationReason: Product.SubscriptionInfo.RenewalInfo.ExpirationReason?
    let isInBillingRetry: Bool
    let gracePeriodExpirationDate: Date?
    let priceIncreaseStatus: Product.SubscriptionInfo.RenewalInfo.PriceIncreaseStatus
    let renewalPrice: Decimal?
    let currencyCode: String?
    let eligibleWinBackOfferIDs: [String]
}
