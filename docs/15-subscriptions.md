# Subscriptions

Auto-renewable subscriptions: declaring them, reading where a subscriber stands, buying and changing plan, sending people to Apple's page to manage them, and testing all of it in no time. Then the rest: monthly billing with a 12-month commitment, bundles, seats, purchases asked for outside the app, Apple's own messages, and non-renewing subscriptions. Offers — the introductory one, win-back, promotional, codes — have [a guide of their own](16-offers.md).

**The package reports store facts and performs store actions; the app owns product policy.** A subscription's state, its dates, whether it will renew and to what, are facts, and they are here. What a membership unlocks, what a lapse locks, and every word the person reads are the app's.

Evidence tags as elsewhere. `[ran]` here means measured against real StoreKit on macOS 26.6 and in the iOS 27 simulator by [phase 0](../spike/README.md#subscriptions--what-real-storekit-does-with-auto-renewable-subscriptions), and held to it by the hosted suite in `Demo/Tests`. What StoreKit does and why is in [the research](13-subscriptions-and-offers.md).

## Declare them

A subscription entry names its group and its level:

```swift
enum Shop {
    static let membership: SubscriptionGroupID = "21482000"   // App Store Connect's identifier
    static let monthly: ProductID = "com.example.membership.monthly"
    static let yearly: ProductID = "com.example.membership.yearly"
    static let plus: ProductID = "com.example.membership.plus"

    static let catalogue: Catalogue = [
        .subscription(monthly, in: membership, level: 2),
        .subscription(yearly, in: membership, level: 2),
        .subscription(plus, in: membership, level: 1),
    ]
}
```

- **The group's identifier** is the one App Store Connect shows for the subscription group, and the `id` of the group in the `.storekit` file. StoreKit is asked for statuses by it, before any product has loaded, so what a subscriber may use waits for no network.
- **The level** is App Store Connect's ranking, and **1 is the highest**: moving from level 2 to level 1 is an upgrade `[ran]`. It decides which of two statuses counts — the person's own and a family member's — and it is what tells an upgrade from a downgrade.
- **Family Sharing** is honoured unless the entry says `familySharing: .ignored`, as for an unlock. `.assigned` — a seat bought by an organisation — counts either way, as it does for an unlock.

`StoreKitConfiguration(contentsOf:).expectNoProblems(against:)` checks the `.storekit` file against these: each subscription is a `RecurringSubscription` in the group and at the level its entry names, and shared as its entry says ([App Store Connect](09-app-store-connect.md#check-the-file-against-the-catalogue)).

## Where the account stands

```swift
let membership = store.standing.subscription(in: Shop.membership)   // SubscriptionStanding
```

| `SubscriptionStanding` | Meaning |
|---|---|
| `.unknown` | The store has not answered. **Not `.none`**: judge nothing by it. `await knownStanding()` first |
| `.none` | Never subscribed in this group |
| `.active(HeldSubscription, all:)` | Entitled: subscribed, or in a grace period |
| `.inactive(HeldSubscription, all:)` | Held once, not entitled now: lapsed, in billing retry, or taken back |

`isActive` is the `Bool?` of it, nil while unknown. `all` is every status the store reported for the group; the one in the case is the one that decides — the entitled one at the highest level, the person's own before anybody else's, then the one that lasts longer.

A `HeldSubscription` keeps four facts apart:

| | |
|---|---|
| `state` | `.subscribed`, `.inGracePeriod(until:)`, `.inBillingRetry`, `.expired(Lapse)`, `.revoked`, or `.unrecognised` for a state StoreKit adds later |
| `periodStarted`, `periodEnds`, `firstSubscribed` | `periodEnds` is when this period ends — **already past in a grace period** |
| `isEntitled`, `accessEnds` | Whether this status gives access — subscribed, or in a grace period — and until when: the grace period's end, or `periodEnds` |
| `renewal` | `willRenew`, `nextProduct` (a different plan while a downgrade waits; kept when auto-renew is switched off, as StoreKit keeps it), `price` in `currencyCode`, `priceIncrease`, the win-back offers Apple allows, and `commitment`. **Nil when no status could be read** |
| `willRenewAtPeriodEnd` | Whether it goes on past this period: `renewal.willRenew`, except in the last month of a commitment that will not be renewed |
| `offer` | The offer this period was bought with, read from the transaction |
| `ownership` | `.purchased`, `.familyShared`, `.assigned` |
| `commitment`, `bundle`, `transactionID` | On the monthly plan, where it stands in the commitment; the bundle it is held through; the transaction's identifier |

`access(to:)` answers `.subscribed(HeldSubscription)` for the plan held, and `.none` for the other plans in the group, which the person does not have. An app that sells two plans of the same thing asks for the group, not the product.

```swift
private var membershipStatus: String {
    switch purchases?.standing.subscription(in: Shop.membership) {
    case nil, .unknown?:
        return "Membership: …"
    case .none?:
        return "Not a member"
    case let .active(held, _)?:
        if case let .inGracePeriod(until) = held.state {
            return "Your payment didn't go through. Update it by \(until.formatted()) to stay a member."
        }
        guard let renewal = held.renewal else { return "Member" }
        if !renewal.willRenew { return "Member until \(held.periodEnds.formatted()), then it ends" }
        return "Member; renews \(held.periodEnds.formatted())"
    case let .inactive(held, _)?:
        if held.state == .inBillingRetry { return "Membership paused: the App Store couldn't take payment" }
        return "Membership ended \(held.periodEnds.formatted())"
    }
}
```

That is the Demo's, and every word of it is the app's.

## Access is Apple's rule

**Subscribed and in a grace period give access; billing retry, expired and revoked do not** `[Apple]`. A grace period is a promise the developer makes in App Store Connect, and the agreement with Apple requires service throughout it `[Apple]`.

Billing retry is reported, not granted. An app that wants to keep a member going for a few days while Apple retries is making a policy decision, and it is written in the app where it can be seen:

```swift
let lenient = membership.isActive == true || membership.current?.state == .inBillingRetry
```

**The status decides, not the listing.** The iOS simulator lists a subscription in billing retry, with a renewal transaction of its own, and at a renewal both platforms list nothing for a moment `[ran]`. The listing stands in only for a group whose status could not be read, and then `renewal` is nil.

## What happens by itself

Nothing wakes an app. **An expiry sends no transaction at all** `[ran]`, and a cancellation made in Settings reached the iOS simulator only at the next renewal `[ran]`. The store looks again at the moment a subscription's access would end, listens for status changes while the app runs, and **reads again whenever it is asked to — call `refresh()` when the app becomes active**:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active { Task { await store.refresh() } }
}
```

**The moment at a renewal.** At the end of every period StoreKit says, for a moment, that the subscription has ended: `expired` for up to 0.7 s on the Mac, and on iOS also "will not renew" and "eligible for a win-back offer", with the listing empty `[ran]`. The store does not believe a lapse there until it lasts: a subscription that was renewing keeps its access across the end of its period while the store looks again, for up to `renewalGrace` — 30 seconds by default, a parameter of `PurchaseStore.init`. The renewal itself usually arrives on the updates stream first, and is held until the status has caught up, as a purchase is.

**Renewals missed while the app was closed** arrive at the next launch, newest first `[ran]`. Each is judged by its dates, never by the order it came in; one whose period has already ended is never held.

**A refund of a past period** revokes that transaction only, and the subscription carries on `[ran]`. It is finished and not announced. A refund of the current period is a withdrawal, as for anything else.

## Buying, and changing plan

A subscription is bought with `PurchaseButton` or `purchase(_:)`, as anything is. An introductory offer the person is eligible for is applied by the App Store to a plain purchase `[ran]`: there is nothing to pass.

| `PurchaseCompletion` | When | Say |
|---|---|---|
| `.subscribed(HeldSubscription)` | Bought; upgraded to; or the plan already held, handed back | Nothing, or close the paywall |
| `.planChangeScheduled(to:at:)` | **A downgrade, or a change to another duration.** It takes effect at the renewal, and nothing has changed yet | "From *at* you'll be on *to*" |
| `.pending` | Ask to Buy | "Waiting for approval." |
| `.cancelled` | The person backed out | Nothing |

A downgrade comes back from StoreKit as a plain success **with the plan already held** `[ran]`. Taken at its word, it says the cheaper plan was bought, which is how an app ends up telling someone on Plus that they are now on Monthly. The store compares the product it asked for with the one it got back, and says `.planChangeScheduled`. Until the renewal, `renewal.nextProduct` names the plan to come. An Ask to Buy for a downgrade stops being pending once it is approved and the status names the plan as next. It does not wait for the renewal.

An upgrade is immediate: a new transaction for the higher level, and the one left behind is marked upgraded and not counted `[ran]`.

**Apple's `SubscriptionStoreView`.** A subscription bought in it reaches the store without help, on the status updates in the iOS simulator and on both streams on the Mac `[ran]`. Hand the view's result over anyway, as for every Apple view: the purchase is then held at once, and a downgrade comes back as `.planChangeScheduled` ([getting started](02-getting-started.md#apples-own-views)):

```swift
SubscriptionStoreView(groupID: Shop.membership.rawValue)
    .onInAppPurchaseCompletion { product, result in
        _ = try? await store.takePurchase(result, of: product)
    }
```

**An account of the app's own.** An app with a server that ties purchases to its own accounts passes a UUID, and Apple returns it on the transaction and in its server notifications `[Apple]`. The package hands it to StoreKit untouched and decides nothing by it:

```swift
try await store.purchase(Shop.monthly, options: PurchaseOptions(appAccountToken: account.id))
PurchaseButton(Shop.monthly, options: PurchaseOptions(appAccountToken: account.id)) { result = $0 } label: { … }
```

## Managing

App Review expects an easy route to Apple's own page for the subscription, and it is where people cancel:

```swift
ManageSubscriptionsButton("Manage Membership", group: Shop.membership)
```

On iOS it presents Apple's sheet. **macOS has none**, because `manageSubscriptionsSheet` and `AppStore.showManageSubscriptions` are unavailable there `[Apple]`. So on the Mac it opens `ManageSubscriptionsButton.manageSubscriptionsURL`, `https://apps.apple.com/account/subscriptions`, in the App Store, and so do a Mac Catalyst app and an iPhone or iPad app running on a Mac, where Apple says not to show the sheet. Either way the store reads again when the person comes back: when the sheet closes, or when the app becomes active again after the link. A cancellation made there sends the app nothing.

## Monthly, with a 12-month commitment

From iOS and macOS 26.4 a yearly subscription can have a second billing plan: billed every month, and committed to for twelve. It has no grace period, retries a failed charge for 90 days, and is not offered in the United States or Singapore `[Apple]`.

```swift
let plans = store.products.first { $0.id == Shop.yearly }?.subscription?.billingPlans   // [BillingPlanTerms]
try await store.purchase(Shop.yearly, options: PurchaseOptions(billingPlan: .monthly))
```

Each `BillingPlanTerms` has the price per billing period (`billingDisplayPrice`, `billingPrice`, `billingPeriod`), what the whole commitment comes to and how long it lasts (`commitmentDisplayPrice`, `commitmentPrice`, `commitmentPeriod`), and the plan's own `offers`. Show both prices, as App Review asks `[Apple]`. A plan asked for where the system is older than 26.4, or that the product does not have, fails as `unsupported`, and nothing is billed some other way. Held, `HeldSubscription.commitment` (`SubscriptionCommitment`) says which month it is (`billingPeriod`) of how many (`billingPeriods`), when the commitment ends (`endsAt`) and what it costs (`price`).

**Cancelled during a commitment, the months are still billed.** `renewal.willRenew` stays true, correctly, and only `renewal.commitment?.willRenew` says the commitment ends `[Apple]`. `renewal.commitment` (`CommitmentRenewal`) also says the product and plan it renews as, when (`renewsAt`), and at what price. Word "member until the commitment ends" from `willRenewAtPeriodEnd`, which is false in the last month of a commitment that will not be renewed, or from `renewal.commitment`. The store's own doubt at a period's end reads it too ([D54](10-decisions.md#d54-on-a-12-month-commitment-whether-it-will-renew-and-whether-it-will-end-are-two-facts)). Xcode's environment could not be made to sell a plan, so it is tried in the sandbox, by hand.

## Held through a bundle

From 27 a subscription can be held through a subscription bundle, perhaps sold by another app `[Apple]`. Its status decides access, as any status does. `HeldSubscription.bundle` (`BundleMembership`) names the bundle's product and group, and `willLeave` says whether the subscription leaves it at its next renewal; a lapse for leaving it is `.expired(.unbundled)`. A bundle's own terms list what it includes (`bundledSubscriptions`). Built with the 27 SDK only ([D56](10-decisions.md#d56-a-subscription-bundle-is-facts-behind-the-27-sdk)).

## Seats

A seat bought for someone by an organisation arrives as `ownership == .assigned`, and counts, as a purchase does. An app that would rather not sell to organisations switches it off in App Store Connect `[Apple]` ([D57](10-decisions.md#d57-seats-and-retention-offers-need-nothing-new)).

## Purchases asked for outside the app

A promoted in-app purchase tapped on the App Store, or a win-back offer taken there with streamlined purchasing off, reaches the app as a request, and **nothing has been bought** `[Apple]`. The store keeps it in `requestedPurchases`. When to go on is the app's call — at once, after onboarding, or not at all for something already owned:

```swift
if let request = store.requestedPurchases.first, !isOnboarding {
    if ownsItAlready(request.product) {
        store.dismissRequestedPurchase(request)
    } else {
        try await store.purchase(request.product, options: request.options)   // with the offer it came with
    }
}
```

A purchase of the product, however it ends, deals with the request. A win-back or promotional offer the person chose goes with it, so buying it never charges the regular price in its place; a promotional one is signed by the app's `OfferSigning`, as any is. An offer of a kind StoreKit adds later is left off, and logged as `requestedOfferUnrecognised`. Xcode's environment delivered no request on either platform, so this is tried in the sandbox, on a device ([D53](10-decisions.md#d53-a-purchase-asked-for-outside-the-app-is-a-request-and-the-app-decides)).

## Apple's own messages

On iOS, StoreKit shows its own sheets — a price rise to agree to, a billing problem, a win-back offer — over whatever is on screen. An app can hold them back until it is ready:

```swift
ContentView()
    .storeMessages(deferredWhile: model.isOnboarding)

// Or, for an app with win-back offers of its own, which never wants Apple's sheet for them:
ContentView()
    .storeMessages(deferredWhile: model.isOnboarding, showing: { $0 != .winBackOffer })
```

Held messages are shown in order when the condition turns false, read as the app says it now. One that cannot be shown — no scene to show it in — waits for the next chance: the condition turning false again, or the scene becoming active. A reason `showing` declines (`StoreMessageReason`: `.priceIncreaseConsent`, `.billingIssue`, `.winBackOffer`, `.generic`, or `.unrecognised` for one StoreKit adds later) is never shown. The Mac has no such messages `[Apple]`, and there the modifier does nothing ([D55](10-decisions.md#d55-apples-own-messages-wait-while-the-app-says-so)).

## Non-renewing subscriptions

Bought for a length of time, and bought again to go on. **StoreKit gives one no end** `[ran]`: its length is the app's to say, in the catalogue, as a trial's is.

```swift
.nonRenewing(Shop.season, lasting: .seconds(30 * 86_400))                              // purchases while one runs add up
.nonRenewing(Shop.pass, lasting: .seconds(30 * 86_400), stacking: .fromEachPurchase)  // each runs from its own date
```

```swift
switch store.standing.nonRenewing(Shop.season) {    // NonRenewingStatus
case .unknown: …
case .none: "No season pass"
case let .active(period): "Season pass until \(period.endsAt)"
case let .ended(period): "Season pass ended \(period.endsAt)"
}
```

`access(to:)` is `.nonRenewing(period)` while one runs, and it ends by itself at `endsAt`, as a trial does. Every purchase counts, since the listing keeps every one `[ran]`. A refund takes back that purchase's time and leaves the rest `[ran]`. A purchase completes as `.nonRenewing(period)`: the period it is part of, at its own date if that is still to come by this device's clock, which may be behind the App Store's. One that hands back a purchase already counted bought nothing, and throws `.system`, from `purchase()` or from one of Apple's views: the iOS simulator did this in two runs of three `[ran]`. An Ask to Buy for one bought before stays pending until a new purchase arrives, since the earlier one is owned already ([D52](10-decisions.md#d52-a-non-renewing-subscriptions-end-is-the-catalogues-and-every-purchase-counts)). Family Sharing does not apply to them.

## Testing

The simulated store renews by its own clock, so a year of renewals is a clock advanced twelve times ([simulated store](06-simulated-store.md#subscriptions)):

```swift
let clock = ManualClock()
let front = SimulatedStoreFront(catalogue: Shop.catalogue, clock: clock)
let store = PurchaseStore(catalogue: Shop.catalogue, front: front, clock: clock)

try await store.purchase(Shop.monthly)
var ends = store.standing.subscription(in: Shop.membership).current!.periodEnds
for _ in 1 ... 12 {
    clock.advance(to: ends)
    await waitUntil { store.standing.subscription(in: Shop.membership).current!.periodEnds > ends }
    ends = store.standing.subscription(in: Shop.membership).current!.periodEnds
}
```

It keeps the moment at a renewal by default, as it keeps every awkward habit: an app that is right through it is right when it is shorter.

| To test | Arrange |
|---|---|
| A member at launch | `front.seedSubscription(HeldSubscription(…))`, or the scenario `subscribed=monthly@3d` |
| Cancelled, runs to its end | `front.cancelAutoRenew(Shop.monthly)`, or `cancelled=monthly@3d` |
| A grace period | `front.behaviour.renewal = .fails; front.behaviour.gracePeriod = .seconds(16 * 86_400)`, or `grace=monthly@2d` |
| Billing retry | `front.behaviour.renewal = .fails`, or `retry=monthly@2d` |
| Lapsed | `front.lapse(Shop.monthly)`, or `lapsed=monthly@40d` |
| Started on another device, or shared by family | `front.deliverSubscription(Shop.monthly, ownership: .familyShared)` |
| A price rise awaiting consent | `front.raisePrice(Shop.monthly, needsConsent: true)` |
| Renewals in seconds | `front.behaviour.subscriptionPeriod = .seconds(30)`, or `period=30s` |

The debug panel has a line for each group and the same controls, for a debug build poked at by hand.

Against real StoreKit, `SKTestSession.timeRate` renews every ten seconds, and `shouldEnterBillingRetryOnRenewal` and `billingGracePeriodIsEnabled` make a charge fail. It works only in a test bundle hosted by an app ([testing](05-testing.md)); `Demo/Tests` has the package's. Family Sharing, and a renewal while a real device's app is closed, need the sandbox.

## Tried by hand

Xcode's environment cannot do these, and they are tried in the sandbox before a release ([checklist](checklist.md)): Family Sharing; a renewal while the app is closed; a promotional offer signed by a real key; a purchase asked for on the App Store; the 12-month commitment; a price rise shown as a message; a subscription bundle.
