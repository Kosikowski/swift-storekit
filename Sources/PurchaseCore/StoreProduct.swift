//
//  StoreProduct.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What the store says about a product it sells: the words and the price.
//

public import Foundation

/// A product as the store describes it to this person, in their language and currency.
public struct StoreProduct: Hashable, Sendable, Identifiable {
    public let id: ProductID
    public let displayName: String
    public let description: String

    /// The price as the store spells it for this storefront. **Show this, and never
    /// a price formatted from a number of your own**: the currency, the rounding and
    /// the tax treatment are the store's to decide.
    public let displayPrice: String

    /// The same price as a number, for comparing with zero and nothing else.
    public let price: Decimal

    public let isFamilyShareable: Bool

    /// For an auto-renewable subscription, its period and its offers. Nil for anything else.
    public let subscription: Subscription?

    public init(
        id: ProductID, displayName: String, description: String = "", displayPrice: String,
        price: Decimal, isFamilyShareable: Bool = false, subscription: Subscription? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.price = price
        self.isFamilyShareable = isFamilyShareable
        self.subscription = subscription
    }
}

extension StoreProduct {
    /// What the store says of an auto-renewable subscription: how long each period is, and
    /// the offers it carries. `displayPrice` is per period.
    ///
    /// **An offer here is one the product has, not one this person may have.** Whether they
    /// may have the introductory offer is `PurchaseStore.introductoryOffer(for:)`, and which
    /// win-back offers they may have is `winBackOffers(in:)`: the store's answers, from Apple.
    public struct Subscription: Hashable, Sendable {
        public let group: SubscriptionGroupID
        public let period: BillingPeriod
        public let introductoryOffer: OfferTerms?
        /// For current and former subscribers, as the app decides.
        public let promotionalOffers: [OfferTerms]
        /// For people who have lapsed, as Apple decides.
        public let winBackOffers: [OfferTerms]

        public init(
            group: SubscriptionGroupID, period: BillingPeriod, introductoryOffer: OfferTerms? = nil,
            promotionalOffers: [OfferTerms] = [], winBackOffers: [OfferTerms] = []
        ) {
            self.group = group
            self.period = period
            self.introductoryOffer = introductoryOffer
            self.promotionalOffers = promotionalOffers
            self.winBackOffers = winBackOffers
        }
    }
}
