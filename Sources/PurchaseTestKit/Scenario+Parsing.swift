//
//  Scenario+Parsing.swift
//  PurchaseTestKit
//
//  The text of a scenario, and the one place it is read.
//
//  The grammar is small enough to type into a scheme's arguments from memory and
//  strict enough that a slip is an error rather than a guess. Clauses are joined by
//  `;`; whitespace round any token is ignored, and so is an empty clause, so a
//  trailing `;` is harmless:
//
//      clause  = "owns=" holding *("," holding)      ; listed from launch
//              | "earlier=" holding *("," holding)   ; the account's, unknown to this device
//              | "purchase=" ("succeeds" | "pending" | "cancelled" | "held" | "fails:" error)
//              | "restore="  ("succeeds" | "cancelled" | "held" | "fails:" error)
//              | "catalogue=" ("loads" | "empty" | "held" | "fails:" error)
//              | "ownership=" ("answers" | "held")
//              | "lag=" 1*DIGIT                      ; reads before a purchase is listed
//      holding = product [ "@" age ] [ "/" ("purchased" | "family" | "assigned") ]
//      age     = 1*( 1*DIGIT ("d" | "h" | "m" | "s") )    ; how long AGO: 13d23h55m
//      product = a catalogue identifier in full, or the last dot-separated component
//                of exactly one — `trial` for `com.example.trial`
//      error   = "productUnavailable" | "purchaseNotAllowed" | "notAvailableInStorefront"
//              | "network" | "system" | "unverified" | "revoked" | "unsupported"
//
//  `held` closes the matching gate: the store has been asked and has not answered —
//  or, for a purchase or a restore, the payment sheet or the password prompt is up.
//  `catalogue=empty` is a build the store sells nothing to.
//
//  **Everything unrecognised is an error naming the clause it is in**, and so is a
//  key given twice or a product held twice: the reader of a scenario is a person
//  looking at a screenshot, who cannot tell which of two contradictory clauses won.
//  Words are matched exactly, case and all, for the same reason.
//

#if DEBUG

public import PurchaseCore

extension Scenario {
    /// Reads a scenario. `catalogue` is what short product names are resolved
    /// against, and nothing outside it can be held.
    ///
    /// Throws `PurchaseTestKitError.invalidScenario` with the offending clause as it
    /// was written. The empty text is a valid scenario: the defaults.
    public init(parsing text: String, catalogue: Catalogue) throws(PurchaseTestKitError) {
        self.init()
        var keys: Set<String> = []
        for piece in text.split(separator: ";") {
            let clause = Self.trimmed(piece)
            if clause.isEmpty { continue }
            func invalid(_ reason: PurchaseTestKitError.ScenarioFault) -> PurchaseTestKitError {
                .invalidScenario(clause: clause, reason: reason)
            }

            guard let equals = clause.firstIndex(of: "=") else { throw invalid(.unknownClause) }
            let key = Self.trimmed(clause[..<equals])
            let value = Self.trimmed(clause[clause.index(after: equals)...])
            guard Self.keys.contains(key) else { throw invalid(.unknownClause) }
            guard keys.insert(key).inserted else { throw invalid(.repeatedClause) }
            guard !value.isEmpty else { throw invalid(.missingValue) }

            do throws(ScenarioFault) {
                switch key {
                case "owns": owns = try Self.holdings(value, in: catalogue)
                case "earlier": earlier = try Self.holdings(value, in: catalogue)
                case "purchase":
                    if value == "held" {
                        holdsPurchase = true
                    } else {
                        behaviour.purchase = try Self.purchaseScript(value)
                    }
                case "restore":
                    if value == "held" {
                        holdsRestore = true
                    } else {
                        behaviour.restore = try Self.restoreScript(value)
                    }
                case "catalogue":
                    if value == "held" {
                        holdsCatalogue = true
                    } else {
                        behaviour.catalogue = try Self.catalogueScript(value)
                    }
                case "ownership":
                    switch value {
                    case "answers": holdsOwnership = false
                    case "held": holdsOwnership = true
                    default: throw ScenarioFault.unknownValue(value)
                    }
                default:
                    // "lag", the last of `Self.keys`.
                    guard value.allSatisfy(Self.isDigit), let reads = Int(value) else {
                        throw ScenarioFault.invalidLag(value)
                    }
                    behaviour.listsPurchasesAfterReads = reads
                }
            } catch {
                throw invalid(error)
            }

            // Across both lists, and after every clause, so that the clause named is
            // the one that brought the second holding in.
            var held: Set<ProductID> = []
            for holding in owns + earlier where !held.insert(holding.id).inserted {
                throw invalid(.repeatedProduct(holding.id))
            }
        }
    }

    // MARK: - Private

    private typealias ScenarioFault = PurchaseTestKitError.ScenarioFault

    private static let keys: Set<String> = [
        "owns", "earlier", "purchase", "restore", "catalogue", "ownership", "lag",
    ]

