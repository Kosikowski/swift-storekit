//
//  OfferID.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  The identifier of a subscription offer, as App Store Connect has it.
//

/// The identifier of a promotional, win-back or code offer. An introductory offer has
/// none: there is one per subscription, and nothing to tell apart.
public struct OfferID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension OfferID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension OfferID: CustomStringConvertible {
    public var description: String { rawValue }
}

extension OfferID: Comparable {
    /// By spelling, as `ProductID`: for a stable order in listings and logs.
    public static func < (lhs: OfferID, rhs: OfferID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
