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
| Buying | `PurchaseAction`, `purchase(confirmIn:)`, or `purchase(options:)` | By anchor; see below. The options — an account token, a billing plan, an offer and its signature — are worked out first by `PurchaseRequest`, which says what to send or why nothing can be sent, and which a test reaches; the gateway only turns it into `Product.PurchaseOption`s. A win-back offer is looked for on the product and on the billing plan asked for. |
| A purchase made in Apple's views | none: the view's result is handed over | `takePurchase(_:of:)` and `takeRedemption(_:)` take `Product.PurchaseResult` and the 27 SDK's offer-code sheet's `VerificationResult<Transaction>`, and judge them as a purchase made here ([D45](10-decisions.md#d45-a-purchase-made-in-apples-own-views-is-handed-to-the-store)) |
| Restoring | `AppStore.sync()` | Prompts for a password. Only behind a button. |
| Subscription statuses | `Product.SubscriptionInfo.status(for:)`, per group | Static: no product loaded first. Read beside the listing, and deciding over it ([D35](10-decisions.md#d35-subscriptions-are-decided-by-the-status-by-apples-rule)). A group StoreKit could not be asked about is left out and logged as `subscriptionStatusUnavailable`, never answered empty |
| Status changes | `Product.SubscriptionInfo.Status.updates` | Merged into the updates stream: an expiry, a cancellation and a grace period send no transaction at all **[ran]** |
| Introductory eligibility | `Product.SubscriptionInfo.isEligibleForIntroOffer(for:)`, and `Transaction.all` for the group | StoreKit's answer keeps its first value, so a verified transaction of the account's own bought with the offer overrules it ([D46](10-decisions.md#d46-introductory-eligibility-has-four-states-and-a-used-offer-is-known-from-what-was-seen)) |
| Purchases asked for outside the app | `PurchaseIntent.intents` | Merged into the updates stream as `.purchaseRequested`, with the win-back or promotional offer the person chose; the intent's product is cached, so buying it needs no second trip ([D53](10-decisions.md#d53-a-purchase-asked-for-outside-the-app-is-a-request-and-the-app-decides)) |
| Billing plans and commitments | `pricingTerms`, `billingPlanType`, `commitmentInfo` | From 26.4, behind `#available`; a plan asked for on an older system fails as `unsupported` ([D54](10-decisions.md#d54-on-a-12-month-commitment-whether-it-will-renew-and-whether-it-will-end-are-two-facts)) |
| Bundles | `bundleProductID`, `willUnbundle`, `bundledSubscriptions` | Named in the 27 SDK only, behind `#if canImport(StoreKit, _version: 816)` ([D56](10-decisions.md#d56-a-subscription-bundle-is-facts-behind-the-27-sdk)) |
| Managing subscriptions | `manageSubscriptionsSheet` (iOS), a link (macOS) | In `PurchaseUI`, not here ([D43](10-decisions.md#d43-managing-a-subscription-is-apples-page-on-the-mac-a-link)) |
| Arrivals | `Transaction.updates`, and `Transaction.unfinished` once | From the first command, for the store's life. The backlog is read once, after subscribing: Apple hands unfinished transactions to a listener at *launch*, and this one may start later ([D29](10-decisions.md#d29-what-was-left-unfinished-is-asked-for-not-waited-for)). |

Nothing from StoreKit 1 is used, and no SDK-27-only symbol outside a compiler check, so the package builds with Xcode 26 and 27.

## Every read is made in a task nobody cancels

| Read | Asked from a cancelled task, real StoreKit answers **[ran]** | So |
|---|---|---|
| What is owned (`Transaction.currentEntitlements`) | nothing: 0 of 1 | `PurchaseStore` reads in a task of its own ([D2](10-decisions.md#d2-ownership-is-never-read-in-a-task-something-else-can-cancel)) |
| Subscription statuses (`status(for:)`) | **an empty array**: "never subscribed" | `PurchaseStore` reads them in its task; `AppStoreFront.subscriptionStatuses(in:)` asks from a task of its own ([D41](10-decisions.md#d41-subscription-statuses-are-read-in-a-task-nobody-cancels)) |
| What is for sale (`Product.products(for:)`) | **an empty list, not an error**: 0 of 2 | `PurchaseStore.loadProducts()` does likewise, and so do `AppStoreFront.products()` and `diagnose()` themselves, for whoever calls them directly ([D26](10-decisions.md#d26-products-too-are-asked-for-in-a-task-nobody-cancels--in-the-adapter)) |

Nothing at all reads as "owns nothing"; an empty list reads as "sells nothing". Neither is an error, which is what makes both dangerous. A cancellation that does arrive as a thrown error is mapped to a failure for a products request — nobody backs out of a price list — and to a cancellation only for a purchase or a restore.

## Triage: one place decides what to do with a transaction

| Verdict | When | Counted | Finished |
|---|---|---|---|
| `foreign` | Not in the catalogue. Decided **first**: whether someone else's transaction verifies is not this app's business. | No | **No** |
| `unverified` | Signature does not check out | No | **No** |
| `withdrawn` | Verified, ours, revoked | No | Yes |
| `pastPeriodWithdrawn` | A subscription transaction revoked **after its period had ended**: an old period refunded, the subscription carrying on **[ran]**. Not announced ([D38](10-decisions.md#d38-what-is-held-is-chosen-by-date-a-past-period-refunded-takes-nothing-away)) | No | Yes |
| `superseded` | A subscription transaction upgraded away from `[Apple]`. Not announced | No | Yes |
| `adopt` | Verified, ours, standing. A subscription's carries its period's end | Yes | Yes |

A subscription **status** has triage of its own, in `SubscriptionTriage`: a status whose transaction does not verify is not counted, and logged; one whose renewal info does not verify is counted, with nothing known of its renewal. StoreKit's renewal states, expiration reasons, offer types and payment modes are open sets, and each is matched with a branch for a value added later, which becomes `unrecognised` ([D40](10-decisions.md#d40-every-storekit-open-set-crosses-with-a-case-for-what-it-adds-later)).

Finishing removes a transaction from the store's redelivery queue for good, which is why a foreign one is left for whoever owns that product, and an unverified one is left to be offered again. Reading entitlements finishes nothing at all.

An unverified transaction is logged as `unverifiedTransactionIgnored` on **every** path it can arrive by — bought, arriving on its own, or read from the listing. The listing is the path on which it locks a paying customer out, and it was the one path that said nothing. A foreign transaction is logged when it is bought or arrives, and not when the listing is read: it is in the listing at every read, for good, and is no news.

Whether an adopted transaction *counts* for this account — a family-shared trial does not — is `StandingResolver`'s decision in Core. The adapter reports facts.

## Updates carry facts

`transactionUpdates()` yields `.granted(OwnedProduct)`, `.withdrawn(ProductID)`, `.subscriptionChanged(HeldSubscription)` with the new status, or `.purchaseRequested(RequestedPurchase)` for a purchase asked for outside the app. It merges three sources — transactions, statuses and intents — and ends only when all three have. A grant arrives **before** `currentEntitlements` has it, so a listener told only "something changed" reads the listing, finds nothing, and never looks again. A refund does not lag. **[ran]** See [decisions, D4](10-decisions.md#d4-the-updates-stream-carries-facts-not-a-signal).

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
| `Product.PurchaseError.ineligibleForOffer` | `offerRefused(.notEligible)` |
| `Product.PurchaseError.invalidOfferSignature` | `offerRefused(.invalidSignature)` — the app's server, and apart from the rest for that reason |
| `Product.PurchaseError.invalidOfferIdentifier`, `.invalidOfferPrice`, `.missingOfferParameters` | `offerRefused(.unknownOffer)`, `(.invalidPrice)`, `(.missingParameters)` |
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
