//
//  Standing.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Everything the store has said about this account, as one value.
//
//  A standing is a fact about a moment, so every question that depends on time takes
//  the date as a parameter and nothing in here reads a clock. That is what makes a
//  trial's expiry testable, and it is also honest: a standing resolved at noon can
//  be asked about half past, and answers correctly without being resolved again.
//

public import Foundation

/// What this account holds, as far as the store has said.
public struct Standing: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// Nothing has been heard from the store yet. Every launch starts here.
        case unknown
        case known
    }

    public let phase: Phase
    /// When this was resolved. The date the convenience queries answer for.
    public let asOf: Date
    public let catalogue: Catalogue
    private let holdings: [ProductID: OwnedProduct]

    /// Built by `StandingResolver`; `holdings` must already be the ones that count.
    init(phase: Phase, asOf: Date, catalogue: Catalogue, holdings: [ProductID: OwnedProduct]) {
        self.phase = phase
        self.asOf = asOf
        self.catalogue = catalogue
        self.holdings = holdings
    }

    /// The standing before the store has said anything.
    public static func unknown(catalogue: Catalogue, asOf: Date = .distantPast) -> Standing {
        Standing(phase: .unknown, asOf: asOf, catalogue: catalogue, holdings: [:])
    }

    public var isKnown: Bool { phase == .known }

    /// What is held and counts, in identifier order. A trial product is in here from
    /// the day it is taken and stays after it ends; ask `trial(_:at:)` where it stands.
    public var ownedProducts: [OwnedProduct] {
        holdings.values.sorted { $0.id < $1.id }
    }

    public func ownership(of id: ProductID) -> OwnedProduct? { holdings[id] }

    // MARK: - Access

    public func access(to id: ProductID, at date: Date) -> ProductAccess {
        guard isKnown else { return .unknown }
        if let owned = holdings[id], catalogue.entry(for: id)?.trialTerms == nil {
            return .owned(owned)
        }
        // Several trials may lend the same unlock; the one that runs longest decides.
        let lending = catalogue.trials(of: id)
            .compactMap { entry in period(of: entry).map { (period: $0, via: entry.id) } }
            .filter { $0.period.isRunning(at: date) }
            .max { $0.period.endsAt < $1.period.endsAt }
        if let lending { return .onTrial(lending.period, via: lending.via) }
        return .none
    }

    public func access(to id: ProductID) -> ProductAccess { access(to: id, at: asOf) }

    // MARK: - Trials

    public func trial(_ id: ProductID, at date: Date) -> TrialStatus {
        guard isKnown else { return .unknown }
        guard let entry = catalogue.entry(for: id), let terms = entry.trialTerms else { return .notOffered }
        if let period = period(of: entry) {
            return period.isRunning(at: date) ? .running(period) : .used(period)
        }
        // Nothing left for it to lend: every unlock it stands in for is owned.
        let lendsNothing = terms.targets.allSatisfy { holdings[$0] != nil }
        return lendsNothing ? .notOffered : .available
    }

    public func trial(_ id: ProductID) -> TrialStatus { trial(id, at: asOf) }

    /// The next moment after `asOf` at which an answer from this standing changes of
    /// its own accord: the end of the running trial that ends soonest.
    ///
    /// Nothing observable happens when a trial runs out — no transaction arrives —
    /// so whoever holds a standing has to look again then, or nothing locks until
    /// something unrelated redraws or the app is relaunched.
    public var nextExpiry: Date? {
        guard isKnown else { return nil }
        return catalogue.entries
            .compactMap { period(of: $0) }
            .filter { $0.isRunning(at: asOf) }
            .map(\.endsAt)
            .min()
    }

    private func period(of entry: CatalogueEntry) -> TrialPeriod? {
        guard let terms = entry.trialTerms, let held = holdings[entry.id] else { return nil }
        return terms.period(startingAt: held.originalPurchaseDate)
    }
}
