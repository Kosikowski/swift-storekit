//
//  AppliedOffer.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  The offer a period of a subscription was bought with.
//
//  Read from the transaction, never assumed from what was asked for: measured, a purchase
//  can go through at the full price with the offer silently not applied (spike/README.md).
//

/// The offer a transaction was bought with.
public struct AppliedOffer: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case introductory
        case promotional
        case code
        case winBack
        /// A kind StoreKit added later — the retention offers of autumn 2026 have no name
        /// in the 27 SDK. Said, not guessed.
        case unrecognised
    }

    public enum PaymentMode: Hashable, Sendable {
        case freeTrial
        case payAsYouGo
        case payUpFront
        /// An offer code for a one-time purchase.
        case oneTime
        case unrecognised
    }

    public let kind: Kind
    /// Nil for an introductory offer, which has none.
    public let id: OfferID?
    /// Nil when the store did not say.
    public let paymentMode: PaymentMode?

    public init(kind: Kind, id: OfferID? = nil, paymentMode: PaymentMode? = nil) {
        self.kind = kind
        self.id = id
        self.paymentMode = paymentMode
    }
}
