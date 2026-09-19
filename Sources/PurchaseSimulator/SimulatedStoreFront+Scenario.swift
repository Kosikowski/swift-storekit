//
//  SimulatedStoreFront+Scenario.swift
//  PurchaseSimulator
//
//  Arranging a simulated store from a `Scenario`.
//
//  This is where a scenario's ages become dates, and they become dates against the
//  *store's* clock — not the wall clock, and not at the moment the text was parsed.
//  That is what makes `owns=trial@13d23h55m` a fourteen-day trial with exactly five
//  minutes left whether the store runs on the system clock in a screenshot run or on
//  a `ManualClock` in a unit test that then advances it five minutes and watches the
//  trial end.
//

#if DEBUG

import Foundation
import PurchaseCore

extension SimulatedStoreFront {
    /// Arranges the store as `scenario` describes.
    ///
    /// Meant for a store that has just been made, before anything reads from it. The
    /// behaviour is replaced; holdings are **added** to whatever is there, replacing
    /// only a holding of the same product; and a gate is closed if the scenario
    /// holds it and otherwise left alone — a test that closed one itself knows when
    /// it wants it open. Call `reset()` first to start from nothing.
    ///
    /// Gates close first, so that an app already asking never sees a moment in which
    /// a held answer got out.
    public func apply(_ scenario: Scenario) {
        if scenario.holdsOwnership { ownershipGate.close() }
        if scenario.holdsCatalogue { catalogueGate.close() }
        if scenario.holdsPurchase { purchaseGate.close() }
        if scenario.holdsRestore { restoreGate.close() }
        behaviour = scenario.behaviour
        for holding in scenario.owns {
            seed(holding.id, age: holding.age, ownership: holding.ownership)
        }
        for holding in scenario.earlier {
            seedEarlierPurchase(holding.id, age: holding.age, ownership: holding.ownership)
        }
        for id in scenario.unverified { seedUnverified(id) }
        for subscription in scenario.subscriptions {
            if let status = status(of: subscription) { seedSubscription(status) }
        }
    }

    /// A scenario's subscription as a status, by this store's clock and behaviour. A grace
    /// period with no length in the behaviour runs the sixteen days App Store Connect
    /// offers in the middle.
    private func status(of subscription: Scenario.Subscription) -> HeldSubscription? {
        guard let terms = catalogue.entry(for: subscription.id)?.subscriptionTerms else { return nil }
        let now = clock.now
        let period = behaviour.subscriptionPeriod.timeInterval
        let age = subscription.age.timeInterval
        let renewing = Renewal(willRenew: true, nextProduct: subscription.id)
        let off = Renewal(willRenew: false, nextProduct: nil)
        let started: Date
        let state: HeldSubscription.State
        var renewal = renewing
        switch subscription.state {
        case .subscribed:
            started = now.addingTimeInterval(-age)
            state = .subscribed
        case .cancelled:
            started = now.addingTimeInterval(-age)
            state = .subscribed
            renewal = off
        case .inGracePeriod:
            started = now.addingTimeInterval(-age - period)
            let grace = (behaviour.gracePeriod ?? .seconds(16 * 86_400)).timeInterval
            state = .inGracePeriod(until: started.addingTimeInterval(period + grace))
        case .inBillingRetry:
            started = now.addingTimeInterval(-age - period)
            state = .inBillingRetry
        case .lapsed:
            started = now.addingTimeInterval(-age - period)
            state = .expired(.autoRenewDisabled)
            renewal = off
        }
        return HeldSubscription(
            product: subscription.id, group: terms.group, ownership: subscription.ownership, state: state,
            firstSubscribed: started, periodStarted: started, periodEnds: started.addingTimeInterval(period),
            renewal: renewal)
    }
}

#endif
