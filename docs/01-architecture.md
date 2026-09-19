# Architecture

How the package is divided, which way the dependencies point, and what each protocol is for.

## The one rule

**The package reports store facts and performs store actions. The app owns product policy.**

| In the package | Left to the app |
|---|---|
| What the account owns, since when, and how it came by it | Which features a purchase unlocks |
| Whether the store has answered yet | What to do while it has not |
| A trial's start, end and status | How the end is worded; what locks when it comes |
| Products and prices as the store states them | Paywall wording and layout |
| Purchases pending approval; whether something is under way | Alerts, and where they appear |
| Typed outcomes and typed errors | The sentence shown for each |

There is deliberately no `isPro`. An app derives its own from `Standing.access(to:at:)`, and in doing so has to decide what `unknown` means for the thing being asked, which is the decision that matters.

## Targets

```
PurchaseCore       Foundation, Observation. No StoreKit, SwiftUI, AppKit or UIKit.
  ▲ ▲ ▲ ▲
  │ │ │ └──── PurchaseDirectDistribution               (one store, for builds sold elsewhere)
  │ │ └────── PurchaseSimulator                        (DEBUG only, whole; imported by no app)
  │ │              ▲           ▲            ▲
  │ │       PurchaseLaunch  PurchaseDebugUI  PurchaseTestKit
  │ │       (app: its store) (app: a panel)  (tests only)
  │ └──────── PurchaseUI                               (SwiftUI)
  └────────── PurchaseStoreKit ◄── PurchaseLaunch      (StoreKit)
```

Dependencies point inwards only. `PurchaseStoreKit` and `PurchaseUI` do not know about each other; they meet in Core, and in Apple's own types.

| Target | What it is | Imports |
|---|---|---|
| `PurchaseCore` | All the logic: values, rules, ports, and the one stateful class | Foundation, Observation |
| `PurchaseStoreKit` | The App Store behind Core's ports | StoreKit; AppKit or UIKit for purchase anchors |
| `PurchaseUI` | Environment entries, a start-at-launch modifier, two buttons. No paywall | SwiftUI; StoreKit in one file, for `@Environment(\.purchase)` |
| `PurchaseLaunch` | The composition root, for an app that does not want to write one: `StoreLaunch.make(catalogue:)`. In a DEBUG build `-PurchaseScenario` chooses a simulated store; otherwise, and always in release, the App Store. Never empty, and the only thing an app imports for this | Foundation |
| `PurchaseDebugUI` | A panel that drives the simulated store in a running debug build. Its *name* is in every build, and draws nothing in release, so an app needs no `#if` to mention it | SwiftUI |
| `PurchaseSimulator` | The simulated store, its gates and scenarios. **The whole module is behind `#if DEBUG`**, so an app that links it — every app using the two above — ships with nothing of it. No app imports it | Foundation, Synchronization |
| `PurchaseTestKit` | What a test imports, and an app never: the simulator re-exported, and a manual clock, `waitUntil`, a recording logger and the `.storekit` validator, guarded by nothing because they grant nothing. To this package what StoreKitTest is to StoreKit | Foundation, Synchronization |
| `PurchaseDirectDistribution` | `EverythingOwnedStoreFront`, for a build sold some other way. Apart so that an App Store build does not contain a store in which everything is owned | Foundation |
| `ReleaseCheck` *(plugin, not a product)* | `swift package release-check`: proves the simulated store is in a debug build and absent from a release one ([release safety](07-release-safety.md)) | PackagePlugin |

