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

A hold ends when the store lists the product and the listing counts ([D19](#d19-a-hold-ends-when-the-listing-counts-the-product-not-when-it-names-it)), when the store withdraws it, or after `listingGrace` (30 seconds by default), whichever is first. Without the limit, anything announced and never listed would be vouched for all session; the revocation of a family-shared purchase has been reported to arrive without a revocation date, looking like a grant. **[check]** The listing stays the last word. The default is generous because lapsing early re-locks something just bought, and the listing was measured to catch up within a second.

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

Backdating a non-consumable is documented — `Product.PurchaseOption.purchaseDate(_:)`, with `SKTestSession.buyProduct(identifier:options:)` **[Apple]** — and whether it works depends on the OS. On macOS 26.6 `buyProduct` fails with `StoreKitError.unknown` (listed as fixed in Xcode 27's release notes; the fix is in the OS), and `product.purchase(options: [.purchaseDate(…)])` succeeds and ignores the date. In the iOS 27.0 simulator both work, and both of the transaction's dates follow. **[ran]** So a trial's length is a `Duration`, and the hosted suite does both: a whole trial in a second and a half everywhere, and a real fortnight with five minutes left where the purchase can be backdated, recorded as a known issue where it cannot.

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

- **A test, a preview or a composition root that names the simulated store must itself be under `#if DEBUG`**, or the first Release build fails. This package's own suite was not, and did not compile in release **[ran]**; it is now, `make check` runs it in release, and the rule is stated where a reader meets the type ([testing](05-testing.md#guard-every-test-that-names-the-simulated-store)).
- **A scenario the build cannot honour is silent.** A UI test run in a Release configuration launches the real store and nothing fails. Hence the "Simulated store" marker, asserted first ([the simulated store](06-simulated-store.md#ui-tests-and-screenshots)).
- **A package gets `DEBUG` by the configuration's name** (D13), by a heuristic Apple does not document. So the release check also reads a built app, not only the package (D27).
- **A TestFlight build is a Release build.** Testers get no simulated store, no scenarios and no debug panel; and a `Debug…` build handed out ad hoc can be unlocked by an argument, by design. Both are now said where a reader meets them ([release safety](07-release-safety.md)).
- **Xcode links a package product into every configuration of a target or none**, so whatever shares a module with the simulated store and is not behind the guard is in every app that ships. There was such a thing — a manual clock, a gate, a `.storekit` reader — and there is not any more (D27).

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

So the unguarded half is `PurchaseTestSupport`, which test targets link and apps do not, and `PurchaseTestKit` is guarded whole — `AnswerGate` included, which belongs to the store whose answers it holds. The dependency runs from Support to the test kit and not back, so the module an app links depends on nothing that is not behind the guard. `EverythingOwnedStoreFront` went to `PurchaseDirectDistribution` for the same reason from the other side: every App Store build was carrying a store in which everything is owned.

That is what lets the release check ask a stronger question. It was a denylist of three type names; it is now **"no symbol mentions either guarded module"**, which a new granting type under a new name cannot get past. And it asks it of a built app as well as of the package, because what ships is Xcode's Release build, where whether the package got `DEBUG` hangs on a heuristic over the configuration's name — the one link a check of SwiftPM's build cannot test.

## D28. The simulated store's habits are per OS, and each is held to the real thing

A fake is only as good as the evidence that the real thing still behaves so. One habit had a canary; the rest were asserted **[ran]** on the strength of a spike run once, and stated as properties of StoreKit. They are not: **a purchase is listed about a second late on macOS 26.6 and at once in the iOS 27.0 simulator**, and an approved Ask to Buy arrives before the listing has it on the one and not on the other. **[ran]**

Each habit now has a test in `Demo/Tests` that measures it against real StoreKit and compares it with what is written down, per OS — so StoreKit changing fails a test rather than letting the fake drift — and the table in [the simulated store](06-simulated-store.md#a-fake-not-a-stub) has a column per OS and says which rows rest on Apple's word or on nothing. Faults that belong to one environment are known issues there, both ways about: two on macOS 26.6 that the 27 releases fixed (D12, D23), and two in the iOS 27.0 simulator that the Mac does not have — a *declined* Ask to Buy delivered as a purchase, and an interrupted purchase that throws.

The fake keeps the awkward behaviour as its default. An app that is right when the listing lags is right when it does not.

## D29. What was left unfinished is asked for, not waited for

Apple says the updates sequence hands over unfinished transactions once, as the app launches. **[Apple]** `PurchaseStore` starts listening with its first command and not with the process, and a listener started a moment after an unfinished purchase was handed nothing in six seconds while `Transaction.unfinished` still held it. **[ran]** So the adapter reads `Transaction.unfinished` once, after subscribing, and treats what it finds as it treats an arrival. One that turns up both ways is finished twice and announced twice, which costs nothing.

This is pinned against the fake gateway and **not** against real StoreKit, and the record should say why: on macOS 26.6 an unfinished purchase appears in `Transaction.unfinished` half a second after `purchase()` returns and is gone again, unfinished by anybody, a second later. **[ran]** A test built on that would be a test of the test environment. **[check]** what production does.

## D30. The real-StoreKit lane runs nightly, and gates nothing

Out of CI altogether, it ran "by hand, before a release" — and it is where every claim about StoreKit's behaviour lives. As a gate on pull requests it would fail for reasons of its own often enough to be ignored (reported; **[check]**). So it runs nightly and on request, non-blocking, with one retry, a timeout — `xcodebuild` was seen to finish a simulator run green and never exit **[ran]** — the result bundle kept, and a red night opening an issue. What it measures replaces the **[check]**.

## D31. Mutation found four guarantees with no test, and D14 now means it

D14 says every regression test is proven to bite, and those were: put back, the old behaviour fails them. But a review mutated the code rather than reverting fixes, and four documented guarantees turned out never to have had a test at all — the re-run that gives a late caller a fresh read, the re-read after a *failed* restore (D9), the adapter's handling of a cancelled products request, and `purchase()` starting the listener. Each has one now, watched to fail against its mutant. **[ran]** The lesson is about where to look: "does the regression test bite" finds weak tests, and only "does the suite notice this line changing" finds missing ones.

