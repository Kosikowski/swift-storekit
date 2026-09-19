//
//  OfferSigning.swift
//  PurchaseCore
//
//  Layer: Port
//
//  The app's server, signing an offer.
//
//  **The app's, never the package's.** A promotional offer, and the introductory override,
//  are signed with an In-App Purchase key, and that key must never be in an app `[Apple]`.
//  So the package holds no key and signs nothing: it asks this, for the one purchase that
//  needs it, and never goes ahead without an answer. Another library carried on with the
//  purchase when signing failed (plan, "How others do it").
//

public import Foundation

/// Signs an offer, on the app's server.
///
///     struct ServerSigner: OfferSigning {
///         func signature(for request: OfferSignatureRequest) async throws -> String {
///             try await api.signOffer(product: request.product.rawValue, …)   // your server
///         }
///     }
///
/// The server signs with Apple's App Store Server Library: `PromotionalOfferV2SignatureCreator`
/// for a promotional offer, `IntroductoryOfferEligibilitySignatureCreator` for the override.
public protocol OfferSigning: Sendable {
    /// A compact JWS for `request`. Throw if one cannot be had: nothing is bought, and the
    /// purchase fails with `PurchaseError.offerNotSigned`.
    func signature(for request: OfferSignatureRequest) async throws -> String
}

/// What the app's server is asked to sign.
public struct OfferSignatureRequest: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A promotional offer: `productId` and `offerIdentifier` in Apple's claims.
        case promotional(OfferID)
        /// The introductory offer, allowed whatever Apple would say: `allowIntroductoryOffer`.
        case introductoryOverride
    }

    public let product: ProductID
    public let kind: Kind
    /// The purchase's own account token, if it has one, for a server that ties the two.
    public let appAccountToken: UUID?

    /// The account's latest transaction in the group, if the store has read one: Apple's
    /// signature creators take it as `transactionId`, and the override's requires it `[Apple]`.
    public let transactionID: String?

    public init(product: ProductID, kind: Kind, appAccountToken: UUID? = nil, transactionID: String? = nil) {
        self.product = product
        self.kind = kind
        self.appAccountToken = appAccountToken
        self.transactionID = transactionID
    }
}
