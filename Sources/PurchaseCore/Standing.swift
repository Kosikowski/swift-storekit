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
    /// The date the convenience queries answer for: when the store last resolved to
    /// something that *reads* differently. A later read that found nothing new is not
    /// published (it would redraw everything that watches this, for nothing), so this
    /// is not "when the store was last asked". Questions that depend on the time take
    /// the date as a parameter; pass the time it is.
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

    /// Whether `other` answers every question this does, each asked of its own moment.
    ///
    /// Not equality, which includes `asOf`: two readings an hour apart of an account that
    /// owns the same things are different values and the same news. What is held has to
    /// match, *and* what it amounts to — a trial that ran out in that hour holds exactly
    /// what it held, and is the one case where nothing new is something new.
    func saysTheSame(as other: Standing) -> Bool {
        guard phase == other.phase, catalogue == other.catalogue, holdings == other.holdings else { return false }
        return catalogue.entries.allSatisfy { entry in
            access(to: entry.id) == other.access(to: entry.id) && trial(entry.id) == other.trial(entry.id)
        }
    }

    private func period(of entry: CatalogueEntry) -> TrialPeriod? {
        guard let terms = entry.trialTerms, let held = holdings[entry.id] else { return nil }
        return terms.period(startingAt: held.originalPurchaseDate)
    }
}
