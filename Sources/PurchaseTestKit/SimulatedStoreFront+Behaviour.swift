//
//  SimulatedStoreFront+Behaviour.swift
//  PurchaseTestKit
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