Core imports no Apple framework beyond Foundation and Observation. That is not tidiness: `SKTestSession` does not work in a package test target at all ([decisions](10-decisions.md#d1-real-storekit-is-tested-from-a-host-app)), so anything that imports StoreKit cannot be tested by `swift test`. Everything that decides something therefore lives where StoreKit is not.

## Layers inside Core

Core is one target, so that an app writes one `import`. Its layers are named in each file's banner instead, and `ci/layers.sh` (part of `make check`) fails the build if a file reaches outwards:

| Layer | May not mention | Contents |
|---|---|---|
| **Domain** | `@MainActor`, Observation, the store, the role protocols | `ProductID`, `Catalogue`, `CatalogueEntry`, `TrialTerms`, `TrialPeriod`, `TrialStatus`, `Ownership`, `OwnedProduct`, `StoreProduct`, `ProductAccess`, `Standing`, `StandingResolver`, `TransactionUpdate`, `PurchaseOutcome`, `PurchaseCompletion`, `RestoreOutcome`, `PurchaseError`, `PurchaseConfirmation`, `PurchaseEvent`, `StoreDiagnosis`, and the `package`-level `Duration.timeInterval` |
| **Port** | `@MainActor`, Observation, the store | `ProductCatalogueLoading`, `OwnershipReading`, `ProductPurchasing`, `PurchaseRestoring`, `TransactionObserving`, `StoreFront`, `StoreDiagnosing`, `TimeProviding`, `PurchaseLogging` |
| **Application** | — | `PurchaseStore`, `PurchaseStateProviding`, `PurchaseCommanding`, `UnlistedPurchases`, `PurchaseActivity`, `ProductLoadState`, `SystemClock`, `SilentPurchaseLogger` |

Every domain value is `Sendable` and `Hashable`. Nothing in the domain reads a clock: every question that depends on time takes the date as a parameter, which is what makes a trial's expiry testable without waiting for it.

## The ports

A store is five small roles, because their consumers differ. `PurchaseStore`'s designated initialiser takes them one by one; `StoreFront` is the typealias for the usual case of one object playing all five.

| Port | Contract a conformer keeps |
|---|---|
| `ProductCatalogueLoading` | Goes over the network. Nothing about what a person may *use* waits on it. |
| `OwnershipReading` | The whole listing every time; only what the store vouches for; never throws; no side effects. |
| `ProductPurchasing` | Finishes the transaction it returns, and only if it is verified and for a catalogue product. |
| `PurchaseRestoring` | For a Restore button only: on the App Store it asks for a password. |
| `TransactionObserving` | Yields the transaction's facts, not a bare signal; registered by the time it returns. |
| `TimeProviding` | `now`, and `sleep(until:)` with an absolute deadline. |
| `PurchaseLogging` | Receives events that are safe to write down as they are. |
| `StoreDiagnosing` | Reports what this build actually receives from the store. |

Three conformers ship: `AppStoreFront` (the App Store, in `PurchaseStoreKit`), `SimulatedStoreFront` (`PurchaseSimulator`, DEBUG only), and `EverythingOwnedStoreFront` (`PurchaseDirectDistribution`, for builds sold some other way, which ships in release by design).

## The store

`PurchaseStore` is `@MainActor @Observable`, because everything that reads it is a view, and a holder that views read synchronously cannot also be a step behind them. Code that is not a view can watch it with `Observations { store.standing }`.

Views see it as `PurchaseStateProviding`, which has no commands. Buttons see it as `PurchaseCommanding`. **Every command returns what came of it to its caller**, as a value or a typed error, and records it nowhere shared: a result kept in one flag watched by several views is announced by all of them at once.

What it holds is only what has to be stateful, which is the order things happen in:

- **Resolving is single-flight, with a re-run, in a task nobody cancels.** The real store answers a cancelled task with nothing at all, which reads as owning nothing, and SwiftUI cancels `.task` whenever a view goes away. So ownership is read in a task of its own, and a cancelled caller waits for it like anyone else. A caller arriving mid-read gets a read that started after it asked, so a `purchase()` that has returned has a standing that includes it. **Prices load the same way**, for the two reasons of their own in [D20](10-decisions.md#d20-prices-load-single-flight-too-in-a-task-nobody-cancels), except that a caller arriving mid-load joins it: prices asked for a moment ago are the prices.
- **Ownership before prices.** `start()` reads what is owned and does not load the catalogue. A catalogue failure keeps the last good prices and never touches the standing.
- **Grants are held until listed.** The store lists a purchase a moment after it says the purchase was made, whether the purchase was made here or arrived as an update. The grant is believed until the listing has it *and counts it*, until the store withdraws it, or until a grace period ends, whichever is first. The time limit keeps the listing the last word.
- **A look is scheduled for whatever changes by itself**: the end of a running trial, and the lapse of a held grant. A wake that lands early finds nothing changed and waits again.
- **Nothing ever downgrades on a failure.** A purchase that throws leaves the standing alone; a restore that throws reads again and rethrows.

## The StoreKit adapter

`LiveStoreKitGateway` is the only file that makes a static StoreKit call. It fetches, forwards and copies fields into `TransactionSnapshot` values; it finishes nothing, filters nothing and maps no errors. Every decision is one layer up, in `AppStoreFront`, `TransactionTriage` and `StoreKitErrorMapping`, where a fake gateway reaches it under `swift test`. See [the adapter](08-storekit-adapter.md).

## SOLID, and where it is knowingly bent

| Principle | Where it is kept | Where it is bent, on purpose |
|---|---|---|
| Single responsibility | Rules are pure types (`StandingResolver`, `Standing`, `UnlistedPurchases`, `TransactionTriage`); the store only sequences | The store holds both the catalogue load and the standing, in exchange for one object in the environment |
| Open/closed | A new store is a new conformer to the ports | Resolver rules are configured by value (`FamilySharing`, `TrialTerms`), not by a strategy protocol: each has one implementation |
| Liskov | All three fronts keep the same contracts, stated on the ports | — |
| Interface segregation | Five store roles; views and buttons see different protocols | — |
| Dependency inversion | Core owns every abstraction; composition happens at the app's root | The purchase anchor crosses Core type-erased (`any Sendable`), because Core may not know what a window is |
