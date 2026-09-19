# Plan: subscriptions and offers

**Status: proposed, 19 September 2026. Nothing here is built.** The research is [Subscriptions and offers in StoreKit](13-subscriptions-and-offers.md); this is what to build from it, in what order, and what to measure before any of it.

Evidence tags as in the research. Names in code sketches are placeholders, to be settled in phase 1; the shapes are the proposal.

## In one page

- **What.** Auto-renewable subscriptions first: what the account holds in each group, whether it gives access, when that changes, and buying, changing and managing a plan. Then offers: introductory, win-back, promotional, and codes. Non-renewing subscriptions and the newer shapes (12-month commitment, bundles, seats) come after, on demand.
- **How.** The package's rule does not change: **it reports store facts and performs store actions; the app owns product policy.** A subscription's state, its renewal, its offers and who Apple says is eligible are facts. What a subscription unlocks, what a lapse locks, which promotional offer to give to whom, and the paywall are the app's.
- **The discounted price for returning subscribers** is an App Store offer, not code. Phase 2 supports the two ways to do it: **win-back offers**, where Apple decides who qualifies and no server is needed, and **promotional offers**, where the app decides and its server signs. [The research](13-subscriptions-and-offers.md#who-runs-a-discounted-price-the-short-answer) explains the choice, and why a second product in a second group is not the way.
- **Measure first.** Every behaviour of real StoreKit the design rests on is measured in the hosted suite before it is built on, as the package did for non-consumables. Sixteen questions, [below](#phase-0-measure-first).
- **No server.** Nothing here needs one, except promotional offers and the introductory override, for which the app supplies the signature. The package never holds a key.

| Phase | What | Size | Needs |
|---|---|---|---|
| **0** | Measure real StoreKit's subscription behaviour, per OS | Small to medium | Nothing |
| **1** | Auto-renewable subscriptions: state, access, renewal, plan changes, manage, simulated store | Large | Phase 0 |
| **2** | Offers: terms, eligibility, win-back, promotional, override, codes | Medium | Phase 1 |
| **3** | On demand: non-renewing, 12-month commitment, bundles, seats, retention offers, `PurchaseIntent` | Small to medium each | Phase 1 |

## What the rule means for subscriptions

| In the package: facts and actions | Left to the app: policy |
|---|---|
| What the account holds in each group, at which level, since when, until when, and how it came by it | What each level unlocks |
| Whether that gives access by Apple's rule: subscribed or in a grace period | Whether to be more lenient in billing retry, and what a lapse locks |
| Whether it will renew, to what, at what price, and whether a price increase awaits consent | How a coming lapse, a pending downgrade or a price rise is worded |
| The terms of every offer, as the store states them | Which offer to feature, and the paywall |
| Which offers Apple says this person may have: introductory, win-back | Which promotional offer to give, and to whom |
| Buying, with an offer; changing plan; opening Apple's manage page | When to ask; the signature for a promotional offer, from the app's server |
| Typed outcomes and errors, including an offer refused | The sentence shown for each |

There is still no `isPro`, and still no paywall.

## How others do it

A survey of eleven libraries and Apple's three samples, read at their current source in September 2026. What matters here is where they went wrong. [Sources](#sources) are at the end.

| | Access | Status detail | Offers | Server | Tests |
|---|---|---|---|---|---|
| **RevenueCat** | Entitlements, computed on its server with the server's clock | Rich; grace folded into the entitlement's expiry, so `isActive` and `expirationDate` disagree during grace | All four; promotional signed on its server | Yes; on-device fallback only when the server fails | Hosted `SKTestSession`, real transactions injected, API testers |
| **Adapty, Qonversion, Apphud** | Server access levels | Varies; Apphud's one enum mixes offer phase with lifecycle | Mostly; codes through StoreKit 1's sheet | Yes | Little or none of purchases |
| **Superwall** | `unknown`, `inactive`, `active(entitlements)`, on the device | `state`, `willRenew`, `offerType` | Introductory only, plus the override | Its dashboard | Simulated "test mode" |
| **Mercato, Flare, StoreHelper** and smaller open-source wrappers | Product identifiers | From none to all of `RenewalInfo` | Introductory; promotional through an app closure at best; **no win-back** | No | From none to hosted `SKTestSession` |
| **Apple's samples** | App-defined tier over the group's statuses | Everything | All, natively | Only to sign | Hosted `SKTestSession` |

**Mistakes the others made, which this plan is shaped to avoid:**

1. **Grace-period subscribers locked out**, by testing `expirationDate > now` or `state == .subscribed` alone: Mercato, FlareUI, StoreHelper, SKHelper, SwiftyStoreKit. Apple's own sample code disagrees with itself: SKDemo counts billing retry as entitled; Backyard Birds ignores the state altogether; Food Truck is right, then clears the entitlement on one family member's status.
2. **`statuses.first`**, or one `currentEntitlement(for:)` row, when a group can have several statuses (own and family) and the singular call is deprecated: Mercato, the 2021 SKDemo.
3. **Eligibility invented**: assumed true when the product could not be fetched (Apphud); "the product has a trial" taken for "this person may have it" (Qonversion); "eligible" for products with no introductory offer (RevenueCat, fixed with a fourth state).
4. **A purchase continued after its offer failed to sign** (Glassfy), or an offer type an app cannot construct (Mercato).
5. **Offline leeway invented**: 30 days (merchantkit), a one-hour stub (Apphud), an estimated expiry (Qonversion). A client has no trusted clock; the package says so, as it does for trials.
6. **A listener that dies** on the first event it did not expect, through a `return` inside the `for await` (StoreHelper, SKHelper), and was blamed on StoreKit.
7. **Frozen enums mirroring StoreKit's open ones.** Adapty had to turn its offer type into a struct; the 27 SDK added `.assigned`, `.unbundled`, bundles and suites.
8. **Public names that collide with StoreKit's.** StoreKit 18.4 added top-level `SubscriptionInfo`, `SubscriptionStatus`, `SubscriptionPeriod` and `SubscriptionRenewalInfo`; RevenueCat and StoreHelper stopped compiling in apps that imported both.
9. **iOS-only calls assumed on macOS**: the manage sheet, `Message`, `SubscriptionOfferView`.

**What to take:** per-group statuses, and the highest level across all of them; state, renewal intent, offer phase and ownership as separate facts rather than one enum; the date access ends named apart from the date the period ends; four-state introductory eligibility that shows the regular price when unknown; win-back offers as the eligible IDs from the account's *own* status, in Apple's order; promotional offers only through a signature the app supplies; listening to status changes as well as transactions; and tests of the pure rules with explicit dates, a simulated store, and a hosted lane with a fast renewal rate.

## The design

### The catalogue

A subscription entry names its group and its level:

```swift
enum Shop {
    static let pro = SubscriptionGroupID("21456789")     // App Store Connect's identifier for the group

    static let catalogue: Catalogue = [
        .unlock(lifetime),
        .subscription(monthly, in: pro, level: 2),
        .subscription(yearly, in: pro, level: 2),
        .subscription(premiumYearly, in: pro, level: 1),
    ]
}
```

**Why restate them.** The group's identifier is what `status(for:)` takes, and it is static: asking needs no product loaded, so what a person may use still waits for no network ([D8](10-decisions.md#d8-not-answered-yet-is-a-state-and-ownership-does-not-wait-for-prices)). The level is needed to choose between statuses — the person's own and a family member's — without prices either. Both are restated for the reason Family Sharing is: a transaction does not carry them reliably and prices must not be waited for. The [`.storekit` check](#checking-the-storekit-file) keeps the restatement honest. Which way App Store Connect numbers levels is `[check]` ("1 is the highest" is the working assumption).

`Catalogue.problems(in:)` gains: a subscription with no group; two groups sharing a product; a level below 1; a trial that names a subscription (a trial stands in for an unlock, and a subscription has its own introductory offer). Family Sharing is declared as it is for an unlock, honoured by default.

### What the store reports: the standing

A **held subscription** is one status the store reports for one group:

```swift
public struct HeldSubscription: Hashable, Sendable {
    public let product: ProductID
    public let group: SubscriptionGroupID
    public let ownership: Ownership
    public let state: State
    public let firstSubscribed: Date      // originalPurchaseDate: the same across renewals
    public let periodStarted: Date
    public let periodEnds: Date           // expirationDate
    public let offer: AppliedOffer?       // the offer this period was bought with, if any
    public let renewal: Renewal?          // nil: the status was not read, so nothing is known of what comes next

    public enum State: Hashable, Sendable {
        case subscribed
        case inGracePeriod(until: Date)
        case inBillingRetry
        case expired(Lapse)
        case revoked
        case unrecognised                 // a state StoreKit added later: said, not guessed
    }
}

public struct Renewal: Hashable, Sendable {
    public let willRenew: Bool
    public let nextProduct: ProductID?    // differs from `product` while a downgrade or crossgrade waits for the renewal
    public let price: RenewalPrice?       // with any offer applied; show `displayPrice`
    public let priceIncrease: PriceIncrease   // .none, .awaitingConsent, .agreed
    public let winBackOffers: [OfferID]   // Apple's, best first; empty in grace or billing retry
}
```

Four facts on separate axes — state, renewal intent, the offer in force, ownership — because every library that folded them into one enum then needed flags beside it for the combinations it could not say ("in a free trial *and* not renewing").

Per group, `Standing` answers:

```swift
standing.subscription(in: Shop.pro)   // SubscriptionStanding
```

```swift
public enum SubscriptionStanding: Hashable, Sendable {
    case unknown                                   // the store has not answered
    case none                                      // never subscribed in this group
    case active(HeldSubscription, all: [HeldSubscription])    // the one that decides, and every status
    case inactive(HeldSubscription, all: [HeldSubscription])  // the most recent, lapsed, in billing retry or revoked
}
```

"The one that decides" is the entitled status with the highest level, the person's own preferred over a family member's, then the later `periodEnds`: the rule `StandingResolver` already applies to duplicate unlocks, extended by level. `ProductAccess` gains `case subscribed(HeldSubscription)`, and `isGranted` is true for it.

### Access follows Apple's rule, and nothing else

**Subscribed and in a grace period give access; billing retry, expired and revoked do not.** That is Apple's entitlement rule `[Apple]`, and a grace period is a contractual obligation to serve `[Apple]`. Billing retry is reported as a state, not granted: an app that wants to be more lenient, as SKDemo is, reads the state and decides so itself. That is policy, and it is written down in the app where it can be seen.

Two sources say what is held, and they are combined the way the package combines its sources already:

- **`currentEntitlements`**, which lists the subscribed and the ones in a grace period, and is what is read today;
- **`status(for:)`** per group, which adds everything else: renewal, lapse, retry, offers.

**Either is enough to grant; a lapse needs both.** A verified status in an entitled state grants even when the listing omits it, which has been reported `[check]`. A subscription stops giving access when the listing no longer has it and no status read says it is entitled. A status read that fails changes nothing ([D9](10-decisions.md#d9-nothing-downgrades-on-a-failure)): access comes from the listing, and `renewal` is nil. **Access never waits for a status read**, as it never waits for prices.

### The clock decides when to look, and the store decides what is true

A trial ends by the clock, because nothing in the store changes when it does ([D12](10-decisions.md#d12-a-trial-is-a-free-non-consumable-dated-by-the-app-store)). **A subscription's end is the store's to say**: at `periodEnds` it may have renewed, gone into grace, or lapsed, and only the store knows which. So the clock schedules a look, and the listing and the status decide:

- `Standing.nextExpiry` includes the soonest `periodEnds`, or the end of the grace period, of anything held. The store reads again then, as it does for a trial.
- If the period has ended and the store still lists the subscription with nothing newer — the renewal not synced yet — access holds and the store looks again on a widening interval, up to a limit, and whenever the app becomes active. **What the listing does in that minute is phase 0's first question.**
- **Every activation reads again.** Cancellations and renewals made while the app was closed may never arrive as events `[check]`. The package already recommends `refresh()` on activation; for subscriptions it is part of the contract.

`access(to:at:)` keeps its signature. For a subscription it answers what the store last said; the dates are in the `HeldSubscription` for an app that wants to show "renews on" or "ends on".

### Buying, and changing plan

```swift
try await store.purchase(Shop.monthly)                                  // introductory offer applied if Apple says so
try await store.purchase(Shop.monthly, offer: .winBack(offerID))        // phase 2
try await store.purchase(Shop.monthly, offer: .promotional(offerID))    // phase 2: the store asks the app's signer
```

`PurchaseCompletion` gains `.subscribed(HeldSubscription)` and `.planChangeScheduled(to: ProductID, at: Date)`, because a downgrade takes effect at the renewal and must not be reported as done `[Apple]`. An upgrade is `.subscribed` at the new level at once. What `purchase()` returns for each of the three — and whether the transaction that was upgraded away from stays listed — is measured in phase 0. A purchase in a group where the person already holds the same product is `.subscribed` with what they hold.

`appAccountToken` becomes an option on every purchase, for apps with a server of their own, passed through untouched.

**Holds carry over.** A subscription bought here is listed late, like anything else ([D3](10-decisions.md#d3-a-grant-is-believed-until-the-store-lists-it)); it is held until the listing counts it, it is withdrawn, or `listingGrace` runs out — and never beyond its own `periodEnds`.

### Managing: Apple's page, never the app's

`PurchaseUI` gains `ManageSubscriptionsButton`, beside `RestorePurchasesButton`. On iOS it presents `manageSubscriptionsSheet` for the group; **on macOS, where there is no sheet, it opens `https://apps.apple.com/account/subscriptions`** `[Apple]`. When it closes, or when the app becomes active again, the store reads. A cancellation made there arrives as nothing else would.

### Transactions: what is finished, and what counts

[D6](10-decisions.md#d6-what-is-finished-and-what-is-left-alone) extends without change of principle:

| Transaction | Finished | Counted |
|---|---|---|
| A renewal, verified, in the catalogue | Yes | Yes, until the store says otherwise |
| A transaction upgraded away from (`isUpgraded`) | Yes | **No**: the higher one counts |
| Revoked: refund, end of Family Sharing, end of a seat | Yes | No |
| Unverified, or not in the catalogue | **No**, as now | No |

`TransactionTriage` gains a verdict for the upgraded-away-from. `TransactionUpdate.granted` carries the subscription's dates, so a renewal arriving on its own is believed at once, as an approved Ask to Buy is ([D4](10-decisions.md#d4-the-updates-stream-carries-facts-not-a-signal)). The adapter also listens to `Status.updates`, and a status change carries its facts too.

### Ports and the adapter

Core stays free of StoreKit, and each new role is a port a fake can play:

| Port | Contract |
|---|---|
| `SubscriptionStatusReading` (new) | Every status for the groups asked, per group; a failure per group is reported, never thrown; no side effects; read in a task nobody cancels, if phase 0 finds a cancelled read answers with nothing, as `currentEntitlements` does |
| `IntroductoryEligibilityReading` (new, phase 2) | Apple's answer per group, as `eligible`, `ineligible` or `unknown`; never throws |
| `OfferSigning` (new, phase 2, **the app's**) | Returns a compact JWS for a product and offer, from the app's server. The package calls it only for a purchase that needs it, and never proceeds without it |
| `ProductPurchasing` | Takes the offer and the account token |
| `TransactionObserving` | Also yields status changes |

In `PurchaseStoreKit`, `LiveStoreKitGateway` still only fetches, forwards and copies: statuses, renewal info, a product's subscription details and offers, eligibility, and `Status.updates`. Every decision is one layer up, where the fake gateway reaches it under `swift test` ([D1](10-decisions.md#d1-real-storekit-is-tested-from-a-host-app)). Every StoreKit value that is an open set crosses with an `unrecognised` case, as `PurchaseResult` does ([D21](10-decisions.md#d21-a-result-storekit-adds-later-is-a-failure-never-a-cancellation)). The 26.4 fields sit behind `#available`; nothing from the 27 SDK is named unguarded ([D17](10-decisions.md#d17-no-sdk-27-only-symbols)).

### Offers (phase 2)

**Terms come from the product, never from the app's code.** `StoreProduct` gains a subscription description: its group, its billing period, and each offer's kind, payment mode, period, number of periods and `displayPrice`. It loads with the prices, and like them it is never waited for by anything that decides access.

| Offer | What the package reports | What the app does |
|---|---|---|
| **Introductory** | Per group: `eligible`, `ineligible`, `noOffer` (the product has none) or `unknown`. Asked again whenever the standing changes. **`unknown` means show the regular price**, and the payment sheet has the last word | Shows the terms; buys with a plain `purchase()` |
| **Win-back** | The offers Apple says this person may have now: the eligible IDs from the account's **own** status, matched to the product's win-back offers, in Apple's order `[Apple]` | Features one; buys with `.winBack(id)`. Apple also shows them outside the app, and redemptions there arrive as transactions |
| **Promotional** | The product's promotional offers; whether this person has ever subscribed in the group, since promotional offers are only for current and former subscribers `[Apple]`; a purchase for someone who never has is refused before the signer is asked | Decides who gets which; implements `OfferSigning` against its server |
| **Introductory override** | The same signer, for the introductory eligibility JWS `[Apple]` | The same |
| **Offer code** | Redemptions are transactions like any other and arrive through the listener, which is on from the first command. With the 27 SDK the redemption sheet also returns the transaction, and it is taken as a purchase's would be | Presents Apple's sheet: a custom code field is not allowed `[Apple]` |

`PurchaseError` gains an offer refused, keeping StoreKit's reasons apart — invalid signature, not eligible, unknown offer, missing parameters — and a signer that failed, which never becomes a purchase.

**The returning-subscriber discount**, concretely: configure win-back offers on the subscription in App Store Connect; the package reports `renewal.winBackOffers` for someone who has lapsed long enough, and the app shows the first with its terms from the product and buys it. Apple does the rest, including for people who never open the app. For a rule of the app's own — lapsed less than a month, say — a promotional offer with a signer.

### The simulated store, scenarios and the debug panel

The simulated store is the reason the package's rules are tested in milliseconds, and subscriptions need it more than purchases do: a year of renewals is a clock advanced, not a year.

- **Subscriptions by the store's clock.** A subscription renews, goes into grace or billing retry, or lapses when the store's clock passes its `periodEnds`, according to `behaviour.renewal` (`.renews`, `.lapses`, `.billingRetry(grace:)`). A renewal is a new transaction with the same first date, announced and listed late, as measured.
- **Arranging and happenings**: `subscribe`, `cancelAutoRenew`, `resumeAutoRenew`, `renewNow`, `lapse`, `failRenewal(grace:)`, `recoverBilling`, `changePlan(to:)` (an upgrade at once, a downgrade at the renewal), `share(fromFamily:)`, `raisePrice(needsConsent:)`, and the existing `revoke`.
- **Offers**: introductory eligibility kept per group from the store's own history; win-back offers made eligible by a lapse, as configured; a promotional purchase that calls the app's signer and can be told to reject it.
- **Its habits** are the ones phase 0 measures, per OS, and each is held to the real thing by a test in `Demo/Tests`, as now ([D28](10-decisions.md#d28-the-simulated-stores-habits-are-per-os-and-each-is-held-to-the-real-thing)).
- **Scenarios** grow holdings with a state: `subscribed=monthly@10d`, `subscribed=monthly/grace`, `subscribed=monthly/retry`, `subscribed=monthly/cancelled`, `lapsed=monthly@40d`, `winback=offer-id`, `intro=used`.
- **The debug panel** grows a section per group: renew now, lapse, billing retry with or without grace, cancel and resume, change plan, refund, shared by a family member, price increase.

### Checking the `.storekit` file

`StoreKitConfiguration` already finds products inside subscription groups ([D18](10-decisions.md#d18-the-storekit-format-is-read-leniently)). It gains the checks that keep the catalogue's restatements honest: every catalogue subscription is an auto-renewable in the group it names, at the level it names; Family Sharing agrees; and, in phase 2, the offers the app refers to exist. Fixtures are files written by Xcode 26.6 and 27.

### Names

No public name the package adds may be one StoreKit already has at the top level — `SubscriptionInfo`, `SubscriptionStatus`, `SubscriptionPeriod`, `SubscriptionRenewalInfo`, `SubscriptionRenewalState` — because an app that imports both would not compile. `HeldSubscription`, `SubscriptionStanding`, `Renewal` and `SubscriptionGroupID` are chosen for that; phase 1 checks the list against the SDKs of Xcode 26.6 and 27 in a test that imports both.

## Phases

### Phase 0: measure first

Every row of the research marked `[check]` that the design leans on, measured in the hosted suite (`Demo/Tests`) with a `.storekit` file holding a subscription group, on macOS 26.6 with Xcode 26.6 and 27.0, and in the iOS 27 simulator. One question per clean environment ([D23](10-decisions.md#d23-every-hosted-test-resets-storekits-test-environment-and-never-disarms-with-nil)). Answers go into [`spike/README.md`](../spike/README.md) and the decisions, each tagged `[ran]`.

| # | Question | Why the design needs it |
|---|---|---|
| 1 | At `periodEnds`, with a renewal due, what does `currentEntitlements` list, and for how long? | Whether access holds through a renewal, and how to poll |
| 2 | Is a subscription purchase listed late, as a non-consumable is on macOS? | Holds |
| 3 | Does a renewal while the app runs arrive on `updates`, and before or after the listing has it? | Whether a renewal is held |
| 4 | Is a renewal made while the app was not running handed over at the next launch, through `updates` or `unfinished`? | The activation read |
| 5 | Does `Status.updates` fire on renewal, on lapse, on auto-renew switched off, on refund? | Whether status changes can be listened for or must be polled |
| 6 | What do `currentEntitlements` and `status(for:)` say in a grace period, and in billing retry without one? | The access rule, measured |
| 7 | After an upgrade, is the old transaction still listed, with `isUpgraded`? What does `purchase()` return for an upgrade, a downgrade, a crossgrade? | Triage and completions |
| 8 | What does a **cancelled** task get from `status(for:)` and from `isEligibleForIntroOffer(for:)`? | Whether D2 applies to them |
| 9 | Is `isEligibleForIntroOffer(for:)` right after a purchase with the offer, after `clearTransactions()`, and for a group with no introductory offer? | Four-state eligibility |
| 10 | Does a win-back offer set eligible in the `.storekit` file appear in `eligibleWinBackOfferIDs` after a lapse, and can it be bought with `.winBackOffer(_:)`? On macOS too? | Win-back on both platforms |
| 11 | Does Xcode accept a JWS-signed promotional offer, and the introductory override, signed with the file's key? | Whether phase 2 can be tested locally |
| 12 | Does a purchase made through `SubscriptionStoreView` reach `Transaction.updates`? | Whether an app using Apple's view needs a bridge to the store |
| 13 | Is an offer code redeemed through the transaction manager announced on `updates`? | Codes need nothing else |
| 14 | Does `expireSubscription(productIdentifier:)` work, and does `forceRenewalOfSubscription`? (Others found neither reliable `[check]`) | What the hosted suite can drive |
| 15 | Does anything in StoreKit's top-level names clash with a candidate name, in either SDK? | Names |
| 16 | Family Sharing, and a renewal while the app is closed on a real device: **by hand, in the sandbox**, on a Mac and an iPhone | Xcode's environment cannot do either `[Apple]` |

**Done when** every row has an answer per OS and tool, or a written reason it could not be had, and the design above has been corrected by what was found.

### Phase 1: auto-renewable subscriptions

- Catalogue entries, `SubscriptionGroupID`, and the catalogue's new problems.
- `HeldSubscription`, `SubscriptionStanding`, `ProductAccess.subscribed`, the resolver's rule by level and ownership, and `nextExpiry` extended.
- `SubscriptionStatusReading`; the store reading statuses beside the listing, single-flight, in a task nobody cancels; status changes on the listener.
- Purchase, upgrade, downgrade, crossgrade, `appAccountToken`; the new completions; holds for subscriptions.
- Triage for renewals and upgrades; finishing.
- `ManageSubscriptionsButton`, with the macOS URL.
- The adapter: fields, statuses, `Status.updates`, open sets.
- The simulated store's subscriptions and habits; scenarios; the debug panel; the `.storekit` checks.
- Documentation: a subscriptions guide beside [trials](04-trials.md); the checklist; [App Store Connect](09-app-store-connect.md) for groups, levels, the grace period (turn it on) and Family Sharing; the roadmap and README.

**Done when** an app can sell a monthly and a yearly subscription in one group and, against the simulated store and a manual clock, a test can walk it through subscribe, renew, grace, billing retry, recovery, lapse, refund, upgrade and downgrade, with every rule in Core proven to bite ([D14](10-decisions.md#d14-every-regression-test-is-proven-to-bite)); and the hosted suite holds each measured habit on both platforms. Released as **0.3.0**, a minor bump: the API moves ([README](../README.md#using-it)).

### Phase 2: offers

- Terms on `StoreProduct`; four-state introductory eligibility; win-back offers from the own status; `OfferSigning`; the purchase options; the new errors; the offer in force on `HeldSubscription`.
- Offer codes: nothing new to receive; with the 27 SDK, the sheet's transaction taken as a purchase's, behind a compiler check.
- The simulated store's offers; scenarios; the panel.
- Documentation: the offers guide, with the returning-subscriber example worked through end to end, App Store Connect setup, and a server-side signing example that points at Apple's library and holds no key.

**Done when** a test can take a person through an introductory offer, a lapse, and a win-back offer bought in the app, and a promotional offer signed by a fake signer, refused by a rejecting one, and never attempted for someone who never subscribed. Released as **0.4.0**.

### Phase 3: on demand

Each is small once phase 1 exists, and none is started without an app that needs it.

| | Why wait |
|---|---|
| **Non-renewing subscriptions** | The app computes the period and they never leave `currentEntitlements` `[Apple]`: close to a trial. A candidate as soon as an app asks |
| **Monthly with a 12-month commitment** (26.4) | Not in the United States or Singapore; no grace period, 90 days of retry, and `willAutoRenew` does not mean what it says `[Apple]` |
| **Bundles and Suites** (27) | New product types, announced for later this year `[Apple]` |
| **Seats** (`.assigned`, from 22 October 2026) | Counted today for unlocks; for subscriptions a policy question, and on by default in App Store Connect `[Apple]` |
| **Retention offers** | Nothing to build: shown by the system; their transactions need only to be recognised `[check]` |
| **`PurchaseIntent`** | Promoted purchases, and win-back with streamlined purchasing off; iOS 16.4 and macOS 14.4 `[Apple]` |
| **The `Message` API** | iOS only; lets an app delay Apple's sheets `[Apple]` |

## Testing

Unchanged in kind, larger in amount:

- **Pure rules with explicit dates**, no clock read: the access rule, the choice between statuses, eligibility, triage. The combinations the others got wrong are each a test: own expired beside family subscribed; grace with `periodEnds` past; billing retry; upgraded beside its replacement; a pending downgrade; refunded; `.assigned`; an unrecognised state.
- **The store against the simulated store and a manual clock**: a year of monthly renewals in one test; expiry looked for at the instant; a lapse with no event; a renewal arriving before the listing.
- **The hosted suite** against real StoreKit, with `timeRate` set to renew in seconds, one product per test where the environment leaks, and each habit held to the fake per OS.
- **An API test that imports StoreKit and the package together, without `@testable`**, so that a name clash or a public type nobody can construct fails the build.
- **Mutation**, as in [D31](10-decisions.md#d31-mutation-found-four-guarantees-with-no-test-and-d14-now-means-it): does the suite notice the access rule changing?

## Decisions to take

Proposed; each becomes a numbered decision when phase 0 has measured what it rests on.

| | Proposal | Rests on |
|---|---|---|
| P1 | Access is Apple's entitlement rule: subscribed and grace count; billing retry, expired and revoked are reported and never granted | `[Apple]`; phase 0 row 6 |
| P2 | Either source grants; a lapse needs both; a failed read takes nothing away; access never waits for a status read | D8, D9; rows 1, 6 |
| P3 | The clock decides when to look; the store decides what is true. Every activation reads | Rows 1, 3, 4, 5 |
| P4 | The group and the level are restated in the catalogue and checked against the `.storekit` file | D8; D18 |
| P5 | The package never signs. The app supplies a signer, and a purchase never proceeds without its signature | `[Apple]`; others' failures |
| P6 | Every StoreKit open set crosses with an `unrecognised` case | D21; the 27 SDK |
| P7 | Offer terms come from the product. Introductory eligibility has four states, and `unknown` shows the regular price | Others' failures; row 9 |
| P8 | No paywall and no wrapper of `SubscriptionStoreView`; a purchase made through Apple's views must still reach the store | The one rule; row 12 |
| P9 | Where macOS has no sheet, a URL | `[Apple]` |
| P10 | No public name StoreKit has at the top level | Others' failures; row 15 |

## Questions for you

1. **Which subscriptions first?** One group with monthly and yearly is the common case and the proposal's target; several levels, or several groups, change how much of the level machinery phase 1 must prove.
2. **Is there, or will there be, a server?** Without one, phase 2 is introductory, win-back and codes; promotional offers and the override need somewhere to sign.
3. **Billing retry.** The proposal does not grant access in it, which is Apple's rule and the strict reading. Some apps keep access for a few days while Apple retries. That stays the app's to do; is that the right default?
4. **Seats.** From 22 October, organisations can buy seats of a StoreKit 2 subscription unless it is switched off in App Store Connect, and those arrive as `.assigned`. Count them, as the package does for unlocks?
5. **Non-renewing subscriptions**: phase 3, or sooner?
6. **The package's name and promise.** The README says "one-time purchases and trials"; phase 1 changes that, and 0.3.0 is where it would.

## Risks

- **Apple's test environment is the least reliable thing here.** Many subscription faults in `SKTestSession` were fixed only in 26.5, 26.6 or 27 `[Apple]`, and CI builds with Xcode 26.6. Phase 0 measures each tool and OS separately, and the fake keeps the awkward behaviour, as now.
- **Some behaviours cannot be tested locally**: Family Sharing, renewals while closed, Apple's own win-back sheet. A sandbox checklist, run by hand before each release, the way `make integration` is.
- **The surface grows by about as much again.** Phases keep it reviewable; the ports keep each piece testable alone.
- **macOS has less.** No manage sheet, no `Message`, no `SubscriptionOfferView`. The design never depends on them.
- **Apple moves fast here.** Three WWDCs have each changed offers. The research is dated, and the checklist gets a line to read the StoreKit release notes before each release.

## Sources

Libraries, read at their current source in September 2026: [RevenueCat purchases-ios](https://github.com/RevenueCat/purchases-ios) 5.90.2, [Adapty](https://github.com/adaptyteam/AdaptySDK-iOS) 4.1.3, [Qonversion](https://github.com/qonversion/qonversion-ios-sdk) 6.17.2, [Apphud](https://github.com/apphud/ApphudSDK) 4.5.0, [Superwall](https://github.com/superwall/Superwall-iOS) 4.17.0, [Glassfy](https://github.com/glassfy/ios-sdk) (archived; the service closed at the end of 2024), [Mercato](https://github.com/tikhop/Mercato), [Flare](https://github.com/space-code/flare), [StoreHelper](https://github.com/russell-archer/StoreHelper) and [SKHelper](https://github.com/russell-archer/SKHelper), [SwiftyStoreKit](https://github.com/bizz84/SwiftyStoreKit); Apple's [Backyard Birds](https://github.com/apple/sample-backyard-birds), [Food Truck](https://github.com/apple/sample-food-truck), and "Implementing a store in your app using the StoreKit API" (SKDemo, WWDC26 version).

The mistakes, where they can be seen:

1. Grace locked out: [Mercato](https://github.com/tikhop/Mercato/blob/e6132a7b8ad9bfd3ad01599e3135f1ed0ac02519/Sources/Mercato/Mercato+StoreKit.swift#L37-L41), [FlareUI](https://github.com/space-code/flare/blob/28a1ff1e1b274295cb3fd9774131bdffee13c376/Sources/FlareUI/Classes/Core/Providers/SubscriptionStatusVerifier/SubscriptionStatusVerifier.swift#L12-L35), [SwiftyStoreKit #605](https://github.com/bizz84/SwiftyStoreKit/issues/605); [Backyard Birds ignores the state](https://github.com/apple/sample-backyard-birds/blob/1843d5655bf884b501e2889ad9862ec58978fdbe/Multiplatform/Shop/BirdBrain.swift#L126-L166); [Food Truck and one family status](https://github.com/apple/sample-food-truck/blob/3954a769e99f3cc53297d94f2b960ceb2665b3d6/FoodTruckKit/Sources/Store/StoreSubscriptionController.swift#L81-L150). Apple on grace and current entitlements: [WWDC22 10039](https://developer.apple.com/videos/play/wwdc2022/10039/).
2. `statuses.first`: [Mercato](https://github.com/tikhop/Mercato/blob/e6132a7b8ad9bfd3ad01599e3135f1ed0ac02519/Sources/Mercato/Mercato.swift#L228-L281); several rows from `currentEntitlements(for:)`: [StoreHelper #95](https://github.com/russell-archer/StoreHelper/pull/95).
3. Eligibility invented: [Apphud](https://github.com/apphud/ApphudSDK/blob/f60bf633fa056800e5c4d77dcb938dce80378c4d/Sources/Internal/ApphudInternal+Eligibility.swift#L17-L36), [Qonversion #602](https://github.com/qonversion/qonversion-ios-sdk/issues/602), [RevenueCat #982](https://github.com/RevenueCat/purchases-ios/issues/982) and [the fourth state](https://github.com/RevenueCat/purchases-ios/pull/1859); slow and wrong eligibility in StoreKit itself: [RevenueCat #1893](https://github.com/RevenueCat/purchases-ios/issues/1893).
4. Signing: [Glassfy continues after a failed signature](https://github.com/glassfy/ios-sdk/blob/38035a2be7c31c19a15a0ede3fed5a3c3514f535/Source/GYManager.m#L835-L862); [Mercato's offer cannot be built](https://github.com/tikhop/Mercato/blob/e6132a7b8ad9bfd3ad01599e3135f1ed0ac02519/Sources/Mercato/Models/PromotionalOffer.swift#L27-L43); [RevenueCat #2114](https://github.com/RevenueCat/purchases-ios/issues/2114).
5. Leeway: [merchantkit](https://github.com/benjaminmayo/merchantkit/blob/ff81e00a3477678467e2014a5b5f16d657067695/Source/Receipt%20Validators/ReceiptValidator.swift#L20-L23), [Apphud](https://github.com/apphud/ApphudSDK/blob/f60bf633fa056800e5c4d77dcb938dce80378c4d/Sources/Internal/ApphudInternal+Fallback.swift#L80-L108); RevenueCat's server-clock window: [#2288](https://github.com/RevenueCat/purchases-ios/pull/2288).
6. The listener that dies: [StoreHelper](https://github.com/russell-archer/StoreHelper/blob/1c55f49473d847fd5a2f495aabe45f6e5ea3e2ef/Sources/StoreHelper/Core/StoreHelper.swift#L996-L1046), [SKHelper #17](https://github.com/russell-archer/SKHelper/issues/17).
7. Frozen enums: [Adapty 4.1.0](https://github.com/adaptyteam/AdaptySDK-iOS/releases/tag/4.1.0).
8. Name clashes: [RevenueCat #4937](https://github.com/RevenueCat/purchases-ios/issues/4937), [StoreHelper #89](https://github.com/russell-archer/StoreHelper/issues/89).
9. macOS: [`showManageSubscriptions(in:)`](https://developer.apple.com/documentation/storekit/appstore/showmanagesubscriptions(in:)), [`Message`](https://developer.apple.com/documentation/storekit/message), [`SubscriptionOfferView`](https://developer.apple.com/documentation/storekit/subscriptionofferview).

Where the test environment was found wanting by others: RevenueCat's notes that [`expireSubscription` and `forceRenewalOfSubscription` do not work well](https://github.com/RevenueCat/purchases-ios/blob/474a29a694/Tests/BackendIntegrationTests/BaseStoreKitIntegrationTests.swift#L285-L309); Flare's [shared test daemon leaking between tests](https://github.com/space-code/flare/pull/235).
