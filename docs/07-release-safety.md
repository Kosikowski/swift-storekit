# Release safety

The simulated store hands out purchases for nothing. This is how it is kept out of what ships.

## The threat

- **On macOS, anyone can pass launch arguments to a shipped app**: `open -a YourApp --args -PurchaseScenario owns=pro`. An app that obeyed that in a release build would be free to whoever read this page.
- A misplaced `#if` in an app, or a build configuration that does not define what its author believes it does.
- This is a public package. People will paste its composition-root example, and some will drop the guard.
- App Review guideline 2.3.1(a): "Don't include any hidden, dormant, or undocumented features in your app." **[Apple]** A purchase simulator that ships, switched off, is one.

## What the package does

**Absent, not disabled.** The simulated store — `SimulatedStoreFront`, its gates, `Scenario` — is one module, `PurchaseSimulator`, wrapped in `#if DEBUG` whole: every file from its first line to its last. In a release build it is empty: not only can nothing in it grant a purchase, there is nothing in it. `#if DEBUG` is also Apple's own pattern for code that belongs to the test environment. **[Apple]**

**And an app never names it.** A module that is empty in release is an awkward thing to import: everything that mentioned it — a composition root, a preview, a panel — had to sit inside an `#if DEBUG` of the app's own, under an import of something that was not there, and the first Release build found whichever one had been forgotten. So the guard is the package's, not the app's. An app imports `PurchaseLaunch`, which is never empty — in release it gives the app the App Store — and which reaches the simulator itself, in a debug build, under an `#if` written once, here. `PurchaseDebugPanel`'s *name* is likewise in every build, and draws nothing in release. What is left for an app to guard is a test that names the simulated store, which builds in debug ([testing](05-testing.md#guard-every-test-that-names-the-simulated-store)), and a `Window` scene for the panel, since a scene cannot be conditional.

**The build decides, and an argument only chooses.** `Scenario.fromLaunchArguments` reads nothing until it is called and builds no store. `StoreLaunch.make` calls it — in a debug build. In a release build the call is not there to be reached.

**It is proven, in CI, of the package and of an app.** `swift package release-check` (`make release-check`, part of `make check`) builds the package twice and searches the compiled symbols of each build. What it looks for is **the module, not a list of names**: no symbol anywhere in the release build may mention `PurchaseSimulator`, nor the store by name, nor what the debug panel draws, and every one of those marks must be *found* in the debug build. A list of the types that can grant a purchase is a list somebody has to remember to extend. **[ran]**

**And then the app, because the app is what ships.** SwiftPM's release build is not Xcode's: in an app, the package is given `DEBUG` by the *name* of the app's build configuration ([below](#screenshot-and-ui-test-configurations)), by a heuristic nobody documents, and that is the one link a check of the package alone cannot test. So `make demo` builds the Demo app both ways and hands both to the same plugin — `swift package release-check --app <Release .app> --debug-app <Debug .app>` — which reads every Mach-O in each bundle, by symbol and by string, for the simulator, and for what a scenario is called on a command line and in the environment. The debug app is the control: the search has to find all of it there — but for the debug panel, which is looked for only in a debug app that links `PurchaseDebugUI`. (The first app moved onto the package does not, and was called vacuous for the want of a panel it never had. **[ran]**) It also fails a release app that has **`PurchaseTestKit`** in it — which the linker already refuses (D34), so this is for whatever gets past that; that name's control is the hosted test bundle inside the debug app, so build the debug app with `build-for-testing`. **[ran]** Point it at your own app's builds for the same assurance about what you ship. The plugin is not a product — Xcode has no way to run a dependency's command plugin from a command line — so it is run from a checkout of this package, with absolute paths to the two apps:

```sh
xcodebuild -scheme YourApp -configuration Debug   -derivedDataPath build/check/debug   build-for-testing
xcodebuild -scheme YourApp -configuration Release -derivedDataPath build/check/release build
swift package --package-path path/to/swift-storekit release-check \
    --app "$PWD/build/check/release/Build/Products/Release/YourApp.app" \
    --debug-app "$PWD/build/check/debug/Build/Products/Debug/YourApp.app"
```

Before archiving, or in CI; it is two full builds. **[ran]**, against the first app moved onto the package.

It is a package command plugin (`Plugins/ReleaseCheck`), which also puts it in Xcode's menu for the package, and it is one because **a check that cannot fail proves nothing, and its two predecessors could not**. Both were shell scripts that went looking for the build's files by the shape of their paths:

- The first searched a directory the build system had stopped using.
- The second picked files whose path contained `Release`. Under SwiftPM's older layout, `.build/<triple>/release`, that is none of them: it searched nothing and reported clean. Its control — "the same search must find the store in a debug build" — was satisfied by the word `Debug` in `PurchaseDebugUI`. **[ran]**
- One of its three names was misspelt (`16PurchaseTestKit…`; the module's name is fifteen letters long), so `Scenario` had never been looked for. **[ran]**

So the plugin follows three rules, one for each:

| Rule | Why |
|---|---|
| **The build says what it built.** `packageManager.build` hands back the libraries of *that* configuration; nothing is inferred from a path. Where the older build system reports none, the objects come from that configuration's own directory. | A script has to go looking, and twice looked in the wrong place. |
| **The release search has a control of its own**: it must find `ManualClock`, which ships in every configuration. | Finding nothing forbidden in a search that can see nothing is not a pass. |
| **Every forbidden name is controlled separately**: each must turn up in the debug build. | A misspelt name, or one a rename left behind, guards nothing and says nothing. |

It was then made to fail on purpose, both ways: with the guards taken off the test kit it reports `SimulatedStoreFront` and `Scenario` present in release, and with a name misspelt it reports itself vacuous. It passes under both SwiftPM build systems. **[ran]**

A macro was considered and cannot do this. A macro sees source at compile time, and the question is about a finished binary; what a macro *could* enforce — that a release build never mentions the simulated store — `#if DEBUG` round the whole file already does, as a compile error, without taking on swift-syntax in a package that has no dependencies.

**What it does not prove is anything about your app.** It checks this package's own products. An app that wants the same assurance about what it ships should search its archived binary for `SimulatedStoreFront` — with `strings`, not `nm`, since a shipped app's symbols are stripped.

What is not under `#if DEBUG` is `PurchaseTestKit`'s own: `ManualClock`, `waitUntil`, `RecordingPurchaseLogger`, and `StoreKitConfiguration` with its problems and errors. They grant nothing, and a test needs them in whatever configuration it is built — **but an app does not need them at all**, and Xcode links a package product into every configuration of a target or none. `PurchaseTestKit` is what tests import, as StoreKitTest is, and no app can link it: it reports through Swift Testing, which only a test target can link, so an app that links it stops in the linker, in Debug and Release alike. **[ran]** ([D34](10-decisions.md#d34-the-test-kit-reports-through-swift-testing-so-no-app-can-link-it))

**Why not leave the guard off, and rely on which targets link it?** For unit tests that is how it works — the test target links `PurchaseTestKit` and the app does not. But a debug panel, a scenario and a preview need the simulated store *in the app*, and Xcode cannot link a package product for one build configuration and not another; SwiftPM cannot make a dependency conditional on the configuration either (only on platform and traits). Unguarded, "is a purchase simulator in the release build?" would be a matter of which targets someone remembered to link — or of a second, debug-only app target kept in step with the real one; `#if DEBUG` makes it a matter the compiler decides ([D22](10-decisions.md#d22-the-simulated-store-is-gated-by-debug-not-moved-to-a-target-of-its-own), [D33](10-decisions.md#d33-an-app-imports-nothing-that-is-empty-in-release)).

`EverythingOwnedStoreFront` is the opposite case and ships in release **by design**: it is for a build sold some other way (Developer ID, Setapp). It cannot be switched on by an argument or a preference; it is what the app was built with. It is in a product of its own, `PurchaseDirectDistribution`, so that an App Store build — which has no use for a store in which everything is owned — does not contain one.

**What this does not cover.** A TestFlight build is a Release build: testers get no simulated store, no scenarios and no debug panel. And in a DEBUG build `StoreLaunch` *does* honour `-PurchaseScenario` and `PURCHASE_SCENARIO`, by design — so a build in any `Debug…`-named configuration, handed to somebody ad hoc, can be unlocked by whoever can pass it an argument. Hand out Release builds.

## Decide by the build, not by an argument

```swift
import PurchaseLaunch

let launch = StoreLaunch.make(catalogue: Shop.catalogue)   // the whole composition root
```

In a debug build `-PurchaseScenario` (or `PURCHASE_SCENARIO`) chooses a simulated store and what it starts with; with neither, and **always in a release build**, the launch is on the App Store ([getting started](02-getting-started.md#the-composition-root)). `launch.store` is the store; `launch.isSimulated` is whether it is simulated, which is never true in release.

The build decides *whether* a simulated store is possible. The argument decides only *what it starts with*, which is what varies from run to run.

**Crash on a scenario that does not parse.** Falling back to the real store turns a typo into a run of screenshots that look plausible and are of the wrong thing.

**A scenario the build cannot honour is silent, and only a test can catch it.** In a Release-configured test run the scenario branch is not there: the app ignores `-PurchaseScenario`, runs on the real store, and nothing fails. Show a marker only when the app is on a simulated store, and have every UI test assert it first ([UI tests and screenshots](06-simulated-store.md#ui-tests-and-screenshots)).

### Writing the root yourself

`StoreLaunch` honours a scenario in any DEBUG build. A screenshot pipeline wants something narrower: a configuration of its own, so that the everyday development build cannot be talked into showing invented purchases at all. That root is the app's to write, over `PurchaseSimulator`, and is the one place an app then has an `#if` about purchases:

```swift
import PurchaseCore
import PurchaseStoreKit
#if SCREENSHOTS
import PurchaseSimulator
#endif

@MainActor
func storeForThisLaunch() -> PurchaseStore {
    #if SCREENSHOTS     // in a configuration named Debug-Screenshots: see below
    do {
        if let scenario = try Scenario.fromLaunchArguments(catalogue: Shop.catalogue) {
            let front = SimulatedStoreFront(catalogue: Shop.catalogue)
            front.apply(scenario)
            return PurchaseStore(catalogue: Shop.catalogue, front: front)
        }
    } catch {
        fatalError("-PurchaseScenario could not be read: \(error)")
    }
    #endif
    return PurchaseStore(catalogue: Shop.catalogue, front: AppStoreFront(catalogue: Shop.catalogue))
}
```

## Screenshot and UI-test configurations

Xcode gives a package target `DEBUG` by the build configuration's **name**, not its type. **[ran]**

| Configuration (all but Release are debug-type) | App target sees | Package target sees |
|---|---|---|
| `Debug` | `DEBUG` | `DEBUG` |
| `Release` | — | — |
| `Screenshots` | `DEBUG SCREENSHOTS` | **nothing** |
| `Debug-Screenshots` | `DEBUG SCREENSHOTS` | `DEBUG` |

An app's own `SWIFT_ACTIVE_COMPILATION_CONDITIONS` never reach a package. So a dedicated screenshots configuration that wants the simulated store must have a name beginning with `Debug`, and should guard its own use of it with its own condition (`#if SCREENSHOTS`, [writing the root yourself](#writing-the-root-yourself)) and its own bundle identifier, so that its runs do not share the development build's container and the everyday development build cannot be talked into showing invented purchases at all. Point the UI-test scheme's Test action at that configuration.

How a custom configuration's name is mapped to a package's debug or release build is a heuristic of the build system's that Apple does not document **[check]**; the table is what was measured, and `spike/debugflag` measures it again.

A package trait was considered as an explicit opt-in and rejected: Xcode applies a trait per package reference, so it would reach Release too.
