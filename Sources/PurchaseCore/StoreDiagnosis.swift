//
//  StoreDiagnosis.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What this build actually receives from the store.
//
//  For the afternoon when the Buy button does nothing. The answer is usually not in
//  the code: it is that this particular build, signed this particular way and
//  launched this particular way, is being told the store sells nothing.
//

/// A snapshot of what the store gives this build.
public struct StoreDiagnosis: Hashable, Sendable {
    public let requested: Set<ProductID>
    /// The products the store returned for them. Empty if it could not be asked.
    public let received: Set<ProductID>
    /// Why the store could not be asked what it sells, if it could not. **Not the
    /// same as selling nothing**, and `received` says nothing at all while this is set.
    public let catalogueFailure: PurchaseError?
    public let verifiedEntitlements: Int
    public let unverifiedEntitlements: Int
    /// Entitlements for products the catalogue does not list.
    public let foreignEntitlements: Int
    /// "Xcode", "Sandbox" or "Production" from the App Store, where it can tell — it
    /// reads this from an entitlement, so nil until something is owned — and
    /// "Simulated" from a simulated store.
    public let environment: String?

    public init(
        requested: Set<ProductID>, received: Set<ProductID>, catalogueFailure: PurchaseError? = nil,
        verifiedEntitlements: Int, unverifiedEntitlements: Int, foreignEntitlements: Int,
        environment: String?
    ) {
        self.requested = requested
        self.received = received
        self.catalogueFailure = catalogueFailure
        self.verifiedEntitlements = verifiedEntitlements
        self.unverifiedEntitlements = unverifiedEntitlements
        self.foreignEntitlements = foreignEntitlements
        self.environment = environment
    }

    public var missing: Set<ProductID> { requested.subtracting(received) }

    public enum Hint: Hashable, Sendable {
        /// The store could not be asked what it sells — offline, most often. Nothing
        /// follows about the products or the build until it can be.
        case catalogueLoadFailed(PurchaseError)
        /// Nothing came back at all. Attach a StoreKit configuration file to the
        /// scheme's Run action, or sign the build with a team that has the app in
        /// App Store Connect (and an active Paid Apps Agreement).
        case storeSellsNothingToThisBuild
        /// Some came back. The rest are misspelt, or not ready for sale.
        case someProductsMissing(Set<ProductID>)
        /// The listing has this many entitlements for the catalogue's products whose
        /// signatures do not check out. They are not counted, so their owner is looking
        /// at a paywall; each is also logged as `unverifiedTransactionIgnored` when read.
        case unverifiedEntitlementsPresent(Int)
    }

    public var hints: [Hint] {
        var hints: [Hint] = []
        if let catalogueFailure {
            hints.append(.catalogueLoadFailed(catalogueFailure))
        } else if received.isEmpty, !requested.isEmpty {
            hints.append(.storeSellsNothingToThisBuild)
        } else if !missing.isEmpty {
            hints.append(.someProductsMissing(missing))
        }
        if unverifiedEntitlements > 0 { hints.append(.unverifiedEntitlementsPresent(unverifiedEntitlements)) }
        return hints
    }
}
