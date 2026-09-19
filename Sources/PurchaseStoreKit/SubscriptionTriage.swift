//
//  SubscriptionTriage.swift
//  PurchaseStoreKit
//
//  What a subscription status from StoreKit means, decided in one place.
//
//  StoreKit's renewal states, expiration reasons and offer types are open sets —
//  `RawRepresentable` structs, to which Apple adds values without a compile error — so
//  every one is matched with a branch for "something newer", which becomes
//  `unrecognised`: said, and never guessed at. A status whose transaction does not
//  verify is not a status this package counts, as an entitlement that does not verify
//  is not; one whose *renewal info* does not verify is counted, with nothing known of
//  what comes next.
//

import Foundation
import PurchaseCore
import StoreKit

enum SubscriptionTriage {
    enum Verdict: Hashable, Sendable {
        case status(HeldSubscription)
        case unverified
        /// Not a subscription this catalogue sells, or not in this group.
        case foreign
    }

    static func verdict(for status: StatusSnapshot, catalogue: Catalogue) -> Verdict {
        let transaction = status.transaction
        guard let terms = catalogue.entry(for: transaction.productID)?.subscriptionTerms else { return .foreign }
        guard transaction.verification == .verified else { return .unverified }
        let periodEnds = transaction.expirationDate ?? transaction.purchaseDate
        return .status(
            HeldSubscription(
                product: transaction.productID, group: terms.group, ownership: transaction.ownership,
                state: state(status.state, renewal: status.renewal, periodEnds: periodEnds),
                firstSubscribed: transaction.originalPurchaseDate, periodStarted: transaction.purchaseDate,
                periodEnds: periodEnds, offer: offer(of: transaction), renewal: status.renewal.map(renewal)))
    }

    /// Apple's own table, on `isInBillingRetry`: retrying with a grace date is a grace
    /// period, retrying without one is billing retry, and not retrying is expired. The
    /// iOS simulator was measured to say `expired` while still retrying, after a grace
    /// period (spike/README.md); by that table it is billing retry, and is said so. A
    /// grace period whose end did not verify is taken to end with its period, which is the
    /// earlier: an end the store did not vouch for is not believed past it.
    static func state(
        _ state: Product.SubscriptionInfo.RenewalState, renewal: RenewalSnapshot?, periodEnds: Date
    ) -> HeldSubscription.State {
        switch state {
        case .subscribed: return .subscribed
        case .inGracePeriod: return .inGracePeriod(until: renewal?.gracePeriodExpirationDate ?? periodEnds)
        case .inBillingRetryPeriod: return .inBillingRetry
        case .expired:
            if renewal?.isInBillingRetry == true { return .inBillingRetry }
            return .expired(lapse(renewal?.expirationReason))
        case .revoked: return .revoked
        default: return .unrecognised
        }
    }

    static func lapse(_ reason: Product.SubscriptionInfo.RenewalInfo.ExpirationReason?) -> HeldSubscription.Lapse {
        guard let reason else { return .unstated }
        switch reason {
        case .autoRenewDisabled: return .autoRenewDisabled
        case .billingError: return .billingError
        case .didNotConsentToPriceIncrease: return .didNotConsentToPriceIncrease
        case .productUnavailable: return .productUnavailable
        case .unknown: return .unknown
        default: return .unrecognised
        }
    }

    static func offer(of transaction: TransactionSnapshot) -> AppliedOffer? {
        guard let type = transaction.offerType else { return nil }
        let kind: AppliedOffer.Kind =
            switch type {
            case .introductory: .introductory
            case .promotional: .promotional
            case .code: .code
            case .winBack: .winBack
            default: .unrecognised
            }
        return AppliedOffer(
            kind: kind, id: transaction.offerID.map(OfferID.init(rawValue:)),
            paymentMode: transaction.offerPaymentMode.map(paymentMode))
    }

    static func paymentMode(_ mode: StoreKit.Transaction.Offer.PaymentMode) -> AppliedOffer.PaymentMode {
        switch mode {
        case .freeTrial: .freeTrial
        case .payAsYouGo: .payAsYouGo
        case .payUpFront: .payUpFront
        case .oneTime: .oneTime
        default: .unrecognised
        }
    }

    static func renewal(_ info: RenewalSnapshot) -> Renewal {
        let increase: Renewal.PriceIncrease =
            switch info.priceIncreaseStatus {
            case .noIncreasePending: .none
            case .pending: .awaitingConsent
            case .agreed: .agreed
            }
        return Renewal(
            willRenew: info.willAutoRenew, nextProduct: info.autoRenewPreference.map(ProductID.init(rawValue:)),
            price: info.renewalPrice, currencyCode: info.currencyCode, priceIncrease: increase,
            winBackOffers: info.eligibleWinBackOfferIDs.map(OfferID.init(rawValue:)))
    }
}
