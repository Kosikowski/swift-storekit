# Offers

The discounted prices a subscription can carry: its introductory offer, win-back offers, promotional offers, the introductory override, and offer codes. This guide covers showing their terms, knowing who may have which, buying with one, and testing all of it. What each offer is, and who decides who gets it, is in [the research](13-subscriptions-and-offers.md#offers). Subscriptions themselves are in [their guide](15-subscriptions.md).

**The package reports store facts and performs store actions; the app owns product policy.** An offer's terms, and who Apple says may have it, are facts, and they are here. The app decides which offer to feature, which promotional offer to give to whom, and every word the person reads. **The package holds no key and signs nothing.** A signature comes from the app's server.

Evidence tags are as elsewhere. `[ran]` means measured against real StoreKit on macOS 26.6 and in the iOS 27 simulator ([phase 0](../spike/README.md#subscriptions--what-real-storekit-does-with-auto-renewable-subscriptions)), and held to it by the hosted suite in `Demo/Tests`.

## Terms come from the product

An offer's price, its number of periods and its currency belong to App Store Connect, per storefront, and can change without a release. So they are read from the store, with the prices, and never written in the app:

```swift
let monthly = store.products.first { $0.id == Shop.monthly }?.subscription   // StoreProduct.Subscription
monthly?.period               // BillingPeriod: .months(1); `value` and `unit`, a BillingPeriod.Unit
monthly?.introductoryOffer    // OfferTerms?
monthly?.promotionalOffers    // [OfferTerms]
monthly?.winBackOffers        // [OfferTerms]
```

| `OfferTerms` | |
|---|---|
| `kind` | `.introductory`, `.promotional`, `.winBack` — or `.unrecognised`, for a kind StoreKit adds later |
| `id` | The offer's identifier; nil for the introductory offer, of which there is one |
| `paymentMode` | `.freeTrial`, `.payAsYouGo`, `.payUpFront`; `.oneTime` for an offer code on a one-time purchase, and `.unrecognised` for a mode StoreKit adds later |
| `period`, `periodCount` | "A month, for two": the discounted periods of pay as you go; for a free trial or a price paid up front, one period that is the whole of it |
| `displayPrice` | **Show this.** Per period, or for the whole, as the store spells it |

"10.99 a month for two months, then 15.99" is `displayPrice` "£10.99", `period` a month and `periodCount` 2, followed by the product's own `displayPrice`. **An offer on the product is one the product has, not one this person may have.** Which offers a person may have is below.

## The introductory offer

One per subscription group per account, and Apple decides who may have it `[Apple]`. A plain purchase applies it: there is nothing to pass `[ran]`.

```swift
switch store.introductoryOffer(for: Shop.monthly) {   // IntroductoryEligibility
case let .eligible(terms): Text("New members: \(terms.displayPrice) a month for \(terms.periodCount) months")
case .unknown, .noOffer, .ineligible: EmptyView()     // the regular price, on the button
}
```

| `IntroductoryEligibility` | Meaning |
|---|---|
| `.unknown` | The prices have not loaded, or the store has not said. **Show the regular price.** The payment sheet has the last word, and applies the offer if it is due |
| `.noOffer` | The product has none |
| `.eligible(OfferTerms)` | Apple says this person may have it, and nothing the store has seen says they have used it |
| `.ineligible` | Used already, on any plan in the group, or Apple says not |

There are four states, not two, because the others' two were wrong both ways. One library assumed "eligible" when the product could not be fetched. Another took "the product has a trial" to mean "this person may have it". A third said "eligible" for a product with no offer at all ([plan](14-subscriptions-plan.md#how-others-do-it)).

**StoreKit's own answer keeps its first value for the life of the process.** `isEligibleForIntroOffer(for:)` said "eligible" before a purchase with the offer, and still said it afterwards `[ran]`. So the package does not take it alone. The App Store's answer is overruled by any verified transaction in the group that was bought with the offer. The store also remembers every purchase it saw bought with the offer, and every status that says so, so an upgrade that replaces that status leaves the offer used. Only the Apple Account's own count: a family member's purchase with the offer uses up nothing of this account's `[Apple]`. ([D46](10-decisions.md#d46-introductory-eligibility-has-four-states-and-a-used-offer-is-known-from-what-was-seen))

## Win-back offers

Apple decides who may have a win-back offer, from criteria set in App Store Connect: how long the person paid, how long ago they lapsed, and how long before they may have one again `[Apple]`. Apple shows them outside the app too, on the product page and in Manage Subscriptions. A redemption made there arrives as a transaction, which the store is already listening for.

In the app:

```swift
if let offer = store.winBackOffers(in: Shop.membership).first {           // [WinBackOffer], best first
    PurchaseButton(offer.product, options: PurchaseOptions(offer: .winBack(offer.id))) { result = $0 } label: {
        Text("Come back: \(offer.terms.displayPrice) a month for \(offer.terms.periodCount) months")
    }
}
```

`winBackOffers(in:)` gives the offers Apple lists as eligible on the **account's own** status, in Apple's order, matched to the lapsed plan's terms. Access through Family Sharing does not count towards a win-back offer `[Apple]`, so a family member's lapse gives none. The list is empty for a member, and until the prices have loaded, since an offer is shown with its terms. Bought, the subscription's `offer` says `.winBack` with the offer's identifier.

In Xcode's environment a win-back offer is eligible the moment the subscription lapses, and on the Mac it can be bought `[ran]`. In the iOS 27 simulator, buying again after a lapse returned the old, expired transaction and bought nothing `[ran]`, so the hosted tests buy one on the Mac only. The Mac did the same once, when asked the moment the lapse was read `[ran]`. A subscription handed back already over was not bought, so the purchase throws `.system`, and trying again is fair ([D51](10-decisions.md#d51-a-subscription-handed-back-already-over-was-not-bought)).

## Promotional offers, and a server that signs

A promotional offer is for current and former subscribers, as the app decides `[Apple]`, and each purchase with one carries a signature from the app's server. The app supplies the signer:

```swift
struct ServerSigner: OfferSigning {
    func signature(for request: OfferSignatureRequest) async throws -> String {
        try await api.signOffer(request)   // your server's endpoint; a compact JWS comes back
    }
}

let store = PurchaseStore(catalogue: Shop.catalogue, front: AppStoreFront(catalogue: Shop.catalogue),
                          offerSigner: ServerSigner())
try await store.purchase(Shop.monthly, options: PurchaseOptions(offer: .promotional("returning.three")))
```

On the server, Apple's [App Store Server Library](https://github.com/apple/app-store-server-library-swift) signs it. `PromotionalOfferV2SignatureCreator` takes the In-App Purchase key, its ID, the issuer ID and the bundle ID, and `createSignature(productId:offerIdentifier:transactionId:)` returns the compact JWS. **The key stays on the server** `[Apple]`. The request carries the product, the offer, the purchase's account token, and the account's latest transaction in the group, when the store has read one.

What the store does, in order:

1. **Someone who has never subscribed in the group is refused before the signer is asked**: `PurchaseError.offerRefused(.notEligible)`. Apple would refuse them anyway, and the server should not be asked for a signature it has no business making.
2. The signer is asked. **If it throws, or the store has no signer, nothing is bought**: `PurchaseError.offerNotSigned`, and the store logs `offerSignerFailed` with the type of what the signer threw. Another library carried on with the purchase when signing failed ([plan](14-subscriptions-plan.md#how-others-do-it)).
3. The store buys with the signature. If StoreKit refuses the offer, the error keeps its reason: `.offerRefused(.invalidSignature)` means the server's signature, while `.notEligible`, `.unknownOffer`, `.invalidPrice` and `.missingParameters` are the store's reasons. Nothing is bought.

For a current subscriber, a promotional offer takes effect at the next billing event `[Apple]`. The purchase completes as `.subscribed`, and `held.renewal?.offer` names the offer waiting. The renewal's period then carries it.

The signature options that took a nonce and a timestamp are deprecated in iOS and macOS 26, and the package does not use them `[Apple]`.

## The introductory override

A server can also allow the introductory offer whatever Apple would say, with the same signer:

```swift
try await store.purchase(Shop.monthly, options: PurchaseOptions(offer: .introductoryOverride))
```

The request's `kind` is `.introductoryOverride`. The server signs it with `IntroductoryOfferEligibilitySignatureCreator`, whose `createSignature(productId:allowIntroductoryOffer:transactionId:)` requires a transaction of the customer's `[Apple]`, so it uses the request's `transactionID`: the account's own latest in the group that has one, read before the signer is asked if the store has read nothing yet.

## When an offer is not applied

**StoreKit can let a purchase through at the full price without the offer, and say nothing.** An introductory override signed with a key Xcode did not know went through at the regular price on the Mac, with no error `[ran]`. So every purchase made with an offer is checked against the offer its transaction carries, or the one its renewal is waiting to apply. One that carries neither completes as:

```swift
case let .offerNotApplied(held):   // bought, subscribed, at the regular price
    notice = "You're a member — but the offer couldn't be applied, so this was at the regular price."
```

It is never reported as the offer ([D47](10-decisions.md#d47-an-offer-that-was-not-applied-is-said)).

## Offer codes

Codes are redeemed in Apple's sheet or the App Store. A custom field for typing a code is not allowed `[Apple]`. A redemption is a transaction like any other, and it arrives on the updates stream the store listens to from its first command: nothing else is needed. In the iOS simulator a code redeemed through the transaction manager arrived on `updates` at once, with `offer.type == .code` `[ran]`.

With the 27 SDK the sheet also hands the transaction back, and the store takes it as it takes a purchase:

```swift
.offerCodeRedemption(isPresented: $redeeming) { result in
    Task { _ = try? await store.takeRedemption(result) }
}
```

## Retention offers

Shown by the system in the cancellation flow, from autumn 2026 `[Apple]`. There is nothing to present and nothing to buy with. A subscription bought with one is counted like any other, and its offer, which the 27 SDK does not name, is `OfferKind.unrecognised` ([D57](10-decisions.md#d57-seats-and-retention-offers-need-nothing-new)).

## The returning-subscriber discount, end to end

The example the subscription work began from: 10.99 a month for the first two months, then 15.99; and, for someone who cancels and comes back, 10.99 for three months, then 15.99 again.

1. **In App Store Connect**, on the monthly subscription: an introductory offer, pay as you go, 1 month, 2 periods, at 10.99; and a win-back offer, pay as you go, 1 month, 3 periods, at 10.99, for people who lapsed between one and six months ago, say, and have not had it in the last year. The eligibility criteria are Apple's to apply ([App Store Connect](09-app-store-connect.md#offers)).
2. **The paywall** shows the introductory terms to someone who may have them, from `introductoryOffer(for:)`, and the regular price to everyone else and while it is unknown.
3. **A lapsed member** sees `winBackOffers(in:)`, with its terms, and buys it with `.winBack(id)`. Apple also offers it outside the app, to people who never open it.
4. **A rule of the app's own**, such as "lapsed less than a month ago", which a win-back offer cannot reach, needs a promotional offer, a server to sign it, and an `OfferSigning`.

No second product and no second group. The research explains why that [does not work](13-subscriptions-and-offers.md#a-second-product-for-returning-customers).

## Testing

The simulated store keeps offers as the real store does. It applies the introductory offer to a plain purchase once per group, and makes a product's win-back offers eligible when a subscription lapses, as Xcode's environment does. It refuses an offer with StoreKit's reasons. A promotional offer bought by a current subscriber waits for the renewal there too. **It keeps its first answer about introductory eligibility**, as StoreKit does (`behaviour.keepsFirstEligibilityAnswer`), so an app that believes that answer after a purchase finds out in a unit test.

```swift
let front = SimulatedStoreFront(catalogue: Shop.catalogue, products: products, clock: clock)   // products with offers
// or: SimulatedStoreFront(catalogue: Shop.catalogue, configuration: try StoreKitConfiguration(contentsOf: storekitFile))
let store = PurchaseStore(catalogue: Shop.catalogue, front: front, offerSigner: TestSigner(), clock: clock)
```

| To test | Arrange |
|---|---|
| Someone who may have the introductory offer | Products with one; or the scenario `intro=eligible` |
| Someone who has used it | `front.useIntroductoryOffer(in: group)`; or `intro=used` |
| A lapsed member offered a win-back | Products with win-back offers, then `front.lapse(id)`; or `winback=come-back; lapsed=monthly@40d` |
| A promotional offer on sale | Products with one; or `promo=returning` |
| The store rejecting the app's signature | `front.behaviour.acceptsOfferSignatures = false`; or `signatures=rejected` |
| What the last purchase asked for | `front.lastPurchaseOptions`: the offer, the account token, the signature sent |

A `.storekit` file is read with its offers, so a simulated store built from it sells what Xcode's environment sells. The offers an app names in its own code can be checked against it:

```swift
file.expectNoProblems(against: Shop.catalogue, offers: [Shop.monthly: ["returning.three"]])
```

Against real StoreKit, `Demo/Tests` reads the terms, holds the introductory answer StoreKit keeps, buys a win-back offer on the Mac, and shows an override StoreKit could not check going through at the full price. Xcode's environment cannot check a signature from a real In-App Purchase key, so **a promotional offer is tried in the sandbox, by hand**, before a release ([checklist](checklist.md)).
