//
//  BillingPlan.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  How a subscription is paid for: all at once, or monthly with a 12-month commitment.
//
//  A yearly subscription can have a second billing plan, from iOS and macOS 26.4: billed
//  every month, and committed to for twelve `[Apple]`. It is not offered in the United
//  States or Singapore, has no grace period, and retries a failed charge for 90 days.
//  **Cancelled during the commitment, it is still billed every month until the commitment
//  ends**: the renewal says it will renew, correctly, and only the commitment's own renewal
//  says it will not renew after that `[Apple]`. So the two are kept apart here.
//

public import Foundation

/// How a subscription is paid for.
public enum BillingPlan: Hashable, Sendable {
    /// The whole period at once: the only plan before 26.4, and the default.
    case upFront
    /// Every month, for a commitment of twelve.
    case monthly
    /// A plan StoreKit added later.
    case unrecognised
}

/// A subscription's price on one billing plan, as the store states it.
public struct BillingPlanTerms: Hashable, Sendable {
    public let plan: BillingPlan
    /// What is charged each billing period — each month, on the monthly plan.
    public let billingDisplayPrice: String
    public let billingPrice: Decimal
    public let billingPeriod: BillingPeriod
    /// The whole commitment: what twelve months come to, and how long it lasts.
    public let commitmentDisplayPrice: String
    public let commitmentPrice: Decimal
    public let commitmentPeriod: BillingPeriod
    /// The offers on this plan.
    public let offers: [OfferTerms]

    public init(
        plan: BillingPlan, billingDisplayPrice: String, billingPrice: Decimal, billingPeriod: BillingPeriod,
        commitmentDisplayPrice: String, commitmentPrice: Decimal, commitmentPeriod: BillingPeriod, offers: [OfferTerms] = []
    ) {
        self.plan = plan
        self.billingDisplayPrice = billingDisplayPrice
        self.billingPrice = billingPrice
        self.billingPeriod = billingPeriod
        self.commitmentDisplayPrice = commitmentDisplayPrice
        self.commitmentPrice = commitmentPrice
        self.commitmentPeriod = commitmentPeriod
        self.offers = offers
    }
}

/// Where a subscription on a commitment stands in it, as its transaction says.
public struct SubscriptionCommitment: Hashable, Sendable {
    public let plan: BillingPlan
    /// Which billing period this is: 1 to `billingPeriods`.
    public let billingPeriod: Int
    public let billingPeriods: Int
    /// When the commitment ends.
    public let endsAt: Date
    /// What the commitment costs in all.
    public let price: Decimal

    public init(plan: BillingPlan, billingPeriod: Int, billingPeriods: Int, endsAt: Date, price: Decimal) {
        self.plan = plan
        self.billingPeriod = billingPeriod
        self.billingPeriods = billingPeriods
        self.endsAt = endsAt
        self.price = price
    }
}

/// What happens when a commitment ends, as the renewal info says.
///
/// **Not the same as `Renewal.willRenew`.** Cancelled during a commitment, the monthly
/// billing goes on — `willRenew` stays true, and rightly — and this says the commitment
/// will not be renewed `[Apple]`. "Member until the commitment ends" is read from here.
public struct CommitmentRenewal: Hashable, Sendable {
    public let willRenew: Bool
    /// The product it renews as, when it does.
    public let nextProduct: ProductID?
    public let plan: BillingPlan
    public let renewsAt: Date
    public let price: Decimal?

    public init(willRenew: Bool, nextProduct: ProductID?, plan: BillingPlan, renewsAt: Date, price: Decimal? = nil) {
        self.willRenew = willRenew
        self.nextProduct = nextProduct
        self.plan = plan
        self.renewsAt = renewsAt
        self.price = price
    }
}
