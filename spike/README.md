# Spikes

Throwaway probes, kept because each answers a question the package's design hangs on and
will need asking again on a new Xcode. None of this is product code; nothing depends on it.

Last run: 18–19 September 2026, macOS 26.6.2, Xcode 27.0 (27A266a), Swift 6.4; and, where it says a hosted runner, GitHub's macOS 26.6.2 image with Xcode 26.6. Where a row says iOS, it is the
iOS 27.0 simulator, through the same questions in `Demo/Tests` (`make integration-ios`).

## `sktestsession/` — does `SKTestSession` work in a package test target?

**No.** Under `swift test` every mutating call fails with `SKInternalErrorDomain Code=1`
("Error saving configuration file") and purchases fail with "Unable to Complete Request".
Under `xcodebuild test` on the package scheme the code is `3`, the product list comes back
empty and purchases throw `notEntitled`. There is no app bundle for StoreKit's test
environment to attach the configuration to.

    cd spike/sktestsession && swift test

## `hosted/` — the same questions from a test bundle hosted by an app

Generated with XcodeGen; the `.storekit` file is a resource of the test bundle.

    cd spike/hosted && xcodegen generate
    xcodebuild test -project HostedSpike.xcodeproj -scheme Host -destination 'platform=macOS'

| Question | Answer |
|---|---|
| Does the session load, and do products come back? | Yes. |
| Does `product.purchase()` go through with `disableDialogs`? | Yes. |
| Is a purchase listed by `currentEntitlements` at once? | **No.** Empty straight after `purchase()` returns; listed within about a second. |
| Does `session.buyProduct(identifier:)` work? | **macOS 26.6 with Xcode 27.0: no** — `StoreKitError.unknown`, with or without the App Sandbox. **The same macOS with Xcode 26.6: yes** (a hosted runner; `Demo/Tests`). **iOS 27.0 simulator: yes.** So it is the newer tools on the older OS. Xcode 27's release notes list this very failure as fixed (FB24168768), which is not what was seen. |
| Does the `.purchaseDate(_:)` option backdate a non-consumable? Apple documents that it does, with `buyProduct(identifier:options:)`. | **macOS 26.6 with Xcode 27.0: no.** Through `buyProduct` it fails with the call; through `product.purchase(options:)` the purchase succeeds and **both** `purchaseDate` and `originalPurchaseDate` are today's. **iOS 27.0: yes, both routes, both dates.** |
| What does a **cancelled** task read from `currentEntitlements`? | **Nothing: 0 of 1**, on both. A read made in a cancelled task looks exactly like owning nothing. |
| Does `setSimulatedError` produce StoreKit's own errors (route E)? | **Yes.** macOS 26.6 throws the error that was armed (`networkError`, `purchaseNotAllowed`). iOS 27.0 throws one of its own whatever was armed: a system error for a load, `unknown` for a purchase. |
| Does a simulated *verification* failure reach the app as an unverified transaction? | **Yes**, on both: `purchase()` returns `.success(.unverified)`, and `currentEntitlements` lists it unverified. |
| Is a simulated error disarmed by passing `nil`, as documented (route F)? | **macOS 26.6: not for `.purchase`** — nil leaves every later purchase throwing `StoreKitError.unknown`. Fine for `.loadProducts` and `.verification`. **iOS 27.0: yes.** `resetToDefaultState()` clears it everywhere. |
| Does the test environment's state end with the process? | **No.** An error armed in one run was still armed in the next. Reset at the start of every test. |
| What does a **cancelled** task get from `Product.products(for:)`? | **An empty list, not an error: 0 of 2**, on both, with 2 before and 2 after. It reads as a store that sells this build nothing. |
| Is a purchase listed the moment `purchase()` returns? | **macOS 26.6: no**, about a second later. **iOS 27.0: yes, at once.** |
| Does an approved Ask to Buy arrive before the listing has it? | **macOS 26.6: usually** — on this Mac every time, on a slower hosted runner not: it is a race between the announcement and the listing. **iOS 27.0: no** — listed by the time it arrives. |
| Is a refund gone from the listing by the time it is announced? | **Yes**, on both. |
| Does a purchase made on this device also come through `Transaction.updates`? | **No**, on both: nothing in three seconds, the purchase having been finished at once. |
| Ask to Buy **declined**: what arrives? | **macOS 26.6: nothing**, and the purchase stays pending. **iOS 27.0: the purchase**, as if approved — a fault of that simulator. |
| An **interrupted purchase** (`interruptedPurchasesEnabled`, then `resolveIssueForTransaction`)? | **macOS 26.6:** `pending`, then it arrives through the updates and unlocks. **iOS 27.0:** `purchase()` throws `StoreKitError.unknown`. |
| A restore under `disableDialogs`; and with `.appStoreSync` armed? | `AppStore.sync()` completes; armed with a network error it throws it (macOS 26.6 as armed). |
| Is a purchase left **unfinished** handed to a listener that starts afterwards? | **Not pinned.** macOS 26.6: `Transaction.unfinished` is empty at once, has the purchase after half a second, and is **empty again a second later**, nobody having finished it; a listener started afterwards hears nothing in three seconds. A live listener *did* hear something when a second purchase was left unfinished. Too inconsistent to build a test on. |
| Does `xcodebuild test` always exit? | **No.** Seen once to finish an iOS simulator run, every test green, and never return. Run it under a timeout. |
| Does the session attach in an older simulator? | **Not in iOS 26.5 under Xcode 27.0**: no products load and purchases throw `notEntitled`, the same symptoms as a package test target. Cause not established. |

