//
//  HeldSubscription.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  One status the store reports for a subscription group.
//
//  Four facts on separate axes — the state, what happens at renewal, the offer in force,
//  and how the account came by it — because every library that folded them into one enum
//  then needed flags beside it for the combinations it could not say: "in a free trial
//  *and* not renewing".
//

public import Foundation

/// A subscription the store says this account holds, or held, in one group.
public struct HeldSubscription: Hashable, Sendable {
    /// Where the subscription stands. Access follows Apple's rule: `subscribed` and
    /// `inGracePeriod` are entitled, and nothing else is.
    public enum State: Hashable, Sendable {
        case subscribed
        /// A renewal failed and Apple is retrying, **and the developer has promised
        /// service meanwhile**: entitled until then. `periodEnds` is already past.
        case inGracePeriod(until: Date)
        /// A renewal failed and Apple is retrying, with no grace period. Not entitled —
        /// reported, so that an app that wants to be lenient can decide so itself.
        case inBillingRetry
        case expired(Lapse)
        /// Taken back: refunded, or no longer shared.
        case revoked
        /// A state StoreKit added later. Not entitled, and said rather than guessed.
        case unrecognised
    }

    /// Why an expired subscription expired.
    public enum Lapse: Hashable, Sendable {
        case autoRenewDisabled
        case billingError
        case didNotConsentToPriceIncrease
        case productUnavailable
        /// Held through a subscription bundle, and left it (27).
        case unbundled
        /// StoreKit's own "unknown".
        case unknown
        /// StoreKit gave no reason. Measured, this is what the moment at every renewal
        /// looks like — and, in the iOS simulator, a real lapse too (spike/README.md).
        case unstated
        case unrecognised
    }

    public let product: ProductID
    public let group: SubscriptionGroupID
    public let ownership: Ownership
    public let state: State

    /// When the account first subscribed: the same across renewals.
    public let firstSubscribed: Date
    public let periodStarted: Date
    /// When this period ends, or ended. In a grace period it is already past.
    public let periodEnds: Date

    /// The offer this period was bought with, if any.
    public let offer: AppliedOffer?

    /// What happens next. **Nil when no status could be read** and this came from the
    /// listing alone: nothing is known of the renewal then.
    public let renewal: Renewal?

    /// StoreKit's identifier for the transaction this status stands on: the latest in the
    /// group. For a server of the app's own, and for the signature of an offer. Nil when
    /// not known.
    public let transactionID: UInt64?

    /// On the monthly plan with a 12-month commitment: which month of how many, and when the
    /// commitment ends. Nil on the up-front plan, and before 26.4.
    public let commitment: SubscriptionCommitment?

    /// The subscription bundle it is held through, if it is (27). Nil when not, and when
    /// nothing is known of the renewal.
    public let bundle: BundleMembership?

    public init(
        product: ProductID, group: SubscriptionGroupID, ownership: Ownership = .purchased,
        state: State, firstSubscribed: Date, periodStarted: Date, periodEnds: Date,
        offer: AppliedOffer? = nil, renewal: Renewal? = nil, transactionID: UInt64? = nil,
        commitment: SubscriptionCommitment? = nil, bundle: BundleMembership? = nil
    ) {
        self.product = product
        self.group = group
        self.ownership = ownership
        self.state = state
        self.firstSubscribed = firstSubscribed
        self.periodStarted = periodStarted
        self.periodEnds = periodEnds
        self.offer = offer
        self.renewal = renewal
        self.transactionID = transactionID
        self.commitment = commitment
        self.bundle = bundle
    }

    /// Whether this status gives access, by Apple's rule: subscribed, or in a grace period.
    public var isEntitled: Bool {
        switch state {
        case .subscribed, .inGracePeriod: true
        case .inBillingRetry, .expired, .revoked, .unrecognised: false
        }
    }

    /// Whether it goes on past the end of this period, as the store last said: false when
    /// auto-renew is off, **and in the last month of a commitment that will not be renewed**.
    /// Nil when nothing is known of the renewal.
    ///
    /// Not `renewal.willRenew`, which on a 12-month commitment stays true after the person
    /// cancels, because the monthly billing does go on until the commitment ends `[Apple]`.
    public var willRenewAtPeriodEnd: Bool? {
        guard let renewal else { return nil }
        if !renewal.willRenew { return false }
        if let commitment, commitment.billingPeriod >= commitment.billingPeriods, renewal.commitment?.willRenew == false {
            return false
        }
        return true
    }

    /// When access by this status ends: the end of the grace period, or of the period.
    ///
    /// Named apart from `periodEnds` on purpose. In a grace period the two differ, and a
    /// check of `periodEnds > now` locks out someone Apple says must still be served.
    public var accessEnds: Date {
        if case let .inGracePeriod(until) = state { return until }
        return periodEnds
    }
}
