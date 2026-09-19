//
//  Scenario.swift
//  PurchaseSimulator
//
//  How a simulated store should be arranged, as a value — so that it can be written
//  in a launch argument, and a UI test or a screenshot run can start the app already
//  owning Pro, or five minutes from the end of a trial, without tapping its way
//  there.
//
//      -PurchaseScenario "owns=trial@13d23h55m; purchase=pending"
//
//  **This file only parses a scenario. Whether to honour one is decided at the
//  composition root**: `StoreLaunch.make` does in a debug build and cannot in a
//  release one, and an app with a root of its own decides under a compilation
//  condition of its own. That division is deliberate. On macOS anyone can pass launch arguments
//  to a shipped app — `open -a App --args -PurchaseScenario owns=pro` — so an app
//  that obeyed one in a release build would unlock itself for whoever asked. Nothing
//  here reads the process's arguments unless it is called, nothing here builds a
//  store, and **the whole file exists only in DEBUG builds**, as the store it
//  arranges does. Mind how a package comes by `DEBUG` under Xcode: by the build
//  configuration's *name*. `Debug-Screenshots` gets it; `Screenshots` does not, and
//  this type will not exist there (spike/README.md).
//
//  **On a scenario that does not parse, crash.** Falling back to the real store, or
//  to a store that owns nothing, turns a typo into a run of screenshots that look
//  plausible and are of the wrong thing; nobody finds out until they are on the App
//  Store. A `fatalError` carrying the error finds out at once. `StoreLaunch.make`, in
//  PurchaseLaunch, is this, and an app that starts with it writes none of it; an app
//  with a root of its own writes:
//
//      #if DEBUG       // or a condition of the app's own, in a Debug-named configuration
//      do {
//          if let scenario = try Scenario.fromLaunchArguments(catalogue: catalogue) {
//              let store = SimulatedStoreFront(catalogue: catalogue)
//              store.apply(scenario)
//              return store
//          }
//      } catch { fatalError("\(error)") }
//      #endif
//
//  A scenario holds no dates. `owns=trial@13d23h55m` says how long *ago* the trial
//  was bought, and becomes a date only against the clock of the store it is applied
//  to — so the same text means the same thing tomorrow, and under a manual clock.
//

#if DEBUG

public import Foundation
public import PurchaseCore

/// An arrangement of a `SimulatedStoreFront`: what the account holds, and how the
/// store behaves. Apply it with `SimulatedStoreFront.apply(_:)`.
public struct Scenario: Hashable, Sendable {
    /// One product the account holds, and since how long ago.
    public struct Holding: Hashable, Sendable {
        public let id: ProductID

        /// How long ago it was bought, by the clock of whichever store this is
        /// applied to. With a fourteen-day trial, thirteen days, twenty-three hours
        /// and fifty-five minutes is a trial with exactly five minutes left.
        public let age: Duration

        public let ownership: Ownership

        public init(_ id: ProductID, age: Duration = .zero, ownership: Ownership = .purchased) {
            self.id = id
            self.age = age
            self.ownership = ownership
        }
    }

    /// Owned and listed from launch, with no announcement.
    public var owns: [Holding]

    /// Owned by the account and **unknown to this device**: bought elsewhere, or
    /// before a reinstall. Buying one, or a restore, brings it here with its age.
    public var earlier: [Holding]

    /// Listed by the store with a signature that does not check out: a customer who
    /// paid, and whom the app must show as owning nothing.
    public var unverified: [ProductID]

    public var behaviour: SimulatedStoreFront.Behaviour

    /// The store has not yet said what is owned — how every launch begins, held
    /// open for as long as a screenshot of it takes.
    public var holdsOwnership: Bool

    /// The store has not yet said what it sells: a slow network.
    public var holdsCatalogue: Bool

    /// A purchase, once begun, stays under way: the payment sheet is up. For a
    /// screenshot or a UI test of what the app shows while it waits.
    public var holdsPurchase: Bool

    /// The same for a restore: the store is asking for a password.
    public var holdsRestore: Bool

    /// A scenario written in code. With no arguments, a store on a good day that
    /// owns nothing — which is also what the empty text parses to.
    public init(
        owns: [Holding] = [],
        earlier: [Holding] = [],
        unverified: [ProductID] = [],
        behaviour: SimulatedStoreFront.Behaviour = SimulatedStoreFront.Behaviour(),
        holdsOwnership: Bool = false,
        holdsCatalogue: Bool = false,
        holdsPurchase: Bool = false,
        holdsRestore: Bool = false
    ) {
        self.owns = owns
        self.earlier = earlier
        self.unverified = unverified
        self.behaviour = behaviour
        self.holdsOwnership = holdsOwnership
        self.holdsCatalogue = holdsCatalogue
        self.holdsPurchase = holdsPurchase
        self.holdsRestore = holdsRestore
    }

    /// The launch argument a scenario follows: `-PurchaseScenario "<text>"`. Spelt
    /// like a user default so that Xcode's scheme editor and `XCUIApplication`'s
    /// `launchArguments` both pass it without ceremony.
    public static let launchArgument = "-PurchaseScenario"

    /// The environment variable read when the argument is absent.
    public static let environmentVariable = "PURCHASE_SCENARIO"

    /// The scenario this process was launched with, if it was launched with one.
    ///
    /// Looks for `-PurchaseScenario <text>` among the arguments and, failing that,
    /// for `PURCHASE_SCENARIO` in the environment; the argument wins when both are
    /// there, being the more deliberate of the two. **Nil means neither was
    /// present** — use the real store. A scenario that is present and does not parse
    /// throws, and the caller should crash on it rather than carry on with a store
    /// nobody asked for. Present and empty is a scenario: a simulated store on a
    /// good day, owning nothing.
    ///
    /// The arguments and the environment are parameters, defaulted only here at the
    /// edge, so that a test of this never touches the real process.
    public static func fromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        catalogue: Catalogue
    ) throws(ScenarioError) -> Scenario? {
        if let flag = arguments.firstIndex(of: launchArgument) {
            let next = arguments.index(after: flag)
            guard next < arguments.endIndex else {
                throw .invalidScenario(clause: launchArgument, reason: .missingValue)
            }
            return try Scenario(parsing: arguments[next], catalogue: catalogue)
        }
        if let text = environment[environmentVariable] {
            return try Scenario(parsing: text, catalogue: catalogue)
        }
        return nil
    }
}

#endif