Consequences: real-StoreKit tests live in a host app (`Demo/`), not in the package; a trial
"nearly over" is tested against real StoreKit with a backdated purchase where the OS can do
it and a very short trial everywhere; every hosted test begins with `resetToDefaultState()`;
and ownership is never read in a task something else can cancel.

**A caution about measuring here.** The first attempt at route E reported that a simulated
verification failure *throws* `StoreKitError.unknown`. It does not. The purchase error had
been "disarmed" with nil a line earlier, which on macOS 26.6 arms `unknown` — so the
verification failure was never reached. One question per clean environment.

## `debugflag/` — does a package target see `DEBUG` under a custom configuration?

**Xcode decides by the configuration's name, not its type.**

    cd spike/debugflag && xcodegen generate
    for c in Debug Release Screenshots Debug-Screenshots; do
      xcodebuild build -project DebugFlagSpike.xcodeproj -scheme Tool -configuration "$c" -derivedDataPath build -quiet
      "build/Build/Products/$c/Tool"
    done

| Configuration (all but Release are debug-type) | App target sees | Package target sees |
|---|---|---|
| `Debug` | `DEBUG` | `DEBUG` |
| `Release` | nothing | nothing |
| `Screenshots` | `DEBUG SCREENSHOTS` | **nothing** |
| `Debug-Screenshots` | `DEBUG SCREENSHOTS` | `DEBUG` |

An app's own `SWIFT_ACTIVE_COMPILATION_CONDITIONS` never reach a package target. A
configuration that needs the simulated store must have a name beginning with `Debug`.

## `subscriptions/` — what real StoreKit does with auto-renewable subscriptions

