# The StoreKit adapter

What `PurchaseStoreKit` calls, what it decides, and why.

## Shape

```
AppStoreFront            decides: what counts, what is finished, how errors map
  └─ StoreKitGateway     protocol, internal
       └─ LiveStoreKitGateway    the only file that makes a static StoreKit call
```

The gateway fetches, forwards and copies a transaction's fields into a `TransactionSnapshot`. It finishes nothing, filters nothing and maps no errors; it throws whatever StoreKit threw. A `Transaction` cannot be constructed outside StoreKit, and `SKTestSession` does not work under `swift test`, so everything that could be got wrong sits above the gateway, where a fake reaches it.

## Calls made

| For | StoreKit call | Notes |
|---|---|---|
| Prices | `Product.products(for:)` | Products are cached so Buy does not go back to the network. |
| What is owned | `Transaction.currentEntitlements` | Current, not deprecated; only the singular `currentEntitlement(for:)` is. At most one transaction per non-consumable; refunded ones are already excluded; family-shared ones are included. **[Apple]** |
| Buying | `PurchaseAction`, `purchase(confirmIn:)`, or `purchase(options:)` | By anchor; see below. |
| Restoring | `AppStore.sync()` | Prompts for a password. Only behind a button. |
| Arrivals | `Transaction.updates`, and `Transaction.unfinished` once | From the first command, for the store's life. The backlog is read once, after subscribing: Apple hands unfinished transactions to a listener at *launch*, and this one may start later ([D29](10-decisions.md#d29-what-was-left-unfinished-is-asked-for-not-waited-for)). |

Nothing from StoreKit 1 is used, and no SDK-27-only symbol, so the package builds with Xcode 26 and 27.

## Every read is made in a task nobody cancels

