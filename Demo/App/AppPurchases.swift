//
//  AppPurchases.swift
//  Demo
//
//  The composition root: the one place that knows which store this launch runs on.
//
//  **Decided by the build, not by an argument.** The simulated store does not exist in
//  a release build, so there is nothing here for an argument to switch on. In a debug
//  build, `-PurchaseScenario` chooses *what the simulated store starts with* — what
//  varies per run — and its absence means the real store.
//
//      -PurchaseScenario "owns=trial@13d23h55m"       a trial with five minutes left
//      -PurchaseScenario "owns=pro"                   an owner
//      -PurchaseScenario "purchase=pending"           Ask to Buy
//      -PurchaseScenario "ownership=held"             the store has not answered
//

import PurchaseCore
import PurchaseStoreKit

#if DEBUG
import PurchaseTestKit
#endif

@MainActor
struct AppPurchases {
    let store: PurchaseStore
    let diagnostics: any StoreDiagnosing
    #if DEBUG
    let simulated: SimulatedStoreFront?
    #endif

    static func forThisLaunch() -> AppPurchases {
        #if DEBUG
        do {
            if let scenario = try Scenario.fromLaunchArguments(catalogue: Shop.catalogue) {
                let front = SimulatedStoreFront(catalogue: Shop.catalogue)
                front.apply(scenario)
                return AppPurchases(
                    store: PurchaseStore(catalogue: Shop.catalogue, front: front),
                    diagnostics: front, simulated: front)
            }
        } catch {
            // Crash, rather than fall back to the real store: a typo that quietly
            // runs on the wrong store produces screenshots of the wrong thing.
            fatalError("-PurchaseScenario could not be read: \(error)")
        }
        let front = AppStoreFront(catalogue: Shop.catalogue)
        return AppPurchases(
            store: PurchaseStore(catalogue: Shop.catalogue, front: front), diagnostics: front, simulated: nil)
        #else
        let front = AppStoreFront(catalogue: Shop.catalogue)
        return AppPurchases(store: PurchaseStore(catalogue: Shop.catalogue, front: front), diagnostics: front)
        #endif
    }
}
