//
//  StoreKitConfigurationProblem.swift
//  PurchaseTestKit
//
//  One way a `.storekit` file disagrees with the app's catalogue.
//
//  Each case is a mistake that costs an afternoon because nothing reports it. A
//  renamed identifier never loads. A trial that is family-shareable hands the whole
//  family the organiser's start date. A trial with a price is not the free
//  non-consumable that guideline 3.1.1 accepts as a trial. The file is where they
//  can be caught before App Store Connect is, so they are values with the product
//  in them rather than a `Bool`: the failing test names what to fix.
//

public import PurchaseCore

/// A disagreement between a StoreKit configuration file and a `Catalogue`.
public enum StoreKitConfigurationProblem: Hashable, Sendable {
    /// In the catalogue and not in the file. The product will never load.
    case missing(ProductID)
    /// In the file and not in the catalogue: the other half of a rename, or
    /// something the app never asks the store for.
    case unexpected(ProductID)
    /// Everything this package sells is a non-consumable. `type` is what the file
    /// says instead — for an identifier found under a subscription group, a
    /// subscription's.
    case notNonConsumable(ProductID, type: String)
    /// A trial is a *free* non-consumable. `displayPrice` is as the file spells it.
    case trialNotFree(ProductID, displayPrice: String)
    /// A shared trial carries the purchaser's start date. The catalogue never
    /// honours one, and the switch cannot be turned off again once it is on in App
    /// Store Connect — so it should not be on in the file that stands in for it.
    case trialFamilyShareable(ProductID)
    /// The file and the catalogue disagree about Family Sharing for an unlock. One
    /// of them misstates App Store Connect, and the tests are run against the wrong
    /// one.
    case familySharingMismatch(ProductID, catalogueHonours: Bool, fileShares: Bool)
}

extension StoreKitConfigurationProblem: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .missing(id):
            "\(id) is in the catalogue and not in the StoreKit configuration file, "
                + "so it will never load. Was it renamed in one place only?"
        case let .unexpected(id):
            "\(id) is in the StoreKit configuration file and not in the catalogue, "
                + "so the app never asks for it. Was it renamed in one place only?"
        case let .notNonConsumable(id, type):
            "\(id) is \(type.isEmpty ? "of no type" : "a \(type)") in the StoreKit "
                + "configuration file. Everything in a catalogue is a NonConsumable."
        case let .trialNotFree(id, displayPrice):
            "\(id) is a trial priced at \"\(displayPrice)\" in the StoreKit configuration "
                + "file. A trial is a free non-consumable: price it at 0."
        case let .trialFamilyShareable(id):
            "\(id) is a trial and is family-shareable in the StoreKit configuration file. "
                + "A shared trial carries the purchaser's start date: turn Family Sharing off."
        case let .familySharingMismatch(id, catalogueHonours, fileShares):
            "\(id) \(fileShares ? "is" : "is not") family-shareable in the StoreKit "
                + "configuration file, and the catalogue \(catalogueHonours ? "honours" : "ignores") "
                + "Family Sharing for it. Make them agree with App Store Connect."
        }
    }
}
