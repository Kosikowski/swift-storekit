//
//  Renewal.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What happens to a subscription at the end of its period, as the store says now.
//

public import Foundation

/// What the store says will happen when the period ends.
public struct Renewal: Hashable, Sendable {
    public enum PriceIncrease: Hashable, Sendable {
        case none
        /// The price is going up and the person has not yet agreed. Unagreed, it lapses.
        case awaitingConsent
        /// Agreed to, or only notified of: the next renewal is at the new price.
        case agreed
    }

    /// Whether it renews at the end of this period. False once the person has switched
    /// auto-renew off: access still lasts to the end of the period.
    public let willRenew: Bool

    /// The product it will renew as. Differs from the one held while a downgrade, or a
    /// crossgrade to another duration, waits for the renewal; nil if it will not renew.
    public let nextProduct: ProductID?

    /// The next charge, with any offer applied, in `currencyCode`. Nil if not said.
    public let price: Decimal?
    public let currencyCode: String?

    public let priceIncrease: PriceIncrease

    /// The win-back offers Apple says this person may have now, best first. Empty while
    /// subscribed, and in a grace period or billing retry.
    public let winBackOffers: [OfferID]

    public init(
        willRenew: Bool, nextProduct: ProductID?, price: Decimal? = nil, currencyCode: String? = nil,
        priceIncrease: PriceIncrease = .none, winBackOffers: [OfferID] = []
    ) {
        self.willRenew = willRenew
        self.nextProduct = nextProduct
        self.price = price
        self.currencyCode = currencyCode
        self.priceIncrease = priceIncrease
        self.winBackOffers = winBackOffers
    }
}
