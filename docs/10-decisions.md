# Decisions

Why the package is the way it is. Each entry says what was decided, why, and how the reason is known:

- **[ran]** reproduced by running something: a spike in [`spike/`](../spike/README.md), the hosted suite in `Demo/`, or a test in this package. Run on macOS 26.6 with Xcode 27.0 (27A266a) and Swift 6.4, on 18 September 2026; where it says iOS, in the iOS 27.0 simulator.
- **[review]** a defect found in existing hand-written StoreKit code, and confirmed against it.
- **[Apple]** from Apple's documentation or SDK interfaces.
- **[check]** believed, and not verified here.

## D1. Real StoreKit is tested from a host app

`SKTestSession` does not work in a package test target. Under `swift test` every mutating call fails with `SKInternalErrorDomain Code=1` ("Error saving configuration file"); under `xcodebuild test` on the package scheme the product list comes back empty and purchases throw `notEntitled`. There is no app for StoreKit's test environment to attach to. **[ran]** Apple documents nothing about where `SKTestSession` works — no page mentions a host application, logic tests or package targets — so this is measurement and nothing else, and worth measuring again on a new Xcode.

So the package is built so that almost nothing needs it. Core imports no StoreKit; the adapter's decisions sit above a gateway a test can fake; and the dozen lines that are left — copying a transaction's fields — are exercised by `Demo/Tests`, a test bundle hosted by an app (`make integration`).

## D2. Ownership is never read in a task something else can cancel

A cancelled task reads **0 of 1** entitlements from `Transaction.currentEntitlements`. **[ran]** Nothing at all is indistinguishable from owning nothing, and SwiftUI cancels `.task` whenever a view goes away, so a paying customer who closes a sheet at the wrong moment is told they own nothing.

`PurchaseStore` reads ownership in an unstructured task of its own, single-flight, which a cancelled caller simply awaits. None of the hand-written implementations reviewed guarded against this. **[review]** The simulated store answers a cancelled task with nothing too, and `Demo/Tests` keeps a canary that will fail if Apple ever changes the behaviour.

## D3. A grant is believed until the store lists it

Straight after `purchase()` returns, `currentEntitlements` is empty; the purchase is listed about a second later. **[ran]** Read straight back, the unlock stays locked until the next launch and the Buy button appears to have done nothing. So the returned transaction is held and vouched for until the listing takes over.

## D4. The updates stream carries facts, not a signal

The first design announced only *which* product had changed, and the listener re-read the listing. Measured: when an approved Ask to Buy arrives on `Transaction.updates`, **the listing at that instant is still empty**, and has the product about half a second later. A refund does not lag: at the instant its update arrives the listing is already empty. **[ran]**

A listener that re-reads on the update therefore finds nothing, and has no reason ever to look again. This was found by the hosted suite, not by the unit tests, because the simulated store's `deliver` listed at once — a fake politer than the real thing. Both were changed: `TransactionObserving` yields `TransactionUpdate.granted(OwnedProduct)` or `.withdrawn(ProductID)`, a grant is held exactly as a purchase is, and the simulated store lists a delivery one read late.

An earlier rule, "drop the held purchase when the store says anything more about that product", was removed with it: a stray update during the lag wiped a purchase made a moment before. **[ran]**

## D5. A held grant lapses

