//
//  ProductID.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  A product identifier, as App Store Connect spells it.
//
//  A type rather than a `String` because everything in this package is keyed by one,
//  and a bare string is also a display name, a price and an error message. The
//  compiler telling them apart is the cheapest test there is: a renamed identifier
//  otherwise fails silently — the product never loads, and to the person in front of
//  it the Buy button "does nothing".
//

/// The identifier of a product, exactly as it is written in App Store Connect and in
/// the StoreKit configuration file.
public struct ProductID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ProductID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension ProductID: Comparable {
    /// By spelling. Used only to make listings and logs come out in a stable order.
    public static func < (lhs: ProductID, rhs: ProductID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension ProductID: CustomStringConvertible {
    public var description: String { rawValue }
}
