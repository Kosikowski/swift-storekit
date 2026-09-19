# Testing

How to test purchasing: what Apple provides, what it cannot do, and where the simulated store fits.

The samples use the `Shop` that [getting started](02-getting-started.md#declare-the-catalogue-once) declares. It lives in your app, so a test reaches it with `@testable import YourApp` — the samples say `YourApp` where yours has a name.

## Apple's three environments

Apple describes three, to be used in this order. **[Apple]** None of them charges anyone.

| Environment | For | Signed by | Only here | Not here |
|---|---|---|---|---|
| **StoreKit Testing in Xcode** (a `.storekit` file, the transaction manager, `SKTestSession`) | Early development, continuous integration, debugging. Offline. | Xcode | Approving or declining Ask to Buy; forcing StoreKit errors (`setSimulatedError`) | Real App Store signatures; price tiers and most storefronts; **Family Sharing** |
| **Sandbox** | End to end with real App Store Connect products, servers included | App Store | Family Sharing, with Sandbox Test Families; declined and prorated refunds | Approving or declining Ask to Buy; forcing errors |
| **TestFlight** | Testers, on a production-configured build | App Store (it is the sandbox) | | As sandbox |

**A TestFlight build is a Release build.** It has no simulated store, no scenarios and no debug panel — those exist only in DEBUG — so everything in [the simulated store](06-simulated-store.md) stops at the archive, and what testers exercise is the sandbox and nothing else.

Apple nowhere suggests mocking StoreKit, abstracting it, or injecting it: its answer to "how do I test this" is always `StoreKitTest` against the local environment. **[Apple]** Its test store is safe by construction — the `.storekit` file's data "don't appear in App Store-signed apps". This package uses Apple's tools for what they are good at and adds a simulated store for what they cannot reach.

## What Apple's tools cannot reach

Measured on macOS 26.6 and in the iOS 27.0 simulator, with Xcode 27.0. **[ran]** See [`spike/README.md`](../spike/README.md).

| Wanted | With Apple's tools |
|---|---|
| Run purchase tests with `swift test` | **Not possible.** `SKTestSession` fails in a package test target; it needs a host app. Apple documents nothing either way. |
| A trial with five minutes left | **Depends on the OS.** Apple documents it — `Product.PurchaseOption.purchaseDate(_:)` with `SKTestSession.buyProduct(identifier:options:)` — and it works in the iOS 27 simulator. On macOS 26.6 `buyProduct` throws `StoreKitError.unknown` (listed as fixed in Xcode 27's release notes, FB24168768; the fix is in the OS) and `product.purchase(options:)` ignores the date. The hosted suite has the test, as a known issue where it cannot pass. |
| A purchase shared by a family member | Not in Xcode's environment at all: sandbox only, with a Sandbox Test Family. |
| Hold the moment before the store has answered | Not possible; it is over in milliseconds. |
| Hold the catalogue on a slow network, or a purchase with its sheet still up | Not possible. |
| SwiftUI previews of each *state* | Previews load products and prices from the `.storekit` file. **[Apple]** They cannot arrange what the account owns. |
| Test an app's own paywall and gates quickly | Only in a hosted UI test. |

## What to test where

| Layer | Against | Run with |
|---|---|---|
| Your app's views, gates and wording | `SimulatedStoreFront` + `ManualClock` | `swift test`, or your app's unit tests |
| Your app, launched in a given state | a [scenario](06-simulated-store.md#ui-tests-and-screenshots) | XCUITest |
| This package's logic | `SimulatedStoreFront` + `ManualClock` | `make test` |
| The StoreKit adapter's decisions | a fake gateway | `make test` |
| The StoreKit adapter against StoreKit's own transactions and errors | real StoreKit, `Demo.storekit` | `make integration`, `make integration-ios` (hosted by the Demo app) |
| Your `.storekit` file against your catalogue | `StoreKitConfiguration` — no StoreKit | `swift test` |
| Family Sharing, real products, real signatures, servers | Sandbox, then TestFlight | by hand |
| **Where the payment sheet appears** — `PurchaseAction`, a window, a view controller | nothing automated: the hosted tests buy with `.automatic`, and no test here reaches `PurchaseButton`'s own path | by hand, with two windows open |

## Guard every test that names the simulated store

`SimulatedStoreFront`, `AnswerGate` and `Scenario` — the whole of `PurchaseTestKit` — exist only in DEBUG builds ([release safety](07-release-safety.md)), so **a test that names them must too**:

```swift
#if DEBUG
import PurchaseCore
import PurchaseTestKit          // the simulated store: DEBUG only
import PurchaseTestSupport      // the clock and the waits: every configuration
import Testing

// …every test below…
#endif
```

Without the guard the file does not compile in a release test run — `swift test -c release`, or a test plan whose configuration is Release — and the failure is a wall of "cannot find 'SimulatedStoreFront' in scope". What is in `PurchaseTestSupport` — `ManualClock`, `waitUntil`, `RecordingPurchaseLogger`, `StoreKitConfiguration` — needs no guard: it grants nothing, and exists in every configuration. Link it into test targets and not into the app.

**A release test job then proves that these files compile, and nothing more**: the guarded tests are not there to run. A suite that is guarded from top to bottom reports "Test run with 0 tests" and passes. **[ran]** Keep what needs no simulated store — the `.storekit` check, anything on `ManualClock` alone — outside the guard, and if the job's count matters, put a floor under it, as this package's CI does for both configurations.

A release run also needs testability switched back on wherever a test uses `@testable import`: `-Xswiftc -enable-testing` for SwiftPM, `ENABLE_TESTABILITY = YES` on the Release configuration for an Xcode test plan.

This package's own suite is guarded the same way, and `make check` runs it in release (`make release-tests`) to keep that true. So that the release run is not only the easy half, a few tests of `PurchaseStore` itself — a cancelled caller, single-flight, a trial running out — run against a small store front that lives in `Tests/`, where nothing ships and so nothing needs a guard. If your release job matters to you, do the same: a stub of your own costs fifty lines.

## The simulated store in a unit test

```swift
#if DEBUG
import PurchaseCore
import PurchaseTestKit
import PurchaseTestSupport
import Testing
@testable import YourApp

@MainActor
@Test("with five minutes left, the unlock is taken back five minutes later, by itself")
func trialRunsOut() async {
    let clock = ManualClock()
    let front = SimulatedStoreFront(catalogue: Shop.catalogue, clock: clock)
    front.seedTrial(Shop.trial, remaining: .seconds(300))
    let store = PurchaseStore(catalogue: Shop.catalogue, front: front, clock: clock)

    await store.start()
    #expect(store.standing.access(to: Shop.pro) != .none)

    await waitUntil { clock.sleeperCount == 1 }   // the store has scheduled its look
    clock.advance(by: .seconds(300))              // five minutes, at once
    await waitUntil { store.standing.access(to: Shop.pro) == .none }
    #expect(store.standing.access(to: Shop.pro) == .none)
}
#endif
```

Three rules keep such tests from flaking:

- **Give the store and the simulated front the same clock**, so purchase dates and expiry agree.
- **Wait on a condition, never on a duration.** `waitUntil` returns the moment its condition holds — or after its `timeout`, five seconds unless you say otherwise — and the `#expect` after it is what fails, so a failure says what was expected rather than "timed out".
- **Before moving time, wait for the sleeper** (`clock.sleeperCount`), so the store has got as far as scheduling its look.

`ManualClock` does not race: deadlines are absolute, so advancing before a sleeper arrives and after it come to the same thing, and whether to park is decided under the lock that `advance` takes.

## Testing your own gate

What an app tests is its own policy, and the shape that makes it testable is one line: **the model takes `any PurchaseStateProviding`, not a `PurchaseStore`**, and asks `knownStanding()` rather than reading `standing`.

```swift
import Foundation
import Observation
import PurchaseCore

@MainActor
@Observable
final class ExportModel {
    private let purchases: any PurchaseStateProviding
    private(set) var isShowingPaywall = false

    init(purchases: any PurchaseStateProviding) { self.purchases = purchases }

    func export() async {
        // Waits for the store's first answer. Nobody is judged before it.
        let standing = await purchases.knownStanding()
        if case .none = standing.access(to: Shop.pro, at: .now) { isShowingPaywall = true }
    }
}
```

## The moment before the store has answered

The most useful test in a purchasing suite. Nothing may be locked, nothing offered, and nobody who has paid shown a paywall.

```swift
#if DEBUG
import PurchaseCore
import PurchaseTestKit
import PurchaseTestSupport
import Testing
@testable import YourApp

@MainActor
@Test("an owner who exports before the store has answered is never shown the paywall")
func ownerIsNotJudgedEarly() async {
    let front = SimulatedStoreFront(catalogue: Shop.catalogue)
    front.seed(Shop.pro)
    front.ownershipGate.close()                       // the store has not answered
    let model = ExportModel(purchases: PurchaseStore(catalogue: Shop.catalogue, front: front))

    let exported = Task { await model.export() }
    await waitUntil { front.ownershipGate.waiterCount == 1 }
    #expect(!model.isShowingPaywall)                  // …and nobody is judged yet
    front.ownershipGate.open()
    await exported.value
    #expect(!model.isShowingPaywall)                  // an owner, once it has
}
#endif
```

`catalogueGate` does the same for a slow network: ownership must still be answered while it is shut. `purchaseGate` holds a purchase with its payment sheet still up, which is when a second tap does its damage ([the simulated store](06-simulated-store.md#arranging-it)).

## Your `.storekit` file is a contract

A renamed identifier fails silently: the product never loads, and the Buy button does nothing. This needs no StoreKit, so it runs anywhere:

```swift
let file = try StoreKitConfiguration(contentsOf: url)
#expect(file.problems(against: Shop.catalogue) == [])
```

It checks that the file sells exactly the catalogue's identifiers, that each is a non-consumable, that a trial is free and not family-shareable, and that an unlock's Family Sharing matches the catalogue's stance. **Check the catalogue the app uses, not a copy of it**: `Demo/Tests` imports the app (`@testable import Demo`) and checks `Shop.catalogue`, so a product renamed in one place fails a test.

## Real StoreKit, from a hosted test bundle

`Demo/Tests/RealStoreKitTests.swift` runs the real `AppStoreFront` through `PurchaseStore` against `Demo.storekit`, on the Mac and in an iOS simulator. What it takes — little of which Apple writes down:

```swift
import StoreKitTest
import Testing

private func session() throws -> SKTestSession {
    // The test bundle's own copy of the file: a sandboxed host cannot read the repository.
    let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
    let file = try #require(bundle.url(forResource: "YourApp", withExtension: "storekit"))
    let session = try SKTestSession(contentsOf: file)
    session.resetToDefaultState()      // first, always: the environment outlives the process
    session.disableDialogs = true
    session.clearTransactions()
    return session
}
```

- **A unit-test bundle hosted by an app** (`TEST_HOST`), not a package test target and not a UI-test bundle. `import StoreKitTest`. Ad-hoc signing with no team is enough. For a target that builds for the Mac *and* iOS, spell the host out — the executable is in `Contents/MacOS` on one and beside `Info.plist` on the other, and XcodeGen's default knows only the second:

  ```
  TEST_HOST     = $(BUILT_PRODUCTS_DIR)/YourApp.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/YourApp
  BUNDLE_LOADER = $(TEST_HOST)
  ```
- **The session in code is what loads the file**: `SKTestSession(contentsOf:)`. The scheme's StoreKit Configuration belongs to the **Run** action **[Apple]**; the Test action and the test plan need none.
- On the Mac the host is sandboxed and cannot read the repository, so the `.storekit` file is a **resource of the test bundle**, found through `Bundle.allBundles` by the `xctest` extension. XcodeGen's default build phase for a `.storekit` file is "none", which is right for an app and wrong here: give it `buildPhase: resources` in the test target (`Demo/project.yml`).
- **`resetToDefaultState()` at the start of every test**, then `disableDialogs = true` and `clearTransactions()`. There is one test environment, every session shares it, and **it outlives the process**: an error armed by one run was still armed in the next. **[ran]**
- One environment: mark the suite `.serialized` — **and keep real-StoreKit tests in one suite**. `.serialized` orders the tests of the suite it is on; a second suite, or Xcode's parallel testing across bundles, still shares the one environment. Keep the session alive to the end of the test with `withExtendedLifetime(session) {}`.
- **In a simulator, use an iOS 27 runtime.** Under Xcode 27 the session does not attach in an iOS 26.5 simulator at all: no products load, and every purchase throws. **[ran]**
- **The host app must not run its own store while hosting**, or its listener finishes the transactions the tests are waiting to see. The Demo builds no store when `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]` is set — a convention of the test runner and not an API, but the one there is. The same goes for your app's ordinary hosted unit tests, which otherwise start `AppStoreFront` on every run.

**Use `setSimulatedError` for the failures.** It is how Apple's environment produces StoreKit's *own* errors, and the only way the adapter's error mapping meets an error a test did not build by hand. **[ran]**

| Armed | macOS 26.6 | iOS 27.0 simulator |
|---|---|---|
| `.loadProducts`, a network error | thrown as armed → `network` | thrown as a *system* error → `system` |
| `.purchase`, `purchaseNotAllowed` | thrown as armed → `purchaseNotAllowed` | thrown as `StoreKitError.unknown` |
| `.verification` | `purchase()` returns an **unverified** transaction, and the listing has it unverified → `unverified`, nothing unlocked | the same |
| `.appStoreSync`, a network error | a restore throws as armed → `network`, and takes nothing away | thrown, as something |
| Disarming with `nil`, as documented | **for `.purchase` it arms `StoreKitError.unknown` instead**, until `resetToDefaultState()` | works |

**And what else the environment can do, cheaply**, all of it through the real adapter in `Demo/Tests`:

| | macOS 26.6 | iOS 27.0 simulator |
|---|---|---|
| A restore under `disableDialogs` | `completed` | `completed` |
| An **interrupted purchase** (`interruptedPurchasesEnabled`, then `resolveIssueForTransaction`) | pending, then unlocks through the updates | `purchase()` throws `StoreKitError.unknown` — a known issue there |
| Ask to Buy **declined** | nothing arrives; the purchase stays pending for the session | the decline is delivered *as a purchase* — a known issue there |
| A purchase made here, and the updates | not announced: it comes back from `purchase()` | the same |
| A **cancelled** request for products | **an empty list, not an error**: 0 of 2 | the same |
| A purchase left unfinished before anything listened | not pinned: it appears in `Transaction.unfinished` after half a second and is gone again, unfinished by anybody, a second later **[check]** | not measured |

So the mapping is proved on the Mac, and on iOS the same tests prove that a failure is a failure and changes nothing. Where a fault belongs to one OS the test records it as a *known issue* there (`withKnownIssue(…, when:)`), which is a canary both ways: it fails if the fault turns up where it should not, and if it has gone from where it was.

**Give `xcodebuild` a timeout.** It has been seen to finish a simulator run — every test green — and then never exit. **[ran]** The Makefile's test lanes run under an alarm (`TEST_TIMEOUT`, twenty minutes).

`make integration` and `make integration-ios` do not gate pull requests: StoreKit's test environment is reported to be unreliable under command-line `xcodebuild` on hosted runners **[check]**, and a lane that fails for reasons of its own teaches people to ignore it. But every claim here about what StoreKit does lives in that suite, so "by hand, before a release" was not often enough either. It runs **nightly and on request** (`.github/workflows/integration.yml`), never blocking, with one retry, the result bundle kept, and a red night opening an issue; what that lane measures is what should replace the **[check]** above. From the command line on a Mac it takes about half a minute, and was green every time it was run here. **[ran]**

What CI does on every push is *build* it all (`make demo`, part of `make check`): the Demo and its hosted tests for the Mac and for iOS, the UI tests, and the app once more in Release — linked, and searched for the simulated store. Nothing else compiles any of it, and an API change would otherwise break it unnoticed. CI runs with the hosted image's Xcode (26.6 when this was written), which is what proves the package builds with the older SDK, and also means a green run there says nothing about StoreKit's behaviour: everything marked **[ran]** was run with Xcode 27.

## What the simulated store does not prove

A green suite against `SimulatedStoreFront` says your app does the right thing *given* a store that behaves as the simulated one does. It says nothing about:

- **Signatures and verification.** The simulated store has no signatures. It can list a purchase as unverified (`seedUnverified`), which tests your support path and not StoreKit's checking.
- **How long the lag is.** It imitates the *order* of events — announced, then listed — in reads, not in time, and that order is itself per OS: a purchase is listed about a second late on macOS 26.6 and at once in the iOS 27 simulator ([the simulated store](06-simulated-store.md#a-fake-not-a-stub)).
- **What is redelivered at launch.** Unfinished transactions, and purchases made while the app was not running, are StoreKit's to hand over. The adapter asks for the backlog; nothing here shows StoreKit giving it.
- **The payment sheet**: that it appears, over which window, and what the person sees.
- **Family Sharing's dates and revocations**, as the App Store really sends them. The simulated store takes your word for the ownership you seed.
- **Storefronts, currencies and price tiers.** It serves what your `.storekit` file says, or made-up prices.
- **Your server**, App Store Server Notifications, and anything else downstream of a real transaction.

Those are what the hosted suite, the sandbox and TestFlight are for, in that order.

## Every regression test is proven to bite

For each behaviour that came from a real defect, put the old behaviour back once and watch the test fail. Three times in building this package that found a check that did not ([decisions, D14](10-decisions.md#d14-every-regression-test-is-proven-to-bite)).
