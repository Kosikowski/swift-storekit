//
//  StoreKitConfigurationError.swift
//  PurchaseTestSupport
//
//  What can go wrong reading a `.storekit` file.
//
//  Typed, so that a test can say *which* failure it expects. Every failure here is a
//  programmer's — a file that is not where the test thinks it is — so, unlike
//  `PurchaseError`, this one does carry text. In every configuration, like the reader
//  that throws it: it grants nothing.
//

/// A failure to read a StoreKit configuration file.
public enum StoreKitConfigurationError: Error, Hashable, Sendable {
    /// The file could not be read: not there, or not readable by this process. In a
    /// test target the usual cause is a fixture that was never declared a resource.
    case unreadableFile(path: String)
    /// The data is not JSON at all.
    case notJSON
    /// JSON, and not a StoreKit configuration: the root is not an object, or carries
    /// no `version`. Every file Xcode has written has one.
    case notAStoreKitConfiguration
    /// An entry with no `productID`. Everything is keyed by it, so this is the one
    /// key whose absence is not tolerated: skipping the entry would report its
    /// product as missing from a file it is sitting in.
    case productWithoutIdentifier(section: String, index: Int)
}

extension StoreKitConfigurationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .unreadableFile(path):
            "The StoreKit configuration file at \(path) could not be read."
        case .notJSON:
            "The StoreKit configuration is not JSON."
        case .notAStoreKitConfiguration:
            "The JSON is not a StoreKit configuration: its root is not an object with a version."
        case let .productWithoutIdentifier(section, index):
            "Entry \(index) of \(section) in the StoreKit configuration has no productID."
        }
    }
}
