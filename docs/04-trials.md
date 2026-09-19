# Trials

How a free trial works for an app that does not sell a subscription: what the product is, where its start date comes from, what an interface draws from it, how it ends, and three ways to test "the trial ends in five minutes".

**The package reports store facts and performs store actions; the app owns product policy.** A trial's start, end and status are facts, and they are here. What the trial unlocks, what locks when it ends, and how the end is worded and formatted are the app's.

Evidence tags (`[ran]`, `[Apple]`, `[review]`, `[check]`) mark statements about real StoreKit; the [checklist](checklist.md) explains them.

## The trial is a free non-consumable

App Review guideline 3.1.1 allows a non-subscription app to offer a free time-based trial by setting up a non-consumable in-app purchase at price tier 0, named for what it is, such as "14-day Trial" `[Apple]`. It is bought like anything else, through the payment sheet, for nothing.

In the catalogue it is an entry that names what it stands in for, and for how long:

```swift
static let catalogue: Catalogue = [
    .unlock(pro),
    .trial(trial, of: [pro], lasting: .seconds(14 * 86_400)),
]
```

[App Store Connect](09-app-store-connect.md) covers setting the product up.

## Its start is the App Store's date, and the app stores nothing

The trial starts at its transaction's `originalPurchaseDate`. The app never records it. Four properties follow:

| Property | Why |
|---|---|
| One trial per account, not per device | The App Store keeps the transaction against the account `[Apple]` |
| It survives a reinstall | For the same reason |
| It cannot be edited | It is a signed transaction, not a value the app wrote |
| It continues and does not restart when bought again | Buying an owned non-consumable hands back the original transaction, original date and all `[ran]` |

The last row was run against real StoreKit from the hosted suite in `Demo/Tests`: buying the trial a second time, after it had ended, returned `.trialUsed` with the first period.

### Why not the keychain or preferences

| Stored in | What goes wrong |
|---|---|
| Preferences | One trial per device, and a fresh one after every reinstall. Editable by anyone who can find the file |
| The keychain | Still one trial per device and not one per account. On macOS, the file-based keychain prompted for approval on every rebuilt binary, which froze launch and hung test runs `[ran]` |
| `AppTransaction` | Dating a trial from the app's own original purchase brings the class of sandbox-against-production `originalAppVersion` hazards. The trial transaction's own date avoids them `[review]` |

## `TrialTerms` and `TrialPeriod`

```swift
let terms = TrialTerms(duration: .seconds(14 * 86_400), targets: [pro])
let period = terms.period(startingAt: start)   // TrialPeriod
period.startedAt
period.endsAt
period.isRunning(at: date)
```

