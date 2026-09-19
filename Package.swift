// swift-tools-version: 6.2
//
//  swift-storekit — one-time purchases and trials over StoreKit 2, for macOS and iOS.
//
//  Selling a non-consumable looks like sixty lines of StoreKit, and every app that
//  writes those sixty lines gets a different handful of them wrong: it reads what is
//  owned in a task SwiftUI then cancels, and a paying customer is shown the paywall;
//  it asks `currentEntitlements` the moment `purchase()` returns, a second before the
//  purchase is listed, and the Buy button "does nothing"; it finishes another
//  product's transactions; it waits for prices before it knows what is owned, and
//  locks an owner out whenever the network is slow. This package is those decisions
//  made once, with a test on each.
//
//  **It reports store facts and performs store actions. It holds no opinion about
//  what a purchase unlocks.** What the account owns and since when, whether the store
//  has answered yet, where a trial stands, what is pending approval: those are here.
//  Feature gates, limits, paywall wording and what locks on a downgrade are the
//  app's, and are deliberately not.
//
//  `PurchaseCore` is the whole of the logic and imports no Apple framework beyond
//  Foundation and Observation — not StoreKit, not SwiftUI. The store is a set of
//  small protocols it owns, so everything that decides anything runs under plain
//  `swift test`, offline, with no test host. That is not tidiness: `SKTestSession`
//  does not work in a package test target at all (see spike/README.md).
//
//  `PurchaseStoreKit` is the App Store behind those protocols, and the only place a
//  static StoreKit call is made. `PurchaseUI` is a few SwiftUI conveniences and no
//  paywall. Neither depends on the other; they meet in Core.
//
//  **An app imports modules that do something in every build, and nothing else.**
//  `PurchaseLaunch` gives an app its store: in a DEBUG build a `-PurchaseScenario`
//  argument chooses a simulated one; otherwise, and always in release, the App Store. The
//  app's own code has no `#if` in it. `PurchaseDebugUI` is a panel that drives the
//  simulated store in a running debug build, and draws nothing in a release one.
//
//  The simulated store itself is `PurchaseSimulator`, which **no app imports** and
//  which exists only in DEBUG builds — the whole module, not only what can grant a
//  purchase — so an app that links it, as every app using PurchaseLaunch does, ships
//  with nothing of it at all, and `swift package release-check` proves that of the
//  package and of a built app. It lists a purchase one read late and answers nothing to
//  a cancelled task, because the real store does and a politer fake hides both bugs.
//
//  `PurchaseTestKit` is to this package what StoreKitTest is to StoreKit: what a test
//  imports, and an app cannot — it reports through Swift Testing, which only a test
//  target can link, so an app that links it does not build. The simulated store, re-exported, and beside it a clock
//  that moves when told, a wait on a condition, a logger that remembers and a reader
//  for the `.storekit` file — none of which grants anything, so none of which is
//  guarded, and all of which work in a release test run. It ships rather than hiding in
//  a test target for the reason a test server ships with a network client: an app
//  testing its own paywall needs a store to point it at.
//
//  `PurchaseDirectDistribution` is one type, `EverythingOwnedStoreFront`, for a build
//  sold some other way. Apart because it is a store in which everything is owned, and
//  an App Store build should not contain one.

import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    // Swift 7's defaults, taken early and one at a time — the same set as the
    // owner's other packages, so code moves between them without surprises.
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "swift-storekit",
    // The floor is the owner's, not StoreKit's: nothing here needs 26 except
    // `Observations`, and everything it is built for already targets it.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PurchaseCore", targets: ["PurchaseCore"]),
        .library(name: "PurchaseStoreKit", targets: ["PurchaseStoreKit"]),
        .library(name: "PurchaseUI", targets: ["PurchaseUI"]),
        .library(name: "PurchaseLaunch", targets: ["PurchaseLaunch"]),
        .library(name: "PurchaseDebugUI", targets: ["PurchaseDebugUI"]),
        // For test targets, and only for them. Shipped, not hidden in one: see above.
        .library(name: "PurchaseTestKit", targets: ["PurchaseTestKit"]),
        // The simulated store by itself, for an app that writes its own composition root
        // (a screenshots configuration with a condition of its own). Most apps never name it.
        .library(name: "PurchaseSimulator", targets: ["PurchaseSimulator"]),
        .library(name: "PurchaseDirectDistribution", targets: ["PurchaseDirectDistribution"]),
    ],
    targets: [
        .target(name: "PurchaseCore", swiftSettings: strict),
        .target(name: "PurchaseStoreKit", dependencies: ["PurchaseCore"], swiftSettings: strict),
        .target(name: "PurchaseUI", dependencies: ["PurchaseCore"], swiftSettings: strict),
        // DEBUG only, whole. Inside every app that uses PurchaseLaunch, and named by none.
        .target(name: "PurchaseSimulator", dependencies: ["PurchaseCore"], swiftSettings: strict),
        .target(
            name: "PurchaseLaunch", dependencies: ["PurchaseCore", "PurchaseStoreKit", "PurchaseSimulator"],
            swiftSettings: strict),
        // Depends on the simulator and not the other way about, so that what an app links
        // depends on nothing that is not behind the guard.
        .target(
            name: "PurchaseTestKit", dependencies: ["PurchaseCore", "PurchaseSimulator"],
            swiftSettings: strict),
        .target(name: "PurchaseDirectDistribution", dependencies: ["PurchaseCore"], swiftSettings: strict),
        .target(
            name: "PurchaseDebugUI", dependencies: ["PurchaseCore", "PurchaseLaunch", "PurchaseSimulator"],
            swiftSettings: strict),
        // `swift package release-check`. A plugin and not a script, because the build
        // can tell a plugin what it built, and a script has to go looking: two scripts
        // went looking in the wrong place and passed (docs/07-release-safety.md). Not
        // a product — it proves something about this package, not about an app.
        .plugin(
            name: "ReleaseCheck",
            capability: .command(
                intent: .custom(
                    verb: "release-check",
                    description: "Proves the simulated store is in a debug build and absent from a release one."))),
        .testTarget(
            name: "PurchaseCoreTests",
            dependencies: ["PurchaseCore", "PurchaseTestKit", "PurchaseDirectDistribution"],
            swiftSettings: strict),
        .testTarget(
            name: "PurchaseTestKitTests", dependencies: ["PurchaseCore", "PurchaseTestKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict),
        .testTarget(
            name: "PurchaseLaunchTests", dependencies: ["PurchaseCore", "PurchaseLaunch", "PurchaseTestKit"],
            swiftSettings: strict),
        .testTarget(
            name: "PurchaseStoreKitTests", dependencies: ["PurchaseCore", "PurchaseStoreKit"],
            swiftSettings: strict),
    ]
)
