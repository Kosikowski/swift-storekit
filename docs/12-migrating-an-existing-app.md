# Migrating an existing app

For an app that already sells a non-consumable with hand-written StoreKit 2 code, usually one "purchase manager" class. This page lists the steps, the defects such code commonly carries and what replaces each, and the one change your customers will notice.

**The package reports store facts and performs store actions; the app owns product policy.** A hand-written manager nearly always mixes the two: it reads StoreKit *and* decides what "Pro" means. Migration is mostly separating them. The store half is deleted, and the policy half stays in the app, rewritten over `Standing`.

Evidence tags: `[ran]` was measured against real StoreKit (macOS 26, Xcode 27; see `spike/README.md` and `Demo/Tests`), `[review]` is a defect found in existing hand-written code and confirmed against it, `[Apple]` is from Apple's documentation, `[check]` is believed and unverified.

## What is being replaced

The shape below is typical, and every line marked is a defect from [the table](#defects-hand-written-code-commonly-carries).

```swift
@MainActor
@Observable
final class OldPurchaseManager {
    var isPro = false                       // false at every launch, until the read finishes
    var purchaseError: String?              // shared: every view watching it raises the alert

    func refresh() async {
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result, transaction.productID == "com.example.app.pro" {
                isPro = true
                return                      // first match wins; "free" otherwise
            }
        }
        isPro = false
    }

    func buy(_ product: Product) async {
        do {
            switch try await product.purchase() {
            case let .success(.verified(transaction)):
                await transaction.finish()
                await refresh()             // the listing does not have it yet
            case .success(.unverified), .userCancelled, .pending:
                break                       // unverified and pending: silence
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}

struct OldRoot: View {
    @State private var manager = OldPurchaseManager()
    var body: some View {
        Text(manager.isPro ? "Pro" : "Free")
            .task { await manager.refresh() }   // cancelled when the view goes away
    }
}
```

## Steps

Do them in this order. After step 2 the app builds and runs on the new store; the rest can be done view by view.

1. **Declare the catalogue.** Collect every product identifier in the app into one `Catalogue`, and delete the string literals. Add the test that checks the `.storekit` file against it ([App Store Connect](09-app-store-connect.md#check-the-file-against-the-catalogue)). If the app has a trial, it becomes a `.trial(_:of:lasting:)` entry ([trials](04-trials.md)).

2. **Replace the manager with `PurchaseStore` at the composition root.** Build `AppStoreFront` and `PurchaseStore` once, and apply `.purchaseStore(_:)` at the root ([getting started](02-getting-started.md#the-composition-root)). Remove the old manager's `Transaction.updates` listener in the same change. Do not run both: two listeners compete for the same transactions, and the old one may finish a transaction the new store is waiting to see `[check]`. The demo app stands its own store down while it hosts the real-StoreKit tests for that reason.

3. **Replace every `isPro` read with a derivation the app owns.** The package has no `isPro`, deliberately. Write one function over `Standing.access(to:at:)` that says what "Pro" means in your app, and make the unknown case explicit ([getting started](02-getting-started.md#derive-your-own-ispro)). Views that *draw* read `standing` and draw nothing while it is unknown.

4. **Move result and alert state out of the shared object.** Delete properties such as `purchaseError`, `showsAlert` and `lastResult` from anything shared. `PurchaseButton` and `RestorePurchasesButton` hand the result to a closure: keep it in the `@State` of the view that owns the button. Write one function that turns `Result<PurchaseCompletion, PurchaseError>` into your wording ([getting started](02-getting-started.md#word-every-outcome)). This matters most where it is least obvious: a paywall presented from *app-wide* state — one `paywallReason` that every window binds a sheet to — comes up in every window at once, and a notice kept on a shared model is then shown N times, and again the next time any paywall opens, because nothing but the next attempt clears it. What is *global* is what the store says is global: `pendingApprovals`, which clears itself when the approval arrives, where a "waiting for approval" string of your own does not. And disable Restore while `activity.isBusy`, as the Buy button is: the store refuses a second action while one is under way (`alreadyInProgress`), where hand-written code usually ran both.

   If the app has a `refresh()` of its own that everything already calls, keep it and forward it: the store's `refresh()` also starts listening, so calling it first is the same as calling `start()`.

5. **Make every gate await `knownStanding()`.** Find each place that *decides* something by the entitlement: feature gates, limits, locks, presenting the paywall, opening a document, state restoration at launch, deep links, App Intents. Each becomes `let standing = await purchases.knownStanding()`, followed by your policy function with the current date.

   ```swift
   func mayOpen(beyondFreeLimit: Bool, now: Date = .now) async -> Bool {
       guard beyondFreeLimit else { return true }
       let standing = await purchases.knownStanding()
       switch standing.access(to: Shop.pro, at: now) {
       case .owned, .onTrial: return true
       case .none, .unknown: return false
       }
   }
   ```

6. **Delete locally stored entitlements and trial dates.** Remove the cached "is Pro" flag in preferences, the trial start in the keychain or in preferences, and any receipt cache. `Transaction.currentEntitlements` is the single source of truth, and it answers from StoreKit's cache when offline `[Apple]`. There is nothing to migrate them into: the package stores nothing. Then read [the last section](#changing-where-a-trials-start-comes-from-changes-peoples-trials) before you ship.

7. **Replace the fake.** If the app's tests have a mock store, replace it with `SimulatedStoreFront`, which keeps real StoreKit's awkward habits on purpose ([the simulated store](06-simulated-store.md)). Expect some tests that passed against a politer mock to fail. They were hiding the defects below.

8. **Pass the time in.** Anything of the app's own that asks "is the trial still running?" by reading `Date()` inside the check becomes a function that takes the date. Inject a clock where the app schedules anything by it.

## Defects hand-written code commonly carries

| Defect | What the person sees | What replaces it |
|---|---|---|
| **Reading ownership in a task SwiftUI cancels.** Real StoreKit answers a cancelled task with *nothing*: 0 of 1 entitlements `[ran]` | A paying customer closes a sheet at the wrong moment, the read returns empty, and they are locked out | `PurchaseStore` reads ownership in a task of its own, single-flight, which nothing else can cancel. A cancelled caller of `knownStanding()` waits for it like anyone else |
| **Reading `currentEntitlements` straight after `purchase()`.** The purchase is listed about a second later `[ran]` | Buy "does nothing" until the next launch | The transaction `purchase()` returned is carried (`PurchaseOutcome.purchased(OwnedProduct)`) and believed until the store lists it in a way that counts for this account, withdraws it, or `listingGrace` runs out |
| **Re-reading the listing when an update arrives.** An approved Ask to Buy arrives on `Transaction.updates` *before* the listing has it `[ran]`; a refund does not lag `[ran]` | A child's approved purchase never unlocks until relaunch | The updates stream carries the facts, `TransactionUpdate.granted(OwnedProduct)` or `.withdrawn(ProductID)`, and a grant is held exactly as a purchase is |
| **Answering on the first matching entitlement**, and "free" otherwise `[review]` | Works until there is a second product; then one listed first silently revokes the other | The whole listing is read every time (`OwnershipReading`'s contract), and `StandingResolver` walks all of it |
| **Finishing every transaction, including other products'** `[review]` | Another handler in the app, or another SDK, never sees its own transactions | Only verified transactions for catalogue products are finished. A foreign transaction is left alone and logged as `.foreignTransactionIgnored`. Reading ownership finishes nothing |
| **Treating unverified as cancelled** `[review]` | Someone who may have been charged is shown a sheet that closed and said nothing | `PurchaseError.unverified` is thrown, the transaction is left unfinished so the store offers it again, and the app words it |
| **Waiting for the catalogue before knowing ownership** `[review]` | An owner is locked out whenever the network is slow or absent | `start()` reads ownership and does not load prices. `productLoad` is a separate state, and `knownStanding()` never waits for it |
| **Surfacing `localizedDescription`** | Some StoreKit errors echo App Store account identifiers, on screen and in logs `[review]` | `PurchaseError` is typed and carries no text. An unrecognised error crosses as `.unknown(typeName:)`. `PurchaseEvent` is safe to log as it is |
| **Downgrading on a failed restore** `[review]` | Restore is cancelled or fails offline, and a known owner becomes "free" | A restore that throws reads ownership again and rethrows. The store could not be reached, which is no evidence that anything stopped being owned |
| A cancellation that arrives **thrown**, as `StoreKitError.userCancelled`, reported as a failure `[Apple]` | Someone who changed their mind is told "something went wrong" | Both forms map to `.cancelled`, for purchases and for restores |
| `pending` handled as silence | Ask to Buy looks like a button that did nothing | `PurchaseCompletion.pending`, and `pendingApprovals` for a "waiting for approval" status |
| One shared result flag | The paywall, settings and a second window all raise the same alert | Commands return their result to the caller, and nothing shared holds it |
| The clock read inside the entitlement check | Expiry cannot be tested without waiting for it | Every time-dependent query takes the date; the store takes a `TimeProviding` |
| Nothing scheduled for the trial's end | The app stays unlocked after expiry until something unrelated redraws | The store schedules its own re-read for `nextExpiry`; an early wake reschedules |
| A second purchase started while one is under way | Two payment sheets, one behind the other | `PurchaseError.alreadyInProgress`; the buttons disable themselves while `activity.isBusy` |

To see that a fix bites, put the old behaviour back and watch the test fail. Three times in this package's own history a check passed against the defect it was written for, and was only caught this way ([decisions](10-decisions.md)).

## What the package will not take over

These stay in the app, and a migration is a good moment to find where they live:

- what a purchase unlocks, and every limit and quota;
- what happens on a downgrade (trial ended, purchase refunded): lock, remove or keep. It is a product decision, so write it down. Locking and keeping the content is the choice that lets a later purchase restore everything as it was;
- the paywall: its wording, its layout, why it appeared, and closing it when the standing turns to owned;
- alerts, and the sentence for each outcome and error, in your languages;
- date formatting, including the end of a trial **with its time**;
- errors thrown from App Intents and Shortcuts, which cannot show a paywall;
- in-app refund requests (`Transaction.beginRefundRequest(in:)` on iOS `[Apple]` `[check]`), which the package does not wrap.

The [checklist](checklist.md) splits every item this way.

## Changing where a trial's start comes from changes people's trials

If the old app kept the trial's start locally, in preferences or in the keychain, then some people have had more than one trial: a reinstall, or a second device, gave them a fresh one.

After migration the trial's start is its transaction's `originalPurchaseDate`, which the App Store keeps against the account. That date does not move.

| Person | Before | After the update |
|---|---|---|
| Took the trial once, and it is still running | Trial running | The same trial, the same end |
| Reinstalled and was given a fresh local trial | A new fortnight | **The trial ends on the App Store's date, possibly at once** |
| Took the trial on one device, then started another on a second | Two trials | One trial, dated from the first |
| Started a local trial that never bought a trial product | Trial running | No trial transaction exists, so the trial is `.available` |

The second and third rows are the change people notice, and from their side it looks like a trial cut short. It is correct, and it needs saying:

- [ ] **Put it in the release notes**: the trial is now one per account and follows the App Store's date.
- [ ] **Brief support** before the release, with the sentence to use and the fact that Restore Purchases will not bring a trial back.
- [ ] **Show the end date and time** wherever the trial appears, so that the new end is visible and not a surprise. `TrialStatus.used(TrialPeriod)` carries when it ended: show the trial button disabled with that date, and do not hide it.
- [ ] **Decide the last row deliberately.** If the old trial was purely local and no trial product existed, everyone gets one store-dated trial after the update, including people whose local trial had ended. If that is not acceptable, it is a policy rule for the app to add on top of the store's facts; the package will report `.available`.
