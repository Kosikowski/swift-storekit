//
//  PurchaseOptions.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  How a purchase is to be made, beyond which product and over which window.
//

public import Foundation

/// How a purchase is to be made. The default is a plain purchase: the product's price,
/// with an introductory offer applied if Apple says this person may have it.
public struct PurchaseOptions: Hashable, Sendable {
    /// An offer to buy with, beyond the introductory one, which needs asking for only to
    /// override Apple.
    public enum Offer: Hashable, Sendable {
        /// A win-back offer Apple says this person may have: `winBackOffers(in:)`.
        case winBack(OfferID)
        /// A promotional offer. The store asks the app's `OfferSigning` for its signature.
        case promotional(OfferID)
        /// The introductory offer, allowed by the app's server whatever Apple would say —
        /// through `OfferSigning` too.
        case introductoryOverride
    }

    public var offer: Offer?

    /// The billing plan to buy on: `.monthly`, for a 12-month commitment. Nil: up front.
    /// Where the system is older than 26.4 a purchase asking for one fails as `unsupported`
    /// rather than being billed up front without saying so.
    public var billingPlan: BillingPlan?

    /// A UUID of the app's own, for an app with a server that ties purchases to its own
    /// accounts. Handed to the store untouched, and returned by Apple on the transaction
    /// and in its server notifications. Nothing here reads it or decides by it.
    public var appAccountToken: UUID?

    /// The signature `offer` needs, from the app's signer: a compact JWS. **The store's to
    /// set**, having asked for it; a store front only reads it. Nil for an offer that needs
    /// none, and whatever an app might have put here is not what is sent.
    public package(set) var signature: String?

    public init(offer: Offer? = nil, appAccountToken: UUID? = nil, billingPlan: BillingPlan? = nil) {
        self.offer = offer
        self.appAccountToken = appAccountToken
        self.billingPlan = billingPlan
    }
}
