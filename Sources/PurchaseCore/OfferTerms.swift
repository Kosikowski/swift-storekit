//
//  OfferTerms.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  An offer's terms, as the store states them for this storefront.
//
//  **Never written in the app's code.** The price, the number of periods and the currency
//  are App Store Connect's, per storefront, and change without a release. A paywall that
//  states them from constants is wrong the day someone edits the offer, and a paywall that
//  shows terms the person cannot have is what App Review rejects `[Apple]`.
//

public import Foundation

/// What an offer charges, and for how long.
///
/// "10.99 a month for two months, then 15.99": `paymentMode` is `.payAsYouGo`, `period` a
/// month, `periodCount` 2, `displayPrice` "£10.99" — and "then 15.99" is the product's own
/// `displayPrice`, which the subscription renews at when the offer ends.
public struct OfferTerms: Hashable, Sendable {
    public let kind: OfferKind
    /// Nil for the introductory offer: a subscription has one, and nothing to tell apart.
    public let id: OfferID?
    public let paymentMode: OfferPaymentMode
    /// One of the offer's periods: a month, in "a month for two months".
    public let period: BillingPeriod
    /// How many of them. For pay as you go, the number of discounted periods; for a free
    /// trial or a price paid up front, 1, and `period` is the whole of it.
    public let periodCount: Int
    /// The price for each period — or for the whole, paid up front — as the store spells
    /// it. **Show this.** Zero, for a free trial.
    public let displayPrice: String
    /// The same as a number, for comparing and nothing else.
    public let price: Decimal

    public init(
        kind: OfferKind, id: OfferID? = nil, paymentMode: OfferPaymentMode, period: BillingPeriod,
        periodCount: Int, displayPrice: String, price: Decimal
    ) {
        self.kind = kind
        self.id = id
        self.paymentMode = paymentMode
        self.period = period
        self.periodCount = periodCount
        self.displayPrice = displayPrice
        self.price = price
    }
}

/// A length of time a subscription, or an offer, is billed by: a week, a month, a year.
public struct BillingPeriod: Hashable, Sendable {
    public enum Unit: Hashable, Sendable {
        case day
        case week
        case month
        case year
        /// A unit StoreKit added later.
        case unrecognised
    }

    public let value: Int
    public let unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    public static func days(_ value: Int) -> BillingPeriod { BillingPeriod(value: value, unit: .day) }
    public static func weeks(_ value: Int) -> BillingPeriod { BillingPeriod(value: value, unit: .week) }
    public static func months(_ value: Int) -> BillingPeriod { BillingPeriod(value: value, unit: .month) }
    public static func years(_ value: Int) -> BillingPeriod { BillingPeriod(value: value, unit: .year) }
}
