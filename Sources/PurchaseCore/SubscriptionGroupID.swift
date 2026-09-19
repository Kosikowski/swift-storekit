//
//  SubscriptionGroupID.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Which subscription group a subscription belongs to.
//
//  App Store Connect gives every group an identifier of its own, and StoreKit asks for a
//  group's statuses by it — statically, with no product loaded, so what a subscriber may
//  use waits for no network. The catalogue restates it for that reason, as it restates
//  Family Sharing, and the `.storekit` check keeps the restatement honest.
//

/// The identifier App Store Connect gave a subscription group, exactly as it is written
/// there and in the StoreKit configuration file.
public struct SubscriptionGroupID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SubscriptionGroupID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension SubscriptionGroupID: Comparable {
    /// By spelling, for a stable order in listings and logs.
    public static func < (lhs: SubscriptionGroupID, rhs: SubscriptionGroupID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension SubscriptionGroupID: CustomStringConvertible {
    public var description: String { rawValue }
}
