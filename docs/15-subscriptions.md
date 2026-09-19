# Subscriptions

Auto-renewable subscriptions: declaring them, reading where a subscriber stands, buying and changing plan, sending people to Apple's page to manage them, and testing all of it in no time. Offers beyond the introductory one — win-back, promotional, codes — are [phase 2 of the plan](14-subscriptions-plan.md#phase-2-offers) and not here yet.

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
| `accessEnds` | When access by this status ends: the grace period's end, or `periodEnds` |
| `renewal` | `willRenew`, `nextProduct` (a different plan while a downgrade waits), `price`, `priceIncrease`, and the win-back offers Apple allows. **Nil when no status could be read** |
| `offer` | The offer this period was bought with, read from the transaction |
| `ownership` | `.purchased`, `.familyShared`, `.assigned` |

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

A downgrade comes back from StoreKit as a plain success **with the plan already held** `[ran]`. Taken at its word, it says the cheaper plan was bought, which is how an app ends up telling someone on Plus that they are now on Monthly. The store compares the product it asked for with the one it got back, and says `.planChangeScheduled`. Until the renewal, `renewal.nextProduct` names the plan to come.

An upgrade is immediate: a new transaction for the higher level, and the one left behind is marked upgraded and not counted `[ran]`.

## Managing

App Review expects an easy route to Apple's own page for the subscription, and it is where people cancel:

```swift
ManageSubscriptionsButton("Manage Membership", group: Shop.membership)
```

On iOS it presents Apple's sheet. **macOS has none** — `manageSubscriptionsSheet` and `AppStore.showManageSubscriptions` are unavailable there `[Apple]` — so on the Mac it opens `https://apps.apple.com/account/subscriptions` in the App Store. Either way the store reads again when the person comes back, because a cancellation made there sends the app nothing.

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

## Not yet

- **Offers**: win-back, promotional with a signer the app supplies, introductory eligibility, codes — [phase 2](14-subscriptions-plan.md#phase-2-offers). The offer a period was bought with is already reported, and an introductory offer already applies.
- **Non-renewing subscriptions, the 12-month commitment, Bundles and Suites** — [phase 3](14-subscriptions-plan.md#phase-3-on-demand).
