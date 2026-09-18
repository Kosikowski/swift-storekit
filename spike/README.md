# Spikes

Throwaway probes, kept because each answers a question the package's design hangs on and
will need asking again on a new Xcode. None of this is product code; nothing depends on it.

Last run: 18 September 2026, macOS 26.6.2, Xcode 27.0 (27A266a), Swift 6.4. Where a row says iOS, it is the
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
| Does `session.buyProduct(identifier:)` work? | **macOS 26.6: no** — `StoreKitError.unknown`, with or without the App Sandbox. Xcode 27's release notes list this as fixed (FB24168768); the fix is in the OS, not the tools. **iOS 27.0: yes.** |
| Does the `.purchaseDate(_:)` option backdate a non-consumable? Apple documents that it does, with `buyProduct(identifier:options:)`. | **macOS 26.6: no.** Through `buyProduct` it fails with the call; through `product.purchase(options:)` the purchase succeeds and **both** `purchaseDate` and `originalPurchaseDate` are today's. **iOS 27.0: yes, both routes, both dates.** |
| What does a **cancelled** task read from `currentEntitlements`? | **Nothing: 0 of 1**, on both. A read made in a cancelled task looks exactly like owning nothing. |
| Does `setSimulatedError` produce StoreKit's own errors (route E)? | **Yes.** macOS 26.6 throws the error that was armed (`networkError`, `purchaseNotAllowed`). iOS 27.0 throws one of its own whatever was armed: a system error for a load, `unknown` for a purchase. |
| Does a simulated *verification* failure reach the app as an unverified transaction? | **Yes**, on both: `purchase()` returns `.success(.unverified)`, and `currentEntitlements` lists it unverified. |
| Is a simulated error disarmed by passing `nil`, as documented (route F)? | **macOS 26.6: not for `.purchase`** — nil leaves every later purchase throwing `StoreKitError.unknown`. Fine for `.loadProducts` and `.verification`. **iOS 27.0: yes.** `resetToDefaultState()` clears it everywhere. |
| Does the test environment's state end with the process? | **No.** An error armed in one run was still armed in the next. Reset at the start of every test. |
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
