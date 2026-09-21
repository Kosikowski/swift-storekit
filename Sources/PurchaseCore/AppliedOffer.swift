//
//  AppliedOffer.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  The offer a period of a subscription was bought with, and the kinds of offer there are.
//
//  Read from the transaction, never assumed from what was asked for: measured, a purchase
//  can go through at the full price with the offer silently not applied (spike/README.md).
//

/// What kind of offer: who decides who may have it, and how it is bought.
public enum OfferKind: Hashable, Sendable {
    /// Once per subscription group per account. Apple decides who may have it, and a plain
    /// purchase applies it.
    case introductory
    /// For current and former subscribers, as the app decides; signed by the app's server.
    case promotional
    /// Redeemed with a code, in Apple's sheet or the App Store.
    case code
    /// For people who have lapsed, as Apple decides from criteria set in App Store Connect.
    case winBack
    /// A kind StoreKit added later — the retention offers of autumn 2026 have no name in
    /// the 27 SDK. Said, not guessed.
    case unrecognised
}

/// How an offer is paid for.
public enum OfferPaymentMode: Hashable, Sendable {
    case freeTrial
    /// A discounted price each period, for a number of periods.
    case payAsYouGo
    /// One discounted price for the whole of the offer's time.
    case payUpFront
    /// An offer code for a one-time purchase.
    case oneTime
    case unrecognised
}

/// The offer a transaction was bought with.
public struct AppliedOffer: Hashable, Sendable {
    public let kind: OfferKind
    /// Nil for an introductory offer, which has none.
    public let id: OfferID?
    /// Nil when the store did not say.
    public let paymentMode: OfferPaymentMode?

    public init(kind: OfferKind, id: OfferID? = nil, paymentMode: OfferPaymentMode? = nil) {
        self.kind = kind
        self.id = id
        self.paymentMode = paymentMode
    }
}