| Read | Asked from a cancelled task, real StoreKit answers **[ran]** | So |
|---|---|---|
| What is owned (`Transaction.currentEntitlements`) | nothing: 0 of 1 | `PurchaseStore` reads in a task of its own ([D2](10-decisions.md#d2-ownership-is-never-read-in-a-task-something-else-can-cancel)) |
| What is for sale (`Product.products(for:)`) | **an empty list, not an error**: 0 of 2 | `PurchaseStore.loadProducts()` does likewise, and so do `AppStoreFront.products()` and `diagnose()` themselves, for whoever calls them directly ([D26](10-decisions.md#d26-products-too-are-asked-for-in-a-task-nobody-cancels--in-the-adapter)) |

Nothing at all reads as "owns nothing"; an empty list reads as "sells nothing". Neither is an error, which is what makes both dangerous. A cancellation that does arrive as a thrown error is mapped to a failure for a products request — nobody backs out of a price list — and to a cancellation only for a purchase or a restore.

## Triage: one place decides what to do with a transaction

| Verdict | When | Counted | Finished |
|---|---|---|---|
| `foreign` | Not in the catalogue. Decided **first**: whether someone else's transaction verifies is not this app's business. | No | **No** |
| `unverified` | Signature does not check out | No | **No** |
| `withdrawn` | Verified, ours, revoked | No | Yes |
| `adopt` | Verified, ours, standing | Yes | Yes |

Finishing removes a transaction from the store's redelivery queue for good, which is why a foreign one is left for whoever owns that product, and an unverified one is left to be offered again. Reading entitlements finishes nothing at all.

An unverified transaction is logged as `unverifiedTransactionIgnored` on **every** path it can arrive by — bought, arriving on its own, or read from the listing. The listing is the path on which it locks a paying customer out, and it was the one path that said nothing. A foreign transaction is logged when it is bought or arrives, and not when the listing is read: it is in the listing at every read, for good, and is no news.

Whether an adopted transaction *counts* for this account — a family-shared trial does not — is `StandingResolver`'s decision in Core. The adapter reports facts.

## Updates carry facts

`transactionUpdates()` yields `.granted(OwnedProduct)` or `.withdrawn(ProductID)`. A grant arrives **before** `currentEntitlements` has it, so a listener told only "something changed" reads the listing, finds nothing, and never looks again. A refund does not lag. **[ran]** See [decisions, D4](10-decisions.md#d4-the-updates-stream-carries-facts-not-a-signal).

## Errors

`StoreKitErrorMapping` reduces an error to which kind it was. Two things it exists to get right:

- **Cancellation arrives two ways**: as `PurchaseResult.userCancelled`, and as a thrown `StoreKitError.userCancelled`. Both become a cancellation. Handle only the first, and someone who changed their mind is shown "something went wrong".
- **Nothing unknown becomes a cancellation.** `Product.PurchaseResult` is not frozen. A case added after this was written is thrown as `unknown(typeName: "Product.PurchaseResult")`: a cancellation is answered with silence, and silence is the wrong answer to someone a new kind of result may have charged ([D21](10-decisions.md#d21-a-result-storekit-adds-later-is-a-failure-never-a-cancellation)).
- **No text survives.** Some StoreKit errors echo account identifiers in `localizedDescription`, so it is never read. An unrecognised error crosses as the name of its type.

| StoreKit | `PurchaseError` |
|---|---|
| `StoreKitError.userCancelled`, `CancellationError` | *(a cancellation, not an error)* |
| `StoreKitError.networkError`, `URLError` | `network` |
| `StoreKitError.systemError` | `system` |
| `StoreKitError.notAvailableInStorefront` | `notAvailableInStorefront` |
| `StoreKitError.notEntitled`, `.unsupported` | `unsupported` |
| `StoreKitError.invalidPresentationContext` (SDK 27) | `invalidConfirmation`. Matched by name so that the adapter compiles against the 26 SDK; a test that only exists where the case can be spelt pins the name. |
| `Product.PurchaseError.productUnavailable` | `productUnavailable` |
| `Product.PurchaseError.purchaseNotAllowed` | `purchaseNotAllowed` |
| Offer errors | `unsupported` |
| Transaction does not verify | `unverified` — never a cancellation: the person may have been charged |
| Transaction already revoked | `revoked` |
| A `Product.PurchaseResult` case added since | `unknown(typeName: "Product.PurchaseResult")` — never a cancellation |
| Anything else | `unknown(typeName:)` |

## Where the payment sheet appears

With several windows open StoreKit has to be told which one a purchase belongs to. Core may not know what a window is, so the anchor crosses it type-erased in `PurchaseConfirmation`. `NSWindow`, `UIViewController`, `UIScene` and `PurchaseAction` are all `Sendable`, so nothing is unchecked.

| Anchor | Call made | Availability |
|---|---|---|
| `.action(PurchaseAction)` | `action(product)` | Apple's recommendation in SwiftUI on every platform. `PurchaseButton` passes it for you. |
| `.window(NSWindow)` | `purchase(confirmIn: window)` | macOS |
| `.viewController(UIViewController)` | `purchase(confirmIn: controller)` | iOS |
| `.scene(UIScene)` | `purchase(confirmIn: scene)` | iOS |
| `.automatic`, or one not recognised | `purchase(options:)` | Fine with one window. An unrecognised anchor is logged. |

`PurchaseAction` lives in `_StoreKit_SwiftUI`, an overlay Xcode loads unasked and SwiftPM does not, so it is imported by name.

## Diagnosis

`AppStoreFront.diagnose()` reports what this build actually receives: which products came back, how many entitlements verified, and from which environment. A build the App Store has never heard of — ad-hoc signed, launched without a `.storekit` file on the scheme — receives no products and no entitlements, and to its developer the Buy button does nothing. **[ran]** The same condition is logged as `catalogueLoadedEmpty`.

A store that could not be *asked* is not a store that sells nothing, and the advice for the two is opposite: check the connection, or fix the scheme. When the product request fails, the diagnosis carries the reason in `catalogueFailure`, its only hint about the catalogue is `catalogueLoadFailed`, and `received` says nothing. The failure used to be swallowed, and an offline Mac was told to attach a StoreKit configuration file.
