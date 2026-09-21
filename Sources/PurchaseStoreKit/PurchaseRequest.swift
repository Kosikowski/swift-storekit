//
//  PurchaseRequest.swift
//  PurchaseStoreKit
//
//  What a purchase asks StoreKit for, worked out before any StoreKit option is made.
//

import Foundation
import PurchaseCore

/// A purchase's options as StoreKit takes them, or the reason it cannot take them.
/// `Offer` is the win-back offer's value, which only the product has.
struct PurchaseRequest<Offer> {
    enum SignedOffer {
        case winBack(Offer)
        case promotional(OfferID, signature: String)
        case introductoryOverride(signature: String)
    }

    let appAccountToken: UUID?
    let billingPlan: BillingPlan?
    let offer: SignedOffer?

    /// - Parameters:
    ///   - winBackOffers: the product's win-back offers on the billing plan asked for.
    ///   - billingPlans: whether this system can buy on a billing plan at all.
    init(_ options: PurchaseOptions, winBackOffers: [OfferID: Offer], billingPlans: Bool) throws(PurchaseError) {
        appAccountToken = options.appAccountToken
        if let plan = options.billingPlan {
            // Asked for and not to be had is a failure, never a purchase billed some other way.
            guard billingPlans, plan != .unrecognised else { throw .unsupported }
        }
        billingPlan = options.billingPlan
        switch options.offer {
        case nil:
            offer = nil
        case let .winBack(id)?:
            guard let found = winBackOffers[id] else { throw .offerRefused(.unknownOffer) }
            offer = .winBack(found)
        case let .promotional(id)?:
            guard let signature = options.signature else { throw .offerRefused(.missingParameters) }
            offer = .promotional(id, signature: signature)
        case .introductoryOverride?:
            guard let signature = options.signature else { throw .offerRefused(.missingParameters) }
            offer = .introductoryOverride(signature: signature)
        }
    }
}

extension PurchaseRequest: Equatable where Offer: Equatable {}
extension PurchaseRequest.SignedOffer: Equatable where Offer: Equatable {}