    private static let errors: [String: PurchaseError] = [
        "productUnavailable": .productUnavailable,
        "purchaseNotAllowed": .purchaseNotAllowed,
        "notAvailableInStorefront": .notAvailableInStorefront,
        "network": .network,
        "system": .system,
        "unverified": .unverified,
        "revoked": .revoked,
        "unsupported": .unsupported,
    ]

    private static func trimmed(_ text: some StringProtocol) -> String {
        String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }

    /// ASCII only. `Character.isNumber` is also true of `٣` and `½`, which `Int`
    /// would then refuse or, worse, accept.
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func purchaseScript(
        _ value: String
    ) throws(ScenarioFault) -> SimulatedStoreFront.Behaviour.PurchaseScript {
        switch value {
        case "succeeds": return .succeeds
        case "pending": return .pending
        case "cancelled": return .cancelled
        default: return .fails(try failure(value))
        }
    }

    private static func restoreScript(
        _ value: String
    ) throws(ScenarioFault) -> SimulatedStoreFront.Behaviour.RestoreScript {
        switch value {
        case "succeeds": return .succeeds
        case "cancelled": return .cancelled
        default: return .fails(try failure(value))
        }
    }

    private static func catalogueScript(
        _ value: String
    ) throws(ScenarioFault) -> SimulatedStoreFront.Behaviour.CatalogueScript {
        switch value {
        case "loads": return .loads
        case "empty": return .loadsOnly([])
        default: return .fails(try failure(value))
        }
    }

    /// `fails:network`. Anything not of that shape is a value the key does not take.
    private static func failure(_ value: String) throws(ScenarioFault) -> PurchaseError {
        guard value.hasPrefix("fails:") else { throw .unknownValue(value) }
        let name = trimmed(value.dropFirst("fails:".count))
        guard let error = errors[name] else { throw .unknownError(name) }
        return error
    }

    private static func holdings(
        _ value: String, in catalogue: Catalogue
    ) throws(ScenarioFault) -> [Holding] {
        var holdings: [Holding] = []
        // Empty pieces are kept, so that `pro,,trial` is an error and not two holdings.
        for piece in value.split(separator: ",", omittingEmptySubsequences: false) {
            holdings.append(try holding(trimmed(piece), in: catalogue))
        }
        return holdings
    }

    /// `product[@age][/ownership]`, in that order. An identifier contains neither
    /// `@` nor `/`, so the first of each is where the next part begins.
    private static func holding(
        _ text: String, in catalogue: Catalogue
    ) throws(ScenarioFault) -> Holding {
        var rest = text[...]
        var ownership = Ownership.purchased
        if let slash = rest.firstIndex(of: "/") {
            let name = trimmed(rest[rest.index(after: slash)...])
            switch name {
            case "purchased": ownership = .purchased
            case "family": ownership = .familyShared
            case "assigned": ownership = .assigned
            default: throw .unknownOwnership(name)
            }
            rest = rest[..<slash]
        }
        var age = Duration.zero
        if let at = rest.firstIndex(of: "@") {
            age = try Self.age(trimmed(rest[rest.index(after: at)...]))
            rest = rest[..<at]
        }
        return Holding(try product(trimmed(rest), in: catalogue), age: age, ownership: ownership)
    }

    /// A full identifier wins over a short name, so a catalogue selling both `pro`
    /// and `com.example.pro` can still say which it means.
    private static func product(
        _ name: String, in catalogue: Catalogue
    ) throws(ScenarioFault) -> ProductID {
        if catalogue.contains(ProductID(name)) { return ProductID(name) }
        let matches = catalogue.entries.map(\.id).filter {
            $0.rawValue.split(separator: ".").last.map(String.init) == name
        }
        guard let match = matches.first else { throw .unknownProduct(name) }
        guard matches.count == 1 else { throw .ambiguousProduct(name, matches: matches) }
        return match
    }

    /// `13d23h55m`: any run of number-and-unit, added up. Arithmetic is checked, as
    /// a launch argument is the one input here that a fuzzer, or a cat, can reach.
    private static func age(_ text: String) throws(ScenarioFault) -> Duration {
        var seconds: Int64 = 0
        var digits = ""
        for character in text {
            if isDigit(character) {
                digits.append(character)
                continue
            }
            let unit: Int64
            switch character {
            case "d": unit = 86_400
            case "h": unit = 3_600
            case "m": unit = 60
            case "s": unit = 1
            default: throw .invalidAge(text)
            }
            guard let count = Int64(digits) else { throw .invalidAge(text) }
            let (product, overflowed) = count.multipliedReportingOverflow(by: unit)
            let (sum, overflowedAgain) = seconds.addingReportingOverflow(product)
            guard !overflowed, !overflowedAgain else { throw .invalidAge(text) }
            seconds = sum
            digits = ""
        }
        // Digits left over had no unit; nothing at all had no number.
        guard digits.isEmpty, !text.isEmpty else { throw .invalidAge(text) }
        return .seconds(seconds)
    }
}

#endif
