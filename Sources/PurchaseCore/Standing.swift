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
    private let subscriptions: [SubscriptionGroupID: SubscriptionStanding]
    /// Every counted purchase of each non-renewing subscription, by date, oldest first.
    private let nonRenewingPurchases: [ProductID: [Date]]

    /// Built by `StandingResolver`; `holdings` must already be the ones that count.
    init(
        phase: Phase, asOf: Date, catalogue: Catalogue, holdings: [ProductID: OwnedProduct],
        subscriptions: [SubscriptionGroupID: SubscriptionStanding] = [:], nonRenewing: [ProductID: [Date]] = [:]
    ) {
        self.phase = phase
        self.asOf = asOf
        self.catalogue = catalogue
        self.holdings = holdings
        self.subscriptions = subscriptions
        self.nonRenewingPurchases = nonRenewing
    }

    /// The standing before the store has said anything.
    public static func unknown(catalogue: Catalogue, asOf: Date = .distantPast) -> Standing {
        Standing(phase: .unknown, asOf: asOf, catalogue: catalogue, holdings: [:])
    }

    public var isKnown: Bool { phase == .known }

    /// What is held and counts, in identifier order. A trial product is in here from
    /// the day it is taken and stays after it ends; ask `trial(_:at:)` where it stands. So
    /// is a non-renewing subscription, as its latest purchase: ask `nonRenewing(_:at:)`.
    /// Subscriptions are not: ask `subscription(in:)`.
    public var ownedProducts: [OwnedProduct] {
        holdings.values.sorted { $0.id < $1.id }
    }

    public func ownership(of id: ProductID) -> OwnedProduct? { holdings[id] }

    // MARK: - Access

    public func access(to id: ProductID, at date: Date) -> ProductAccess {
        guard isKnown else { return .unknown }
        // A subscription gives access by what the store last said, not by the clock: its
        // end is the store's to say (it may have renewed, or be in a grace period), and
        // the store is asked again when it comes. For the dates, see the `HeldSubscription`.
        if let terms = catalogue.entry(for: id)?.subscriptionTerms {
            if case let .active(held, _) = subscription(in: terms.group), held.product == id { return .subscribed(held) }
            return .none
        }
        // By the clock, as a trial is: its end is the catalogue's to say.
        if catalogue.entry(for: id)?.nonRenewingTerms != nil {
            if case let .active(period) = nonRenewing(id, at: date) { return .nonRenewing(period) }
            return .none
        }
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

    // MARK: - Subscriptions

    /// Where this account stands in `group`. Before the store has answered, `unknown`.
    ///
    /// A product in the group is `access(to:)`'s business only when it is the one held;
    /// an app that sells monthly and yearly plans of the same thing asks this instead.
    public func subscription(in group: SubscriptionGroupID) -> SubscriptionStanding {
        guard isKnown else { return .unknown }
        return subscriptions[group] ?? .none
    }

    // MARK: - Non-renewing subscriptions

    /// Where the non-renewing subscription `id` stands at `date`: the period running then,
    /// made of every purchase that reaches it, or the last one that ended.
    public func nonRenewing(_ id: ProductID, at date: Date) -> NonRenewingStatus {
        guard isKnown else { return .unknown }
        guard let terms = catalogue.entry(for: id)?.nonRenewingTerms else { return .none }
        let periods = terms.periods(of: nonRenewingPurchases[id] ?? [])
        if let running = periods.first(where: { $0.isRunning(at: date) }) { return .active(running) }
        if let ended = periods.last(where: { $0.endsAt <= date }) { return .ended(ended) }
        return .none
    }

    public func nonRenewing(_ id: ProductID) -> NonRenewingStatus { nonRenewing(id, at: asOf) }

    /// Every counted purchase of the non-renewing subscription `id`, by date.
    func purchases(ofNonRenewing id: ProductID) -> [Date] { nonRenewingPurchases[id] ?? [] }

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
    ///
    /// For a subscription, the moment its access by the store's last word ends: the end of
    /// its period, or of its grace period. Nothing may change then — it may have renewed —
    /// but only the store can say, so that is when to ask it.
    public var nextExpiry: Date? {
        guard isKnown else { return nil }
        let trials = catalogue.entries
            .compactMap { period(of: $0) }
            .filter { $0.isRunning(at: asOf) }
            .map(\.endsAt)
        let subscribed = subscriptions.values.compactMap { standing -> Date? in
            guard case let .active(held, _) = standing, held.accessEnds > asOf else { return nil }
            return held.accessEnds
        }
        let nonRenewing = nonRenewingPurchases.keys.compactMap { id -> Date? in
            if case let .active(period) = self.nonRenewing(id) { return period.endsAt }
            return nil
        }
        return (trials + subscribed + nonRenewing).min()
    }

    /// Whether `other` answers every question this does, each asked of its own moment.
    ///
    /// Not equality, which includes `asOf`: two readings an hour apart of an account that
    /// owns the same things are different values and the same news. What is held has to
    /// match, *and* what it amounts to — a trial that ran out in that hour holds exactly
    /// what it held, and is the one case where nothing new is something new.
    func saysTheSame(as other: Standing) -> Bool {
        guard phase == other.phase, catalogue == other.catalogue, holdings == other.holdings,
              subscriptions == other.subscriptions, nonRenewingPurchases == other.nonRenewingPurchases
        else { return false }
        return catalogue.entries.allSatisfy { entry in
            access(to: entry.id) == other.access(to: entry.id) && trial(entry.id) == other.trial(entry.id)
                && nonRenewing(entry.id) == other.nonRenewing(entry.id)
        }
    }

    private func period(of entry: CatalogueEntry) -> TrialPeriod? {
        guard let terms = entry.trialTerms, let held = holdings[entry.id] else { return nil }
        return terms.period(startingAt: held.originalPurchaseDate)
    }
}
