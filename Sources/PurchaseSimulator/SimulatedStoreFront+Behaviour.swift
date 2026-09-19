//
//  SimulatedStoreFront+Behaviour.swift
//  PurchaseSimulator
//
//  The ways the simulated store can be made to misbehave.
//

#if DEBUG

public import PurchaseCore

extension SimulatedStoreFront {
    /// How the store behaves. Every default is the real store on a good day —
    /// including the two habits that are not good: listing late, and answering a
    /// cancelled task with nothing.
    public struct Behaviour: Hashable, Sendable {
        public enum PurchaseScript: Hashable, Sendable {
            case succeeds
            /// Ask to Buy. Settle it with `approvePending(_:)`.
            case pending
            case cancelled
            case fails(PurchaseError)
        }

        public enum RestoreScript: Hashable, Sendable {
            case succeeds
            case cancelled
            case fails(PurchaseError)
        }

        /// What happens when a subscription that is to renew reaches the end of its period.
        public enum RenewalScript: Hashable, Sendable {
            /// It renews: a new transaction, for the plan it was to renew as.
            case renews
            /// The charge fails: into the grace period, if `gracePeriod` is set, then
            /// billing retry for `billingRetryPeriod`, then expired.
            case fails
        }

        public enum CatalogueScript: Hashable, Sendable {
            case loads
            /// Only some products come back: the rest are misspelt or not yet
            /// approved. `loadsOnly([])` is a build the store sells nothing to.
            case loadsOnly(Set<ProductID>)
            case fails(PurchaseError)
        }

        public var purchase: PurchaseScript = .succeeds
        /// How a purchase of one product ends, where that differs from `purchase`:
        /// the trial goes through and the unlock is left pending.
        public var purchases: [ProductID: PurchaseScript] = [:]
        public var restore: RestoreScript = .succeeds
        public var catalogue: CatalogueScript = .loads

        /// How many reads of what is owned go by before a purchase is listed. One,
        /// as with the real store: the read straight after a purchase does not have
        /// it. Zero is a store more helpful than the real one, and hides the bug.
        public var listsPurchasesAfterReads = 1

        /// The real store answers a cancelled task with nothing — no products, and
        /// nothing owned. Leave this on.
        public var answersNothingWhenCancelled = true

        /// Whether a restore brings what the account owns elsewhere
        /// (`seedEarlierPurchase`) to this device. It does, with the real store; off,
        /// a restore completes and finds nothing, which is what "Restore did not bring
        /// my purchase back" looks like to an app.
        public var restoreListsEarlierPurchases = true

        /// How long a subscription bought here runs before it is due to renew. A month, as
        /// near as a fixed length gets; a test that watches renewals sets it to seconds.
        public var subscriptionPeriod: Duration = .seconds(30 * 86_400)

        /// How many reads of the statuses go by, once a subscription is listed, before its
        /// status is said. Zero: said with the listing. On the Mac both were measured empty
        /// for about 0.6 s after a purchase, and nothing says which catches up first; a test
        /// of the moment the listing has a new subscription and the status does not sets this.
        public var saysStatusAfterReads = 0

        /// What happens at a renewal. Change it before the period ends.
        public var renewal: RenewalScript = .renews

        /// The billing grace period, as App Store Connect sets it: nil is off, which is
        /// App Store Connect's default too. 3, 16 or 28 days there.
        public var gracePeriod: Duration?

        /// How long Apple goes on retrying a failed charge before the subscription expires.
        public var billingRetryPeriod: Duration = .seconds(60 * 86_400)

        /// **The moment at a renewal**, as measured against the real store: the status
        /// says the subscription has expired — will not renew, no reason — and the listing
        /// has nothing, until the renewal is listed; the renewal itself is announced first.
        /// On by default, like every awkward habit here: an app that is right through it
        /// is right when it is shorter. Its length is counted in reads, one more than
        /// `listsPurchasesAfterReads`.
        public var showsTheRenewalMoment = true

        /// The three scripts, for a store that misbehaves from its first line. The rest
        /// are properties, and the defaults are the real store on a good day.
        public init(
            purchase: PurchaseScript = .succeeds, restore: RestoreScript = .succeeds,
            catalogue: CatalogueScript = .loads
        ) {
            self.purchase = purchase
            self.restore = restore
            self.catalogue = catalogue
        }
    }
}

#endif
