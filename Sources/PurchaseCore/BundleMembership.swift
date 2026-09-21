//
//  BundleMembership.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  A subscription held through a subscription bundle.
//
//  From iOS and macOS 27 a developer can sell a subscription bundle: one subscription that
//  includes others, perhaps of other apps `[Apple]`. A subscription of this app held through
//  one is this app's subscription as far as access goes — its status decides, as any
//  status does — and the renewal info says which bundle it is held through, and whether it
//  leaves the bundle at the next renewal. Said here as facts; what the app makes of them is
//  its own. Not measured: Xcode's environment could not be made to sell one.
//

/// The bundle a subscription is held through.
public struct BundleMembership: Hashable, Sendable {
    /// The bundle's product, which may be sold by another app.
    public let product: ProductID
    public let group: SubscriptionGroupID?
    /// Whether this subscription leaves the bundle at its next renewal: bought on its own
    /// then, or lapsing with `Lapse.unbundled`.
    public let willLeave: Bool

    public init(product: ProductID, group: SubscriptionGroupID? = nil, willLeave: Bool = false) {
        self.product = product
        self.group = group
        self.willLeave = willLeave
    }
}

/// A subscription a bundle includes, as the store states it.
public struct BundledSubscription: Hashable, Sendable {
    public let product: ProductID
    public let displayName: String
    public let displayPrice: String
    public let group: SubscriptionGroupID
    /// Its level in its group: 1 is the highest.
    public let level: Int

    public init(product: ProductID, displayName: String, displayPrice: String, group: SubscriptionGroupID, level: Int) {
        self.product = product
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.group = group
        self.level = level
    }
}
