# The simulated store

A store with no StoreKit in it, and with StoreKit's awkwardness left in. For unit tests, SwiftUI previews, UI tests, screenshots, and a debug build being poked at by hand.

> ⚠️ `SimulatedStoreFront`, `Scenario` and `PurchaseDebugUI` exist **only in DEBUG builds**. See [release safety](07-release-safety.md). **Everything that names them — a test, a preview, a composition root — goes inside `#if DEBUG` too**, or the first Release build (an archive, a test plan in Release, `swift test -c release`) fails with "cannot find 'SimulatedStoreFront' in scope".

The samples use the `Shop` that [getting started](02-getting-started.md#declare-the-catalogue-once) declares: `Shop.pro`, `Shop.trial`, `Shop.catalogue`.

## A fake, not a stub

It remembers what was bought, the way the real store does for the account, and it keeps the real store's bad habits on purpose. A politer fake hides the bugs those habits cause; two of the rows below are here because an earlier, politer version hid exactly that bug.

| Habit of the real store **[ran]** | In the simulated one |
|---|---|
| A purchase is listed about a second after `purchase()` returns | Listed **one read late** (`listsPurchasesAfterReads`, default 1) |
| A grant that arrives on its own is announced before it is listed | `deliver` announces at once and lists one read late |
| A refund does not lag | `revoke` is gone from the very next read |
| A cancelled task is told it owns nothing | The same (`answersNothingWhenCancelled`) |
| Buying what is owned hands back the original transaction, original date and all | The same, which is what makes a trial one trial. An approved Ask to Buy is that same purchase arriving later, so it comes with the original date too |
| The payment sheet stays up for as long as the person takes | `purchaseGate`, and `restoreGate` for the password prompt |
| The account may own things this device has not heard of | `seedEarlierPurchase`; they turn up when bought again, or on restore |

## Arranging it

All of it inside `#if DEBUG`, like everything else that names the simulated store.

```swift
let front = SimulatedStoreFront(catalogue: Shop.catalogue, clock: clock)

front.seed(Shop.pro)                                // owned at launch
front.seed(Shop.pro, age: .seconds(86_400), ownership: .familyShared)
front.seedTrial(Shop.trial, remaining: .seconds(300))   // five minutes left
front.seedTrial(Shop.trial, remaining: .seconds(-86_400)) // ended yesterday
front.seedEarlierPurchase(Shop.trial, age: .seconds(20 * 86_400))  // on another device
```

Things that happen by themselves, announced on the updates stream so a running app reacts:

```swift
front.deliver(Shop.pro)                  // bought on another device
front.deliverTrial(Shop.trial, remaining: .seconds(300))
front.approvePending(Shop.pro)           // a parent approves; false, and nothing granted, if it was not pending
front.revoke(Shop.pro)                   // a refund
front.announceWithoutListing(owned)               // announced, and never listed
```

How it misbehaves, changeable at any time:

```swift
front.behaviour.purchase = .pending               // .succeeds | .cancelled | .fails(.unverified)
front.behaviour.restore = .fails(.network)        // .succeeds | .cancelled
front.behaviour.catalogue = .loadsOnly([])        // a build the store sells nothing to
front.behaviour.listsPurchasesAfterReads = 5      // a slower listing
```

Four gates, open by default. Each holds an answer back until it is opened:

```swift
front.ownershipGate.close()     // the store has not answered yet
front.catalogueGate.close()     // a slow network; ownership must still be answered
front.purchaseGate.close()      // the payment sheet is up
front.restoreGate.close()       // the store is asking for a password
```

`purchaseGate` holds the state a person looks at for longest, and the one in which a second tap, a closed window or a Buy button that was never disabled does its damage: while it is shut `activity` is `.purchasing`, and a second purchase is refused with `alreadyInProgress`. What the purchase comes to is decided when the gate opens, so a test can have the person back out — `front.behaviour.purchase = .cancelled`, then `front.purchaseGate.open()`.

To serve your app's real names and prices, build it from your `.storekit` file:

```swift
let file = try StoreKitConfiguration(contentsOf: url)
let front = SimulatedStoreFront(catalogue: Shop.catalogue, configuration: file)
```

## "Trial ends in five minutes"

| Where | How | Time taken |
|---|---|---|
| A unit test | `seedTrial(_:remaining:)` with a `ManualClock`, then `clock.advance(by:)` | None |
| A running debug build | `deliverTrial(_:remaining:)` from the debug panel, or a scenario, on the real clock | Five minutes, while you watch the app lock itself |
| Real StoreKit | A catalogue whose trial lasts a second or two, everywhere; or a backdated purchase (`.purchaseDate` with `SKTestSession.buyProduct`), which works in the iOS 27 simulator and not on macOS 26.6. **[ran]** | A second or two |

## Scenarios

A scenario is how a simulated store should start, as text, so that a UI test or a screenshot run can launch the app already owning something.

```
-PurchaseScenario "owns=trial@13d23h55m; purchase=pending"
```

Falling back to the environment variable `PURCHASE_SCENARIO` when the argument is absent. The package only **parses** it; your composition root decides whether to honour it ([release safety](07-release-safety.md#decide-by-the-build-not-by-an-argument)).

Clauses are joined by `;`.

| Clause | Meaning |
|---|---|
| `owns=` holding, … | Listed from launch |
| `earlier=` holding, … | Owned by the account, unknown to this device |
| `purchase=` `succeeds` \| `pending` \| `cancelled` \| `held` \| `fails:`error | How the next purchases end. `held` closes the purchase gate: the payment sheet is up |
| `restore=` `succeeds` \| `cancelled` \| `held` \| `fails:`error | How a restore ends. `held` closes the restore gate |
| `catalogue=` `loads` \| `empty` \| `held` \| `fails:`error | `held` closes the catalogue gate |
| `ownership=` `answers` \| `held` | `held` closes the ownership gate |
| `lag=`N | Reads before a purchase is listed |

A **holding** is `product[@age][/purchased|family|assigned]`. The product is a full identifier or the unique last component of one, so `trial` means `Shop.trial`, whatever comes before its last dot. The age is how long *ago* it was bought: `13d23h55m`, `90s`. It becomes a date only against the clock of the store it is applied to, so the same text means the same thing tomorrow.

Errors: `productUnavailable`, `purchaseNotAllowed`, `notAvailableInStorefront`, `network`, `system`, `unverified`, `revoked`, `unsupported`.

| To see | Launch with |
|---|---|
| An owner | `owns=pro` |
| A trial with five minutes left | `owns=trial@13d23h55m` |
| A trial used up | `owns=trial@20d` |
| A trial used on another device | `earlier=trial@20d` |
| Ask to Buy | `purchase=pending` |
| A purchase that does not verify | `purchase=fails:unverified` |
| The store not having answered | `ownership=held` |
| A purchase under way, the sheet still up | `purchase=held`, then press Buy |
| An owner, offline | `owns=pro; catalogue=fails:network` |
| A build the store sells nothing to | `catalogue=empty` |

`held` is for looking at, not for getting past. A key may be given once, so `purchase=held` cannot also say how the purchase ends: let go, it succeeds. And a UI test cannot let it go at all — only code in the app can open a gate, which in practice means the debug panel — so a test that holds a purchase ends with it still held. To test how a purchase *ends*, script it (`purchase=cancelled`, `purchase=fails:network`); to choose the ending of a held one, hold it from a unit test, where `front.behaviour.purchase` can be changed before `front.purchaseGate.open()`.

**Crash on a scenario that does not parse.** A typo that quietly falls back to the real store produces screenshots of the wrong thing.

## The debug panel

On macOS, in a window of its own, beside the app's `WindowGroup`:

```swift
#if DEBUG
import PurchaseDebugUI
#endif

// …in the App's `body`, `purchases` being the AppPurchases made at launch:
#if DEBUG
Window("Purchases", id: "purchase-debug") {
    PurchaseDebugPanel(store: purchases.store, simulated: purchases.simulated,
                       diagnostics: purchases.diagnostics)
}
#endif
```

`Window` scenes do not exist on iOS; present the panel in a sheet there, from a view that was handed `purchases` and has a `@State private var showsDebugPanel = false`:

```swift
#if DEBUG
Button("Purchase debug panel…") { showsDebugPanel = true }
    .sheet(isPresented: $showsDebugPanel) {
        PurchaseDebugPanel(store: purchases.store, simulated: purchases.simulated,
                           diagnostics: purchases.diagnostics)
    }
#endif
```

`purchases` is the `AppPurchases` of the [composition root](07-release-safety.md#decide-by-the-build-not-by-an-argument); `Demo/App` does both, one on each platform.

The top of the panel shows facts from **whatever store the app is running on**, the real one included, ticking every second so a trial can be watched running out. The controls appear only when a simulated store is handed in: start a trial with any number of seconds left, deliver a purchase from "another device" or through Family Sharing, refund, approve Ask to Buy, script the next purchase, hold any of the gates — a purchase with its payment sheet still up included — and empty or fail the catalogue. "What this build receives" asks the store directly, which is most useful against the real one on the afternoon Buy does nothing.

## Previews

Apple's previews load products and prices from the `.storekit` file, and cannot arrange what the account *owns*. A simulated store can, so each state of a paywall gets a preview of its own:

```swift
#if DEBUG
import PurchaseTestKit

#Preview("Trial nearly over") {
    let front = SimulatedStoreFront(catalogue: Shop.catalogue)
    front.seedTrial(Shop.trial, remaining: .seconds(90))
    return PaywallView().purchaseStore(PurchaseStore(catalogue: Shop.catalogue, front: front))
}
#endif
```

- **The `#if DEBUG` is not optional.** A preview usually lives in the file of the view it previews, which is in the app; without the guard the app's first Release build — the archive — fails with "cannot find 'SimulatedStoreFront' in scope".
- **Keep the `return`.** It is what lets the seeding statement sit beside the view. Without it the statement is inside a view builder, and the compiler does not report that: it crashes (Swift 6.4). **[ran]**

## UI tests and screenshots

A UI test cannot reach into the app, and should not tap its way to "a trial with five minutes left". It launches the app already there:

```swift
import XCTest

final class PaywallUITests: XCTestCase {
    @MainActor
    func testATrialNearlyOverSaysWhenItEnds() {
        let app = XCUIApplication()
        app.launchArguments += ["-PurchaseScenario", "owns=trial@13d23h55m"]
        app.launch()

        // First, always: is this the simulated store at all? (below)
        XCTAssertTrue(
            app.staticTexts["simulated-store"].waitForExistence(timeout: 10),
            "Not on the simulated store. Is the Test action built in a configuration whose name begins with Debug?")

        // Waited for, not read at once: until the store has answered there is a spinner
        // where the status will be, and a spinner is not a static text.
        let status = app.staticTexts["pro-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Trial until"))
    }
}
```

The two identifiers are the app's to provide. The marker is three lines, where `purchases` is the `AppPurchases` of the composition root:

```swift
#if DEBUG
if purchases.simulated != nil {
    Text("Simulated store").accessibilityIdentifier("simulated-store")
}
#endif
```

`Scenario.launchArgument` and `Scenario.environmentVariable` are the two spellings, for code on the app's side; `launchEnvironment["PURCHASE_SCENARIO"]` works where an argument is awkward. The app honours the scenario at its [composition root](07-release-safety.md#decide-by-the-build-not-by-an-argument), and three things about the build decide whether it can:

| | |
|---|---|
| **The Test action's build configuration must give the package `DEBUG`**, which Xcode decides by the configuration's *name*: `Debug`, or one beginning with `Debug` ([release safety](07-release-safety.md#screenshot-and-ui-test-configurations)). | In a Release-configured test plan the simulated store does not exist. The app ignores the argument and runs on **the real store**, and nothing fails: the screenshots are of the wrong thing. A scenario that does not *parse* crashes; a scenario the build cannot *honour* is silent. |
| **So assert a marker first.** Show something only when the app is on a simulated store — the Demo shows a "Simulated store" badge with the identifier `simulated-store` — and make it the first assertion of every UI test. | It turns the silent case into a failure that says what is wrong. |
| **For a screenshot pipeline, give the run a configuration of its own**: `Debug-Screenshots`, with its own compilation condition (`DEBUG SCREENSHOTS`) and **its own bundle identifier**, and honour scenarios under `#if SCREENSHOTS` rather than `#if DEBUG`. | The bundle identifier gives the run its own container, so screenshot window frames and preferences do not leak into the development build; the condition keeps the development build from being talked into showing invented purchases at all. The name has to begin with `Debug`, or the package is built without the simulated store. |

`Demo/UITests` is this, run by `make ui-tests` on an iOS simulator. On the Mac a UI test runner also needs Automation Mode permitted (`automationmodetool`), and, signed ad hoc, the hardened runtime switched off for the UI-test target alone.
