//
//  StoreLaunch.swift
//  PurchaseLaunch
//
//  The composition root, for an app that does not want to write one.
//
//  One place in an app decides which store a launch runs on, and the right shape for it
//  is always the same: in a DEBUG build, a `-PurchaseScenario` argument chooses a
//  simulated store and what it starts with; otherwise, and **always in a release build**,
//  the App Store. Written in the app, that is an `#if DEBUG`, an import that names a
//  module which is not there in release, and a `fatalError` that people forget. Written
//  here it is a function, and the app's own code has no `#if` in it at all.
//
//  **This module is never empty, and it is the only thing an app imports for this.** The
//  simulated store is reached from in here, under `#if DEBUG`, from a module the app
//  never names. In a release build the scenario branch does not exist — not "is not
//  taken": the simulator's module compiles to nothing, and `swift package release-check`
//  proves that of the package and of a built app — so an argument has nothing to switch
//  on. On macOS anyone can pass a shipped app launch arguments.
//
//  **On a scenario that does not parse, this crashes.** Falling back to the real store
//  turns a typo into a run of screenshots that look plausible and are of the wrong
//  thing.
//
//  An app with a condition of its own — a `Debug-Screenshots` configuration that should
//  honour scenarios where the everyday debug build does not — writes its own root over
//  `SimulatedStoreFront` and `Scenario` instead; they are public (docs/07).
//

public import Foundation
public import PurchaseCore
import PurchaseStoreKit

#if DEBUG
package import PurchaseSimulator
#endif

/// The store this launch runs on, and whether it is a simulated one.
@MainActor
public struct StoreLaunch {
    public let store: PurchaseStore

    /// Whether this launch is on a simulated store. **Always false in a release build.**
    ///
    /// Show something only when this is true — a "Simulated store" badge — and have every
    /// UI test assert it first: a scenario the build cannot honour is silent, the app
    /// runs on the real store, and the pictures are of the wrong thing.
    public var isSimulated: Bool {
        #if DEBUG
        simulated != nil
        #else
        false
        #endif
    }

    #if DEBUG
    /// The simulated store, for the debug panel's controls. `package`, because an app has
    /// no business with it: what an app may know is `isSimulated`.
    package let simulated: SimulatedStoreFront?
    #endif

    /// The store for this launch.
    ///
    /// - Parameters:
    ///   - logger: given to the store and to the App Store front alike, so that a purchase
    ///     that does not verify is heard of whichever of them met it.
    ///   - live: the store when no scenario asks for a simulated one. The App Store unless
    ///     you say otherwise; a build sold some other way says `EverythingOwnedStoreFront`.
    ///   - arguments: searched for `-PurchaseScenario <text>`, in a DEBUG build only.
    ///   - environment: searched for `PURCHASE_SCENARIO`, likewise, when the argument is absent.
    public static func make(
        catalogue: Catalogue,
        clock: any TimeProviding = SystemClock(),
        logger: any PurchaseLogging = SilentPurchaseLogger(),
        live: ((Catalogue, any PurchaseLogging) -> any StoreFront)? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> StoreLaunch {
        #if DEBUG
        do {
            if let scenario = try Scenario.fromLaunchArguments(arguments, environment: environment, catalogue: catalogue) {
                let front = SimulatedStoreFront(catalogue: catalogue, clock: clock)
                front.apply(scenario)
                return StoreLaunch(
                    store: PurchaseStore(catalogue: catalogue, front: front, clock: clock, logger: logger),
                    simulated: front)
            }
        } catch {
            fatalError("\(Scenario.launchArgument) could not be read: \(error)")
        }
        #endif
        let front = live?(catalogue, logger) ?? AppStoreFront(catalogue: catalogue, logger: logger)
        return on(front, catalogue: catalogue, clock: clock, logger: logger)
    }

    /// A store for a SwiftUI preview, arranged by a scenario: `"owns=pro"`,
    /// `"owns=trial@13d23h55m"`, `"ownership=held"` (docs/06).
    ///
    /// Text, and not a simulated store to arrange, so that a preview names nothing that is
    /// missing from a release build: previews are compiled in release too, and one that
    /// names `SimulatedStoreFront` fails the archive. In a release build this is a store
    /// that owns nothing and sells nothing, which no preview ever runs.
    public static func preview(catalogue: Catalogue, scenario: String = "") -> PurchaseStore {
        #if DEBUG
        do {
            let front = SimulatedStoreFront(catalogue: catalogue)
            front.apply(try Scenario(parsing: scenario, catalogue: catalogue))
            return PurchaseStore(catalogue: catalogue, front: front)
        } catch {
            fatalError("The preview's scenario could not be read: \(error)")
        }
        #else
        return PurchaseStore(catalogue: catalogue, front: NothingStoreFront())
        #endif
    }

    // MARK: - Private

    /// Opens `any StoreFront`: the store takes a front of one type.
    private static func on(
        _ front: some StoreFront, catalogue: Catalogue, clock: any TimeProviding, logger: any PurchaseLogging
    ) -> StoreLaunch {
        let store = PurchaseStore(catalogue: catalogue, front: front, clock: clock, logger: logger)
        #if DEBUG
        return StoreLaunch(store: store, simulated: nil)
        #else
        return StoreLaunch(store: store)
        #endif
    }
}

#if !DEBUG
/// What a preview's store stands on in a release build, where no preview runs: a store
/// that owns nothing, sells nothing and refuses to sell. It can grant nothing.
private struct NothingStoreFront: StoreFront {
    func products() async throws(PurchaseError) -> [StoreProduct] { [] }
    func ownedProducts() async -> [OwnedProduct] { [] }
    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws(PurchaseError) -> PurchaseOutcome {
        throw .purchaseNotAllowed
    }
    func restorePurchases() async throws(PurchaseError) -> RestoreOutcome { .completed }
    func transactionUpdates() -> AsyncStream<TransactionUpdate> { AsyncStream { $0.finish() } }
}
#endif
