# StoreKit 2 on macOS and iOS: a checklist

Lessons from adding a one-time unlock and a free 14-day trial to an app (macOS 26, with an iPad companion), September 2026, and from measuring real StoreKit while building this package. Use it to review an app's purchasing before release, whether or not the app uses the package.

Every section is split in two:

- **Handled by the package.** The named type or behaviour does it. Tick the item when you have confirmed that your app relies on it, and has no code of its own doing the same job differently.
- **Your app's responsibility.** The package cannot do these, either because they are product policy or because they live outside the code.

The division follows the package's one rule: **it reports store facts and performs store actions; the app owns product policy.**

Each item says how it is known:

- **[ran]** reproduced by running something: a test, a probe against real StoreKit, or `SKTestSession`. Checked on macOS 26 with Xcode 27.
- **[review]** a defect found in code review, confirmed against the code and fixed.
- **[Apple]** from Apple's documentation or guidelines, not tested here.
- **[check]** believed true but not verified here. Confirm it on your own target before you rely on it.

---

## 1. Products and App Store Connect

### Handled by the package

- [ ] **Every product identifier is kept in one place.** `Catalogue` is the only place an identifier is written: the store is asked for exactly those, only those count as owned, and only their transactions are finished. A renamed identifier otherwise fails silently: the product never loads and the button "does nothing". [ran] ([catalogue](03-catalogue-and-standing.md))
- [ ] **A test that your StoreKit configuration file sells exactly those identifiers.** `StoreKitConfiguration(contentsOf:).expectNoProblems(against:)`, one line in a plain unit test of yours, each problem a failure of its own. It also checks that every product is a non-consumable, that a trial is free and not family-shareable, and that an unlock's Family Sharing agrees with the catalogue. [ran] ([App Store Connect](09-app-store-connect.md#check-the-file-against-the-catalogue))
- [ ] **Family Sharing is guarded in code.** A trial dated by its purchase would otherwise hand every family member the organiser's start date, which is often already over, and take away their own trial. The App Store Connect switch cannot be turned off once it is on [Apple], so `StandingResolver` never counts a family-shared trial, and does not count a shared unlock declared `.unlock(_, familySharing: .ignored)`. [review] ([catalogue](03-catalogue-and-standing.md#family-sharing-restated-in-code))

### Your app's responsibility

