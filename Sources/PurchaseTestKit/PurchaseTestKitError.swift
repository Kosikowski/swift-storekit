//
//  PurchaseTestKitError.swift
//  PurchaseTestKit
//
//  What can go wrong in this module that is not the simulated store misbehaving on
//  request.
//
//  One enum for the module, typed, so that a test can say *which* failure it expects
//  and a parser cannot fail in a way its caller has no case for. Every failure here
//  is a programmer's — a file that is not where the test thinks it is, a scenario
//  with a typo in it — so, unlike `PurchaseError`, this one does carry text: the
//  offending clause, word for word, because "the scenario was invalid" sends someone
//  to read forty characters by eye and "owns=trail: no product called trail" does
//  not.
//
//  Not `#if DEBUG`, although half its cases are about scenarios, which are: an error
//  grants nothing, and the configuration validator that throws the other half is
//  needed by an app's tests in whatever configuration they are built.
//

public import PurchaseCore

/// A failure to read a StoreKit configuration file or a scenario.
public enum PurchaseTestKitError: Error, Hashable, Sendable {
    /// What is wrong with one clause of a scenario.
    ///
    /// An `Error` only so that the parser's own helpers can throw one. It reaches a
    /// caller inside `invalidScenario`, beside the clause it is about, never alone.
    public enum ScenarioFault: Error, Hashable, Sendable {
        /// Not `key=value`, or a key the grammar does not have.
        case unknownClause
        /// The same key twice. Neither is obviously the one that was meant, and
        /// picking one quietly is how a screenshot comes out wrong.
        case repeatedClause
        /// A key with nothing after it — or `-PurchaseScenario` as the last launch
        /// argument, with no scenario following.
        case missingValue
        /// A value the key does not take: `purchase=maybe`.
        case unknownValue(String)
        /// `fails:` followed by something that is not one of the scriptable errors.
        case unknownError(String)
        /// Neither a catalogue identifier nor the last component of one.
        case unknownProduct(String)
        /// The last component of more than one catalogue identifier. Spell it out.
        case ambiguousProduct(String, matches: [ProductID])
        /// The same product held twice, in one list or across `owns` and `earlier`:
        /// it cannot be both known to this device and not.
        case repeatedProduct(ProductID)
        /// Not a run of `<digits><d|h|m|s>`, or too long ago to be a date.
        case invalidAge(String)
        /// Not `purchased`, `family` or `assigned`.
        case unknownOwnership(String)
        /// Not a whole number of reads.
        case invalidLag(String)
    }

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
    /// A scenario that does not parse. `clause` is the offending clause as written.
    case invalidScenario(clause: String, reason: ScenarioFault)
}

extension PurchaseTestKitError: CustomStringConvertible {
    /// A sentence for a developer, fit for the message of the `fatalError` a bad
    /// scenario deserves.
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
        case let .invalidScenario(clause, reason):
            "Invalid scenario clause \"\(clause)\": \(reason)."
        }
    }
}

extension PurchaseTestKitError.ScenarioFault: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownClause:
            "not a clause the scenario grammar has"
        case .repeatedClause:
            "this key has already been given"
        case .missingValue:
            "nothing follows it"
        case let .unknownValue(value):
            "\"\(value)\" is not a value this key takes"
        case let .unknownError(name):
            "\"\(name)\" is not an error a scenario can script"
        case let .unknownProduct(name):
            "no product in the catalogue is called \"\(name)\""
        case let .ambiguousProduct(name, matches):
            "\"\(name)\" could be any of \(matches.map(\.rawValue).joined(separator: ", "))"
                + " — write the identifier in full"
        case let .repeatedProduct(id):
            "\(id) is held more than once"
        case let .invalidAge(age):
            "\"\(age)\" is not an age such as 13d23h55m"
        case let .unknownOwnership(name):
            "\"\(name)\" is not purchased, family or assigned"
        case let .invalidLag(lag):
            "\"\(lag)\" is not a whole number of reads"
        }
    }
}