Phase 0 of [the plan](../docs/14-subscriptions-plan.md#phase-0-measure-first): every
behaviour the subscription design leans on, asked of real StoreKit before anything is built
on it. A group with two plans at one level and one above them, the monthly plan carrying
the offers of the example that started this (introductory 10.99 × 2, then 15.99;
promotional, win-back and code offers of 10.99 × 3), and a second group with no
introductory offer. Each probe prints a timeline — the listing, the group's statuses,
and both streams, `Transaction.updates` and `Status.updates` — and asserts almost nothing.

    cd spike/subscriptions && xcodegen generate
    xcodebuild test -project SubscriptionsSpike.xcodeproj -scheme Host -destination 'platform=macOS' \
      -only-testing:HostTests/Probes
    # q04, a renewal while nothing runs, is two processes:
    TEST_RUNNER_PROBE_PHASE=leave xcodebuild test … -only-testing:'HostTests/Probes/q04a_subscribeAndLeave()'
    sleep 35
    TEST_RUNNER_PROBE_PHASE=return xcodebuild test … -only-testing:'HostTests/Probes/q04b_comeBack()'
    # q12, a purchase in Apple's own views, is a UI test: a person has to press the button.
    xcodebuild test -project SubscriptionsSpike.xcodeproj -scheme HostUI \
      -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:HostUITests

q12 needs a UI test, and two things about UI tests had to be found out first. **An
`SKTestSession` made in the UI-test runner governs the app under test**, on both platforms:
it clears the transactions and switches the payment sheet off, so nothing needs
confirming. And on the Mac the runner needs Automation Mode, which `automationmodetool`
says this machine grants without a password; it takes the mouse for the length of the run.
A static text's string is its `label` on iOS and its `value` on the Mac.

Run on 19 September 2026: macOS 26.6.2 with Xcode 27.0, and the iOS 27.0 simulator. With
Xcode 26.6: **not yet run** — the hosted runner is the only place it is installed.

| # | Question | macOS 26.6, Xcode 27.0 | iOS 27.0 simulator |
|---|---|---|---|
| 1 | At a period's end, with a renewal due, what do the listing and the status say? | **For a moment, that it has ended.** The status says `expired` — `willAutoRenew` still true, no expiration reason — for up to 0.7 s; once of three renewals the listing was empty too. Then the renewal arrives and both say subscribed | **The same, and worse to read**: the status says `expired`, `willAutoRenew` **false**, win-back eligible, no reason, and the listing is empty, for 0.03–0.3 s. Nothing in the values tells it from a real lapse; only that it does not last |
| 2 | Is a subscription purchase listed late? | **Yes**: empty straight after `purchase()`, listed 0.6 s later. The status is empty for as long | No: listed at once. (The first probe of the first run hung for three minutes on a cold simulator, and not again) |
| 3 | Does a renewal while the app runs arrive on `updates`, before the listing has it? | **Yes, on `updates`, 0.1–0.9 s before the listing** has it | Yes; the listing has it within 0.25 s |
| 4 | Renewals made while nothing ran | Every one is handed over on `updates` at the next launch, **newest first**, and the original purchase with them though it was finished. `Transaction.unfinished` was empty | The same, newest first, the latest renewal handed over twice; `unfinished` held the latest; the finished purchase was not handed over again |
| 5 | What does `Status.updates` report? | Purchase, renewal, auto-renew off and on, grace, billing retry, lapse, a plan change waiting for the renewal. Not a refund of a past period, which comes on `Transaction.updates` | The same for purchase, renewal, grace, retry and lapse. Auto-renew switched off or on through `SKTestSession` shows **nothing until the next renewal** |
| 6 | Grace period, and billing retry without one | Grace: `inGracePeriod`, `gracePeriodExpirationDate`, still listed. Retry: `inBillingRetryPeriod`, `billingError`, **not listed**, no transaction. Then `expired`. Only `Status.updates` says any of it | Grace: the same, listed. Retry: **a renewal transaction arrives on `updates` and is listed** while the status says `inBillingRetryPeriod`. After grace the status is `expired` with `isInBillingRetry` rather than `inBillingRetryPeriod` |
| 7 | Upgrade, downgrade, crossgrade | Upgrade: immediate, a new transaction for the higher level with the same `originalID`; the old one `isUpgraded`, in `Transaction.all` and **not listed**. **Downgrade and a crossgrade to a different duration: `purchase()` returns `.success` with the transaction already held**, unchanged; only `autoRenewPreference` names the product to come | The same |
| 8 | A cancelled task reads | `currentEntitlements`: nothing. **`status(for:)`: an empty array, not an error** — "never subscribed". `isEligibleForIntroOffer(for:)`: unaffected | The same |
| 9 | `isEligibleForIntroOffer(for:)` | **Keeps its first answer for the life of the process.** True before a purchase, still true after the purchase used the offer, and after `clearTransactions()`. Asked first after other purchases, false throughout, while a purchase got the introductory price. A plain `purchase()` applies the offer | The same, in both runs. Later, in the hosted suite, it once said false straight after the purchase: not to be relied on either way |
| 10 | Win-back offers | Eligible the moment it lapses: `eligibleWinBackOfferIDs` has the offer. Bought with `.winBackOffer(_:)`: a new transaction with `offer.type == .winBack` at 10.99. Later, in the hosted suite, a purchase made the moment the lapse was read handed back the old transaction, as iOS does ([D51](../docs/10-decisions.md#d51-a-subscription-handed-back-already-over-was-not-bought)) | Eligible as soon as it lapses. **Buying again after a lapse returns the old, expired transaction** and makes no purchase, with the offer or without, in both runs |
| 11 | Signed offers in Xcode's environment | A promotional JWS signed with a key Xcode does not know: `StoreKitError.unknown`. The introductory override so signed: **the purchase goes through at the full price, silently** | Offers to a current subscriber return the transaction already held, whatever the signature |
| 12 | A purchase through Apple's own views | **Heard.** A subscription in `SubscriptionStoreView` arrives on `Transaction.updates` 0.4–1.4 s after the view completes, and on `Status.updates`; an unlock in `ProductView`, on `Transaction.updates` 0.6 s before it is listed. The view finishes it. A completion handler, if the app sets one, is handed the verified transaction | **An unlock in `ProductView` is announced nowhere**: listed, finished by the view, and nothing on either stream. A subscription in `SubscriptionStoreView` arrives on `Status.updates` at once, and on `Transaction.updates` in two runs of six — both with a completion handler, and two others with one did not. Finished by the view |
| 13 | An offer code redeemed outside the app | Not reachable: `buyProduct` throws `StoreKitError.unknown` here, as it does for everything | Arrives on `updates` at once, listed, `offer.type == .code` with the code's name |
| 14 | `expireSubscription`, `forceRenewalOfSubscription` | Both work | `forceRenewal` works; `expireSubscription` had no effect within 3 s |
| 15 | Names | StoreKit's top-level names in the 27 SDK are 24; of the plan's names, none clashes. `SubscriptionInfo`, `SubscriptionStatus`, `SubscriptionPeriod`, `SubscriptionRenewalInfo` and `SubscriptionRenewalState` do | The same |
| 16 | Family Sharing; a renewal while a real device's app is closed | Sandbox only: not run | |

Also seen: **a purchase made here is announced on `updates` on macOS** (0.5 s later, once
finished) — which a non-consumable's is not — and not on iOS. Refunding the first period of
a subscription that has renewed revokes that transaction and nothing else: the subscription
stays subscribed. Buying a product already subscribed returns the transaction held.
`resolveIssueForTransaction` took the renewal's identifier on iOS and refused the
purchase's on macOS (`SKTestErrorDomain` 6), where retry made no renewal transaction to
take.

q12, run twice per platform and variant. It is why `PurchaseStore.takePurchase(_:of:)`
exists: an app that sells an unlock in `ProductView` or `StoreView` on iOS must hand the
view's result to the store, or the store hears of the purchase only at its next read
([D45](../docs/10-decisions.md#d45-a-purchase-made-in-apples-own-views-is-handed-to-the-store)).
`Demo/UITests` holds it to the real thing.

Consequences, carried into [the plan](../docs/14-subscriptions-plan.md#what-phase-0-found):
the status decides and the listing does not, since iOS lists a subscription in billing
retry; a lapse at a period's end is believed only when it lasts; a plan change is read by
comparing what `purchase()` returned with what was asked for; missed renewals are ordered by
date, never by arrival; a withdrawal names a transaction, not a product; status reads go in
a task nobody cancels; introductory eligibility is also read from the group's own
transactions; and win-back purchases can only be tested on the Mac.
