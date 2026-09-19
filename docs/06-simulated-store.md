# The simulated store

A store with no StoreKit in it, and with StoreKit's awkwardness left in. For unit tests, SwiftUI previews, UI tests, screenshots, and a debug build being poked at by hand.

> ⚠️ The simulated store exists **only in DEBUG builds** ([release safety](07-release-safety.md)), and **an app never names it**. A test reaches it with `import PurchaseTestKit`. An app reaches it without naming it: `StoreLaunch.make` for a launch, `StoreLaunch.preview` for a preview, `PurchaseDebugPanel` for the panel — all three of which exist in every build, and in a release one do the dull thing.

The samples use the `Shop` that [getting started](02-getting-started.md#declare-the-catalogue-once) declares: `Shop.pro`, `Shop.trial`, `Shop.catalogue`.

## A fake, not a stub

It remembers what was bought, the way the real store does for the account, and it keeps the real store's bad habits on purpose. A politer fake hides the bugs those habits cause; two of the rows below are here because an earlier, politer version hid exactly that bug.

| Habit of the real store | macOS 26.6 | iOS 27.0 simulator | Held to it by | In the simulated one |
|---|---|---|---|---|
| A purchase is listed *after* `purchase()` returns | about a second after **[ran]** | **at once** **[ran]** | `habitListingLag` | Listed **one read late** (`listsPurchasesAfterReads`, default 1). Set it to 0 for a store as prompt as iOS 27's; leave it, to find the bug the Mac will find for you |
| A grant that arrives on its own is announced before it is listed | usually: a race, lost every time on one Mac and won on a slower hosted runner **[ran]** | listed by the time it arrives **[ran]** | `habitGrantBeforeListing` | `deliver` announces at once and lists one read late |
| A refund does not lag | gone from the listing when announced **[ran]** | the same **[ran]** | `habitRefundDoesNotLag` | `revoke` is gone from the very next read |
| A cancelled task is told it owns nothing | 0 of 1 **[ran]** | the same **[ran]** | the `CANARY` of that name | The same (`answersNothingWhenCancelled`) |
| A cancelled request for *products* is answered with an empty list, not an error | 0 of 2 **[ran]** | the same **[ran]** | `cancelledCatalogueRead` | The same |
| A purchase made here is not also announced | nothing in three seconds **[ran]** | the same **[ran]** | `habitSameDevicePurchaseIsNotAnnounced` | `purchase()` announces nothing |
| A declined Ask to Buy sends nothing at all | nothing; it stays pending **[ran]** | delivered *as a purchase* — a fault of that simulator **[ran]** | `habitDeclinedAskToBuy` | `declinePending` clears the store's side and announces nothing |
| An interrupted purchase is pending, and goes through later by itself | yes **[ran]** | `purchase()` throws — a fault of that simulator **[ran]** | `interruptedPurchase` | The same shape as Ask to Buy: `.pending`, then `approvePending` |
| Buying what is owned hands back the original transaction, original date and all | yes **[ran]** | yes **[ran]** | `trialTwice` | The same, which is what makes a trial one trial. An approved Ask to Buy is that same purchase arriving later, so it comes with the original date too |
| The payment sheet stays up for as long as the person takes | **[Apple]** | | — | `purchaseGate`, and `restoreGate` for the password prompt |
| The account may own things this device has not heard of, and a restore brings them | **[Apple]** | | — not reachable in Xcode's environment, which has one device | `seedEarlierPurchase`; they turn up when bought again, or on restore |
| A purchase can arrive as a family member's | **[Apple]**, sandbox only | | — | `seed(_:age:ownership: .familyShared)`: your word for it |
| A grant can be announced and never listed | reported, not seen **[check]** | | — | `announceWithoutListing` |

"Held to it by" is a test in `Demo/Tests` that *measures* the habit against real StoreKit and compares it with what is written down, per OS; when one fails, StoreKit has changed, and this table and perhaps the fake change with it. The habits differ between the two columns today. **Test against the awkward one**: an app that is right when the listing lags is right when it does not.

## Arranging it

In a test, which is where the simulated store is named, after `import PurchaseTestKit`. It exists only in debug builds, which is where test bundles are built ([testing](05-testing.md#a-test-imports-the-test-kit-and-an-app-cannot-link-it)); a running app arranges it with a [scenario](#scenarios) or the [debug panel](#the-debug-panel) instead.

```swift
// Owning things and misbehaving from its first line, for a test that needs no more:
let owner = SimulatedStoreFront(
    catalogue: Shop.catalogue, owned: [OwnedProduct(id: Shop.pro, originalPurchaseDate: clock.now)],
    clock: clock, behaviour: .init(purchase: .pending))

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
front.declinePending(Shop.pro)           // …or declines: nothing is announced, as with the real store
front.listUnlisted()                     // the listing catches up by itself, with nobody reading it
front.revoke(Shop.pro)                   // a refund
front.announceWithoutListing(owned)               // announced, and never listed
```

How it misbehaves, changeable at any time:

```swift
front.behaviour.purchase = .pending               // .succeeds | .cancelled | .fails(.unverified)
front.behaviour.purchases = [Shop.pro: .pending]  // …or per product: the trial goes through, the unlock waits
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

A customer who paid, and whose purchase does not verify — the support case an app most needs to have thought about. The store lists it, nobody owns it, and `diagnose()` says why:

```swift
front.seedUnverified(Shop.pro)
```

To serve your app's real names and prices in a test, build it from your `.storekit` file:

```swift
let file = try StoreKitConfiguration(contentsOf: url)
let front = SimulatedStoreFront(catalogue: Shop.catalogue, configuration: file)
```

## "Trial ends in five minutes"

| Where | How | Time taken |
|---|---|---|
| A unit test | `seedTrial(_:remaining:)` with a `ManualClock`, then `clock.advance(by:)` | None |
| A running debug build | `deliverTrial(_:remaining:)` from the debug panel, or a scenario, on the real clock | Five minutes, while you watch the app lock itself |
| Real StoreKit | A catalogue whose trial lasts a second or two, everywhere; or a backdated purchase (`.purchaseDate` with `SKTestSession.buyProduct`), which works in the iOS 27 simulator and on macOS 26.6 with Xcode 26.6, and not on macOS 26.6 with Xcode 27.0. **[ran]** | A second or two |

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
| `unverified=` product, … | Listed, with a signature that does not check out: owned by nobody |
| `purchase=` `succeeds` \| `pending` \| `cancelled` \| `held` \| `fails:`error | How the next purchases end. `held` closes the purchase gate: the payment sheet is up |
| `purchase=` product`:`outcome, … | The same, per product: `purchase=pro:pending,trial:succeeds` |
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
| Someone who paid, and whose purchase does not verify | `unverified=pro` |
| The trial goes through and the unlock waits for approval | `purchase=pro:pending,trial:succeeds` |
| The store not having answered | `ownership=held` |
| A purchase under way, the sheet still up | `purchase=held`, then press Buy |
| An owner, offline | `owns=pro; catalogue=fails:network` |
| A build the store sells nothing to | `catalogue=empty` |

`held` is for looking at, not for getting past. A key may be given once, so `purchase=held` cannot also say how the purchase ends: let go, it succeeds. And a UI test cannot let it go at all — only code in the app can open a gate, which in practice means the debug panel — so a test that holds a purchase ends with it still held. To test how a purchase *ends*, script it (`purchase=cancelled`, `purchase=fails:network`); to choose the ending of a held one, hold it from a unit test, where `front.behaviour.purchase` can be changed before `front.purchaseGate.open()`.

**Crash on a scenario that does not parse.** A typo that quietly falls back to the real store produces screenshots of the wrong thing.

## The debug panel

`PurchaseDebugPanel(launch)` takes the `StoreLaunch` the app was started with. **Its name is in every build, and in a release build it draws nothing**, so nothing about it needs an `#if` — except a `Window` scene, because a scene cannot be conditional and an empty window would still have its place in the Window menu:

```swift
import PurchaseDebugUI

// On the Mac, a window of its own, beside the app's `WindowGroup`. The one `#if` the
// panel costs, and it is the app's own, round a scene:
#if DEBUG
Window("Purchases", id: "purchase-debug") { PurchaseDebugPanel(launch) }
#endif
```

`Window` scenes do not exist on iOS; present the panel in a sheet there — or anywhere — with no `#if` at all. `PurchaseDebugPanel.isAvailable` is true in a debug build and false in a release one, for the button that opens it:

```swift
if PurchaseDebugPanel.isAvailable {
    Button("Purchase debug panel…") { showsDebugPanel = true }
        .sheet(isPresented: $showsDebugPanel) { PurchaseDebugPanel(launch) }
}
```

`Demo/App` does both, one on each platform. (An app that [wrote its own root](07-release-safety.md#writing-the-root-yourself) hands the panel its store and its simulated front instead, under its own `#if`.)

The top of the panel shows facts from **whatever store the app is running on**, the real one included, ticking every second so a trial can be watched running out. The controls appear only when a simulated store is handed in: start a trial with any number of seconds left, deliver a purchase from "another device" or through Family Sharing, refund, approve Ask to Buy, script the next purchase, hold any of the gates — a purchase with its payment sheet still up included — and empty or fail the catalogue. "What this build receives" asks the store directly, which is most useful against the real one on the afternoon Buy does nothing.

## Previews

Apple's previews load products and prices from the `.storekit` file, and cannot arrange what the account *owns*. A simulated store can, so each state of a paywall gets a preview of its own — arranged by a [scenario](#scenarios)'s text:

```swift
import PurchaseLaunch

#Preview("Trial nearly over") {
    PaywallView().purchaseStore(StoreLaunch.preview(catalogue: Shop.catalogue, scenario: "owns=trial@13d23h58m"))
}

#Preview("An owner, offline") {
    PaywallView().purchaseStore(StoreLaunch.preview(catalogue: Shop.catalogue, scenario: "owns=pro; catalogue=fails:network"))
}
```

**Text, and not a simulated store to arrange, because previews are compiled in release builds too.** A preview that names `SimulatedStoreFront` fails the app's first Release build — the archive — with "cannot find 'SimulatedStoreFront' in scope", unless somebody remembered an `#if DEBUG` round it. `StoreLaunch.preview` exists in every build; in a release one it is a store that owns nothing and sells nothing, which no preview ever runs. A scenario that does not parse crashes the preview, and says why.

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

The two identifiers are the app's to provide. The marker is three lines, where `launch` is the `StoreLaunch` the app was started with — and needs no `#if`, since `isSimulated` is never true in a release build:

```swift
if launch.isSimulated {
    Text("Simulated store").accessibilityIdentifier("simulated-store")
}
```

`Scenario.launchArgument` and `Scenario.environmentVariable` are the two spellings, for code on the app's side; `launchEnvironment["PURCHASE_SCENARIO"]` works where an argument is awkward. `StoreLaunch.make` honours the scenario ([getting started](02-getting-started.md#the-composition-root)), and three things about the build decide whether it can:

| | |
|---|---|
| **The Test action's build configuration must give the package `DEBUG`**, which Xcode decides by the configuration's *name*: `Debug`, or one beginning with `Debug` ([release safety](07-release-safety.md#screenshot-and-ui-test-configurations)). | In a Release-configured test plan the simulated store does not exist. The app ignores the argument and runs on **the real store**, and nothing fails: the screenshots are of the wrong thing. A scenario that does not *parse* crashes; a scenario the build cannot *honour* is silent. |
| **So assert a marker first.** Show something only when the app is on a simulated store — the Demo shows a "Simulated store" badge with the identifier `simulated-store` — and make it the first assertion of every UI test. | It turns the silent case into a failure that says what is wrong. |
| **For a screenshot pipeline, give the run a configuration of its own**: `Debug-Screenshots`, with its own compilation condition (`DEBUG SCREENSHOTS`) and **its own bundle identifier**, and honour scenarios under `#if SCREENSHOTS`, in [a root of your own](07-release-safety.md#writing-the-root-yourself), rather than in any debug build. | The bundle identifier gives the run its own container, so screenshot window frames and preferences do not leak into the development build; the condition keeps the development build from being talked into showing invented purchases at all. The name has to begin with `Debug`, or the package is built without the simulated store. |

`Demo/UITests` is this, run by `make ui-tests` on an iOS simulator. On the Mac a UI test runner also needs Automation Mode permitted (`automationmodetool`), and, signed ad hoc, the hardened runtime switched off for the UI-test target alone.
