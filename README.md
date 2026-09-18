# swift-storekit

One-time purchases and trials over StoreKit 2, for macOS 26 and iOS 26, with a simulated store for testing them.

> ⚠️ **Early.** Non-consumables and trials only. No subscriptions, no consumables. The API may still move.

Selling a non-consumable looks like sixty lines of StoreKit, and every app that writes those sixty lines gets a different handful of them wrong. Each of these was found in shipping code or measured against real StoreKit, and each has a test here:

- Ownership read in a task SwiftUI then cancels. The real store answers a cancelled task with **nothing**, so a paying customer is shown the paywall.
- `currentEntitlements` read the moment `purchase()` returns, a second before the purchase is listed. The Buy button "does nothing".
- The listing re-read when an update arrives. An approved Ask to Buy arrives *before* the listing has it.
- Another product's transactions finished, so their owner never sees them.
- Prices waited for before ownership is known, locking owners out offline.
- A purchase that does not verify reported as a cancellation, to someone who may have been charged.

## The one rule

**The package reports store facts and performs store actions. Your app owns product policy.** What the account owns and since when, whether the store has answered yet, where a trial stands, what is pending approval: here. What a purchase unlocks, limits, paywall wording, what locks on a downgrade: yours. There is deliberately no `isPro`.

## Layout

```
┌──────────────────┐  ┌────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ PurchaseStoreKit │  │ PurchaseUI │  │ PurchaseTestKit │◄─│ PurchaseDebugUI │
│  the App Store   │  │  SwiftUI   │  │ simulated store │  │   debug panel   │
└────────┬─────────┘  └─────┬──────┘  └────────┬────────┘  └─────────────────┘
         └──────────────────┼──────────────────┘
                   ┌────────▼────────┐
                   │  PurchaseCore   │   Foundation and Observation only.
                   │  all the logic  │   No StoreKit, no SwiftUI.
                   └─────────────────┘
```

Everything that decides anything is in `PurchaseCore` and runs under plain `swift test`, offline. That is not tidiness: `SKTestSession` does not work in a package test target at all.

## Using it

```swift
.package(url: "https://github.com/Kosikowski/swift-storekit.git", branch: "main")
```

```swift
import PurchaseCore
import PurchaseStoreKit
import PurchaseUI
import SwiftUI

let catalogue: Catalogue = [
    .unlock("com.example.pro"),
    .trial("com.example.trial", of: ["com.example.pro"], lasting: .seconds(14 * 86_400)),
]

@main
struct ExampleApp: App {
    // `PurchaseStore` is on the main actor, so it is made where the app is.
    private let purchases = PurchaseStore(catalogue: catalogue, front: AppStoreFront(catalogue: catalogue))

    var body: some Scene {
        WindowGroup { ContentView().purchaseStore(purchases) }
    }
}
```

```swift
struct Paywall: View {
    @Environment(\.purchaseState) private var purchases
    @State private var result: Result<PurchaseCompletion, PurchaseError>?   // local, on purpose

    var body: some View {
        PurchaseButton("com.example.pro") { result = $0 } label: { Text("Buy Pro") }
    }
}
```

Anything that gates on a purchase waits for the store's first answer rather than reading `standing` during launch:

```swift
let standing = await purchases.knownStanding()
if case .none = standing.access(to: "com.example.pro", at: .now) { showPaywall() }
```

## Five things that decide how to use it

1. **`unknown` is not `none`.** Until the store has answered, nothing should be locked, offered or judged. Await `knownStanding()`.
2. **Results go to the button that asked.** Keep them in that view's `@State`. A shared flag makes every view watching it raise the same alert.
3. **Ownership does not wait for prices.** `start()` reads what is owned; `loadProducts()` is separate, and its failure changes nothing about what a person may use.
4. **A trial is a free non-consumable, dated by the App Store.** Never store its start. It ends at an instant, so show the time.
5. **The simulated store exists only in DEBUG builds**, and Xcode gives a package `DEBUG` by the configuration's *name*: `Debug-Screenshots` yes, `Screenshots` no.

## Testing

```
make test             # everything that decides anything; offline, no test host
make check            # layers, tests (debug and release), the iOS build, the Demo's builds
                      # (needs XcodeGen), and proof the simulated store is absent from
                      # release: `swift package release-check`, also in Xcode's package menu
make integration      # real StoreKit through the real adapter, hosted by Demo/ (needs XcodeGen)
make integration-ios  # the same, in an iOS simulator
make ui-tests         # the Demo launched with scenarios, as a screenshot run launches it
make stress           # the suite ten times, for races
```

Test your own app against `SimulatedStoreFront` and a `ManualClock`: a trial with five minutes left runs out in no time at all. Launch it for a UI test already owning something with `-PurchaseScenario "owns=pro"`. Anything that names the simulated store goes inside `#if DEBUG`, because that is the only place it exists. See [testing](docs/05-testing.md) and [the simulated store](docs/06-simulated-store.md).

## Documentation

| | |
|---|---|
| [Architecture](docs/01-architecture.md) | Targets, layers, ports, and where SOLID is bent |
| [Getting started](docs/02-getting-started.md) | From nothing to a working purchase |
| [Catalogue and standing](docs/03-catalogue-and-standing.md) | The values an app reads |
| [Trials](docs/04-trials.md) | The free non-consumable, its dates and its end |
| [Testing](docs/05-testing.md) | Apple's environments, and where the simulated store fits |
| [The simulated store](docs/06-simulated-store.md) | Behaviour, scenarios, the debug panel, previews |
| [Release safety](docs/07-release-safety.md) | Keeping the simulated store out of what ships |
| [The StoreKit adapter](docs/08-storekit-adapter.md) | Calls made, finish policy, error mapping |
| [App Store Connect](docs/09-app-store-connect.md) | The setup that is not code |
| [Decisions](docs/10-decisions.md) | Why, with the evidence for each |
| [Not implemented, deliberately](docs/11-roadmap.md) | Subscriptions, consumables, and the rest |
| [Migrating an existing app](docs/12-migrating-an-existing-app.md) | From hand-written StoreKit 2 |
| [Checklist](docs/checklist.md) | Everything to get right, and who handles it |

## Licence

MIT. See [LICENSE](LICENSE).