- [ ] **For a free trial on a non-subscription app, create a free non-consumable**, priced at tier 0 and named for what it is (for example "14-day Trial"). This is the form App Review guideline 3.1.1 accepts. Before the trial starts, the paywall must say how long it lasts, what stops being accessible when it ends, and what the full unlock costs. [Apple] ([App Store Connect](09-app-store-connect.md#the-trial-product))
- [ ] **Turn Family Sharing on for the paid unlock and off for the trial** in App Store Connect, and say the same in the catalogue. [review]
- [ ] **Decide the price text once and take it from the product.** Show `StoreProduct.displayPrice`. Never format a hard-coded price. [Apple]
- [ ] **Activate the Paid Apps Agreement, add localisations and a review screenshot, and submit the first in-app purchases with an app version.** [Apple] ([App Store Connect](09-app-store-connect.md))

## 2. Development builds and the StoreKit configuration file

### Handled by the package

- [ ] **A debug build that App Store Connect doesn't know gets nothing from StoreKit, and the package says so.** An ad-hoc signed build with no team gets an empty `Product.products(for:)` and an empty `Transaction.currentEntitlements`. Every purchase fails, and to the developer the Buy button "does nothing". [ran] The store logs `PurchaseEvent.catalogueLoadedEmpty(requested:)`, and `AppStoreFront.diagnose()` returns a `StoreDiagnosis` with the hint `.storeSellsNothingToThisBuild`. ([getting started](02-getting-started.md#the-development-build-trap))
- [ ] **A hand-written `.storekit` file is read leniently.** `StoreKitConfiguration` parses the schema versions Xcode has written so far (3.0, 4.0, 6.x), ignores unknown keys, and collects products from every section of the file. [ran]

### Your app's responsibility

- [ ] **Attach a `.storekit` configuration to the scheme's Run action.** Builds launched from Xcode then buy from it locally. With XcodeGen that is `schemes.<name>.run.storeKitConfiguration: path/to/File.storekit`. [ran]
- [ ] **Keep the `.storekit` file out of the shipping app.** XcodeGen's default build phase for `.storekit` is "none", so it isn't copied into the bundle. Confirm that in the generated project. [ran]
- [ ] **The scheme's configuration applies only to builds launched from Xcode.** A build started any other way asks the App Store. [Apple]
- [ ] **Refund and delete test purchases with Xcode's Debug › StoreKit › Manage Transactions.** Use it to exercise refunds and downgrades by hand. [Apple]
- [ ] **Your own daily-use debug build becomes a free user** once it buys from the local file. Buy the unlock locally (nothing is charged), or anything you gate will lock on you.
- [ ] **A hand-written `.storekit` file is valid** if `SKTestSession(contentsOf:)` loads it and `Product.products(for:)` returns its products. The minimal shape used here is: `version {major: 4, minor: 0}`, and a `products` array whose entries have `productID`, `referenceName`, `type: "NonConsumable"`, `displayPrice`, `familyShareable`, `internalID`, and `localizations` (`locale`, `displayName`, `description`). Alongside it go `settings`, `subscriptionGroups: []` and `nonRenewingSubscriptions: []`. [ran]
- [ ] **Name any build configuration that needs the simulated store so that it begins with `Debug`.** Xcode gives a package target `DEBUG` by the build configuration's *name*, not its type: `Debug-Screenshots` gets it, `Screenshots` does not, and an app's own compilation conditions never reach a package target. Everything in the package that can grant a purchase exists only under `DEBUG`. [ran] ([release safety](07-release-safety.md))

## 3. Reading what the person owns

### Handled by the package

- [ ] **`Transaction.currentEntitlements` is the single source of truth.** The package keeps no entitlement of its own and stores nothing. It answers from StoreKit's cache when offline. [Apple]
- [ ] **Products are never asked for in a task something else can cancel, either.** A cancelled `Product.products(for:)` is answered with an *empty list*, not an error: 0 of 2. It reads as a store that sells this build nothing. `PurchaseStore.loadProducts()`, `AppStoreFront.products()` and `diagnose()` all ask from a task of their own. [ran] ([decisions](10-decisions.md))
- [ ] **Ownership is never read in a task something else can cancel.** A cancelled task reads *nothing* from `currentEntitlements`: 0 of 1 entitlements. Nothing at all is indistinguishable from owning nothing, and SwiftUI cancels `.task` whenever a view goes away, so a paying customer who closes a sheet at the wrong moment is told they own nothing. `PurchaseStore` reads in a task of its own, single-flight, and a cancelled caller waits for it like anyone else. [ran] ([decisions](10-decisions.md))
- [ ] **A transaction counts only if it is `.verified`, its `revocationDate` is nil, and** (for anything whose meaning depends on who bought it, such as a trial) **`ownershipType == .purchased`.** Family-shared transactions carry the organiser's `originalPurchaseDate`. `TransactionTriage` decides the first two and `StandingResolver.counts(_:in:)` the third. [review] ([the adapter](08-storekit-adapter.md))
- [ ] **A trial is dated by its own transaction's `originalPurchaseDate`.** It is then the same on every device, survives a reinstall and can't be edited. Buying the trial again returns the original transaction, so the trial carries on rather than restarting (§4). [review] ([trials](04-trials.md))
- [ ] **No trial start is kept in the keychain or in preferences.** It would be one trial per device instead of one per account. On macOS the file-based keychain also prompted for approval on every rebuilt binary, which froze launch and hung test runs. [ran]
- [ ] **The trial transaction's own date is preferred to `AppTransaction`**, which the package never reads. This avoids the class of sandbox-against-production `originalAppVersion` hazards. [review]
- [ ] **"Not answered yet" is a state of its own.** Until StoreKit has answered, the standing is `unknown`, which is not "free": `Standing.isKnown`, `ProductAccess.unknown`, `TrialStatus.unknown`. `knownStanding()` waits for the first answer. [ran] ([catalogue and standing](03-catalogue-and-standing.md#the-store-has-not-answered-yet))
- [ ] **What is owned is waited for, not the catalogue.** `Product.products(for:)` goes over the network, and offline it can take a long time to fail. `start()` reads ownership and does not load prices; `productLoad` is a separate state from whether the standing is known. [ran]
- [ ] **The time is passed in; the clock is never read inside a check.** `access(to:at:)`, `trial(_:at:)` and `TrialPeriod.isRunning(at:)` take the date, and the store takes a `TimeProviding`. This is what makes trial expiry testable. [review]
- [ ] **A fresh read is scheduled for the moment a trial ends.** Otherwise nothing observable changes when a trial expires while the app is running, and nothing locks until something unrelated redraws or the app relaunches. A read that lands early reschedules. [ran]

### Your app's responsibility

- [ ] **Keep no entitlement of your own either.** No cached "is Pro" flag, no local trial date. Derive your own policy from `standing.access(to:at:)` each time. [Apple]
- [ ] **Let nothing judge by the standing until it is known.** Gates, limits, paywalls and locks must all await `knownStanding()`. Otherwise a paying user meets the paywall, or sees locks, at every launch. While it is unknown, draw neither "Pro" nor "Free". [ran]
- [ ] **Pass the time into your own policy functions as well.** Something like `unlocksPro(at date:)`. [review]
- [ ] **A trial ends at an instant, so show the date and the time.** "Until 30 September" is wrong by evening for someone who started in the evening. The package gives `TrialPeriod.endsAt`; the formatting is yours. [review]
- [ ] **Call `refresh()` when the app becomes active.** The scheduled re-read waits on the continuous clock and does not notice the wall clock being changed.

## 4. Purchasing

### Handled by the package

- [ ] **`currentEntitlements` doesn't list a purchase the moment `purchase()` returns.** Under `SKTestSession` on macOS it appeared about a second later. Reading the list straight after the purchase finds nothing, so the unlock stays locked until the next launch and the Buy button looks broken. [ran] ([decisions](10-decisions.md))
    - The grant comes from the transaction `purchase()` returns, carrying its product ID and original purchase date: `PurchaseOutcome.purchased(OwnedProduct)`.
    - The grant is held until StoreKit lists the product *in a way that counts for this account* (a family member's copy of an unlock that ignores Family Sharing does not end the hold on one's own), until StoreKit withdraws it (a refund, for example), **or until a grace period ends** (`listingGrace`, 30 seconds by default), whichever is first. A refund that overtakes the listing is therefore not ignored for the rest of the session, and a grant the store never goes on to list lapses, so the listing stays the last word. [ran]
    - An earlier rule, "drop the held grant when StoreKit reports anything more about that product", was wrong: a stray update during the lag wiped a purchase made a moment before. [ran]
    - The same filter as §3 is applied to the purchase's own transaction, so a purchase that grants this account nothing is never held. It is returned as `PurchaseCompletion.notCounted`. [review]
- [ ] **`Transaction.updates` is listened to from launch, for the app's whole life.** It carries Ask to Buy approvals, purchases on other devices and refunds. It does not carry purchases made with `purchase()` in this process. [Apple] The listener starts with `start()`, which `.purchaseStore(_:)` calls.
    - **The stream carries the transaction's facts, not only a product ID**: `TransactionUpdate.granted(OwnedProduct)` or `.withdrawn(ProductID)`. An update for a grant arrives *before* the listing has it: when an approved Ask to Buy arrives, the listing at that instant is still empty, and has the product about half a second later. A listener that re-reads the listing on the update finds nothing, and has no reason ever to look again. A refund's update does not lag: the listing is already empty when it arrives. So a grant is held exactly as a purchase is, and a withdrawal drops the hold at once. [ran]
    - Verified transactions for catalogue products are finished. Unverified ones are not, because the App Store offers them again. [Apple] Transactions for products the catalogue does not list are left alone, for whoever owns them. ([the adapter](08-storekit-adapter.md))
- [ ] **The outcomes are told apart by type.** `PurchaseCompletion` has `.owned`, `.trialRunning`, `.trialUsed`, `.notCounted`, `.subscribed`, `.offerNotApplied`, `.planChangeScheduled`, `.pending` and `.cancelled`; what went wrong is a thrown `PurchaseError`. An unverified purchase is `PurchaseError.unverified` and is never a cancellation. A cancellation that arrives *thrown*, as `StoreKitError.userCancelled`, is still a cancellation. [review]
- [ ] **Errors carry no text.** `PurchaseError` is typed, and an unrecognised error crosses as the name of its type, because some StoreKit errors echo App Store account identifiers in `localizedDescription`. [review]
- [ ] **Buying an already-owned non-consumable returns the original transaction.** For a used trial the purchase returns `PurchaseCompletion.trialUsed(TrialPeriod)`, and `TrialStatus.used(TrialPeriod)` says when it ended. [ran]
- [ ] **Restore is `AppStore.sync()` followed by a fresh read.** `restorePurchases()` and `RestorePurchasesButton`. A restore that fails reads again and never downgrades. [Apple]
- [ ] **The purchase is given a presentation context.** SwiftUI's `@Environment(\.purchase)` is Apple's recommendation on every platform, and `PurchaseButton` passes it for you. Otherwise `PurchaseConfirmation.window(_:)` takes an `NSWindow` on macOS; on iOS the modern overload takes a `UIViewController` (iOS 18.2 and later), `.viewController(_:)`, and an older one a `UIScene`, `.scene(_:)`. [Apple] ([getting started](02-getting-started.md#say-where-the-payment-sheet-goes))

### Your app's responsibility

- [ ] **Say each outcome in words** (localised):
    - success: nothing, or close the paywall;
    - `.cancelled`: say nothing;
    - `.pending` (Ask to Buy): "waiting for approval", not a failure;
    - `.unverified`: "could not be verified; try Restore, contact support if charged". Never report it as cancelled, because someone who paid would be shown nothing;
    - `.productUnavailable`: "not available at the moment";
    - `.trialUsed`: when the trial ended. [review] ([getting started](02-getting-started.md#word-every-outcome))
- [ ] **Put a visible Restore Purchases button on the paywall and in settings.** App Review expects one. [Apple]
- [ ] **Never log or show `localizedDescription` of a StoreKit error in your own code.** [review]
- [ ] **Test the confirmation sheet with several windows or scenes open.** [check]
- [ ] **For in-app refund requests on iOS, use `Transaction.beginRefundRequest(in:)`** or SwiftUI's `refundRequestSheet`. The package does not wrap them. [Apple] [check]

## 5. Interface

### Handled by the package

- [ ] **A result goes back to the button that was pressed, and is published nowhere.** `PurchaseButton` and `RestorePurchasesButton` hand the result to a closure, and `PurchaseStateProviding` has no "last result" property. Both buttons disable themselves while a purchase or restore is under way. [review]
- [ ] **The trial's three states are supplied.** `TrialStatus` is `.available`, `.used(TrialPeriod)`, or one of `.running`, `.notOffered` and `.unknown`. [ran] ([trials](04-trials.md#trialstatus-and-the-three-things-an-interface-draws))

The package has no paywall, no wording and no layout.

### Your app's responsibility

- [ ] **Say why the paywall appeared.** Give the feature that stopped the person, not a generic pitch. List everything, with that feature first. [review]
- [ ] **Close the paywall when the standing turns to owned.**
- [ ] **On macOS, SwiftUI won't present a sheet over a sheet.** Inside sheets (export, history), offer Buy inline, together with the reason and any purchase failure, instead of raising the paywall. [review]
- [ ] **Show purchase failures where the button is, with room to be read.** A long message in a crowded footer squeezes and truncates its neighbours. [ran]
- [ ] **Give the trial button three states:** available (enabled); used (**disabled**, with "Your trial ended on … at …"); not offered (the unlock owned, trial running, or StoreKit hasn't answered). Hiding it once used leaves people wondering where it went. [ran]
- [ ] **Keep a result's alert with the button that was pressed, in local state.** A global flag watched by several views (paywall sheet, Settings, several windows) shows the alert several times at once. [review]
- [ ] **App Intents and Shortcuts can't show a paywall.** Throw a localised error whose message is the paywall's reason. [review]

## 6. Downgrades: trial ended, purchase refunded

### Handled by the package

- [ ] **A downgrade is noticed without a relaunch.** A refund arrives as `TransactionUpdate.withdrawn` and the standing is resolved again at once; a trial's end is a scheduled re-read. Either way `standing` changes, and what observes it redraws. [ran]
- [ ] **Opening can wait for the first answer.** `knownStanding()` exists for this, and is safe to call from a task that may be cancelled. [ran]

What a downgrade *does* is policy, and none of it is the package's.

### Your app's responsibility

- [ ] **Lock, don't delete.** Content beyond the free limit stays visible, marked locked (dimmed, with a padlock and "Available with Pro"), and opening it shows the paywall. Buying restores it exactly as it was. [ran]
- [ ] **Decide what stays unlocked by something the user can't change.** A first design used position in a reorderable list, so dragging any item to the top unlocked it. Use an **immutable "added order"**, set once on creation and persisted. [ran]
    - Give existing data this order **once**, on first load after the upgrade (in the list's current order), and write it back. [ran]
    - Assign the order **after any `await`** in the add path. Two concurrent adds numbered before a suspension got the same number, and the tie fell back to the reorderable order. [ran]
    - Removing an unlocked item frees its slot for the next-oldest item. Adding stays blocked while the count is at or over the limit. Remove-all-then-add-three works as the free tier intends. [ran]
- [ ] **Route every way of opening locked content through one check**, then add a **backstop at the point where resources are actually acquired**, so a new entry point that forgets the check fails closed. [ran]
    - The entry points to cover: UI selection, keyboard shortcuts, the switcher, "open in new window", deep links, Spotlight, the Finder service, App Intents, state restoration at launch, and step-next/previous (which should skip locked items rather than hit the paywall).
- [ ] **Make opening wait for the first answer** before deciding: `await knownStanding()`. A click during launch otherwise opens locked content, which is only shut again when the answer arrives. [ran]
- [ ] **A view on content that becomes locked** moves to unlocked content, or empties and explains why (and offers the unlock, not "add another"). Clear its state *before* the first `await`, so a switch that starts meanwhile isn't undone. Flush unsaved edits on the way out. [review]

## 7. Testing

### Handled by the package

- [ ] **The App Store is behind a protocol** (products, owned products, purchase, restore, an updates stream), five small ones joined as `StoreFront`, and the decision logic is tested against a fake. ([architecture](01-architecture.md))
- [ ] **The fake is as awkward as the real thing**, or it hides real bugs. `SimulatedStoreFront` ([the simulated store](06-simulated-store.md)):
    - lists a purchase **one read late**, as StoreKit does. The first version listed it at once and hid the lag bug; [ran]
    - answers a **cancelled task with nothing**, as StoreKit does; [ran]
    - returns the **original** date when an owned product is bought again;
    - has "earlier purchases" the device hasn't listed yet (another device, before a reinstall);
    - has `deliver` (a transaction arriving by itself) and `revoke` (a refund), both through the updates stream **with the transaction's facts**. A delivery is listed one read late too; a refund is not. The first version of `deliver` listed at once, and hid the bug in §4; [ran]
    - has a gate that holds "what is owned" shut, for "StoreKit hasn't answered yet" (`ownershipGate`);
    - has a gate that holds the catalogue shut, for "slow network" (`catalogueGate`);
    - has gates that hold a purchase and a restore open, for "the payment sheet is up" (`purchaseGate`, `restoreGate`);
    - approves an Ask to Buy only if one is pending, and as the purchase it would have been: for something already owned elsewhere, the original date; and declines one by announcing nothing, as StoreKit does;
    - answers a cancelled request for *products* with an empty list, as StoreKit does; [ran]
    - can end each product's purchase differently, list a purchase as unverified, and let the listing catch up with nobody reading it.
- [ ] **Each habit the fake imitates is measured against real StoreKit, per OS**, by a test that fails when StoreKit changes; the habits already differ between macOS 26.6 and the iOS 27 simulator. [ran] ([decisions](10-decisions.md))
- [ ] **What a test needs and an app does not is a product of its own** (`PurchaseTestKit`), and the simulator another (`PurchaseSimulator`), so that the one an app links is empty in release. [ran]
- [ ] **An app that links the test kit does not build**, in Debug or in Release, and `make demo` holds that true with an app that links it. [ran] ([decisions](10-decisions.md#d34-the-test-kit-reports-through-swift-testing-so-no-app-can-link-it))
- [ ] **An app imports nothing that is empty in release.** It reaches the simulator through names that exist in every build — `StoreLaunch.make`, `StoreLaunch.preview`, `PurchaseDebugPanel` — and never names it. ([decisions](10-decisions.md#d33-an-app-imports-nothing-that-is-empty-in-release))
- [ ] **The clock is injected.** `TimeProviding`, with `SystemClock` and `ManualClock`. Expiry is tested both with a manual clock (logic) and with a real sub-second interval (the scheduled re-read). ([trials](04-trials.md#testing-the-trial-ends-in-five-minutes))
- [ ] **Real StoreKit is probed from a hosted test** to learn what a given build actually receives: `StoreDiagnosing`, which `AppStoreFront` implements. That is how "debug builds get nothing" was found. [ran]
- [ ] **The package's own adapter is run end to end with `SKTestSession`**, in `Demo/Tests`, on the Mac and in an iOS simulator, including StoreKit's own errors (`setSimulatedError`), an unverified purchase, and a canary that fails if StoreKit ever starts answering a cancelled task. Faults that belong to one OS are recorded as known issues there. [ran] ([testing](05-testing.md))
- [ ] **The package's own tests run in release as far as they can**: everything that does not need the simulated store, which does not exist there, plus a few tests of `PurchaseStore` itself against a store front that lives in `Tests/` (`make release-tests`; 90 of 208 today), and **`make check` compiles the Demo with its hosted tests for the Mac and iOS, its UI tests, and the app once more in Release, linked**, since nothing else would notice an API change breaking them. [ran]

### Your app's responsibility

- [ ] **Host real-StoreKit tests in an app.** `SKTestSession` does not work in a package test target: under `swift test` every mutating call fails with `SKInternalErrorDomain Code=1`, and under `xcodebuild test` on a package scheme the product list comes back empty and purchases throw `notEntitled`. There is no app for StoreKit's test environment to attach to. [ran]
- [ ] **Run end-to-end tests with `SKTestSession` through the real `AppStoreFront`:** the catalogue matches the identifiers, the trial is free and not family-shareable, buying the trial starts it, and buying the unlock unlocks it. [ran]
    - A sandboxed test host can't read the repo: ship the `.storekit` file in the **test bundle's resources** and find it by `Bundle.allBundles` with extension `xctest`.
    - Begin every test with `resetToDefaultState()`, then `disableDialogs = true` and `clearTransactions()`; keep the session alive for the whole test, and run the suite serially. The environment is shared, and outlives the process. [ran]
    - Disarm a simulated error with `resetToDefaultState()`, not by passing nil: on macOS 26.6, nil for `.purchase` leaves every later purchase failing. [ran]
    - No StoreKit Configuration is needed on the Test action or the test plan: the session made in code loads the file. The scheme's setting belongs to Run. [Apple]
    - Keep the app's own store out of the way while it hosts tests: build none when `XCTestConfigurationFilePath` is in the environment. It listens for transactions too, and finishes the ones the tests are waiting to see.
- [ ] **Test StoreKit's own failures with `setSimulatedError`**: a load that fails, a purchase that is refused, a purchase that does not verify, a restore the App Store cannot be reached for. And what else the environment does cheaply: an interrupted purchase, a declined Ask to Buy. [ran]
- [ ] **Give `xcodebuild` a timeout.** It has been seen to finish a simulator run green and never exit. [ran]
- [ ] **Test a trial that is nearly over with a very short trial, and with a backdated purchase where the OS allows it.** Apple documents backdating (`.purchaseDate(_:)` with `buyProduct(identifier:options:)`), and it works in the iOS 27 simulator and on macOS 26.6 with Xcode 26.6. With Xcode 27.0 on macOS 26.6 `buyProduct` fails with `StoreKitError.unknown` and the option, through `product.purchase(options:)`, is ignored. [ran]
- [ ] **Test your own policy against the simulated store and a manual clock**: nothing locked and nothing offered before the store answers, the downgrade when a trial ends, the wording of each outcome. Give the model `any PurchaseStateProviding`, and have it ask `knownStanding()`.
- [ ] **Make every release build check itself.** A last Run Script phase on the app target fails any build not named `Debug…` — an archive included — that carries the simulator, and `release-check --app` adds the proof that its names would be found. ([release safety](07-release-safety.md#making-the-apps-check-automatic)) [ran]
- [ ] **Link `PurchaseTestKit` into test targets and never into the app.** An app that links it does not build: the test kit reports through Swift Testing, which only test targets can link. `swift package release-check --app` fails a release app that carries it anyway. [ran]
- [ ] **Remember that a TestFlight build is a Release build**: no simulated store, no scenarios, no debug panel. And hand out Release builds, not `Debug…` ones: a debug build honours `-PurchaseScenario`, by design.
- [ ] **Put whatever names the simulated store inside `#if DEBUG`.** It exists only there, so anything else fails the first Release build. For an app that is nothing, if it starts with `StoreLaunch.make` and previews with `StoreLaunch.preview`; for tests it matters only where they are also built for release. [ran]
- [ ] **Have every UI test assert a "simulated store" marker first.** In a build that cannot honour a scenario the app runs on the real store and nothing fails. [ran]
- [ ] **Test Family Sharing in the sandbox, with a Sandbox Test Family.** Xcode's environment cannot make a purchase arrive as a family member's; the simulated store can, and is the only automated way. [Apple]
- [ ] **Prove each regression test bites.** Put the old behaviour back and see the test fail, rather than trusting a green run.

## 8. Platform notes

### Handled by the package

- [ ] **An app using the package links in Release.** With Xcode 27, a package's public function returning `some View` that ends in `.task` does not, generic or otherwise: the SDK emits that `task` into its caller, and its opaque type leaks into the package's public signature with no descriptor to link against. `purchaseStore(_:)` keeps its task inside a view modifier, and `make check` links the Demo in Release. [ran] ([decisions](10-decisions.md))
- [ ] **One library for macOS and iOS.** AppKit and UIKit are kept out of the core entirely, and split behind `#if os(macOS)` / `#elseif canImport(UIKit)` in the adapter. **The iOS target is built in CI** (`make ios`, part of `make check`). A shared package elsewhere stopped compiling for iOS for eleven days because nothing built it. [ran]
- [ ] **Scene-based presentation on iOS and iPadOS** (see §4): `PurchaseButton` passes SwiftUI's `PurchaseAction`, which knows its own scene. [Apple]

### Your app's responsibility

- [ ] **macOS sandbox:** StoreKit transactions run in a system process, so the purchase flow needs no network entitlement of its own. (The app this was checked in ships `network.client` for another reason, so this wasn't isolated here.) [check]
- [ ] **Build your own iOS target in CI** as well, if the app has one. [ran]
- [ ] **Test purchases with several windows open** on iOS, iPadOS and macOS. [check]
- [ ] **A Mac build sold outside the Mac App Store has no StoreKit behind it.** Give it `EverythingOwnedStoreFront` at the composition root, or licensing of your own. [Apple] ([App Store Connect](09-app-store-connect.md#macos))

## 9. Support and release

### Handled by the package

Nothing in this section is the package's.

### Your app's responsibility

- [ ] **Changing where a trial's start comes from changes people's trials.** Anyone who had been given a fresh local trial by reinstalling will see it end on the App Store's date, possibly at once. Put that in the release notes and brief support. ([migrating](12-migrating-an-existing-app.md#changing-where-a-trials-start-comes-from-changes-peoples-trials))
- [ ] **Downgrade behaviour is a product decision.** Choose between lock, remove and keep deliberately, and write the choice down. Keeping everything unlocked turns a trial into permanent extras.

## 10. Subscriptions

### Handled by the package

- [ ] **Access is Apple's rule, decided by the status.** Subscribed and in a grace period give access; billing retry, expired and revoked do not, and are reported. The status decides and the listing stands in only when no status can be read, because the iOS simulator lists a subscription in billing retry. [ran] ([subscriptions](15-subscriptions.md#access-is-apples-rule))
- [ ] **A subscriber is not locked out at a renewal.** StoreKit says, for a moment at the end of every period, that the subscription has expired; a lapse there is believed only when it lasts (`renewalGrace`), and the renewal, which arrives on the updates stream first, is held. [ran] ([D36](10-decisions.md#d36-a-lapse-at-a-periods-end-is-believed-only-when-it-lasts))
- [ ] **A downgrade is not reported as bought.** StoreKit returns the plan already held; the completion is `.planChangeScheduled(to:at:)`. [ran]
- [ ] **Statuses are read in a task nobody cancels**, since a cancelled read answers "never subscribed". [ran]
- [ ] **Renewals missed while the app was closed are judged by date**, not by the order they arrive in — newest first. [ran]
- [ ] **The group and level in the catalogue are checked against the `.storekit` file.** Level 1 is the highest. [ran]

### Your app's responsibility

- [ ] **Turn on the billing grace period in App Store Connect**, and say what a person in it should do: their payment failed, and they keep access until it ends. [Apple] ([App Store Connect](09-app-store-connect.md#subscriptions))
- [ ] **Decide whether billing retry keeps access.** The package says no, as Apple does; leniency is yours to write. ([subscriptions](15-subscriptions.md#access-is-apples-rule))
- [ ] **Call `refresh()` when the app becomes active.** A cancellation made elsewhere, and an expiry, send nothing. [ran]
- [ ] **Hand every purchase made in Apple's own views to the store** — `ProductView`, `StoreView`, `SubscriptionStoreView` — with `store.takePurchase(result, of: product)` in `.onInAppPurchaseCompletion`. In the iOS simulator an unlock bought in `ProductView` is announced nowhere. [ran] ([D45](10-decisions.md#d45-a-purchase-made-in-apples-own-views-is-handed-to-the-store))
- [ ] **Offer Apple's page for managing the subscription** — `ManageSubscriptionsButton`, a link on macOS, where there is no sheet. [Apple]
- [ ] **Word the paywall as App Review asks**: the plan, its length, the full renewal price as the most prominent price, and links to the terms and privacy policy. [Apple]
- [ ] **Try Family Sharing and a renewal while the app is closed in the sandbox**, by hand: Xcode's environment can make neither. [Apple]

## 11. Subscription offers

### Handled by the package

- [ ] **An offer's terms are the store's.** `StoreProduct.subscription` carries each offer's price, periods and payment mode as StoreKit states them for the storefront. [ran] ([offers](16-offers.md#terms-come-from-the-product))
- [ ] **Introductory eligibility has four states, and "unknown" shows the regular price.** StoreKit's own answer keeps its first value for the life of the process; the group's transactions, and what the store has seen, say when the offer is used. [ran] ([D46](10-decisions.md#d46-introductory-eligibility-has-four-states-and-a-used-offer-is-known-from-what-was-seen))
- [ ] **Win-back offers are Apple's to allow**: the eligible offers on the account's own status, in Apple's order, with their terms. [ran] ([offers](16-offers.md#win-back-offers))
- [ ] **A promotional offer is never attempted without a signature**, and never asked of the signer for someone who has never subscribed in the group. [review] ([D48](10-decisions.md#d48-the-package-never-signs-a-signer-the-app-supplies-is-asked-only-when-it-must-be))
- [ ] **An offer that was not applied is said**, as `.offerNotApplied`: StoreKit let an override through at the full price and said nothing. [ran] ([D47](10-decisions.md#d47-an-offer-that-was-not-applied-is-said))
- [ ] **A redeemed offer code reaches the store**, from the updates stream, or from the 27 SDK's sheet through `takeRedemption(_:)`. [ran]

### Your app's responsibility

- [ ] **Show an offer's terms from the store, never from constants**, and the regular price whenever the introductory offer is `unknown`. [Apple]
- [ ] **Word the offer as App Review asks**: what is charged and for how long, then the full renewal price. [Apple]
- [ ] **Keep the In-App Purchase key on your server**, and sign there with Apple's App Store Server Library; implement `OfferSigning` to ask it. [Apple] ([offers](16-offers.md#promotional-offers-and-a-server-that-signs))
- [ ] **Decide who gets which promotional offer.** That is policy, and it is yours.
- [ ] **Check the offers your code names against the `.storekit` file**: `expectNoProblems(against:offers:)`. [ran]
- [ ] **Try a promotional offer in the sandbox, by hand**, signed by your server: Xcode's environment cannot check a real key's signature. [ran]

## 12. Non-renewing subscriptions, commitments, and what arrives from outside

### Handled by the package

- [ ] **A non-renewing subscription's end is the catalogue's**, and every purchase counts: the listing keeps every one, and StoreKit gives them no end. [ran] ([D52](10-decisions.md#d52-a-non-renewing-subscriptions-end-is-the-catalogues-and-every-purchase-counts))
- [ ] **A purchase handed back that was already counted is not reported as bought.** [ran]
- [ ] **On a 12-month commitment, "will it end" is read from the commitment**, not from `willRenew`, which stays true after a cancellation. [Apple] ([D54](10-decisions.md#d54-on-a-12-month-commitment-whether-it-will-renew-and-whether-it-will-end-are-two-facts))
- [ ] **A purchase asked for on the App Store waits for the app**, in `requestedPurchases`: nothing is bought until the app buys it. [Apple]

### Your app's responsibility

- [ ] **Say how long a non-renewing subscription lasts, and whether purchases add up** — `lasting:` and `stacking:` in the catalogue — and say it on the paywall.
- [ ] **Show a 12-month commitment's monthly price and what the commitment comes to**, as App Review asks. [Apple]
- [ ] **Act on `requestedPurchases`**: buy with the request's options, or let it go. [Apple]
- [ ] **Decide when Apple's messages may be shown** (`storeMessages(deferredWhile:)`), on iOS. [Apple]
- [ ] **In the sandbox, by hand**: a promoted purchase tapped on the App Store, the monthly plan in a storefront that offers it, a price rise shown as a message, and a subscription bundle. Xcode's environment produces none of them. [ran]

## 13. The shape of the library

The package's targets, layers, protocols and the reasons behind them are in [architecture](01-architecture.md) and [decisions](10-decisions.md). To move an app that already has hand-written StoreKit code onto it, see [migrating an existing app](12-migrating-an-existing-app.md).
