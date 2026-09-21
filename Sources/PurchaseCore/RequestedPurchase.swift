//
//  RequestedPurchase.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  A purchase someone started outside the app.
//
//  A promoted in-app purchase tapped on the App Store, or a win-back offer taken there
//  with streamlined purchasing switched off, reaches the app as StoreKit's `PurchaseIntent`
//  `[Apple]`: a request, not a purchase. Nothing has been bought. When to go on with it —
//  at once, after onboarding, or not at all because it is already owned — is the app's.
//

/// A purchase the person asked for outside the app, waiting for the app to go on with it.
public struct RequestedPurchase: Hashable, Sendable, Identifiable {
    public let product: ProductID
    /// The offer it came with: a win-back offer, when streamlined purchasing is off.
    public let offer: PurchaseOptions.Offer?

    public init(product: ProductID, offer: PurchaseOptions.Offer? = nil) {
        self.product = product
        self.offer = offer
    }

    public var id: RequestedPurchase { self }

    /// The options to buy it with: its offer, if it came with one.
    public var options: PurchaseOptions { PurchaseOptions(offer: offer) }
}
