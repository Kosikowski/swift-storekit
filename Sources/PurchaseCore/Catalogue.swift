//
//  Catalogue.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Every product the app sells, said once.
//
//  This is the single place an identifier is written. The store is asked for exactly
//  these; only these are counted as owned; only their transactions are finished; and
//  `PurchaseTestKit` can check a StoreKit configuration file against it, so that a
//  renamed product is a failing test and not a Buy button that does nothing.
//

/// The products an app sells.
public struct Catalogue: Hashable, Sendable {
    /// Something wrong with a list of entries.
    public enum Problem: Hashable, Sendable {
        case duplicateIdentifier(ProductID)
        case trialWithoutTargets(ProductID)
        /// A trial names something that is not in the catalogue.
        case trialTargetMissing(trial: ProductID, target: ProductID)
        /// A trial names another trial. A trial stands in for something kept.
        case trialTargetIsNotAnUnlock(trial: ProductID, target: ProductID)
    }

    public let entries: [CatalogueEntry]
    private let index: [ProductID: CatalogueEntry]

    /// A catalogue is a constant written by a programmer, so a bad one is a bug and
    /// is treated as one: this traps, with the problems in the message. Check a list
    /// that comes from anywhere else with `problems(in:)` first.
    public init(_ entries: [CatalogueEntry]) {
        let problems = Self.problems(in: entries)
        precondition(problems.isEmpty, "Invalid catalogue: \(problems)")
        self.entries = entries
        self.index = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    public static func problems(in entries: [CatalogueEntry]) -> [Problem] {
        var problems: [Problem] = []
        var seen: [ProductID: CatalogueEntry] = [:]
        for entry in entries {
            if seen.updateValue(entry, forKey: entry.id) != nil {
                problems.append(.duplicateIdentifier(entry.id))
            }
        }
        for entry in entries {
            guard let terms = entry.trialTerms else { continue }
            if terms.targets.isEmpty { problems.append(.trialWithoutTargets(entry.id)) }
            for target in terms.targets.sorted() {
                guard let found = seen[target] else {
                    problems.append(.trialTargetMissing(trial: entry.id, target: target))
                    continue
                }
                if found.trialTerms != nil {
                    problems.append(.trialTargetIsNotAnUnlock(trial: entry.id, target: target))
                }
            }
        }
        return problems
    }

    public var identifiers: Set<ProductID> { Set(index.keys) }

    public func entry(for id: ProductID) -> CatalogueEntry? { index[id] }

    public func contains(_ id: ProductID) -> Bool { index[id] != nil }

    /// The trials that stand in for `id`, in catalogue order.
    public func trials(of id: ProductID) -> [CatalogueEntry] {
        entries.filter { $0.trialTerms?.targets.contains(id) == true }
    }

    public static func == (lhs: Catalogue, rhs: Catalogue) -> Bool { lhs.entries == rhs.entries }

    public func hash(into hasher: inout Hasher) { hasher.combine(entries) }
}

extension Catalogue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: CatalogueEntry...) {
        self.init(elements)
    }
}
