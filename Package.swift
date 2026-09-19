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
//  `PurchaseTestKit` ships rather than hiding in a test target, for the reason a
//  test server ships with a network client: an app testing its own paywall needs a
//  store to point it at, and the alternative is every app inventing a worse one.
//  Its simulated store lists a purchase one read late and answers nothing to a
//  cancelled task, because the real one does and a politer fake hides both bugs.
//  **Everything in it exists only in DEBUG builds** — the whole module, not only what
//  can grant a purchase — so an app that links it, as it must to have a debug panel
//  or a scenario, ships with nothing of it at all, and `swift package release-check`
//  proves that about the package and about a built app. `PurchaseDebugUI` is the
//  panel that drives it, kept apart so that the module unit tests link carries no
//  SwiftUI.
//
//  `PurchaseTestSupport` is what a *test* needs and an app does not: a clock that
//  moves when told, a wait on a condition, a logger that remembers, and a reader for
//  the `.storekit` file. None of it grants anything, so none of it is guarded and
//  all of it works in a release test run. It is apart so that an app does not carry
//  it: Xcode links a package product into every configuration of a target or none.
//
//  `PurchaseDirectDistribution` is one type, `EverythingOwnedStoreFront`, for a build
//  sold some other way. Apart for the same reason: it is a store in which everything
//  is owned, and an App Store build should not contain one.

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
        // Shipped, not test-only. See the note above.
        .library(name: "PurchaseTestKit", targets: ["PurchaseTestKit"]),
        .library(name: "PurchaseTestSupport", targets: ["PurchaseTestSupport"]),
        .library(name: "PurchaseDebugUI", targets: ["PurchaseDebugUI"]),
        .library(name: "PurchaseDirectDistribution", targets: ["PurchaseDirectDistribution"]),
    ],
    targets: [
        .target(name: "PurchaseCore", swiftSettings: strict),
        .target(name: "PurchaseStoreKit", dependencies: ["PurchaseCore"], swiftSettings: strict),
        .target(name: "PurchaseUI", dependencies: ["PurchaseCore"], swiftSettings: strict),
        .target(name: "PurchaseTestKit", dependencies: ["PurchaseCore"], swiftSettings: strict),
        // Depends on the test kit and not the other way about, so that the test kit —
        // the one an app links — depends on nothing that is not behind the guard.
        .target(
            name: "PurchaseTestSupport", dependencies: ["PurchaseCore", "PurchaseTestKit"],
            swiftSettings: strict),
        .target(name: "PurchaseDirectDistribution", dependencies: ["PurchaseCore"], swiftSettings: strict),
        .target(
            name: "PurchaseDebugUI", dependencies: ["PurchaseCore", "PurchaseTestKit"],
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
            dependencies: ["PurchaseCore", "PurchaseTestKit", "PurchaseTestSupport", "PurchaseDirectDistribution"],
            swiftSettings: strict),
        .testTarget(
            name: "PurchaseTestKitTests", dependencies: ["PurchaseCore", "PurchaseTestKit", "PurchaseTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict),
        .testTarget(
            name: "PurchaseStoreKitTests", dependencies: ["PurchaseCore", "PurchaseStoreKit"],
            swiftSettings: strict),
    ]
)
