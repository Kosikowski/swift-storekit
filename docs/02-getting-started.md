# Getting started

From an empty project to a working purchase: add the package, declare what the app sells, build one store at the composition root, and wire two buttons. Each step says which part is the package's and which is left to the app.

Evidence tags (`[ran]`, `[Apple]`, `[check]`) mark statements about real StoreKit; the [checklist](checklist.md) explains them.

## The one rule

**The package reports store facts and performs store actions. The app owns product policy.**

The package tells you what the account owns and since when, how it came by it, whether the store has answered yet, where a trial stands, what the store sells and for how much, what is waiting for someone's approval, and whether something is under way. It returns typed outcomes and typed errors.

It does not know which features a purchase unlocks, what your limits are, what locks on a downgrade, what the paywall says or looks like, when to raise an alert, or how to format a date. There is deliberately no `isPro` anywhere. You derive your own, and in doing so decide what "the store has not answered yet" means for the thing being asked ([below](#derive-your-own-ispro)).

## Add the package

The package needs iOS 26 or macOS 26, and Swift tools 6.2.

In Xcode, use File › Add Package Dependencies…. In a `Package.swift`:

```swift
dependencies: [
    // Up to the next *minor*, until 1.0: `from:` accepts everything below 1.0, and
    // before 1.0 a minor release is where the API moves.
    .package(url: "https://github.com/Kosikowski/swift-storekit.git", .upToNextMinor(from: "0.2.0")),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "PurchaseCore", package: "swift-storekit"),
            .product(name: "PurchaseStoreKit", package: "swift-storekit"),
            .product(name: "PurchaseUI", package: "swift-storekit"),
        ]),
]
```

| Product | Link it into | What it is |
|---|---|---|
| `PurchaseCore` | the app | All the logic. Imports Foundation and Observation only. |
| `PurchaseStoreKit` | the app | `AppStoreFront`: the App Store behind Core's protocols. |
| `PurchaseUI` | the app | Two environment entries, `.purchaseStore(_:)`, `PurchaseButton`, `RestorePurchasesButton`. No paywall. |
| `PurchaseLaunch` | the app | `StoreLaunch.make(catalogue:)`: the store for this launch. The App Store — and, in a debug build given `-PurchaseScenario`, a simulated one. |
| `PurchaseDebugUI` | the app | `PurchaseDebugPanel`, which drives a simulated store in a running debug build and draws nothing in a release one. |
| `PurchaseTestKit` | **test targets only** — an app that links it does not build | `SimulatedStoreFront`, `AnswerGate`, `Scenario` (debug builds); `ManualClock`, `waitUntil`, `RecordingPurchaseLogger`, `StoreKitConfiguration` (every build). |
| `PurchaseDirectDistribution` | a build sold outside the App Store | `EverythingOwnedStoreFront`. |

**An app imports modules that do something in every build, and nothing else.** The simulated store exists only in `DEBUG` builds — a store that hands out purchases for nothing must be absent from a shipped binary, not disabled in it — and an app never names it: `PurchaseLaunch` reaches it, in a debug build, under an `#if` of the package's own. So there is no `#if DEBUG` about purchases in your code, no import that names a module missing from a release build, and nothing for a test module to do in an app. Read [release safety](07-release-safety.md) before adding a custom build configuration: Xcode gives a package target `DEBUG` by the configuration's *name* `[ran]`. **If your everyday configuration is called `Development` or `Staging`, the package is built for release in it**: scenarios are not honoured and the debug panel draws nothing, quietly. The name has to begin with `Debug`.

## Declare the catalogue once

This is the only place a product identifier is written.

```swift
import PurchaseCore

enum Shop {
    static let pro: ProductID = "com.example.app.pro"
    static let trial: ProductID = "com.example.app.trial"

    static let catalogue: Catalogue = [
        .unlock(pro),
        .trial(trial, of: [pro], lasting: .seconds(14 * 86_400)),
    ]
}
```

The store is asked for exactly these products, only these are counted as owned, and only their transactions are finished. A renamed identifier otherwise fails silently: the product never loads, and the Buy button "does nothing". [Catalogue and standing](03-catalogue-and-standing.md) covers the types; [trials](04-trials.md) covers the second entry.

## The composition root

One place in the app decides which store this launch runs on, and the package has written it:

```swift
import PurchaseCore
import PurchaseLaunch

@MainActor
enum Purchases {
    static let launch = StoreLaunch.make(catalogue: Shop.catalogue, logger: OSPurchaseLogger())
}
```

`StoreLaunch.make` answers with the store (`launch.store`) and whether it is a simulated one (`launch.isSimulated`):

| Build | Launched with | The store |
|---|---|---|
| Release | anything at all | The App Store. **There is no other branch**: the simulator's module compiles to nothing in release, so an argument has nothing to switch on. On macOS anyone can pass a shipped app launch arguments |
| Debug | nothing | The App Store |
| Debug | `-PurchaseScenario "owns=trial@13d23h55m"`, or `PURCHASE_SCENARIO` in the environment | A [simulated store](06-simulated-store.md) arranged as the scenario says. One that does not parse **crashes**, rather than quietly running on the real store and producing screenshots of the wrong thing |

The logger goes to the store and to the App Store front alike, so that a purchase that does not verify is heard of whichever of them met it.

**A build sold some other way** — Developer ID, an enterprise build, another shop — has no App Store behind it. The real store lists nothing to such a build, so a build that *is* the paid edition would lock out its own buyers. Say what the live store is:

```swift
import PurchaseDirectDistribution

StoreLaunch.make(catalogue: Shop.catalogue) { catalogue, _ in
    EverythingOwnedStoreFront(catalogue: catalogue)
}
```

It answers that every unlock has been owned since long ago, offers no trial, sells nothing (`products()` is empty and `purchase` throws `.purchaseNotAllowed`), and completes a restore without doing anything. It ships in release builds by design, is chosen by a target or a compilation condition of your own, and cannot be switched on by a launch argument or a preference. It is a product of its own so that an App Store build does not link it.

**Writing the root yourself** is still possible, and is what a screenshots configuration with a condition of its own wants (`#if SCREENSHOTS`, in a configuration named `Debug-Screenshots`): `SimulatedStoreFront` and `Scenario` are public, in `PurchaseSimulator`, and [release safety](07-release-safety.md#writing-the-root-yourself) has the shape. That code is then the one place in your app with an `#if` in it.

`PurchaseStore` is `@MainActor` and `@Observable`. Building one touches nothing: no listener is started and nothing is read until `start()`, so a store made for a preview or a test has not spoken to anything. `PurchaseStore.init(catalogue:front:clock:logger:listingGrace:)` defaults the clock to `SystemClock()`, the logger to `SilentPurchaseLogger()` and `listingGrace` to 30 seconds. A second initialiser takes the five store roles one at a time ([architecture](01-architecture.md)).

## Put the store in the environment

```swift
import PurchaseCore
import PurchaseUI
import SwiftUI

@main
struct ExampleApp: App {
    private let store = Purchases.launch.store

    var body: some Scene {
        WindowGroup {
            RootView()
                .purchaseStore(store)
        }
    }
}
```

`.purchaseStore(_:)` does three things:

1. sets `\.purchaseState` (what a view may read; it has no commands) and `\.purchaseCommands` (what a button may ask for);
2. calls `start()`, which begins listening for transactions and reads what is owned;
3. then calls `loadProductsIfNeeded()`, unless you pass `loadsProducts: false`.

Ownership is read first and prices second, because nothing about what a person may use should wait for a network request that can take a long time to fail.

SwiftUI cancels the modifier's task if the view goes away, and that is safe. The store reads ownership in a task of its own, because real StoreKit answers a cancelled task with nothing at all, which reads as owning nothing `[ran]`.

Apply the modifier once, at the root. An app with a second scene applies it to that scene's root view as well: `start()` does nothing the second time, and prices that are loaded are not asked for again. `loadProducts()` itself goes to the network every time, which is what a Retry button wants; everything else wants `loadProductsIfNeeded()`.

## `standing`, or `knownStanding()`?

Every launch begins with the standing `unknown`. Unknown is not "owns nothing", and treating it as such is the bug where a paying customer meets the paywall at every launch.

| | `standing` | `await knownStanding()` |
|---|---|---|
| Kind | Synchronous, observable property | `async` function |
| Before the store answers | `.unknown` | Waits, and starts the store if nothing has |
| Right for | **Drawing.** A view body that reads it redraws when it changes | **Deciding.** Gates, limits, locks, whether to present the paywall, "open this" paths, state restoration at launch, App Intents |
| If used for the other job | A view cannot `await` in its body | A decision made on `standing` during launch opens something that should be locked or, more often, shows an owner the paywall |

While the standing is unknown, a view draws neither "Pro" nor "Free" and neither locks nor a paywall:

```swift
struct ProBadge: View {
    @Environment(\.purchaseState) private var purchases

    var body: some View {
        switch purchases?.standing.access(to: Shop.pro) {
        case nil, .unknown?:
            EmptyView()            // not answered yet: draw neither "Pro" nor "Free"
        case .owned?, .subscribed?:
            Text("Pro")
        case let .onTrial(period, _)?:
            Text("Trial until \(period.endsAt.formatted(date: .abbreviated, time: .shortened))")
        case .none?:
            Text("Free")
        }
    }
}
```

`knownStanding()` is safe to call from a task that SwiftUI may cancel: a cancelled caller waits for the same read as everyone else and receives the whole answer. It does not wait for prices.

## Derive your own `isPro`

What "Pro" means is policy, so it lives in the app. Write it once, from `access(to:at:)`, and make the unknown case explicit:

```swift
extension Standing {
    /// App policy, not a store fact: what "Pro" means here.
    /// Nil while the store has not answered — the caller decides what that means.
    func unlocksPro(at date: Date) -> Bool? {
        access(to: Shop.pro, at: date).isGranted
    }
}
```

`ProductAccess.isGranted` is true when owned or lent by a running trial, false when neither, and **nil until the store has answered**. It is a `Bool?` and not a `Bool` on purpose: an optional cannot be tested with `if` until somebody has decided what nil means for the thing being asked, and "no" is nearly always the wrong decision. If Pro means something else in your app — several unlocks, a trial that lends only part of it — write the `switch` yourself.

A gate then waits for the answer, so the unknown case cannot arise by accident:

```swift
@MainActor
func mayExport(_ purchases: any PurchaseStateProviding, now: Date = .now) async -> Bool {
    let standing = await purchases.knownStanding()
    return standing.unlocksPro(at: now) ?? false
}
```

The date is a parameter because a standing is a fact about a moment. Nothing in the package reads a clock to answer a question, which is what makes a trial's expiry testable ([catalogue and standing](03-catalogue-and-standing.md)). Where the app does need the time — a model that answers `isPro` for a view — ask the store's own clock, `store.clock.now`, rather than keeping a second one beside it: under a `ManualClock` in a test, the two would disagree.

## Buttons, and where the result lives

`PurchaseButton` and `RestorePurchasesButton` carry no wording and no layout. Each hands the result to a closure, and publishes it nowhere.

```swift
struct PaywallView: View {
    @Environment(\.purchaseState) private var purchases

    /// This view's own. Never in a shared model.
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading) {
            PurchaseButton(Shop.pro) { notice = Wording.notice(for: $0) } label: {
                Text("Buy Pro\(price(of: Shop.pro))")
            }
            RestorePurchasesButton("Restore Purchases") { result in
                if case let .failure(error) = result { notice = Wording.sentence(for: error) }
            }
            if purchases?.pendingApprovals.contains(Shop.pro) == true {
                Text("Waiting for approval.")
            }
            if let notice { Text(notice) }
        }
    }

    private func price(of id: ProductID) -> String {
        purchases?.products.first { $0.id == id }.map { " for \($0.displayPrice)" } ?? ""
    }
}
```

**Keep the result in the `@State` of the view whose button was pressed.** A result held in one shared flag is announced by every view watching that flag: the paywall sheet, the settings pane and a second window all raise the same alert at once. This is why `PurchaseStateProviding` has no "last result" property, and why the commands return their outcome to the caller instead.

Both buttons:

- are disabled while a purchase or restore is under way (`activity.isBusy`), and when no store is in the environment, so there is never a button that does nothing;
- run in an unstructured `Task`, not `.task`, so a purchase is not abandoned because its button scrolled out of sight while the payment sheet was up.

| Initialiser | Use |
|---|---|
| `PurchaseButton(_ id:, onCompletion:, label:)` | Any label view |
| `PurchaseButton(_ titleKey:, buying:, onCompletion:)` | A text label |
| `RestorePurchasesButton(onCompletion:, label:)` | Any label view |
| `RestorePurchasesButton(_ titleKey:, onCompletion:)` | A text label |

Always show `StoreProduct.displayPrice`. The currency, the rounding and the tax treatment are the store's to decide, so never format a price from a number of your own `[Apple]`.

### Apple's own views

An app that sells through Apple's `ProductView`, `StoreView` or `SubscriptionStoreView` instead of these buttons **hands each purchase to the store from the view's completion**:

```swift
ProductView(id: Shop.pro.rawValue)
    .onInAppPurchaseCompletion { product, result in
        _ = try? await store.takePurchase(result, of: product)   // import PurchaseStoreKit
    }
```

Measured in the iOS simulator, an unlock bought in `ProductView` is announced nowhere: nothing arrives on `Transaction.updates`, and the view finishes the transaction itself `[ran]`. Without that line the store hears of the purchase only at its next read, and "Free" stays on screen. `takePurchase` judges the view's result as a purchase made here is judged. It finishes the transaction if it is verified and in the catalogue, believes it at once, and throws `unverified` without finishing it. It returns the same `PurchaseCompletion`. ([D45](10-decisions.md#d45-a-purchase-made-in-apples-own-views-is-handed-to-the-store))

## Word every outcome

The completion closure receives `Result<PurchaseCompletion, PurchaseError>`. Ways of *ending* are values; things that went wrong are errors. The split matters because a cancellation is something the person chose and wants no words about, while a failure happened to them and needs saying.

| `PurchaseCompletion` | What happened | Say |
|---|---|---|
| `.owned(OwnedProduct)` | An unlock, now held. The standing already includes it | Nothing, or close the paywall |
| `.trialRunning(TrialPeriod)` | A trial, now running | Nothing, or when it ends, with the time |
| `.trialUsed(TrialPeriod)` | The trial was bought and the store handed back one already over: taken on another device, or before a reinstall | "Your trial ended on … at …". Do not let the button go grey without a word |
| `.notCounted(OwnedProduct)` | The store completed it and it gives this account nothing, such as a trial that arrived through Family Sharing | A sentence. Rare |
| `.subscribed(HeldSubscription)` | A subscription, now held: bought, upgraded to, or already held | Nothing, or close the paywall |
| `.planChangeScheduled(to:at:)` | A downgrade, or a change to another duration, that takes effect at the renewal. **Nothing has changed yet**: StoreKit reports it as a success with the subscription already held | When the change happens: "From … you'll be on …" |
| `.offerNotApplied(HeldSubscription)` | A subscription, now held, bought with an offer that **was not applied**: at the regular price ([offers](16-offers.md#when-an-offer-is-not-applied)) | That the offer could not be applied. Never the offer's price |
| `.pending` | Ask to Buy: someone else has to approve it | **"Waiting for approval."** Not a failure, and not silence. The product is in `pendingApprovals` until it is settled |
| `.cancelled` | The person backed out | Nothing |

`RestoreOutcome` is `.completed` or `.cancelled` (the person dismissed the sign-in prompt: say nothing). Whether a restore *found* anything is in the standing, which has been read again by the time the outcome is returned.

| `PurchaseError` | Meaning | Say |
|---|---|---|
| `.unverified` | The store says the purchase was made and its signature does not check out. Nothing is unlocked and the transaction is left unfinished, so the store offers it again | "Could not be verified. Try Restore Purchases, and contact support if you were charged." **Never report this as a cancellation: the person may have been charged** |
| `.revoked` | The store completed the purchase and has already taken it back | That it was taken back, and that nothing is unlocked |
| `.productUnavailable` | No such product for this account: not in the catalogue, not sold here, or not yet approved | "Not available at the moment" |
| `.notAvailableInStorefront` | Not sold in this country or region | The same |
| `.purchaseNotAllowed` | Purchases are switched off on this device (Screen Time, a managed profile) | That purchases are switched off |
| `.network` | The store could not be reached | Try again in a moment |
| `.alreadyInProgress` | A purchase or restore is already under way from somewhere else | That one is under way |
| `.system` | The system failed in a way that is nobody's fault here | Try again |
| `.invalidConfirmation` | The window or scene the payment sheet was to appear over is not usable | Try again; log it, because it is a bug in the anchor you passed |
| `.offerRefused(OfferRefusal)` | The store refused the offer asked for, and nothing was bought. The reason is kept: `.notEligible`, `.invalidSignature`, `.unknownOffer`, `.invalidPrice`, `.missingParameters` | That the offer is not available; the regular price, if that is what the paywall offers next. A bad signature is your server's: log it |
| `.offerNotSigned` | The offer needed a signature from your `OfferSigning`, and none came. The purchase was not attempted | Try again in a moment; log it |
| `.unsupported` | Something this package does not do | A general failure; log it |
| `.unknown(typeName:)` | Not recognised. Carries the error's *type name* and nothing else | A general failure; log the type name |

```swift
enum Wording {
    static func notice(for result: Result<PurchaseCompletion, PurchaseError>) -> String? {
        switch result {
        case .success(.owned), .success(.trialRunning), .success(.subscribed), .success(.cancelled):
            nil
        case .success(.offerNotApplied):
            "You're subscribed, but the offer couldn't be applied, so this was at the regular price."
        case let .success(.planChangeScheduled(_, at)):
            "Your plan changes at your next renewal\(at.map { ", on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")."

        case .success(.pending):
            "Waiting for approval. Pro unlocks as soon as it is given."
        case let .success(.trialUsed(period)):
            "Your trial ended on \(period.endsAt.formatted(date: .abbreviated, time: .shortened))."
        case .success(.notCounted):
            "That purchase was completed, but it does not unlock anything for this account."
        case let .failure(error):
            sentence(for: error)
        }
    }

    static func sentence(for error: PurchaseError) -> String {
        switch error {
        case .unverified:
            "The App Store could not verify this purchase, so nothing has been unlocked. "
                + "Try Restore Purchases, and contact support if you were charged."
        case .revoked:
            "The App Store completed this purchase and then took it back. Nothing has been unlocked."
        case .productUnavailable, .notAvailableInStorefront:
            "This is not available from the App Store at the moment."
        case .purchaseNotAllowed:
            "Purchases are switched off on this device."
        case .network:
            "The App Store could not be reached. Try again in a moment."
        case .alreadyInProgress:
            "A purchase is already under way."
        case .offerRefused, .offerNotSigned:
            "That offer isn't available just now. Nothing has been charged."
        case .system, .invalidConfirmation, .unsupported, .unknown:
            "Something went wrong, and nothing has been unlocked. Try again."
        }
    }
}
```

The switch over `PurchaseError` has no `default`, so a case added later is a compile error in your wording and not a silent fallthrough. Localise the strings as you would any others.

`PurchaseError` carries no text on purpose. StoreKit's own `localizedDescription` is not safe to show or to log, because some of its errors echo App Store account identifiers `[review]`, so nothing of the store's error crosses into your app except which kind it was.

## Say where the payment sheet goes

With one window, StoreKit can be left to choose. With several (an iPad in Split View, a Mac with a window per document) it has to be told which one the purchase was started from, or the sheet may appear over another.

`PurchaseButton` does this for you: it reads SwiftUI's `PurchaseAction` from its own environment and passes it as the confirmation. `@Environment(\.purchase)` is Apple's recommended route in SwiftUI on every platform, because the action knows the scene of the view it was read in `[Apple]`.

When you call `purchase(_:confirmation:)` yourself, pass one of these:

| Confirmation | Platform | Anchor |
|---|---|---|
| `.action(_:)` | all | SwiftUI's `PurchaseAction`, from `@Environment(\.purchase)` |
| `.window(_:)` | macOS | `NSWindow` |
| `.viewController(_:)` | iOS | `UIViewController` (StoreKit's overload needs iOS 18.2 or later `[Apple]`) |
| `.scene(_:)` | iOS | `UIScene` |
| `.automatic` | all | None: the store chooses. `purchase(_:)` with no confirmation uses this |

The named constructors are in `PurchaseStoreKit`. `.automatic` and the type itself are in `PurchaseCore`, which imports no UI framework; the anchor crosses it type-erased. An anchor the adapter does not recognise is treated as `.automatic` and logged as `.unrecognisedConfirmationAnchor`.

```swift
import PurchaseCore
import PurchaseStoreKit
import PurchaseUI
import StoreKit
import SwiftUI

struct CustomBuyButton: View {
    @Environment(\.purchaseCommands) private var commands
    @Environment(\.purchase) private var purchase
    @State private var notice: String?

    var body: some View {
        Button("Buy Pro") {
            guard let commands else { return }
            Task {
                do throws(PurchaseError) {
                    let completion = try await commands.purchase(Shop.pro, confirmation: .action(purchase))
                    notice = Wording.notice(for: .success(completion))
                } catch {
                    notice = Wording.sentence(for: error)
                }
            }
        }
    }
}
```

`purchase(_:confirmation:)` is declared `throws(PurchaseError)`, so `do throws(PurchaseError)` gives the `catch` a typed error with no cast.

`PurchaseAction` and `\.purchase` live in the overlay module `_StoreKit_SwiftUI`. Xcode loads it unasked when a file imports both StoreKit and SwiftUI; a SwiftPM target on its own has to add `import _StoreKit_SwiftUI`, or `\.purchase` is not found. A target that links `PurchaseUI` compiles without it, with a warning about the missing import `[ran]`.

## Logging

The package ships only `SilentPurchaseLogger`. Conform `PurchaseLogging` to see what it is doing:

```swift
import os
import PurchaseCore

struct OSPurchaseLogger: PurchaseLogging {
    private let logger = Logger(subsystem: "com.example.app", category: "purchases")

    func log(_ event: PurchaseEvent) {
        logger.info("\(String(describing: event), privacy: .public)")
    }
}
```

`PurchaseEvent` is privacy-safe by construction: product identifiers, typed errors and type names only. There is no transaction in it, no description string from the store, and nothing an account could be recognised by, so an event may be logged as it is and marked public.

Pass the same logger to `AppStoreFront` and to `PurchaseStore`. The adapter logs what the store never sees: `.unverifiedTransactionIgnored`, `.foreignTransactionIgnored` and `.unrecognisedConfirmationAnchor`.

In your own code, **never log or display `localizedDescription` of a StoreKit error**, for the reason given above.

## Consumers that are not views

`PurchaseStore` is `@Observable`, so code that is not a view can watch it with `Observations`:

```swift
import Observation
import PurchaseCore

@MainActor
func watch(_ store: PurchaseStore) -> Task<Void, Never> {
    Task {
        let standings = Observations { store.standing }
        for await standing in standings where standing.isKnown {
            print(standing.ownedProducts.map(\.id))
        }
    }
}
```

`import Observation` is needed in a file that does not import SwiftUI, which re-exports it; importing `PurchaseCore` alone does not bring `Observations` into scope.

Written straight into a `for await` header, the trailing-closure form draws a warning (the closure is confusable with the loop's body), so either bind the sequence first, as above, or write `Observations({ store.standing })`. From code that is not on the main actor, isolate the closure: `Observations({ @MainActor in store.standing })`.

The first value may be the unknown standing. Skip it, or call `knownStanding()` first.

## Read again when the app becomes active

```swift
struct RootView: View {
    @Environment(\.purchaseCommands) private var commands
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        PaywallView()
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, let commands else { return }
                Task { await commands.refresh() }
            }
    }
}
```

The store schedules its own re-read for the moment a trial ends, and waits on the continuous clock, which keeps counting while the machine sleeps. What it cannot notice is the wall clock being *changed* while the app was inactive. `refresh()` reads the time afresh and resolves again, which covers that. It does not load prices.

## The development-build trap

> ⚠️ A debug build that App Store Connect does not know receives **no products and no entitlements** `[ran]`. An ad-hoc signed build with no team gets an empty product list and an empty `Transaction.currentEntitlements`. Nothing fails loudly: every purchase is refused, and what the developer sees is a Buy button that does nothing.

Attach a `.storekit` configuration file to the scheme's Run action (Product › Scheme › Edit Scheme… › Run › Options › StoreKit Configuration; with XcodeGen, `schemes.<name>.run.storeKitConfiguration`). Builds launched from Xcode then buy from that file locally `[ran]`. [App Store Connect](09-app-store-connect.md) covers the file, and how to test that it matches the catalogue.

The package reports the trap three ways:

- the store logs `PurchaseEvent.catalogueLoadedEmpty(requested:)` when a load returns nothing at all, while `productLoad` is `.loaded` and `products` is empty;
- `AppStoreFront` conforms to `StoreDiagnosing`, and `await front.diagnose()` — or `await store.diagnose()`, if the store was made in one line and the front was not kept — returns a `StoreDiagnosis` whose `hints` include `.storeSellsNothingToThisBuild`;
- `PurchaseDebugPanel` shows the same diagnosis under "What this build receives".

## Next

- [Catalogue and standing](03-catalogue-and-standing.md): the values you read.
- [Trials](04-trials.md): the free non-consumable, and testing its end.
- [Testing](05-testing.md) and [the simulated store](06-simulated-store.md).
- [App Store Connect](09-app-store-connect.md): the setup that is not code.
- [Checklist](checklist.md): everything, split into what the package handles and what is yours.