`duration` is a `Duration` and not a number of days, so that a test can run a whole trial in a third of a second against the real clock. That is the only way to see the scheduled re-read fire ([below](#3-real-storekit-with-a-very-short-duration)).

`targets` are the unlocks the trial stands in for while it runs. `Catalogue` validates that each is in the catalogue and is an unlock.

**The end is exclusive**: at `endsAt` exactly, the trial is over. A re-read scheduled *for* `endsAt` therefore finds it over. Were the end inclusive, the re-read would find the trial running for one more instant and have to be scheduled again.

`isRunning(at:)` takes the date as a parameter and never reads the clock. A check that reads the clock itself cannot be tested for expiry without waiting for it.

## `TrialStatus`, and the three things an interface draws

`standing.trial(_:at:)` answers where one trial stands:

| `TrialStatus` | Meaning | Draw |
|---|---|---|
| `.available` | Never taken, and there is something it would lend that is not already owned | **A button that starts the trial** |
| `.used(TrialPeriod)` | Taken, and over. It cannot be taken again | **The same button, disabled, saying when the trial ended, with the date and the time.** Hidden, people wonder where it went |
| `.running(TrialPeriod)` | Taken, and still running | Nothing here. The end is shown wherever the app shows its status |
| `.notOffered` | Not a trial this catalogue knows, or everything it stands in for is owned | Nothing |
| `.unknown` | The store has not answered yet, which is every launch until it does | **Nothing.** Offer nothing and judge nothing by this |

```swift
struct TrialButton: View {
    @Environment(\.purchaseState) private var purchases
    @State private var notice: String?

    var body: some View {
        switch purchases?.standing.trial(Shop.trial) {
        case .available?:
            PurchaseButton("Start 14-day Trial", buying: Shop.trial) { result in
                if case let .success(.trialUsed(period)) = result {
                    notice = "Your trial ended on \(Self.moment(period.endsAt))."
                }
            }
        case let .used(period)?:
            // Shown, and disabled. Hidden, people wonder where it went.
            Button("Trial ended \(Self.moment(period.endsAt))") {}.disabled(true)
        case .running?, .notOffered?, .unknown?, nil:
            EmptyView()
        }
    }

    /// Date AND time: a trial ends at an instant.
    private static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
```

A real button handles the other outcomes as well ([getting started](02-getting-started.md#word-every-outcome)).

One detail: a trial that was taken answers `.running` or `.used` even once the unlock is owned, because holding the trial product is a fact. Only a trial never taken turns `.notOffered` when its targets are owned. An interface for an owner usually shows no trial button at all, so check `access(to:)` for the unlock first.

### `PurchaseCompletion.trialUsed`

The status can say `.available` on a device that has not yet heard of a trial taken elsewhere: on another device, or before a reinstall. The person presses the button, and the store hands back the original transaction, already over.

`purchase` then returns `.trialUsed(TrialPeriod)`, and the standing turns to `.used`. Tell the person when it ended. Do not let the button go grey under their pointer without a word.

The other trial completions are `.trialRunning(TrialPeriod)`, for a trial now running, and `.notCounted(OwnedProduct)`, for a purchase the store completed that gives this account nothing.

## Family Sharing never counts for a trial

A family-shared transaction carries the *purchaser's* dates. A shared trial would hand every member of the family the organiser's trial, which is probably already over, and take away their own, since a trial that is owned cannot be started.

So a trial counts only when `ownership == .purchased`. Shared, assigned or unrecognised, it is ignored, however it arrives: in the listing, from `purchase`, or as an update. There is no option to change this. Turn Family Sharing **off** for the trial product in App Store Connect as well; the switch cannot be turned off again once it is on `[Apple]`, which is why the package does not rely on it.

## How a trial ends

**Nothing arrives when a trial ends.** No transaction, no update. Without a re-read scheduled for that moment, nothing locks until something unrelated redraws, or the app is relaunched.

`PurchaseStore` therefore schedules its own look:

1. After every resolve it takes `standing.nextExpiry`, the end of the running trial that ends soonest. (If a purchase is being held until the store lists it, the hold's lapse is a deadline too, and the sooner of the two is used.)
2. It sleeps until that date, on the clock it was given.
3. It resolves again. The trial is now `.used`, `access(to:)` for its targets is `.none`, and because `standing` is observable, views redraw.

A wake that lands a moment early needs no special case. Nothing has changed at that instant, so the same deadline comes back and is waited for again.

Buying the unlock during a trial leaves nothing to expire: `access(to:)` is `.owned`, which beats a trial.

`SystemClock` waits on the continuous clock, which keeps counting while the machine sleeps, so a fortnight is still a fortnight across a closed lid. It does not notice the wall clock being *changed*; calling `refresh()` when the app becomes active covers that ([getting started](02-getting-started.md#read-again-when-the-app-becomes-active)).

A view that draws the current state needs nothing more. A view that counts down asks the same standing about a moving date, without resolving it again:

```swift
TimelineView(.periodic(from: .now, by: 1)) { timeline in
    status(at: timeline.date)     // standing.access(to: Shop.pro, at: timeline.date)
}
```

## Show the end with its time

A trial ends at an instant, not on a day. "Until 30 September" is wrong by evening for someone who started in the evening.

The package gives the instant, `TrialPeriod.endsAt`. Formatting is the app's, in the app's locale:

```swift
period.endsAt.formatted(date: .abbreviated, time: .shortened)
```

## Testing "the trial ends in five minutes"

### 1. A manual clock, in a unit test

Instant, offline, and under plain `swift test`. (`YourApp` is your app's module, where `Shop` lives.) `ManualClock` moves only when told to, and `SimulatedStoreFront.seedTrial(_:remaining:)` puts the trial's purchase date where it needs to be.

```swift
import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing
@testable import YourApp

@MainActor
@Test("with five minutes left, Pro locks five minutes later, by itself")
func trialEndsInFiveMinutes() async {
    let clock = ManualClock()
    let front = SimulatedStoreFront(catalogue: Shop.catalogue, clock: clock)
    let store = PurchaseStore(catalogue: Shop.catalogue, front: front, clock: clock)

    front.seedTrial(Shop.trial, remaining: .seconds(300))
    await store.start()
    #expect(store.standing.nextExpiry == clock.now.addingTimeInterval(300))

    // The store has parked its re-read on the clock; now move time.
    await waitUntil { clock.sleeperCount == 1 }
    clock.advance(by: .seconds(300))

    await waitUntil { store.standing.access(to: Shop.pro) == .none }
    #expect(store.standing.access(to: Shop.pro) == .none)
    if case .used = store.standing.trial(Shop.trial) {} else { Issue.record("the trial should be used") }
}
```

Give the store and the simulated front the **same** clock: the front dates the seeded purchase by it, and the store waits on it.

Related arrangements:

| Call | Arranges |
|---|---|
| `seedTrial(_:remaining:)` | A trial with that long left. A negative `remaining` is a trial over by that much |
| `seedEarlierPurchase(_:age:ownership:)` | A trial the account took elsewhere, unknown to this device: `.available` until bought, then `.trialUsed` |
| `clock.wakeSleepers()` | A timer firing early, without moving time |
| `clock.sleeperCount` | Whether the store has scheduled its re-read yet |

`ManualClock` exists in every build configuration. `SimulatedStoreFront` exists only in `DEBUG`, which is where test bundles are built; if yours are also built for release, that test needs an `#if DEBUG` round it ([testing](05-testing.md#a-test-imports-the-test-kit-and-an-app-cannot-link-it)).

### 2. A running debug build, in real time

To watch the app lock itself, with its real views:

- **`deliverTrial(_:remaining:)`** on the simulated store announces a trial with that long left to a *running* app, which should react without being relaunched. `PurchaseDebugPanel` has a button for it ("Trial with that long left", with a field for the seconds) and another for a trial that ended a day ago.
- **A launch argument** starts the app already there:

  ```
  -PurchaseScenario "owns=trial@13d23h55m"
  ```

  The age is how long *ago* the trial was bought, so thirteen days, twenty-three hours and fifty-five minutes is a fourteen-day trial with five minutes left. It becomes a date only against the clock of the store it is applied to.

Both need the app to be running on a simulated store, which is the app's decision at its composition root and is possible only in a debug build. [The simulated store](06-simulated-store.md) covers the scenario grammar and the panel.

### 3. Real StoreKit, with a very short `Duration`

To prove the whole path against real StoreKit, make the trial short:

```swift
let catalogue: Catalogue = [.unlock(pro), .trial(trial, of: [pro], lasting: .milliseconds(1_500))]
```

Buy the trial through `AppStoreFront` under an `SKTestSession`, and wait for `access(to:)` to turn `.none`. `Demo/Tests/RealStoreKitTests.swift` does exactly this.

A short trial works everywhere. **Backdating the purchase works only where the OS and the tools can do it** `[ran]`. Apple documents the route — `Product.PurchaseOption.purchaseDate(_:)` with `SKTestSession.buyProduct(identifier:options:)` `[Apple]` — and in the iOS 27.0 simulator, and on macOS 26.6 with Xcode 26.6, it does what it says, so `Demo/Tests` also runs a real fortnight's trial bought thirteen days, twenty-three hours and fifty-five minutes ago. On macOS 26.6 with Xcode 27.0:

- `SKTestSession.buyProduct(identifier:)` fails with `StoreKitError.unknown`, with or without the App Sandbox (though Xcode 27's release notes list that very failure as fixed);
- the `.purchaseDate(_:)` option, through `product.purchase(options:)`, succeeds and **the date is ignored**.

There the test is recorded as a known issue, so it says when that changes.

Either way it has to run in a test bundle **hosted by an app**, because `SKTestSession` does not work in a package test target at all `[ran]`. See [testing](05-testing.md).

The same trick works on the real clock without StoreKit: a simulated store, a `.milliseconds(300)` trial and no `ManualClock` proves that the scheduled re-read fires.
