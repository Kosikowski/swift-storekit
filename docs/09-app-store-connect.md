# App Store Connect and the StoreKit configuration file

The setup that is not code: agreements, products, Family Sharing, review metadata, the `.storekit` file, sandbox and TestFlight, and what differs on macOS. Most purchasing failures that "cannot be reproduced" start here, because nothing in this list reports an error. The product does not load, and the Buy button does nothing.

**The package reports store facts and performs store actions; the app owns product policy.** App Store Connect is where the store's facts are defined, and the package cannot see into it. What it can do is check the local copy of those facts against the catalogue, which is [one unit test](#check-the-file-against-the-catalogue).

Evidence tags: `[ran]` was measured by running it (macOS 26, Xcode 27), `[Apple]` is from Apple's documentation and is not tested here, `[check]` is believed and unverified. Confirm `[check]` items on your own account before relying on them.

## Before any product will load

- [ ] **The Paid Apps Agreement is active**, with tax and banking complete. Until it is, products never load, in sandbox included, and nothing says why `[Apple]`.
- [ ] **The build is one App Store Connect knows**: signed with the team that owns the app record, with a matching bundle identifier. A debug build it does not know receives no products and no entitlements `[ran]`; see [the `.storekit` file](#the-storekit-configuration-file).

## Create the products

An unlock and a trial are **non-consumables**; a subscription is an **auto-renewable subscription**, set up [below](#subscriptions). In App Store Connect, open the app, then In-App Purchases under Monetization, and create one product per catalogue entry that is not a subscription.

| Field | The unlock | The trial |
|---|---|---|
| Type | Non-Consumable | Non-Consumable |
| Product ID | Exactly the catalogue's `ProductID` | Exactly the catalogue's `ProductID` |
| Reference name | For you; never shown | For you; never shown |
| Price | Your price | **Tier 0 (free)** |
| Display name | For example "Pro" | **Named for what it is: "14-day Trial"** |
| Family Sharing | **On** | **Off** |

A product ID cannot be reused, even after the product is deleted `[Apple]`. Choose it once, and write it in exactly one place in the app ([catalogue](03-catalogue-and-standing.md)).

### The trial product

Guideline 3.1.1 allows a non-subscription app to offer a free time-based trial by setting up a non-consumable at price tier 0 whose name follows the convention "XX-day Trial" `[Apple]`. The same guideline puts three things on the app: before the trial starts, the app must clearly identify its duration, the content or services that will no longer be accessible when it ends, and any charges the person would need to pay for full functionality `[Apple]`. That is paywall wording, so it is yours and not the package's.

The length in the display name and the `Duration` in the catalogue are two separate statements of the same fact. Nothing compares them. Change both or neither.

### Family Sharing

Turn it **on for the unlock** and **off for the trial**.

A family-shared transaction carries the purchaser's dates. A shared trial would hand every family member the organiser's start date, which is often already past its end, and take away their own trial.

**The switch cannot be turned off once it is on** `[Apple]`. For that reason the package guards it in code regardless of how the switch is set: a trial counts only when this account bought it, and an unlock declared `.unlock(id, familySharing: .ignored)` does not count when shared. Setting the switch correctly is still worth doing, because it decides what the App Store shows and delivers to family members.

If Family Sharing is switched on for a non-consumable that some people have already bought, their family members receive it only through a restore `[check]`. This is one of the few cases where the Restore Purchases button does real work.

## Subscriptions

Under Monetization, Subscriptions: create a **subscription group**, and the subscriptions in it. One group is right for most apps `[Apple]`: a person can hold one subscription per group, and moving between the group's plans is an upgrade, downgrade or crossgrade rather than a second subscription — which is what guideline 3.1.2(b) asks for `[Apple]`.

| Field | Where it goes |
|---|---|
| The group's ID | The catalogue's `SubscriptionGroupID`, exactly |
| Each subscription's Product ID | The catalogue's `ProductID`, exactly |
| The ranking of the group's subscriptions | The catalogue's `level`. **1 is the highest** `[ran]` |
| Duration, price | App Store Connect's alone; the package reads them from the store |
| Family Sharing | As the catalogue's entry says; like a non-consumable's, it cannot be turned off again once on `[Apple]` |

**Turn on the billing grace period** (Monetization, Subscriptions, Billing Grace Period): 3, 16 or 28 days, for all renewals or paid-to-paid only `[Apple]`. With it, a person whose payment fails keeps access while Apple retries, and the package grants it ([D35](10-decisions.md#d35-subscriptions-are-decided-by-the-status-by-apples-rule)); without it, they are in billing retry at once, which is not access. It can be turned on for the sandbox alone first, and changes take up to 24 hours `[Apple]`.

Offers — introductory, promotional, win-back, codes — are set on each subscription. What each does and who decides who gets it is in [the research](13-subscriptions-and-offers.md#offers); the package applies an introductory offer through a plain purchase, and the rest are [phase 2](14-subscriptions-plan.md#phase-2-offers).

App Review asks a subscription paywall for the plan's name, length and full renewal price, with the amount billed the most prominent price; links to the terms and the privacy policy; a way to restore; and an easy route to Apple's page to manage it `[Apple]` — `ManageSubscriptionsButton` ([subscriptions](15-subscriptions.md#managing)).

## Localisations and review information

Each product needs, before it can be submitted `[Apple]`:

- at least one **localisation**: a display name and a description. The app shows these through `StoreProduct.displayName` and `.description`, so write them for customers;
- a **review screenshot** showing the product on the paywall, and review notes if the purchase is hard to find;
- a price and availability.

A product without them sits at "Missing Metadata" and cannot be submitted `[Apple]`.

## The first in-app purchases go in with an app version

An app's first in-app purchases must be submitted together with a new app version: select them in the version's In-App Purchases section before submitting it for review `[Apple]`. Later products can be submitted on their own.

Until a product is approved it is absent from the production store. That is not an error to the package. `products()` returns fewer than were asked for, and `StoreDiagnosis.hints` reports `.someProductsMissing`.

## Restore Purchases

App Review expects a way to restore restorable purchases `[Apple]`. Put a Restore Purchases button **on the paywall and somewhere in settings**; `RestorePurchasesButton` is the package's.

It is rarely needed, because StoreKit keeps itself current. It prompts for the account password, so it is for a button the person presses, and is never called on their behalf. A failed restore never takes away what was already known to be owned.

## The `.storekit` configuration file

A debug build that App Store Connect does not know receives nothing from StoreKit: an empty product list, empty entitlements, and purchases that fail `[ran]`. A `.storekit` file gives builds launched from Xcode a local store to buy from.

- [ ] **Local or synced.** A *synced* file mirrors the products in App Store Connect and is refreshed from it; a *local* file is edited in Xcode or by hand, and needs no account `[Apple]`. Local is enough for everything in this package, and works before the products exist in App Store Connect.
- [ ] **Attach it to the scheme's Run action.** Product › Scheme › Edit Scheme… › Run › Options › StoreKit Configuration. With XcodeGen: `schemes.<name>.run.storeKitConfiguration: path/to/File.storekit` `[ran]`.
- [ ] **The scheme setting applies only to builds launched from Xcode.** A build started any other way, from Finder or from a script, asks the App Store `[Apple]`.
- [ ] **Keep the file out of the shipping app.** It must not be a member of the app target's resources. XcodeGen's default build phase for `.storekit` is "none", so it is not copied into the bundle; confirm that in the generated project `[ran]`.
- [ ] **Add it to the test bundle's resources** if tests read it. A sandboxed test host cannot read the repository `[ran]`.
- [ ] **Refund and delete test purchases** with Debug › StoreKit › Manage Transactions while the app runs from Xcode `[Apple]`. Use it to exercise refunds and downgrades by hand.
- [ ] **Your own daily-use debug build becomes a free user** once it buys from the local file. Buy the unlock locally (nothing is charged), or everything you gate will lock on you.

### A file written by hand

A hand-written file is valid if `SKTestSession(contentsOf:)` loads it and `Product.products(for:)` returns its products `[ran]`. The minimal shape, which is `Demo/Demo.storekit` with its second product left out (so the identifiers are the Demo's, not the `Shop` of getting started):

```json
{
  "identifier" : "D3A0C0DE",
  "nonRenewingSubscriptions" : [ ],
  "products" : [
    {
      "displayPrice" : "19.99",
      "familyShareable" : true,
      "internalID" : "6800000001",
      "localizations" : [
        { "description" : "Everything, for good.", "displayName" : "Demo Pro", "locale" : "en_US" }
      ],
      "productID" : "com.example.purchasedemo.pro",
      "referenceName" : "Pro",
      "type" : "NonConsumable"
    }
  ],
  "settings" : {
    "_failTransactionsEnabled" : false,
    "_locale" : "en_US",
    "_storefront" : "USA",
    "_storeKitErrors" : [ ]
  },
  "subscriptionGroups" : [ ],
  "version" : { "major" : 4, "minor" : 0 }
}
```

The root `identifier` and each product's `internalID` are yours to make up. Choose them once and leave them alone: Xcode keeps test transactions between runs, and changing the identifiers under them is asking for stale state `[check]`.

### Check the file against the catalogue

A product identifier is written in three places (App Store Connect, the `.storekit` file, the app) and nothing compares them. `StoreKitConfiguration` in `PurchaseTestKit` reads the file as the JSON it is, without StoreKit, so the comparison is an ordinary unit test:

```swift
import PurchaseTestKit
import Testing
@testable import YourApp        // for `Shop`

@Test("the StoreKit configuration file sells exactly what the catalogue declares")
func storeKitFileMatchesCatalogue() throws {
    let file = try StoreKitConfiguration(contentsOf: url)   // finding `url` is covered below
    file.expectNoProblems(against: Shop.catalogue)
}
```

Each thing that is wrong is a failure of its own, as a sentence. A rename in one place is two:

```
com.example.app.professional is in the catalogue and not in the StoreKit configuration file, so it will never load. Was it renamed in one place only?
com.example.app.pro is in the StoreKit configuration file and not in the catalogue, so the app never asks for it. Was it renamed in one place only?
```

| `StoreKitConfigurationProblem` | The rule it enforces |
|---|---|
| `.missing(ProductID)` | Every catalogue identifier is in the file |
| `.unexpected(ProductID)` | Nothing else is |
| `.notNonConsumable(ProductID, type:)` | Every unlock and trial is a non-consumable, wherever in the file it was found |
| `.notAutoRenewable(ProductID, type:)` | Every subscription is a `RecurringSubscription` |
| `.subscriptionGroupMismatch(ProductID, catalogue:, file:)` | A subscription is in the group the catalogue names |
| `.subscriptionLevelMismatch(ProductID, catalogue:, file:)` | A subscription is at the level the catalogue names (`groupNumber` in the file) |
| `.trialNotFree(ProductID, displayPrice:)` | A trial is priced at exactly zero. A price that cannot be read is not free |
| `.trialFamilyShareable(ProductID)` | A trial is not family-shareable |
| `.familySharingMismatch(ProductID, catalogueHonours:, fileShares:)` | An unlock or a subscription is family-shareable exactly when its entry honours Family Sharing |

Finding the file from a test:

| Test target | How |
|---|---|
| Hosted by an app (Xcode) | Add the file to the test bundle's resources, then `Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?.url(forResource:withExtension:)`, as `Demo/Tests` does `[ran]` |
| SwiftPM | Declare it under `resources:` and use `Bundle.module.url(forResource:withExtension:)` |

The reader is lenient on purpose. The format is undocumented, and Xcode has written schema versions 3.0, 4.0 and 6.x so far, so unknown keys are ignored and a newer Xcode saving the file does not break your tests. `StoreKitConfiguration` is not `DEBUG`-only, so this test builds in any configuration.

The file is a stand-in for App Store Connect, and this test proves only that the stand-in agrees with the app. Nothing can check App Store Connect itself from a unit test; [the diagnosis](#when-the-buy-button-does-nothing) helps there.

The same file can feed a [simulated store](06-simulated-store.md), through `SimulatedStoreFront(catalogue:configuration:)`, so that previews and screenshots show the real names and prices.

## Sandbox and TestFlight

| Environment | Reached by | Products come from |
|---|---|---|
| Xcode | A build launched from Xcode with a `.storekit` file on the scheme | The file |
| Sandbox | A development-signed build without the file, signed in with a sandbox Apple Account; and TestFlight builds | App Store Connect, including products not yet approved `[check]` |
| Production | The App Store build | App Store Connect, approved products only |

- Create sandbox testers under Users and Access › Sandbox in App Store Connect `[Apple]`. A sandbox account works only with apps of the same developer account, and a change to a product's metadata can take an hour to reach it `[Apple]`.
- **A build launched from Xcode with the `.storekit` file on its scheme never reaches the sandbox.** To test there, set the scheme's StoreKit Configuration to None, or launch the development-signed build some other way.
- **Family Sharing can only be tested here.** Xcode's environment has a Family Sharing checkbox per product and no way to make a purchase arrive *as* a family member's. It is also the one thing the [simulated store](06-simulated-store.md) does that no automated Apple tool can: `seed(_:age:ownership: .familyShared)`. By hand, in the sandbox:

  1. In App Store Connect, under Users and Access › Sandbox, put two sandbox testers in a **Sandbox Test Family** (up to six, all of one storefront) `[Apple]`.
  2. Sign one in on a device and buy the family-shareable unlock. Sign the other in on a second device, or the same one afterwards, and launch the app. The purchase reaches the second tester as a transaction whose ownership is family-shared `[Apple]`; if it does not turn up, Restore Purchases — see the note on restores under [Family Sharing](#family-sharing) `[check]`.
  3. For the second tester, expect `standing.ownership(of: Shop.pro)?.ownership == .familyShared` and `access(to:)` to be `.owned` for an unlock that honours Family Sharing — and, for one declared `.ignored`, `access(to:)` to be `.none` with the Buy button still there. Have the first tester take the trial as well: for the second, `trial(Shop.trial)` must stay `.available`, because a shared trial is never counted.
  4. Then take it away: the family's sharing settings for the sandbox account have "Stop Sharing Purchases" (App Store Connect, or Settings › Developer on iOS) `[Apple]`. The app receives the transaction again with a revocation date, and the unlock should lock **without a relaunch**.
- Ask to Buy in the sandbox stops at *pending* (`.simulatesAskToBuyInSandbox`); only Xcode's environment can approve or decline it `[Apple]`.
- TestFlight purchases are free and use the sandbox `[Apple]`.
- `StoreDiagnosis.environment` reports "Xcode", "Sandbox" or "Production". It is read from an entitlement, so it is nil until the account owns something. (A simulated store says "Simulated".)
- A trial is one per account, and a sandbox account is an account. Once a tester has taken the trial, it stays taken. App Store Connect can clear a sandbox tester's purchase history `[Apple]`; whether that returns the trial to `.available` on a given device is worth confirming before you depend on it `[check]`. A fresh sandbox tester always has the trial available.
- Ask to Buy and refunds are quickest to exercise with the `.storekit` file and Xcode's transaction manager, or with the simulated store. Backdating a non-consumable, to reach "the trial ends in five minutes", is documented by Apple and works in the iOS 27 simulator, and on macOS 26 with Xcode 26; it does not work under `SKTestSession` with Xcode 27.0 on macOS 26 `[ran]`; see [trials](04-trials.md#testing-the-trial-ends-in-five-minutes) for what to do instead.

## When the Buy button does nothing

Ask the store what this build receives. `AppStoreFront` conforms to `StoreDiagnosing`:

```swift
let diagnosis = await AppStoreFront(catalogue: Shop.catalogue).diagnose()
diagnosis.requested      // the catalogue's identifiers
diagnosis.received       // the products the store returned for them
diagnosis.catalogueFailure // why the store could not be asked, if it could not; `received` then says nothing
diagnosis.missing        // requested, not received
diagnosis.environment    // "Xcode", "Sandbox", "Production", or nil; "Simulated" from a simulated store
diagnosis.hints
```

| `StoreDiagnosis.Hint` | Usual cause |
|---|---|
| `.catalogueLoadFailed(PurchaseError)` | The store could not be *asked* — offline, most often. It says nothing about the products or the build, and replaces the two hints below until the store can be reached |
| `.storeSellsNothingToThisBuild` | No `.storekit` file on the scheme, and a build App Store Connect does not know; or the Paid Apps Agreement is not active |
| `.someProductsMissing(Set<ProductID>)` | Misspelt, or not yet ready for sale |
| `.unverifiedEntitlementsPresent(Int)` | Entitlements that did not verify, and are being ignored |

`PurchaseDebugPanel` shows the same thing under "What this build receives".

## macOS

- [ ] **In-app purchase needs a Mac App Store build.** A Developer ID build, or any build sold another way, has no App Store behind it: StoreKit lists nothing, and a build that *is* the paid edition would lock its own buyers out `[Apple]`. Give such a build `EverythingOwnedStoreFront` at the composition root, or licensing of your own behind the same five protocols ([architecture](01-architecture.md)). `EverythingOwnedStoreFront` owns every unlock, offers no trial and sells nothing, and it ships in release builds by design ([getting started](02-getting-started.md#the-composition-root)).
- [ ] **Universal Purchase.** One app record with both the iOS and the macOS platform shares its in-app purchases: bought on one, owned on the other. Separate app records do not share anything, and their product IDs are separate products `[Apple]`.
- [ ] **Several windows.** Say which window the payment sheet belongs over. `PurchaseButton` does this for you ([getting started](02-getting-started.md#say-where-the-payment-sheet-goes)).
- [ ] **Sandbox.** StoreKit's transactions run in a system process, so the purchase flow should need no network entitlement of its own `[check]`.
