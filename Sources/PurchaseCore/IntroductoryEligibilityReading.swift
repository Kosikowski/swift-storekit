//
//  IntroductoryEligibilityReading.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Says, group by group, whether this person may have an introductory offer.
///
/// Optional, like `SubscriptionStatusReading`: a store that cannot say need not play it,
/// and every introductory offer is then `unknown` — the regular price is shown, and the
/// payment sheet decides.
///
/// **The contract a conformer keeps.** True when the store says this person may have an
/// introductory offer in the group, false when it says not. A group that could not be
/// asked about is left out, never guessed. Never throws; no side effects. Measured,
/// StoreKit's own answer keeps its first value for the life of the process, before and
/// after the offer is used (spike/README.md), so the App Store's conformer also looks for
/// an introductory offer among the group's transactions, and the store for one among the
/// purchases it has seen.
public protocol IntroductoryEligibilityReading: Sendable {
    func introductoryEligibility(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: Bool]
}