A hold ends when the store lists the product and the listing counts ([D19](#d19-a-hold-ends-when-the-listing-counts-the-product-not-when-it-names-it)) — a subscription's, when its status has caught up ([D36](#d36-a-lapse-at-a-periods-end-is-believed-only-when-it-lasts)) — when the store withdraws it, or after `listingGrace` (30 seconds by default), whichever is first. Without the limit, anything announced and never listed would be vouched for all session; the revocation of a family-shared purchase has been reported to arrive without a revocation date, looking like a grant. **[check]** The listing stays the last word. The default is generous because lapsing early re-locks something just bought, and the listing was measured to catch up within a second.

## D6. What is finished, and what is left alone

| Transaction | Finished? | Why |
|---|---|---|
| Verified, in the catalogue, standing | Yes | Dealt with. |
| Verified, in the catalogue, revoked | Yes | Dealt with; counts for nothing. |
| Unverified | **No** | Nothing was delivered for it, and the store offers an unfinished transaction again. Apple's samples do the same without saying so. **[Apple]** |
| For a product not in the catalogue | **No** | Finishing removes it from the redelivery queue for good, so its real owner would never see it. One reviewed implementation finished every transaction it saw. **[review]** |
| Anything met while *reading* entitlements | Never | Reading has no side effects. Unfinished ones reach the updates stream, which is listening from launch. |

Apple documents neither the unverified nor the unknown-product case, so these are this package's decisions. **[Apple]**

## D7. The whole listing is read

One reviewed implementation answered on the first matching entitlement and "free" otherwise. It held for exactly as long as there was one product. **[review]** The adapter's first test for this did not catch the mistake either, because its listing had only one countable product; it was caught by restoring the old behaviour and watching the test pass. See D14.

## D8. "Not answered yet" is a state, and ownership does not wait for prices

Until the store has answered, the standing is `unknown`, which is not `none`. Everything that judges by it should await `knownStanding()`; otherwise a paying customer meets the paywall at every launch. **[ran]** Prices are a separate load: `Product.products(for:)` goes over the network and offline can take a long time to fail, whereas ownership is answered from StoreKit's cache. One reviewed implementation returned before reading ownership when the catalogue failed to load, locking owners out offline. **[review]**

## D9. Nothing downgrades on a failure

A thrown purchase leaves the standing unread and unwritten. A thrown restore reads again and rethrows. A failed catalogue reload keeps the last good prices. One reviewed implementation replaced a known entitlement with an error state when `AppStore.sync()` was cancelled. **[review]**

## D10. Errors carry no text

Some StoreKit errors echo App Store account identifiers in `localizedDescription`. **[review]** `PurchaseError` is a typed enum with no strings, and an error the package does not recognise crosses as the name of its type. Cancellation arrives two ways — as `PurchaseResult.userCancelled` and as a thrown `StoreKitError.userCancelled` — and both map to a cancellation. **[Apple]**

## D11. Commands return their result; nothing shared holds it

A result kept in one flag watched by several views — a paywall, a settings pane, a second window — is announced by all of them at once. **[review]** Commands return a `PurchaseCompletion` or throw a `PurchaseError` to whoever asked. The shared store holds only global facts.

## D12. A trial is a free non-consumable, dated by the App Store

The shape guideline 3.1.1 accepts for an app without a subscription. **[Apple]** Its start is the transaction's `originalPurchaseDate`, which the App Store keeps against the account: the same on every device, surviving a reinstall, and uneditable. **[Apple]** Bought again, the original transaction comes back, original date and all, so the trial continues rather than restarts. **[ran]** A trial never honours Family Sharing, with no option to make it: a shared transaction carries the purchaser's dates. **[review]**

Backdating a non-consumable is documented — `Product.PurchaseOption.purchaseDate(_:)`, with `SKTestSession.buyProduct(identifier:options:)` **[Apple]** — and whether it works depends on the OS *and the tools*. With Xcode 27.0 on macOS 26.6 `buyProduct` fails with `StoreKitError.unknown` (which Xcode 27's release notes list as fixed), and `product.purchase(options: [.purchaseDate(…)])` succeeds and ignores the date. With Xcode 26.6 on the same macOS, and in the iOS 27.0 simulator, both work. **[ran]** The first of those was found by the hosted suite's first run on a hosted runner, where a test written to expect the fault failed to find it. So a trial's length is a `Duration`, and the hosted suite does both: a whole trial in a second and a half everywhere, and a real fortnight with five minutes left where the purchase can be backdated, recorded as a known issue where it cannot.

## D13. The simulated store exists only in DEBUG builds

It hands out purchases for nothing, and on macOS anyone can pass launch arguments to a shipped app. Absent is safer than disabled, so the files are wrapped whole in `#if DEBUG`, and `swift package release-check` proves the symbols are missing from a release build ([release safety](07-release-safety.md)). The package only *parses* a scenario; whether to honour one is the app's decision at its composition root.

Xcode gives a package target `DEBUG` by the build configuration's **name**, not its type: `Debug-Screenshots` gets it, `Screenshots` does not, and an app's own compilation conditions never reach a package. **[ran]** A package trait was considered as an opt-in and rejected: Xcode applies a trait per package reference, so it would apply to Release as well.

## D14. Every regression test is proven to bite

A test that has only ever passed proves little. For each behaviour here that came from a real defect, the old behaviour was put back and the test watched to fail. Three times this found a check that did not: the whole-listing test (D7); the first release check, which searched a directory the build system had stopped using; and the second, which chose its files by the word `Release` in their path, found none under SwiftPM's older layout, and had its control satisfied by the word `Debug` in `PurchaseDebugUI`. **[ran]**

The release check is now a package plugin that is *told* what each configuration built, with a control on the release search as well as the debug one and on every name it looks for, and it was made to fail both ways before it was trusted ([release safety](07-release-safety.md)). The fixes that followed the first review were made the same way round: the test first, watched to fail, then the change. **[ran]**

## D15. One Core target, with checked layers

Splitting the domain into its own target would make the compiler enforce the dependency rule, at the cost of two imports in every file of every app. The layers are named in each file's banner and checked by `ci/layers.sh` instead.

## D16. `PurchaseAction` is imported by name

`PurchaseAction` and `@Environment(\.purchase)` live in `_StoreKit_SwiftUI`, an overlay that Xcode loads unasked when a file imports both StoreKit and SwiftUI, and that SwiftPM does not. **[ran]** The two files that need it import it explicitly.

## D17. No SDK-27-only symbols

`StoreKitError.invalidPresentationContext` arrived with the 27 SDK and is matched by name, `Transaction.OwnershipType.assigned` likewise by its raw value (the name is new; the value is back-deployed), and the two error switches use a plain `default` rather than `@unknown default`, which would warn on 27 about a case that cannot be spelt on 26. The package builds with either: it is written with Xcode 27, and CI builds and tests it with Xcode 26.6. **[ran]** That is worth having, because the machine it is written on has only the newer SDK and cannot find such a fault: the first hosted run failed on `.assigned` within a minute. The two tests that spell the new names are behind `#if canImport(StoreKit, _version: 816)`, and are absent there.

## D18. The `.storekit` format is read leniently

Apple has never documented it, and Xcode has written schema versions 3.0, 4.0 and 6.x. `StoreKitConfiguration` reads the keys it needs, ignores the rest, and looks for products in every section, so an identifier hiding under `subscriptionGroups` is still seen. A hand-written version 4.0 file loads in `SKTestSession` and sells its products. **[ran]** The 3.0 and 4.0 fixtures follow files Xcode wrote; the 6.x fixture was composed by hand from the newer root keys, and has not been checked against a file written by Xcode 27. **[check]**

A price is read only if the whole string is a plain number. `Decimal(string:)` reads `"0,99"` as 0, which would let a paid trial pass as free.

## D19. A hold ends when the listing *counts* the product, not when it names it

A held grant (D3) was let go as soon as the listing had the same identifier. But a listing can have a product and not count it: a family member's copy of an unlock whose entry ignores Family Sharing, or a shared trial. An account with one of those that then bought its own had the purchase let go at the first read — the listing "had it" — while the resolver refused the shared copy, and with no hold left nothing scheduled another look. Buy did nothing until the next launch, which is the defect the hold exists to prevent. **[ran]**

`PurchaseStore` now settles holds against what the listing has *and the resolver counts*. One rule decides what counts, and it is asked in both places.

## D20. Prices load single-flight too, in a task nobody cancels

`loadProducts()` was the one command still made in its caller's task, with nothing to order two of them. Two defects followed. Two loads finish in whichever order the network likes and the last to finish won, so a first load timing out after a retry had succeeded left "could not load" over prices that were there. **[ran]** And SwiftUI cancels `.task` whenever a view goes away; a cancelled request comes back from the adapter as a failure, and the state is shared, so one paywall closing at the wrong moment told every view the store was broken. **[ran]**

It is now single-flight in an unstructured task, as resolving is (D2), with one difference: a caller arriving mid-load *joins* it rather than being given a fresh one. Prices asked for a moment ago are the prices; what is owned may just have changed. What StoreKit answers to a cancelled `Product.products(for:)` has since been measured, and it is the worse of the two possibilities: not an error but **an empty list**, 0 of 2, on the Mac and on iOS **[ran]** — which reads as a store that sells this build nothing (D26).

## D21. A result StoreKit adds later is a failure, never a cancellation

`Product.PurchaseResult` is not frozen. An unknown case used to be reported as `userCancelled`, and a cancellation is answered with silence — the wrong answer to someone a future kind of result may have charged (the same reasoning as `unverified`, D6). It now crosses the gateway as `unrecognised` and is thrown as `unknown(typeName: "Product.PurchaseResult")`, so it is *said*, and Restore Purchases is what finds out.

## D22. The simulated store is gated by DEBUG, not moved to a target of its own

The alternative is a separate product, linked only where it is wanted and with no `#if` in it. For unit tests that is already how things are: the test target links `PurchaseTestKit`, the app does not, and nothing ships. But the debug panel, scenarios and previews need the simulated store *inside the app*, and Xcode cannot link a package product for one build configuration and not another. A separate product would make "is a purchase simulator in the release build?" depend on which targets someone remembered to link, and on a dedicated app target kept in step with the real one. `#if DEBUG` makes it something the compiler decides, it is Apple's own pattern for test-environment code **[Apple]**, and a simulator that shipped switched off would be a hidden feature under guideline 2.3.1(a).

The gate has three costs, and each is paid for rather than denied:

- **Whatever names the simulated store must itself be under `#if DEBUG`**, or the first Release build fails. (That was a test, a preview or a composition root; since D33 an app has no need to name it, and it is a test.) This package's own suite was not, and did not compile in release **[ran]**; it is now, `make check` runs it in release, and the rule is stated where a reader meets the type ([testing](05-testing.md#a-test-imports-the-test-kit-and-an-app-cannot-link-it)).
- **A scenario the build cannot honour is silent.** A UI test run in a Release configuration launches the real store and nothing fails. Hence the "Simulated store" marker, asserted first ([the simulated store](06-simulated-store.md#ui-tests-and-screenshots)).
- **A package gets `DEBUG` by the configuration's name** (D13), by a heuristic Apple does not document. So the release check also reads a built app, not only the package (D27).
- **A TestFlight build is a Release build.** Testers get no simulated store, no scenarios and no debug panel; and a `Debug…` build handed out ad hoc can be unlocked by an argument, by design. Both are now said where a reader meets them ([release safety](07-release-safety.md)).
- **Xcode links a package product into every configuration of a target or none**, so whatever shares a module with the simulated store and is not behind the guard is in every app that ships. There was such a thing — a manual clock, a gate, a `.storekit` reader — and there is not any more (D27, D33).

## D23. Every hosted test resets StoreKit's test environment, and never disarms with nil

There is one test environment, every `SKTestSession` shares it **[Apple]**, and it outlives the process: an error armed by one run was still armed in the next. **[ran]** So each hosted test begins with `resetToDefaultState()`, which Apple recommends and the suite did not do; its Ask to Buy test switched the setting off again on its last line, which a failure half way would never have reached.

`resetToDefaultState()` rather than disarming what was armed, because on macOS 26.6 `setSimulatedError(nil, forAPI: .purchase)` — the documented way to disarm — leaves every later purchase throwing `StoreKitError.unknown`. **[ran]** That fault also produced a false measurement while this was being worked out: a simulated verification failure appeared to *throw*, when in truth it returns an unverified transaction and the throw came from the nil a line earlier. One question per clean environment ([spikes](../spike/README.md)).

## D24. The simulated store can hold a purchase open

The payment sheet being up is the state of a purchase a person looks at for longest, and the one in which a second tap or a Buy button that was never disabled does its damage. It could not be held: this package's own test of "one purchase at a time" held the *ownership* gate instead and caught the purchase in the read that follows it. `purchaseGate` and `restoreGate` hold the thing itself, `purchase=held` and `restore=held` say so in a scenario, and what the purchase comes to is decided when the gate opens, so a test can have the person back out.

## D25. `.task` lives in a view modifier, because otherwise an app does not link in Release

`purchaseStore(_:)` used to end in `.task { … }` and return `some View`. With Xcode 27, an app using it built and ran in Debug and **failed to link in Release**: "Undefined symbols … opaque type descriptor for … `View.task(name:priority:file:line:_:)`". **[ran]**

In the 27 SDK that overload of `task` is emitted into whoever calls it, so the opaque type it returns has no descriptor in SwiftUI itself. Written straight into a public function that returns `some View`, the type becomes part of this module's public signature; the app refers to its descriptor, and nothing defines it. Measured across a module boundary with `swift build -c release`: a method with no parameters, one taking an existential, one taking `some P`, and a free function **all fail to link**; the same task inside a `ViewModifier` links; everything links in Debug. **[ran]** (A first reproduction appeared to show that only the generic form failed. It was wrong, and is why this entry was rewritten: the shapes were not compared under one driver.) Nothing here noticed, because no check linked the package into an optimised app, which is exactly what an archive is.

The task is now inside a private `ViewModifier`, so the type an app sees is `ModifiedContent`, and `make demo` (part of `make check`) builds the Demo in Release and links it. The same trap is open to any package with a public function that returns `some View` and ends in `.task`.

## D26. Products, too, are asked for in a task nobody cancels — in the adapter

D2 is about what is owned. The same fault exists for what is for sale, and was found later because it was assumed away: D20 took it that a cancelled request for products *throws*. It does not. **Real StoreKit answers a cancelled `Product.products(for:)` with an empty list** — measured with controls either side, 2 then 0 then 2, on macOS 26.6 and in the iOS 27.0 simulator **[ran]** — and an empty list is an *answer*: the store sells this build nothing. `PurchaseStore.loadProducts()` was already safe (D20). `AppStoreFront.products()` and `diagnose()` are public and were not: `diagnose()` asked from a cancelled task advised attaching a `.storekit` file to a scheme that had one.

Both now ask from a task of their own. A cancellation that reaches the adapter as a *thrown* error is a failure, never an empty catalogue; a test pins that, because the branch that does it had none and a mutant that returned `[]` there survived the whole suite. The simulated store answers a cancelled request for products with nothing too, and `Demo/Tests` has the canary.

## D27. The test kit is two modules, and the release check reads apps

`PurchaseTestKit` held the simulated store, guarded, and beside it what a test needs — a manual clock, a wait, a recording logger, the `.storekit` reader — unguarded, because it grants nothing and tests need it in every configuration. But an app links `PurchaseTestKit` to have a debug panel, Xcode links it in Release as well, and a Release build of the Demo carried 115 symbols of `ManualClock` it never called. **[ran]** Harmless, and still test scaffolding in a shipped app, and a standing exception to "absent, not disabled".

So the two halves became two modules: the guarded one, which an app links, and the unguarded one, which test targets link and apps do not — `AnswerGate` going with the guarded half, since it belongs to the store whose answers it holds. The dependency runs from the unguarded module to the guarded one and not back, so the module an app links depends on nothing that is not behind the guard. (They were called `PurchaseTestKit` and `PurchaseTestSupport` then. D33 kept the split and changed the names, and who imports what.) `EverythingOwnedStoreFront` went to `PurchaseDirectDistribution` for the same reason from the other side: every App Store build was carrying a store in which everything is owned.

That is what lets the release check ask a stronger question. It was a denylist of three type names; it is now **"no symbol mentions either guarded module"**, which a new granting type under a new name cannot get past. And it asks it of a built app as well as of the package, because what ships is Xcode's Release build, where whether the package got `DEBUG` hangs on a heuristic over the configuration's name — the one link a check of SwiftPM's build cannot test.

## D28. The simulated store's habits are per OS, and each is held to the real thing

A fake is only as good as the evidence that the real thing still behaves so. One habit had a canary; the rest were asserted **[ran]** on the strength of a spike run once, and stated as properties of StoreKit. They are not: **a purchase is listed about a second late on macOS 26.6 and at once in the iOS 27.0 simulator**, and an approved Ask to Buy arrives before the listing has it on the one — usually: it is a race, which this Mac loses every time and a slower hosted runner was seen to win — and not on the other. **[ran]**

Each habit now has a test in `Demo/Tests` that measures it against real StoreKit and compares it with what is written down, per OS — so StoreKit changing fails a test rather than letting the fake drift — and the table in [the simulated store](06-simulated-store.md#a-fake-not-a-stub) has a column per OS and says which rows rest on Apple's word or on nothing. Faults that belong to one environment are known issues there, both ways about: two on macOS 26.6 that the 27 releases fixed (D12, D23), and two in the iOS 27.0 simulator that the Mac does not have — a *declined* Ask to Buy delivered as a purchase, and an interrupted purchase that throws.

The fake keeps the awkward behaviour as its default. An app that is right when the listing lags is right when it does not.

## D29. What was left unfinished is asked for, not waited for

Apple says the updates sequence hands over unfinished transactions once, as the app launches. **[Apple]** `PurchaseStore` starts listening with its first command and not with the process, and a listener started a moment after an unfinished purchase was handed nothing in six seconds while `Transaction.unfinished` still held it. **[ran]** So the adapter reads `Transaction.unfinished` once, after subscribing, and treats what it finds as it treats an arrival. One that turns up both ways is finished twice and announced twice, which costs nothing.

This is pinned against the fake gateway and **not** against real StoreKit, and the record should say why: on macOS 26.6 an unfinished purchase appears in `Transaction.unfinished` half a second after `purchase()` returns and is gone again, unfinished by anybody, a second later. **[ran]** A test built on that would be a test of the test environment. **[check]** what production does.

## D30. The real-StoreKit lane runs nightly, and gates nothing

Out of CI altogether, it ran "by hand, before a release" — and it is where every claim about StoreKit's behaviour lives. As a gate on pull requests it would fail for reasons of its own — the runner's Xcode, a race — often enough to be ignored. So it runs nightly and on request, non-blocking, with one retry, a timeout — `xcodebuild` was seen to finish a simulator run green and never exit **[ran]** — the result bundle kept, and a red night opening an issue. Its first run, on a hosted runner with an older Xcode, passed every test that touches StoreKit and failed two that encoded this package's beliefs about it (D12, D28) — which is the argument for the lane, made by the lane. **[ran]**

## D31. Mutation found four guarantees with no test, and D14 now means it

D14 says every regression test is proven to bite, and those were: put back, the old behaviour fails them. But a review mutated the code rather than reverting fixes, and four documented guarantees turned out never to have had a test at all — the re-run that gives a late caller a fresh read, the re-read after a *failed* restore (D9), the adapter's handling of a cancelled products request, and `purchase()` starting the listener. Each has one now, watched to fail against its mutant. **[ran]** The lesson is about where to look: "does the regression test bite" finds weak tests, and only "does the suite notice this line changing" finds missing ones.

## D32. What the first real integration asked of the package

The app this package came out of was moved onto it, and then reviewed. Nothing was lost in the move; what the review found was what a real app has to write, or work round, that the package could have done.

- **A read that finds nothing new is not published.** An app reads again whenever it becomes active and whenever a settings pane opens, and `standing` was assigned every time — a new value, because `asOf` had moved — which redrew every lock on a rail and every gate, for nothing. It is now published only when it *says* something different: what is held, or what that amounts to. A trial running out is the one case where nothing held has changed and everything has, and is published. **[ran]** `asOf` is therefore "when it last read differently", not "when it was last asked".
- **`ProductAccess.isGranted`, a `Bool?`.** Every app derives "owned or on trial", and D8's point is that the derivation must not lose `unknown`. An optional keeps it: it cannot be tested with `if` until somebody has decided what nil means.
- **The store's clock is public.** The app kept a clock of its own beside the store's, to ask `access(to:at:)` what is true *now*; under a manual clock in a test those are two clocks.
- **`loadProductsIfNeeded()`.** `loadProducts()` goes to the network every time, which is right for Retry and wrong for a paywall opening and for a second scene.
- **`PurchaseStore.diagnose()`.** Made in one line, the store was the only thing the app kept, and the front — the only thing that could say what the build receives — was gone.
- **`SimulatedStoreFront(catalogue:owned:…)` and `Behaviour(purchase:…)`.** The app's tests wrote both as conveniences of their own, as every app's would.
- **Said, rather than built:** what `alreadyInProgress` should be worded as (nothing; and Restore should be disabled while busy, as Buy is); that a paywall bound to app-wide state comes up in every window, so a shared notice shows N times ([migrating](12-migrating-an-existing-app.md)); and that before 1.0 the pin should be up to the next *minor*.

## D33. An app imports nothing that is empty in release

D22 and D27 left an app writing this, at its composition root, round its debug panel and round every preview:

```swift
#if DEBUG
import PurchaseTestKit
#endif
```

— or writing the import bare, which compiles, and imports a module with nothing in it. The first real integration (D32), which has neither a panel nor a scenario yet, wrote `#if DEBUG` seven times in its tests, two of them round an import. **[ran]** And the objection that settled it was not the count: **a module that is empty in the build that ships is not a thing to import.** Nobody imports `StoreKitTest` into an app, and `Combine` has no release build in which it is hollow. The import was a symptom — the app was being asked to *name the simulator*, and everything else followed from that.

So an app no longer names it. What an app needs of the simulator is three things, and each is now something that exists in every build and does the dull thing in a release one:

- **`StoreLaunch.make(catalogue:)`**, in `PurchaseLaunch`: the composition root. Live, unless this is a debug build launched with a scenario. In a release build there is no branch to take, and no mention of the simulator to take it to.
- **`StoreLaunch.preview(catalogue:scenario:)`**: a preview's store, arranged by a scenario's *text* — so a preview, which is compiled into the archive too, names nothing that is not there.
- **`PurchaseDebugPanel(launch)`**, with `isAvailable`: a view that is the panel in a debug build and `EmptyView` in a release one. The one `#if` left is round a `Window` scene, because a scene cannot be conditional, and it is the app's own `#if`, round the app's own window.

The simulator is a module of its own, `PurchaseSimulator`, guarded whole as before; `PurchaseLaunch` and `PurchaseDebugUI` depend on it, so an app *links* it and never *imports* it. **`PurchaseTestKit` is now what its name says and only that** — what a test imports: the simulator re-exported, beside the manual clock, the waits, the recording logger and the `.storekit` reader. One import for a test, where there were two.

What was weighed and not done:

- **`@_spi(Testing)` on the test helpers.** SPI decides who can *see* a declaration; it has nothing to say about whether it is *linked*, which is D27's whole complaint. It is also an underscored attribute Apple does not document. The helpers are kept out of apps the dull way: a module apps do not link, and a check that they did not.
- **Link the simulator for debug only.** SwiftPM's target conditions are platforms and traits; there is no configuration. **[ran]** Xcode links a package product into every configuration of a target or none. A trait would make "is the simulator in this build?" depend on how the package was resolved rather than on what is being built.
- **A second app target for debugging**, linking what the shipping target does not. Honest, and it is D22's alternative again: two targets kept in step by hand, and the one that is tested is not the one that ships.

The release check follows. `--app` still fails a release app in which any symbol mentions the simulator, and now also one that carries `PurchaseTestKit` — which asks more than "is it harmless": it asks whether somebody linked the test kit into an app. `--debug-app` must find both, the test kit in the hosted test bundle, or the check is searching for a misspelling (D27 has the history). **[ran]**

The cost is that `StoreLaunch.make` is a root this package wrote, and a root is where an app says what it is. It takes the live store as a closure for an app whose live store is not the App Store's — a developer-ID build in which everything is owned — and an app with a screenshots configuration, or any other idea of when to simulate, [writes its own](07-release-safety.md#writing-the-root-yourself) in a dozen lines, with the `#if` and the import that come with naming the simulator. That is the old way, and it is still there; it is no longer the only way.

## D34. The test kit reports through Swift Testing, so no app can link it

D33 kept the test kit out of apps with a check that reads a built app. That finds it after the fact, and only in the builds somebody checks. The question asked next was whether it could be a compiler *warning* in a debug build and an *error* in a release one. Not as asked. A package's module is compiled once per configuration, for every target that links it, and nothing tells it which those are: a `#warning` in the test kit would be in every test build, and `#if !DEBUG #error` would fail every test run built for release — this package's own `make release-tests` among them. Nor does an app need a warning's latitude in debug. Everything an app does with the simulator by hand — a scenario, the debug panel, a preview — it does without the test kit (D33).

What does work is stronger. Swift Testing is on the search path of a test target and of nothing else, so a module that calls into it cannot be linked into an app. The build stops in the linker — `Undefined symbols … referenced from: … in PurchaseTestKit.o` — in Debug and in Release, for arm64 and x86_64, whether or not the app uses anything of it, because Xcode links a package target whole. **[ran]** Nothing that should build is touched: the test kit's own suite runs in both configurations, the package builds for iOS devices, and the Demo's hosted tests build with it. **[ran]**

So the test kit calls Swift Testing, for a reason of its own. `StoreKitConfiguration.expectNoProblems(against:)` records each way the `.storekit` file disagrees with the catalogue as a failure of its own, as a sentence, at the line that asked — where `#expect(file.problems(against:) == [])` printed an array of enum cases on one line. A use and not a trick; and not one to be refactored away quietly, because `make demo` builds an app that links the test kit and requires the build to fail, over the test kit.

The costs, stated:

- **The failure is the linker's, not a sentence of this package's.** It names the test kit and Swift Testing, and [testing](05-testing.md#a-test-imports-the-test-kit-and-an-app-cannot-link-it) quotes it, so a search finds the reason.
- **It can be got past on purpose.** An app that puts Swift Testing on its own search paths may link. That is what `release-check --app` is still for.
- **Not measured: a product Xcode builds as a dynamic framework**, which it may do when one product is shared between an app and its extension. **[check]**


## D35. Subscriptions are decided by the status, by Apple's rule

What a subscription group amounts to is `SubscriptionStanding`, from the statuses `Product.SubscriptionInfo.status(for:)` reports. **Subscribed and in a grace period give access; billing retry, expired and revoked do not** — Apple's entitlement rule `[Apple]`, and for the grace period a promise the developer makes in App Store Connect `[Apple]`. Billing retry is reported as a state, never granted: an app that wants to be lenient says so in its own code ([subscriptions](15-subscriptions.md#access-is-apples-rule)).

**The status decides, and the listing stands in only for a group whose status could not be read.** The plan had it the other way — either source enough to grant — and phase 0 measured why not: the iOS simulator lists a subscription in billing retry, with a renewal transaction of its own, and at a renewal both platforms list nothing for a moment. **[ran]** A status read that fails takes nothing away (D9); a group that could not be read is left out of the answer, never answered empty, since empty is "never subscribed".

Of several statuses, the entitled one at the highest level decides, the person's own before anybody else's, then the one that lasts longer. `statuses.first` is how other libraries lost a family member's subscription behind the person's own expired one ([plan](14-subscriptions-plan.md#how-others-do-it)).

## D36. A lapse at a period's end is believed only when it lasts

At the end of every period StoreKit says, for a moment, that the subscription has ended: `expired` for up to 0.7 s on the Mac, and in the iOS simulator also "will not renew" and "eligible for a win-back offer", with nothing in the values to tell it from a real lapse. **[ran]** Believed, every subscriber is locked out at every renewal — for a moment, or, with nothing scheduled to look again, until the next launch.

So an `expired` reading, or none, for a subscription the last standing held as active and renewing, read less than `renewalGrace` (30 seconds by default) after its period ended, is not believed yet: the previous standing stands, and the store looks again in a couple of seconds. Billing retry and revocation are definite and believed at once; so is a lapse before the period is up. The renewal itself usually arrives on the updates stream first, and is held until a status has caught up with it, as a grant is (D4); a held renewal whose status says billing retry — the iOS simulator's — is settled by that status.

**A subscription's hold is let go by its status, never by the listing alone.** A grant's hold ends when the listing counts it (D5), and a subscription's did too, until review found the gap: after a purchase on the Mac the listing and the status are both empty for about 0.6 s **[ran]**, and nothing says which catches up first. With the listing first, the hold went, the status still said nothing — "never subscribed" — and someone who had just paid was shown the paywall, with nothing scheduled to look again. Only for a group whose status could not be read does the listing let a hold go, since there it stands in for the status. The simulated store can say a status later than the listing (`saysStatusAfterReads`) to keep this true.

The tests that pin it found a store that spun. A doubted lapse leaves the standing as it was, unpublished, and its `nextExpiry` a moment already gone; a look scheduled for that moment woke at once, and again. Looks are never scheduled in the past, and a subscription the store still calls subscribed after its end is looked at again a minute later. **[ran]** And a year of monthly renewals against the simulated store, which keeps the moment by default (D42), could not fail at first: the lock-out lasted one read, and a poll never saw it. The store's log of each read now names the active subscriptions, which is what "why did a subscriber see the paywall" needs anyway, and the test reads every one.

## D37. A change of plan is read by comparing what was asked for with what came back

A downgrade, and a crossgrade to another duration, come back from `purchase()` as `.success` **with the transaction already held**, unchanged, on both platforms. **[ran]** Taken at its word, it says the cheaper plan was bought. `PurchaseStore` compares the product it asked for with the product it got: another product of the same group is `.planChangeScheduled(to:at:)`, and nothing changes until the renewal, when the plan waited for is what renews. An upgrade is a new transaction at once, and the one left behind is marked upgraded, finished, and not counted. **[ran]**

The same holds for an Ask to Buy. Approved, a downgrade arrives as the plan already held, and the plan asked for is not active until the renewal. So `pendingApprovals` lets go of a plan when the status names it as the next one, not when it is active. Otherwise "waiting for approval" stays up for as long as a whole period after someone has approved it.

Asked in the same instant as the first purchase, before StoreKit had listed it, a downgrade on the Mac came back as the new plan instead — seen once, and not pinned. **[check]** No person downgrades within half a second of subscribing. It came back as the new plan once more, in a full hosted run on the Mac after the first purchase had been listed, and never when the test ran alone. The hosted test now accepts that one outcome as an intermittent known issue, and fails on any other.

## D38. What is held is chosen by date; a past period refunded takes nothing away

Renewals missed while nothing ran arrive at the next launch **newest first**, the oldest last and sometimes the original purchase after them. **[ran]** A listener that took the last to arrive as the current one would hold a period long over. A subscription's hold never outlasts the end of the period it bought, so one already over is not believed at all.

Refunding the first period of a subscription that has renewed revokes that transaction and nothing else. **[ran]** Announced as a withdrawal of the product, it would drop the hold on the renewal that is current. The adapter finishes a subscription transaction revoked after its period ended and announces nothing — the revocation date and the expiration date say which it was, with no clock.

## D39. The group and the level are restated in the catalogue

`status(for:)` takes the group's identifier and needs no product loaded, so what a subscriber may use waits for no network (D8). The level chooses between two statuses with no prices either. A transaction carries neither reliably. So both are written in the catalogue, as Family Sharing is, and the `.storekit` check keeps them honest. **Level 1 is the highest**: moving from level 2 to level 1 was an upgrade. **[ran]**

## D40. Every StoreKit open set crosses with a case for what it adds later

`RenewalState`, `ExpirationReason`, `Transaction.OfferType` and `Transaction.Offer.PaymentMode` are `RawRepresentable` structs, and Apple adds values to them without a compile error — the 27 SDK added `.assigned`, `.unbundled` and the bundle product types. **[Apple]** Each is matched with a branch for something newer, which becomes `unrecognised`: said, and never taken for subscribed (D21). An expiry with no reason is `unstated`, which is what the moment at a renewal looks like. `expired` while the renewal info says it is still retrying is billing retry, by Apple's own table **[Apple]** — the iOS simulator says so after a grace period **[ran]**.

## D41. Subscription statuses are read in a task nobody cancels

A status read from a cancelled task answers with **an empty array**, "never subscribed", on the Mac and in the iOS simulator, as the listing answers a cancelled task with nothing (D2). **[ran]** `PurchaseStore` reads statuses beside the listing in its own task; `AppStoreFront.subscriptionStatuses(in:)` asks from a task of its own for whoever calls it directly. `isEligibleForIntroOffer(for:)` is not affected by cancellation — but it keeps its first answer for the life of the process, before and after the offer is used **[ran]**, which phase 2 has to design around.

## D42. The simulated store renews by its clock, and keeps the renewal moment

A year of renewals is a `ManualClock` advanced twelve times. The simulated store does what its clock has done at each read: renews, lapses, or goes through a grace period and billing retry into expiry, as its behaviour says. And it keeps the moment at a renewal by default — the renewal announced first, the status expired and not renewing, the listing empty, for a read longer than a purchase's lag — for D28's reason: a fake politer than the real store hides the lock-out that moment causes. Each subscription habit is held to real StoreKit, per OS, by a test in `Demo/Tests` ([simulated store](06-simulated-store.md#subscriptions)).

## D43. Managing a subscription is Apple's page; on the Mac, a link

`ManageSubscriptionsButton` presents Apple's sheet on iOS. macOS has no sheet — `manageSubscriptionsSheet` and `AppStore.showManageSubscriptions` are unavailable there **[Apple]** — so it opens `https://apps.apple.com/account/subscriptions`. So do a Mac Catalyst app and an iPhone or iPad app running on a Mac, where Apple says not to show the sheet **[Apple]**. Catalyst is decided when it is built, from `targetEnvironment(macCatalyst)`, as Apple asks. An iPhone or iPad app on a Mac is decided at run time, from `isiOSAppOnMac`, because it is the same binary as on iOS. A review of the pull request found that Catalyst had been left out. Either way the store reads again when the person comes back: a cancellation made there sends the app nothing **[ran]**. There is still no paywall, and nothing wraps `SubscriptionStoreView`.

With the link, "back" is the app becoming active again, not the scene phase. Review found that the first version waited for `scenePhase` to become `.active`. A Mac window that stays visible behind the App Store never leaves `.active`, so that version never read again.

## D44. No public name StoreKit has at the top level

StoreKit 18.4 added top-level `SubscriptionInfo`, `SubscriptionStatus`, `SubscriptionPeriod`, `SubscriptionRenewalInfo` and `SubscriptionRenewalState`, and libraries with those names stopped compiling in apps that import both ([plan](14-subscriptions-plan.md#how-others-do-it)). The package's are `HeldSubscription`, `SubscriptionStanding`, `SubscriptionGroupID`, `SubscriptionTerms`, `Renewal`, `AppliedOffer` and `OfferID`, checked against the 24 top-level names of the 27 SDK. **[ran]**

A check made once is not kept, so `PurchaseAPITests` keeps it. It imports StoreKit, SwiftUI and every module an app can import, nothing `@testable`, and names every public type unqualified. A name StoreKit also has is then ambiguous, and the build fails — with the SDK of whichever Xcode builds it, which on CI is the older one. It also builds the values an app builds for its previews and tests, and conforms a type of its own to the ports, so an initialiser left internal fails the build. A last test reads `Sources/` and fails for a public type the file does not name. Each was watched to fail: a `SubscriptionPeriod` of the package's own, a public type left off the list, and an internal `HeldSubscription.init`. **[ran]**

## D45. A purchase made in Apple's own views is handed to the store

Phase 0 left one question open, because it needed a UI test: what reaches an app when a person buys in Apple's `SubscriptionStoreView`. The UI test found that a session made in the runner governs the app under test, and then it asked. On the Mac, everything is heard. A subscription arrives on both streams, and an unlock bought in `ProductView` on `Transaction.updates`. **In the iOS simulator an unlock bought in `ProductView` is announced nowhere.** It is listed, the view finishes it, and neither stream says a thing. A subscription there arrives on `Status.updates` at once, and on `Transaction.updates` only sometimes: two runs of six. **[ran]**

So a purchase made in one of Apple's views does not reliably reach a store that listens, and for an unlock on iOS it never does. The person pays, the view closes, and the paywall stays until the app next reads. The plan's P8 said such a purchase "must still reach the store". It needs help to.

The help is the view's own completion. `.onInAppPurchaseCompletion` is handed the verified transaction on both platforms **[ran]**, and `PurchaseStore.takePurchase(_:of:)` takes it from there. It is judged by the same function as a purchase made through `AppStoreFront` (finished if verified and the catalogue's, unverified thrown and left unfinished), and then held and read, as `purchase()` holds and reads. The completions are the same, a downgrade's included. The Core form, `takePurchase(_ outcome:of:)`, takes a `PurchaseOutcome` and serves a store of an app's own, and tests. Phase 2's offer-code sheet hands over a transaction in the same way.

It is the app's line to write, not a wrapper round Apple's view. The package still wraps no paywall, and an app that sets its own completion keeps it. `Demo/UITests` buys Pro in `ProductView` against real StoreKit in the iOS simulator, and fails with "Free" on screen when the line is taken out. **[ran]**

## D46. Introductory eligibility has four states, and a used offer is known from what was seen

`IntroductoryEligibility` is `unknown`, `noOffer`, `eligible(OfferTerms)` or `ineligible`. Two states were wrong both ways in other libraries: "eligible" assumed when the product could not be fetched, "the product has a trial" taken for "this person may have it", and "eligible" for a product with no introductory offer at all ([plan](14-subscriptions-plan.md#how-others-do-it)). `unknown` means showing the regular price, and the payment sheet, which applies the offer to a plain purchase if it is due **[ran]**, has the last word.

StoreKit's answer is not taken alone, because it keeps its first value for the life of the process: "eligible" before a purchase with the offer, and still "eligible" after it **[ran]**. That held every time on the Mac. In the iOS simulator it held twice in phase 0, and once in the hosted suite it said "not eligible" straight after the purchase **[ran]**. It cannot be relied on in either direction. The App Store front overrules it with the group's own transactions. One verified transaction bought with the offer, and the group's offer is used. The store also remembers each purchase it saw bought with the offer, and each status that says so. The last of these is what survives an upgrade: the status is then the higher plan's, bought with no offer, and StoreKit's first answer still says "eligible". Mutation found that: with the store's memory taken out, no test failed until one upgraded. **[ran]** The answer is read with the prices, in a task nobody cancels, and like the prices it is never waited for by anything that decides access (D8). The simulated store keeps its first answer too (`keepsFirstEligibilityAnswer`), by D28's rule.

What the store remembers is the Apple Account's own. A family member's transaction bought with the offer, or a status of theirs, uses up nothing of this account's `[Apple]`, and a review of the branch found that it did, in the front, the store's memory and the store's reading of a status. A status is now remembered too, not only consulted, so one bought elsewhere and then replaced by an upgrade leaves the offer used; until then the memory had held purchases only, and the docs had said otherwise.

## D47. An offer that was not applied is said

A purchase made with an offer can go through without it and say nothing. On the Mac, an introductory override signed with a key Xcode did not know went through at the full price, with no error **[ran]**. So a purchase with an offer completes as `.offerNotApplied(HeldSubscription)` unless its transaction carries the offer, or its renewal is waiting to apply it. The second is there because a promotional offer bought by a current subscriber takes effect at the next billing event `[Apple]`: nothing is wrong, and it must not read as though something were. `OwnedProduct.offer` carries the transaction's offer so that the answer is right before the status has caught up, and `Renewal.offer` carries the one waiting. `Demo/Tests` holds the Mac's silence to the real thing.

## D48. The package never signs; a signer the app supplies is asked only when it must be

A promotional offer and the introductory override are signed with an In-App Purchase key, which must never be in an app `[Apple]`. The package holds no key. `OfferSigning` is the app's: it asks its server, and Apple's App Store Server Library makes the JWS (`PromotionalOfferV2SignatureCreator`, `IntroductoryOfferEligibilitySignatureCreator`). The store asks the signer from inside the purchase, after the one-at-a-time guard, so `PurchaseButton` needs nothing extra. Three rules come with it. Someone who has never subscribed in the group is refused a promotional offer before the signer is asked, since Apple gives them only to current and former subscribers `[Apple]` — though only where the status could be read, since the listing alone cannot tell a former subscriber from nobody. A signer that throws, or no signer, means nothing is bought (`offerNotSigned`): another library carried on with the purchase. And the signature a store front reads is the one the store set: `PurchaseOptions.signature` is `package(set)`, and whatever an app might have put there is cleared.

StoreKit's refusals keep their reasons (`PurchaseError.offerRefused`): a bad signature is the app's server, and must not read as a person the offer is not for. They were all `unsupported` before, when the package sold no subscriptions.

## D49. Offer terms come from the product; win-back offers from the account's own status

`StoreProduct.Subscription` carries each offer's terms as StoreKit states them, and the app shows those rather than numbers of its own: they are App Store Connect's, per storefront, and change without a release. Win-back offers are the identifiers Apple lists as eligible on the **account's own** status, in Apple's order, matched to the lapsed plan's terms. Access through Family Sharing does not count towards one `[Apple]`. There are none for a member: at a renewal the iOS simulator says "eligible for a win-back offer" for a moment **[ran]**, and D36 keeps that moment from being believed. Nor are there any before the prices have loaded, because an offer is shown with its terms. In Xcode's environment a lapse makes them eligible at once **[ran]**, and the simulated store does the same.

## D50. A scheme that builds the package its own way builds in a directory of its own

`make demo` built the Demo, the app that must not link the test kit, and the UI tests into the Demo's derived-data directories. The Demo builds the package as frameworks, and the other two build it as static modules. The static `PurchaseCore.swiftmodule` they left in `Build/Products` was found first by the next build of the Demo, which then compiled against a Core a morning old, missing every type added since: "cannot find type 'HeldSubscription'". Built mid-edit, the UI tests' app crashed on launch in `initializeWithCopy for StoreProduct`. Two stale directories had already been moved aside by hand (`build/demo-stale-*`). CI starts clean and never sees it. `LinksTheTestKit` and `DemoUI` now build in `build/links-the-test-kit` and `build/demo-ui-ios`, and a second `make demo` with nothing moved aside passes. **[ran]**

## D51. A subscription handed back already over was not bought

Buying the monthly plan again moments after `expireSubscription` had lapsed it, the hosted suite on the Mac got `.success` from StoreKit with the **old transaction**, its period already over, and nothing bought **[ran]**. Phase 0 had seen the same in the iOS simulator every time, with an offer or without (q10), and on the Mac a purchase two seconds after a lapse went through. Taken at its word, the store answered `.subscribed` with a period that had ended. The override asked for then looked applied, because the old transaction had been bought with the introductory offer a month before. So `purchase()` now judges a subscription transaction that is over by the store's clock as a purchase that did not happen. It throws `.system`, which means nobody's fault and trying again is fair, holds nothing, and reads again. The simulated store can do the same (`handsBackTheLapsedTransaction`), off by default because the Mac was also seen to buy.

A purchase made in one of Apple's views and handed over with `takePurchase(_:of:)` is judged the same way, and fails the same way; it had gone straight to being "subscribed", period over and all. Its core form now throws.

## D52. A non-renewing subscription's end is the catalogue's, and every purchase counts

StoreKit gives a non-renewing subscription no end: its transaction has no expiration date, and the product no subscription info **[ran]**. How long one lasts is the app's to say, as a trial's is, and it is said once, in the catalogue: `.nonRenewing(id, lasting:)`. Measured, buying one again makes a new transaction, and **the listing keeps every purchase** **[ran]**, where the research had taken Apple's word that only the latest stays. So the standing keeps every counted purchase's date, and the terms turn them into periods.

How purchases made while one runs add up is policy, and the app declares it. `.consecutive`, the default, adds the time: nothing paid for is lost. `.fromEachPurchase` runs each from its own date, as Apple's sample does. Each purchase is held beside the others until the listing has that one, since a second purchase held in place of the first would lose the first for a moment. A refund takes back one purchase and leaves the others **[ran]**. And a purchase that hands back one already counted bought nothing: the iOS simulator did that in two runs of three **[ran]**, so `purchase()` throws `.system`, as D51 does for a subscription. The hosted suite holds both habits, and met the second.

"Already counted" is counted **before the purchase**: a read made while StoreKit was still returning could count the new purchase, and fail a real one. A purchase from Apple's views has no "before", so it is compared with the standing when it is handed over, and one the updates stream announced is new however soon it was counted, since the Mac announces what the views sell (q12). An Ask to Buy for one bought before is not settled by the earlier purchase, which is owned already: only a purchase made after it began waiting settles it. And a purchase dated ahead of this device's clock — the date is the App Store's — completes as its own period, and the store looks again when it begins.

## D53. A purchase asked for outside the app is a request, and the app decides

A promoted in-app purchase tapped on the App Store, and a win-back offer taken there with streamlined purchasing off, reach the app as StoreKit's `PurchaseIntent` `[Apple]`. Nothing has been bought. Apple says the app may go on at once, later, or not at all — after onboarding, say, or not for something already owned — and that is policy. So the store announces it (`TransactionUpdate.purchaseRequested`) and keeps it in `requestedPurchases`. The app buys it with the request's own options, or lets it go (`dismissRequestedPurchase(_:)`). A purchase of the product, however it ends, deals with the request. The name is `RequestedPurchase`, because StoreKit has `PurchaseIntent` at the top level (D44).

The offer the person chose goes with the request: a win-back offer, and a promotional one, which the app's signer signs when it is bought. Left off, buying the request would charge the regular price in place of the offer the person saw. An introductory offer needs no asking, and one of a kind StoreKit adds later is left off and logged, `requestedOfferUnrecognised`.

A Mac Catalyst app is never sent one for a promoted purchase, because the Mac App Store does not promote them **[Apple]**; there `requestedPurchases` stays empty. Not measured: in Xcode's environment no intent arrived on either platform, whether the `itms-services://` URL was opened by the app or, in the iOS simulator, by the system **[ran]**. It is tried in the sandbox, on a device, by hand.

## D54. On a 12-month commitment, whether it will renew and whether it will end are two facts

A yearly subscription can be billed monthly with a 12-month commitment, from 26.4 `[Apple]`. The terms are on the product (`billingPlans`), the plan is a purchase option (`billingPlan`), and the transaction says which month of the commitment it is (`HeldSubscription.commitment`). Asked for where the system is older than 26.4, a plan is a failure, `unsupported`, never a purchase billed up front instead.

Apple documents the trap. Cancelled during a commitment, the renewal still says it will renew, because the monthly billing does go on, and only the commitment's own renewal says it ends `[Apple]`. So `Renewal.commitment` carries that apart. `HeldSubscription.willRenewAtPeriodEnd` is false in the last month of a commitment that will not be renewed, whatever `willRenew` says. The test of the simulated store found that D36's doubt read `willRenew`, and so doubted, for ever, a lapse that was certain. It reads `willRenewAtPeriodEnd` now, and the test failed without it. **[ran]**

Not measured: no `.storekit` file with a billing plan could be written that `SKTestSession` would load. Eighteen shapes were tried, and the same file without the plan loaded every time **[ran]**. So the fields are copied as the SDK names them, behind `#available(26.4)`, and tried in the sandbox, in a storefront that offers the plan, by hand.

## D55. Apple's own messages wait while the app says so

A price rise to agree to, a billing problem and a win-back offer are sheets StoreKit shows by itself, and on iOS an app may hold them back `[Apple]`. When to show them is policy. `.storeMessages(deferredWhile:showing:)` in `PurchaseUI` is the mechanism: messages wait while the app says so, are shown in order when it stops, and a reason the app never wants shown, the win-back sheet of an app with its own say, is not shown. macOS has no messages, and there it does nothing. Apple lists them for Mac Catalyst, so a Catalyst app runs the iOS code. Not measured: no purchase could be made from a UI-test runner to ask a price rise of **[ran]**.

The first version read the app's condition from the task that began with the view, so it never saw it change: an app that began deferred held every later message for good, a price rise to agree to among them. The condition is now read as the app says it now, and the holding is `MessageQueue`, which a test reaches. A message the app has taken StoreKit will not show itself, so one that cannot be shown is kept for the next chance, not dropped.

## D56. A subscription bundle is facts, behind the 27 SDK

From 27, a subscription can be held through a bundle, perhaps of another app's `[Apple]`. Access is decided by the status, as it always is. The renewal info's bundle fields become `HeldSubscription.bundle`, a lapse for leaving a bundle is `Lapse.unbundled`, and a bundle product's `bundledSubscriptions` are on its terms. The names exist only in the 27 SDK, back-deployed, so they are behind `#if canImport(StoreKit, _version: 816)`, and the reason is matched by its value (6), as `.assigned` is (D17). Not measured: Xcode's environment could not be made to sell one.

## D57. Seats and retention offers need nothing new

A seat bought by an organisation arrives as `.assigned` and counts, for subscriptions as for unlocks and now non-renewing subscriptions. The plan asked whether it should, and the answer is yes: an app that would rather not sell to organisations switches it off in App Store Connect `[Apple]`. A retention offer, shown by the system in the cancellation flow, has no name in the 27 SDK's offer types. Whatever value StoreKit sends is reported as `OfferKind.unrecognised`, and the purchase is counted as any other.

## D58. The simulated store changes a status; it never rebuilds one

A review of the branch found the simulated store losing what a subscription was, wherever it built a status afresh: a lapse dropped the commitment, the bundle and the transaction; `renewNow` dropped the commitment and a pending downgrade, and switched auto-renew back on; switching auto-renew off dropped a price rise awaiting consent; a cancelled commitment jumped past by the clock rolled into a new one. Each was a field left out of a copy. So `HeldSubscription`, `Renewal` and the commitment types have setters inside the package, and the simulated store copies a status and changes what changes. A renewal is one step, taken period by period by the clock and once by `renewNow`, and every control first catches up with the clock.

The same review found where it was kinder or harsher than StoreKit, and it now does as StoreKit does or as Apple documents: a commitment has no grace period and is retried for 90 days `[Apple]`; a price rise not agreed lapses the subscription `[Apple]`; an introductory offer paid as you go runs for its periods; a subscription switched off keeps the plan it would renew as, as `autoRenewPreference` does; the controls act on the account's own subscription before a family member's; a resubscription is the subscription first subscribed; a request made before anything listens reaches the first listener. None of these is measured in Xcode's environment, which could not be made to do them, so the sandbox rows stand.

## D59. A known issue is decided by StoreKit, never by the package

Three hosted tests excused an environment's fault by what the package made of it: `gracePeriod` by the store's mapped state, so a mapping that lost the grace period would have been excused; `habitDowngradeReturnsHeld` by the very value it checked, so it could not fail; and the iOS `boughtAgain` by any `.system`. Each is now excused only by StoreKit's own word — its status says it renewed with no grace period; it still holds Plus with Monthly scheduled; it holds one purchase — and anything else fails. A test whose only assertion was an intermittent known issue could not fail at all, and `habitRenewalMoment` is gone: the spike's q01 measures the moment. The hosted suites are one serialized suite, since `.serialized` orders only a suite's own tests.
