# Release safety

The simulated store hands out purchases for nothing. This is how it is kept out of what ships.

## The threat

- **On macOS, anyone can pass launch arguments to a shipped app**: `open -a YourApp --args -PurchaseScenario owns=pro`. An app that obeyed that in a release build would be free to whoever read this page.
- A misplaced `#if` in an app, or a build configuration that does not define what its author believes it does.
- This is a public package. People will paste its composition-root example, and some will drop the guard.
- App Review guideline 2.3.1(a): "Don't include any hidden, dormant, or undocumented features in your app." **[Apple]** A purchase simulator that ships, switched off, is one.

## What the package does

**Absent, not disabled.** Every file that can grant a purchase — `SimulatedStoreFront`, its extensions, `Scenario`, and the whole of `PurchaseDebugUI` — is wrapped in `#if DEBUG` from its first line to its last. In a release build those types do not exist. App code that mentions them outside its own `#if DEBUG` does not compile, so the compiler finds the mistake. `#if DEBUG` is also Apple's own pattern for code that belongs to the test environment. **[Apple]**

**That cuts both ways, and the other way is yours to handle**: everything of yours that names those types — a composition root, a preview, a test — goes inside `#if DEBUG` too, or your first Release build fails. For tests that means a release test run ([testing](05-testing.md#guard-every-test-that-names-the-simulated-store)); for a preview it means the archive.

**It only parses.** `Scenario.fromLaunchArguments` reads nothing until it is called and builds no store. Whether a scenario is honoured is decided by the app, at its composition root.

**It is proven, in CI.** `swift package release-check` (`make release-check`, part of `make check`) builds the package twice and searches the compiled symbols of each build: every name the simulated store goes by must be *found* in the debug build and *absent* from the release one. **[ran]**

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

What is not under `#if DEBUG`: `ManualClock`, `AnswerGate`, `waitUntil`, `RecordingPurchaseLogger`, `StoreKitConfiguration` with its `StoreKitConfigurationProblem`, and `PurchaseTestKitError`. They grant nothing, and an app's tests need them in whatever configuration they are built.

**Why not a target of its own instead**, linked only where it is wanted? For unit tests that is already how it works — the test target links `PurchaseTestKit` and the app does not — and nothing of it ships whatever the guard says. But a debug panel, a scenario and a preview need the simulated store *in the app*, and Xcode cannot link a package product for one build configuration and not another. A separate product would make "is it in the release build?" a matter of which targets someone remembered to link; `#if DEBUG` makes it a matter the compiler decides ([D22](10-decisions.md#d22-the-simulated-store-is-gated-by-debug-not-moved-to-a-target-of-its-own)).

`EverythingOwnedStoreFront` is the opposite case and ships in release **by design**: it is for a build sold some other way (Developer ID, Setapp). It cannot be switched on by an argument or a preference; it is what the app was built with.

## Decide by the build, not by an argument

The whole type, as `Demo/App/AppPurchases.swift` has it. `@MainActor` because `PurchaseStore` is; `diagnostics` and `simulated` are what the [debug panel](06-simulated-store.md#the-debug-panel) is handed.

```swift
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
```

The build decides *whether* a simulated store is possible. The argument decides only *what it starts with*, which is what varies from run to run.

**Crash on a scenario that does not parse.** Falling back to the real store turns a typo into a run of screenshots that look plausible and are of the wrong thing.

**A scenario the build cannot honour is silent, and only a test can catch it.** In a Release-configured test run the `#if DEBUG` branch is not there: the app ignores `-PurchaseScenario`, runs on the real store, and nothing fails. Show a marker only when the app is on a simulated store, and have every UI test assert it first ([UI tests and screenshots](06-simulated-store.md#ui-tests-and-screenshots)).

## Screenshot and UI-test configurations

Xcode gives a package target `DEBUG` by the build configuration's **name**, not its type. **[ran]**

| Configuration (all but Release are debug-type) | App target sees | Package target sees |
|---|---|---|
| `Debug` | `DEBUG` | `DEBUG` |
| `Release` | — | — |
| `Screenshots` | `DEBUG SCREENSHOTS` | **nothing** |
| `Debug-Screenshots` | `DEBUG SCREENSHOTS` | `DEBUG` |

An app's own `SWIFT_ACTIVE_COMPILATION_CONDITIONS` never reach a package. So a dedicated screenshots configuration that wants the simulated store must have a name beginning with `Debug`, and should guard its own use of it with its own condition (`#if SCREENSHOTS` round the scenario branch above, in place of `#if DEBUG`) and its own bundle identifier, so that its runs do not share the development build's container and the everyday development build cannot be talked into showing invented purchases at all. Point the UI-test scheme's Test action at that configuration.

How a custom configuration's name is mapped to a package's debug or release build is a heuristic of the build system's that Apple does not document **[check]**; the table is what was measured, and `spike/debugflag` measures it again.

A package trait was considered as an explicit opt-in and rejected: Xcode applies a trait per package reference, so it would reach Release too.
