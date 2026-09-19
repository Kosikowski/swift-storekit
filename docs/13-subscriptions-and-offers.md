# Subscriptions and offers in StoreKit

What the App Store does for auto-renewable subscriptions and their offers, what StoreKit tells an app on the device, and what only a server hears. This is the research behind [the plan](14-subscriptions-plan.md). **None of it is implemented by the package yet.**

Evidence tags are the ones used elsewhere:

- `[ran]` measured against real StoreKit by [phase 0 of the plan](14-subscriptions-plan.md#phase-0-measure-first), in Xcode's test environment on macOS 26.6 with Xcode 27.0 and in the iOS 27.0 simulator, on 19 September 2026. The probes and the full answers are in [`spike/`](../spike/README.md#subscriptions--what-real-storekit-does-with-auto-renewable-subscriptions). Xcode's environment is not production; where the two may differ, it says so.
- `[Apple]` Apple's documentation, App Store Connect Help, a WWDC session, release notes, or the Xcode 27.0 SDK interfaces, read on 19 September 2026.
- `[check]` reported by a third party, or two of Apple's own sources disagree, and not yet measured here.

The package's rule still decides what belongs where: **the package reports store facts and performs store actions; the app owns product policy.** Most of this document is store facts. The places where it is policy are called out.

## Who runs a discounted price: the short answer

> A subscription is 10.99 a month for the first two months, then 15.99. Cancelled and restarted, it is 10.99 again for two months, or three, then 15.99. Is that StoreKit, or the app?

**The App Store runs the price schedule.** The discount is an *offer*, configured in App Store Connect on the subscription product. The *pay as you go* mode charges a discounted price for a number of periods, after which the subscription renews at the standard price unless the person cancels `[Apple]`. The app never charges, switches prices, or counts periods, and must not try to.

What differs between the kinds of offer is **who decides that a returning customer gets the discount again**. The introductory offer cannot: a person gets one introductory offer per subscription group, whether they are new or returning `[Apple]`. Four mechanisms can:

| Mechanism | Who decides the person qualifies | Needs a server | Fits the example because |
|---|---|---|---|
| **Win-back offer** | **Apple**, from criteria set in App Store Connect: how long they paid, how long ago they lapsed (1–24 months), how long before they can have the offer again (2–24 months) `[Apple]` | No | Two win-back offers with different lapse windows give "two months, or three". Apple also shows it on the App Store product page and in Manage Subscriptions, outside the app `[Apple]` |
| **Promotional offer** | **The developer**, for anyone who is or was a subscriber `[Apple]` | **Yes**: a server signs each one | Any rule the app likes, such as "cancelled at least 30 days ago" |
| **Introductory offer with the eligibility override** | **The developer**: the server signs "allow the introductory offer" `[Apple]` | **Yes** | The same introductory terms again. Third parties report it re-enables the offer for people who have used it; Apple's page says only that it "determines whether the customer is eligible" `[check]` |
| **Offer code**, eligibility "expired subscribers" | The developer decides who gets a code; Apple enforces the category `[Apple]` | No | The person redeems a code: a link, the App Store, or the system sheet in the app |

Most likely, what was seen was a win-back offer (Apple's decision) or a promotional offer (the developer's).

| Whose job | What |
|---|---|
| **The App Store's** | Deciding eligibility for introductory, win-back and code offers; checking signatures; charging the discounted periods and then the standard price; showing win-back offers on the App Store, in Manage Subscriptions and in its own sheet |
| **The app's (policy)** | Which promotional offer to show to whom; asking its server for a signature; the wording of the terms |
| **A package like this one (facts and actions)** | Reading an offer's terms from the product; saying which offers this person is eligible for, where Apple says; passing the right purchase option; noticing a subscription redeemed outside the app |
| **A server's** | Signing promotional offers and the introductory override. The signing key must never be in the app `[Apple]` |

**For "lapsed subscribers get the discount again" with no server, use win-back offers.** Use a promotional offer when the rule is the app's own and a server is acceptable.

## The products

| | Auto-renewable subscription | Non-renewing subscription |
|---|---|---|
| Renews | By itself, until cancelled | Never; bought again |
| Who computes the period | The App Store: `Transaction.expirationDate` | **The app**, which also has to prompt for renewal and make it available on every device `[Apple]` |
| On the device | Leaves `currentEntitlements` when it is no longer entitled | **Stays in `currentEntitlements` for ever**, the latest transaction per product, finished or not `[Apple]` |
| Offers | Introductory, promotional, win-back, codes | Offer codes (from iOS 16.3 / macOS 15) `[Apple]` |

A non-renewing subscription is closer to this package's trial than to an auto-renewable one: a period the app dates from a transaction.

**Subscription groups.** Every auto-renewable subscription is in a group, and a person can hold one subscription per group at a time. Buying another product in the same group is an upgrade, downgrade or crossgrade, never a second subscription. A group holds up to 100 subscriptions, and Apple recommends one group for most apps `[Apple]`. Guideline 3.1.2(b) says a person must not be able to subscribe to several variations of the same thing by accident, which is what one group prevents `[Apple]`.

**Levels** rank the subscriptions in a group and decide which way a change goes: to a higher level is an upgrade, to a lower one a downgrade, at the same level a crossgrade `[Apple]`. StoreKit reports `SubscriptionInfo.groupLevel` and `groupDisplayName` `[Apple]`. **Level 1 is the highest**: moving from level 2 to level 1 was an upgrade, at once, with the transaction left behind marked `isUpgraded` `[ran]`.

**Durations**: 1 week, 1, 2, 3 or 6 months, 1 year `[Apple]`. `Product.SubscriptionPeriod` has a `unit` and a `value` `[Apple]`.

**Newer shapes**, none of which this package plans for yet:

- **Monthly billing with a 12-month commitment** (iOS and macOS 26.4, built with the 26.5 SDK). A one-year subscription gets a second billing plan: `SubscriptionInfo.pricingTerms`, `BillingPlanType` `.upFront` or `.monthly`, `commitmentInfo`, and `.billingPlanType(_:)` to buy it. Not offered in the United States or Singapore `[Apple]`.
- **Bundles and Suites** (27 SDK): `ProductType.subscriptionBundle` and `.subscriptionSuite`, `SubscriptionInfo.bundledSubscriptions` `[Apple]`.
- **Seats for groups and organisations** (volume purchasing from 22 October 2026). A seat arrives as a transaction whose ownership is `.assigned`, and from iOS and macOS 27 the transaction queries return it **by default** `[Apple]`. The package already maps `.assigned` ([D17](10-decisions.md#d17-no-sdk-27-only-symbols)).

## What the device can read

### `Transaction.currentEntitlements`

For auto-renewables it lists **the latest transaction for each subscription whose state is `subscribed` or `inGracePeriod`**. It is keyed by product, not group `[Apple]`. So:

- Expired, in billing retry without a grace period, revoked and refunded subscriptions are **not** listed `[Apple]`.
- A subscription shared by a family member is listed `[check]` (Apple engineer, forums).
- A subscription the person upgraded *away from* can still be listed, and Apple's advice is to ignore transactions whose `isUpgraded` is true `[Apple]`. In Xcode's environment it was not listed, on either platform `[ran]`.
- **It is not only the entitled.** In the iOS simulator a subscription in billing retry was listed, with a renewal transaction of its own, and at a renewal both platforms listed nothing for a moment `[ran]`. The status, below, says what the listing cannot.
- `currentEntitlements(for:)` (iOS and macOS 18.4 / 15.4) replaced the singular `currentEntitlement(for:)`. The WWDC25 session gave the reason as a person holding a product both by purchase and through Family Sharing; the reference page says a regular product yields no more than one transaction `[check]`. Either way, read zero or more.
- Before iOS and macOS 26.5 it could be empty for a paying subscriber whose calendar was not Gregorian `[Apple]` (fixed in 26.5, and within this package's deployment range).

### Subscription status

`Product.SubscriptionInfo.status(for: groupID)` returns `[Status]` for a group, **empty if the person never subscribed** in it, and **more than one** when the person has their own subscription and a family member's `[Apple]`. It is a static call that takes the group's identifier, so it needs no product loaded first. Each `Status` has:

- `state`, a `RenewalState`;
- `transaction`, the latest transaction in the group, as a `VerificationResult`;
- `renewalInfo`, a `VerificationResult<RenewalInfo>`.

`Status.updates` emits "when a subscription's status changes" and `Status.all` streams every group's statuses; neither is documented further `[Apple]`. `Status.all` could return a stale status until 26.2 `[Apple]`. Measured, `Status.updates` reported a purchase, a renewal, auto-renew switched off and on, grace, billing retry, a lapse and a plan change waiting for the renewal; not the refund of a past period, which came on `Transaction.updates`; and in the iOS simulator nothing for auto-renew switched off until the next renewal `[ran]`.

**A status read from a cancelled task answers with an empty array**, which reads as "never subscribed" `[ran]`, as `currentEntitlements` answers a cancelled task with nothing ([D2](10-decisions.md#d2-ownership-is-never-read-in-a-task-something-else-can-cancel)).

`Transaction.subscriptionStatus` is a trap: the SDK returns one `Status?`, chosen from the unverified payload with `try?`, while its documentation describes an array `[Apple]`.

| `RenewalState` | Entitled to service | Notes |
|---|---|---|
| `subscribed` | **Yes** | |
| `inGracePeriod` | **Yes**, until `gracePeriodExpirationDate`, although `expirationDate` has passed | The developer agreement requires full service throughout `[Apple]` |
| `inBillingRetryPeriod` | No, unless another status gives access | Apple retries for up to 60 days `[Apple]` |
| `expired` | No | `RenewalInfo.expirationReason` says why |
| `revoked` | No | "The App Store has revoked the customer's access to the subscription group" `[Apple]` |

**These are not enums.** `RenewalState`, `ExpirationReason`, `OwnershipType`, `RevocationReason`, `ProductType` and `Transaction.OfferType` are `RawRepresentable` structs, and Apple adds values without a compile error: `.assigned`, `.unbundled` and `.upgradedToBundle` all arrived that way `[Apple]`. Every switch over them needs a branch for "something newer", and should treat it the way D21 treats an unknown purchase result: said, not guessed.

### `RenewalInfo`: what happens next

| Field | Meaning `[Apple]` |
|---|---|
| `willAutoRenew` | Whether it renews at the end of this period |
| `autoRenewPreference` | The product it will renew *to*. Differs from the current one when a downgrade is pending; nil if it will not renew |
| `expirationReason` | Nil while active. `.autoRenewDisabled`, `.billingError`, `.didNotConsentToPriceIncrease`, `.productUnavailable`, `.unknown`, `.unbundled` |
| `isInBillingRetry` | Apple is still trying to renew an expired subscription |
| `gracePeriodExpirationDate` | Set only in a grace period: give full service until then |
| `priceIncreaseStatus` | `.noIncreasePending`, `.pending` (awaiting consent), `.agreed` |
| `renewalDate` | The end of the most recent period. Always present, and may be in the past |
| `renewalPrice`, `currency` | The next charge, **with any offer applied**, in currency units |
| `offer` | The offer applying at the next renewal (iOS 18 / macOS 15) |
| `eligibleWinBackOfferIDs` | Win-back offers this person may have now, best first. Empty in a grace period or billing retry (iOS 18 / macOS 15) |
| `recentSubscriptionStartDate` | Ignores lapses shorter than 60 days. Not for counting paid days |
| `commitmentInfo`, `renewalBillingPlanType` | The 12-month commitment (26.4) |

### `Transaction`: what happened

| Field | Meaning `[Apple]` |
|---|---|
| `id`, `originalID` | A renewal has a new `id` and the same `originalID` |
| `subscriptionGroupID` | The group, as a string |
| `purchaseDate`, `originalPurchaseDate`, `expirationDate` | `expirationDate` is when this period ends or renews |
| `reason` | `.purchase` or `.renewal` (iOS 17 / macOS 14) |
| `isUpgraded` | True on a transaction the person has upgraded away from |
| `ownershipType` | `.purchased`, `.familyShared`, `.assigned` |
| `offer` | `id`, `type` (`.introductory`, `.promotional`, `.code`, `.winBack`), `paymentMode` (`.freeTrial`, `.payAsYouGo`, `.payUpFront`, `.oneTime`), `period` (iOS 17.2 / macOS 14.2; `period` from 18.4). The older `offerType` and `offerID` are deprecated |
| `revocationDate`, `revocationReason` | Plus `revocationType` (`.familyRevocation`, `.fullRefund`, `.proratedRefund`, `.assignmentRevocation`) and `revocationPercentage` (26.4) |
| `price`, `currency` | After any offer, in currency units. Signed payloads and the server use **milliunits** |
| `appAccountToken` | The UUID the app passed when buying |

## How the app learns what happened

`Transaction.updates` emits transactions made outside the app or on another device, and hands over unfinished ones once, at launch. `Transaction.unfinished` returns them at any time `[Apple]`. The package already listens from its first command and reads `unfinished` once ([D29](10-decisions.md#d29-what-was-left-unfinished-is-asked-for-not-waited-for)). **An expiry produces no transaction at all**: it shows only as a changed status, and as the product leaving `currentEntitlements` `[Apple]`. Nothing wakes the app for any of this.

| Event | What the device sees | How it arrives |
|---|---|---|
| Subscribed here | A transaction, `reason == .purchase`, maybe with an `offer`. Listed 0.6 s late on the Mac, at once on iOS `[ran]` | `purchase()` returns it. **On the Mac it is also announced on `updates`**, unlike a non-consumable's; not on iOS `[ran]` |
| Renewed | A new transaction: `reason == .renewal`, same `originalID`, new `expirationDate`. It must be finished `[Apple]` | `updates`, before the listing has it `[ran]`. **For a moment at the period's end, the status says `expired`** and the listing may be empty `[ran]` — see the traps. Renewals made while nothing ran arrive at the next launch, **newest first** `[ran]` |
| Auto-renew switched off | `willAutoRenew == false`, `autoRenewPreference == nil`. Access continues to `expirationDate` `[Apple]` | `Status.updates` on the Mac; in the iOS simulator, not until the next renewal `[ran]` |
| Lapsed | State `expired`, `expirationReason` set, gone from `currentEntitlements` | Status only; no transaction `[Apple]` |
| Renewal failed, grace period | State `inGracePeriod`, `isInBillingRetry`, `gracePeriodExpirationDate`; still listed `[ran]` | Status. The developer turns grace on in App Store Connect: 3, 16 or 28 days (3 or 6 for weekly), for all renewals or paid-to-paid only; changes take up to 24 hours `[Apple]` |
| Renewal failed, no grace | State `inBillingRetryPeriod`, `expirationReason == .billingError`; not listed on the Mac, **listed with a renewal transaction in the iOS simulator** `[ran]` | Status. On iOS 16.4+ the App Store shows its own billing-issue sheet `[Apple]` |
| Refunded, or sharing ended | `revocationDate` on the transaction; state `revoked`; not listed. **Refunding a past period revokes that transaction only**, and the subscription carries on `[ran]` | `updates` |
| Upgraded | Immediate. A new transaction for the higher level; the old one `isUpgraded` `[Apple]` | `purchase()` if made here; `updates` otherwise. Xcode testing did not report upgrades on `updates` before 27 `[Apple]` |
| Downgraded | **At the next renewal.** Until then `currentProductID` is unchanged and `autoRenewPreference` names the lower product `[Apple]`. **`purchase()` returns `.success` with the transaction already held** `[ran]` | Status; the downgrade itself arrives as the renewal |
| Crossgraded | Same duration: immediately. Different duration: at the next renewal `[Apple]`, and `purchase()` returns the transaction held, as for a downgrade `[ran]` | As upgrade or downgrade |
| Price increase | `priceIncreaseStatus`, `renewalPrice`. Consent is required above about 50% *and* about US$5 a period (US$50 a year), or for a second increase within a year, or where the law requires it; otherwise people are only told `[Apple]` | Status. On iOS the App Store shows the consent sheet; the `Message` API can delay it. **Not available on macOS** `[Apple]` |
| Ask to Buy | `purchase()` returns pending; on approval the transaction arrives `[Apple]` | `updates` |
| Offer code or win-back redeemed in the App Store | A transaction with `offer.type` `.code` or `.winBack` | `updates`. From iOS and macOS 27 the in-app code sheet also returns the transaction `[Apple]` |

## Offers

| Offer | Who decides eligibility | Server | StoreKit, minimum OS | Presented by | Seen afterwards as |
|---|---|---|---|---|---|
| **Introductory** | Apple: once per group per account | No | iOS 15 / macOS 12 | `subscription.introductoryOffer` and `isEligibleForIntroOffer`; **a plain `purchase()`** applies it | `offer.type == .introductory` |
| **Introductory override** | Developer: signed `allowIntroductoryOffer` | Yes | `.introductoryOfferEligibility(compactJWS:)`, back-deployed; needs the 18.4 SDK | The purchase option | As introductory |
| **Promotional** | Developer: current or former subscribers only | Yes | `.promotionalOffer(_:compactJWS:)`, back-deployed; needs the 26 SDK | The app's own UI and the purchase option | `.promotional`, with the offer's `id` |
| **Win-back** | Apple, from configured criteria | No | iOS 18 / macOS 15 | Apple's own sheet (iOS), the App Store, Manage Subscriptions; in the app, `eligibleWinBackOfferIDs` and `.winBackOffer(_:)` | `.winBack` |
| **Offer code** | Developer chooses who gets codes; Apple enforces | No | Subscriptions iOS 14.2 / macOS 15 | **The system sheet only**; a custom entry field is not allowed | `.code` |
| **Retention offer** (new, autumn 2026) | Apple, or the developer through the real-time Retention Messaging API | No; yes for the real-time API | Shown by the system in the cancellation flow | The system | No named `OfferType` case yet; a raw value StoreKit does not name `[check]` |

**Introductory.** Free trial, pay as you go, or pay up front `[Apple]`. `periodCount` is the number of discounted periods for pay as you go and 1 otherwise. One current and one future offer per storefront; it cannot be edited, only deleted and made again `[Apple]`. `isEligibleForIntroOffer(for:)` is per group, and **can be true when no introductory offer exists** `[Apple]`. Measured, **it keeps its first answer for the life of the process**: true before a purchase and still true after the purchase used the offer, while a plain `purchase()` applied the offer each time `[ran]`. The group's own transactions say more, and the payment sheet is the last word. Whether a family member who received a shared introductory offer can have their own is `[check]`. South Korea requires extra consent when an offer converts to the full price, which the App Store handles `[Apple]`.

**Promotional.** Up to 10 active per subscription; all storefronts; only the price can be edited later `[Apple]`. The ECDSA signature options are **deprecated in iOS and macOS 26**. The replacement signs a JWS with an In-App Purchase key (not the App Store Connect API key), and `promotionalOffer(_:compactJWS:)` **returns an array** of purchase options to add to the set `[Apple]`. A bad signature fails the purchase with `invalidOfferSignature`. Apple's App Store Server Library signs them, in Swift among others `[Apple]`. A promotional offer normally takes effect at the next billing event, immediately for an upgrade or crossgrade of the same duration; only one is active at a time `[Apple]`.

**Win-back.** Criteria: minimum paid duration, time since the subscription lapsed (a range within 1–24 months), and an optional wait between offers. It must be for the product the person most recently lapsed from; a person in a grace period or billing retry is not eligible, and access through Family Sharing does not count. Up to 350 per subscription, five running per storefront `[Apple]`. With *streamlined purchasing* on (the default) a redemption in the App Store completes outside the app and arrives on `updates`; off, the app receives a `PurchaseIntent` `[Apple]`. The `Message` API that lets an app delay Apple's win-back sheet is **not available on macOS**, and whether the Mac shows the sheet by itself is `[check]`. In Xcode's environment a win-back offer is eligible the moment the subscription lapses, and on the Mac can be bought with `.winBackOffer(_:)`; in the iOS 27 simulator, buying again after a lapse returns the old transaction and buys nothing `[ran]`.

**Offer codes.** One-time-use codes (batches of 500–25,000) or custom codes; eligibility per offer: new, existing, expired subscribers. Since WWDC25 codes also exist for consumables, non-consumables and non-renewing subscriptions, from iOS 16.3 / macOS 15 `[Apple]`. Redemption is the system's sheet. **It changed in 27**: `offerCodeRedemption(isPresented:onCompletion:)` and `presentOfferCodeRedeemSheet(from:)` are deprecated, and the replacements take `RedeemOption`s and return the `VerificationResult<Transaction>`. `RedeemOption` has no public values in the 27.0 SDK `[Apple]`. Before 27 the redeemed transaction reaches the app only through `updates`.

**Keeping a price.** When the developer raises a price and keeps the current price for existing subscribers, a person who lapses can come back at the preserved price **within 60 days** `[Apple]`. There is no other way to charge a returning customer a different price for the same product without an offer; a second product is the other idea, [below](#a-second-product-for-returning-customers).

### A second product for returning customers

The idea: two subscriptions configured identically, each with an introductory offer of 10.99 a month for three months and 15.99 after. One is shown to new customers, the other only to returning ones.

**In the same group it does not work.** Introductory eligibility belongs to the group, not the product: someone who has had the offer on the first product is not eligible on the second `[Apple]`. The second would charge 15.99 from the start.

**In a second group it works, once, and costs more than it saves.** Eligibility in a new group is fresh, so a returning customer gets the three months again `[Apple]`. But:

- **Two groups are two subscriptions.** A person can hold both at once and pay for both `[Apple]`. The obvious case is someone who has switched auto-renew off, still has days left on the first, and buys the second. Guideline 3.1.2(b) is about exactly this: people "should not be able to inadvertently subscribe to multiple variations of the same thing" `[Apple]`. Whether App Review rejects the arrangement was not found either way `[check]`.
- **It works for one return.** Having used the offer in the second group, a person who lapses again has nothing left, short of a third group.
- **A move between groups is not a change of plan.** There is no proration, and the paid time that counts towards the 85% rate after a year starts again `[Apple]`.
- **The rule is the app's alone.** Deciding who is "returning", and hiding the other product from them, is code in the app. Nothing outside the app applies it: in Manage Subscriptions a lapsed person resubscribes to what they had, at 15.99 `[check]`.
- **Both groups have to unlock the same thing**, which is the app's policy too, and every place the app asks "is this person subscribed" asks twice.

**A win-back offer on the one product does this without any of that.** Same group, same subscription, no double billing; Apple decides who is eligible, it repeats after the wait you choose, Apple shows it outside the app, and no server is needed `[Apple]`. Several win-back offers can give different terms to different lapse windows. What it cannot do is reach someone straight away: the shortest lapse window is one month `[Apple]`. Two cases fall outside it:

- **Cancelled and not yet lapsed.** Turning auto-renew back on keeps them at their current price. There is nothing to win back.
- **Lapsed less than a month ago.** A promotional offer, which is for current and former subscribers on the developer's own rule, and needs a server to sign it `[Apple]`.

**Stacking.** An introductory offer and then a promotional offer run one after the other, never combined; an offer code can follow the introductory offer if the developer allows; only one promotional offer is active; of overlapping win-back offers Apple shows one `[Apple]`. At the end of any offer the subscription renews at the standard price, except a free code offer set not to renew `[Apple]`.

## What only a server knows

Everything above is readable on the device, **the next time the app runs and reads**. The device can tell a refund, a billing problem, a pending downgrade, a price increase and an approaching lapse from the status and the renewal info `[Apple]`. It cannot:

- hear about anything while the app is not running, or be woken for it;
- see the refund process: `CONSUMPTION_REQUEST` and `REFUND_DECLINED` exist only as server notifications, because a declined refund changes no transaction `[Apple]`;
- tie a subscription to an account of the app's own, or share it across apps, platforms or the web, without `appAccountToken` and a server `[Apple]`;
- manage seats, or use the real-time Retention Messaging API `[Apple]`.

[Not implemented, deliberately](11-roadmap.md) keeps server-side verification and App Store Server Notifications out of this package, and the plan keeps it that way.

## macOS and iOS differ

| | iOS | macOS |
|---|---|---|
| Manage subscriptions in the app (`showManageSubscriptions`, `manageSubscriptionsSheet`) | Yes | **No.** Open `https://apps.apple.com/account/subscriptions` `[Apple]` |
| `Message` API: price-consent, billing-issue and win-back sheets | Yes | **No** `[Apple]` |
| `SubscriptionOfferView` (26) | Yes | **No** `[Apple]` |
| `SubscriptionStoreView`, `subscriptionStatusTask` | iOS 17 | macOS 14 `[Apple]` |
| Refund request | `UIWindowScene` | `NSViewController`; the sheet did not appear before macOS 27 `[Apple]` |
| Offer-code sheet | `UIWindowScene`; `UIViewController` in 27 | `NSViewController` (15); `NSWindow` in 27 `[Apple]` |
| Billing problems page | `https://apps.apple.com/account/billing`, "only supported for iOS and macOS" `[Apple]` | The same |

## What App Review asks of a subscription paywall

This is paywall wording, so it is the app's, but it is what the package's facts have to be good enough to fill:

- The subscription's name, its length, and what it includes; the full renewal price shown clearly, **with the amount billed the most prominent price**; a trial's length and the price after it `[Apple]`.
- Links to the privacy policy and terms of use in the app; a way to restore; an easy route to Apple's manage and cancel page `[Apple]`.
- A period of at least seven days, available on all the person's devices; no bait and switch; nothing removed that existing subscribers paid for (3.1.2(a)) `[Apple]`.
- For a 12-month commitment, the monthly price and the total commitment, before purchase `[Apple]`.

## Testing subscriptions with Apple's tools

Everything in [testing](05-testing.md) still holds: `SKTestSession` works only in a test bundle hosted by an app ([D1](10-decisions.md#d1-real-storekit-is-tested-from-a-host-app)), and there is one shared test environment, so tests that change it run one at a time `[Apple]`.

- **The `.storekit` file** defines groups, levels, durations, Family Sharing and every kind of offer, including win-back eligibility and, from Xcode 26.5, offers per billing plan `[Apple]`; a hand-written version 4.0 file with all four kinds loads `[ran]`. Promotional offers are signed in Xcode with the file's own "Subscription Offers Key", not the production key `[Apple]`. Signed with a key Xcode does not know, a promotional offer failed with `StoreKitError.unknown` and an introductory override **went through at the full price, silently** `[ran]`.
- **`SKTestSession`** has `timeRate` (a month renews every 30 seconds, down to a renewal every 2 seconds); `expireSubscription(productIdentifier:)`, `forceRenewalOfSubscription(productIdentifier:)`, `refundTransaction(identifier:)`; `shouldEnterBillingRetryOnRenewal` and `billingGracePeriodIsEnabled`; `disableAutoRenewForTransaction` and `enableAutoRenewForTransaction`; the price-increase consent calls; and, for `buyProduct(identifier:options:)`, the test-only options `.promotionalOffer(id:)` (no signature needed), `.codeOffer(referenceName:)` and `.purchaseDate(_:renewalBehavior:)` `[Apple]`. It cannot simulate a notify-only price increase, Family Sharing, seats, or a chosen grace length. There is no call to reset introductory eligibility; `clearTransactions()` clears the history.
- **Sandbox** renews a month every 5 minutes and a year every hour by default, up to 12 renewals; billing failures are switched on in iOS Settings, for the whole sandbox account; introductory eligibility is reset from the sandbox account's settings `[Apple]`.
- **Recently fixed in Apple's tools**, and so present in some tools this package supports `[Apple]`: billing-retry status updates wrong in Xcode testing (fixed in 26); win-back purchases broken in Xcode testing (26.2); `SKTestSession` ignoring the configuration in unit tests (26.5) and unable to connect in the Simulator (iOS 26.6); `purchaseDate(_:renewalBehavior:)` ignoring the renewal behaviour, and upgrades not reported on `updates` (27). The package's CI builds with Xcode 26.6.

## Traps

1. **In a grace period `expirationDate` is already in the past** and the person is still entitled. A check of `expirationDate > now` locks out a paying customer. Decide by state `[Apple]`.
2. **At the end of every period StoreKit says, for a moment, that the subscription has ended**: `expired` for up to 0.7 s on the Mac; on iOS also "will not renew" and "eligible for a win-back offer", and the listing empty. An app that locks on the first `expired` locks a paying customer at every renewal. Believe a lapse when it lasts `[ran]`.
3. **A downgrade comes back from `purchase()` as a success, with the transaction already held.** Compare the product returned with the product asked for `[ran]`.
4. **Renewals missed while the app was closed arrive newest first.** The last to arrive is the oldest `[ran]`.
5. **An upgraded-away-from transaction can still be listed.** Ignore `isUpgraded` and take the highest level `[Apple]`.
6. **A downgrade is not immediate.** Nothing changes until the renewal; `autoRenewPreference` only says what is coming `[Apple]`.
7. **More than one status per group**: the person's own `expired` beside a family member's `subscribed` `[Apple]`.
8. **The status types are open sets**, and Apple adds to them `[Apple]`.
9. **An expiry sends nothing.** Look again at the expiry, and whenever the app becomes active `[Apple]`.
10. **Every renewal is a transaction to finish** `[Apple]`.
11. **`AppStore.sync()` asks for a password.** Never automatically `[Apple]`.
12. **Non-renewing subscriptions never leave `currentEntitlements`**: the app computes their end `[Apple]`.
13. **`isEligibleForIntroOffer` can be true with no introductory offer**, and may be stale. Show terms from the product, and let the payment sheet decide `[Apple]`.
14. **Prices are in units on the device and milliunits on the server**, and `renewalPrice` already includes the offer `[Apple]`.
15. **On a 12-month commitment, `RenewalInfo.willAutoRenew` stays true after the person cancels**; the commitment's own `willAutoRenew` says so. No grace period, and billing retry lasts 90 days `[Apple]`.
16. **From 27, seats appear in the queries by default**, as `.assigned`. Count them or turn selling to organisations off `[Apple]`.
17. **macOS has no manage sheet, no `Message` API and no `SubscriptionOfferView`** `[Apple]`.
18. **Xcode's test environment is not production** for renewals, upgrades and dialogs, and many of its faults were fixed only in 26.5, 26.6 or 27 `[Apple]`. Anything the package rests on is measured against it and in the sandbox, on the OS versions it supports.

## Sources

Apple, read 19 September 2026. SDK interfaces: Xcode 27.0 (27A266a), `StoreKit.swiftmodule`, `_StoreKit_SwiftUI.swiftmodule` and `StoreKitTest.framework` for macOS and iOS.

- Products and groups: [Offer auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions), [Auto-renewable subscriptions](https://developer.apple.com/app-store/subscriptions/), [Handling subscriptions billing](https://developer.apple.com/documentation/storekit/handling-subscriptions-billing)
- State: [`currentEntitlements`](https://developer.apple.com/documentation/storekit/transaction/currententitlements), [`currentEntitlements(for:)`](https://developer.apple.com/documentation/storekit/transaction/currententitlements(for:)), [`status(for:)`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/status(for:)), [`RenewalState`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalstate), [`RenewalInfo`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo), [`isUpgraded`](https://developer.apple.com/documentation/storekit/transaction/isupgraded), [`Transaction.updates`](https://developer.apple.com/documentation/storekit/transaction/updates)
- Lifecycle: [Reducing involuntary subscriber churn](https://developer.apple.com/documentation/storekit/reducing-involuntary-subscriber-churn), [Enable billing grace period](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions), [Managing price increases](https://developer.apple.com/documentation/storekit/managing-price-increases-for-auto-renewable-subscriptions), [Manage pricing](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions), [Supporting Family Sharing](https://developer.apple.com/documentation/storekit/supporting-family-sharing-in-your-app), [`Message`](https://developer.apple.com/documentation/storekit/message)
- Offers: [Introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions), [Implementing introductory offers](https://developer.apple.com/documentation/storekit/implementing-introductory-offers-in-your-app), [Promotional offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-promotional-offers-for-auto-renewable-subscriptions), [Implementing promotional offers](https://developer.apple.com/documentation/storekit/implementing-promotional-offers-in-your-app), [Generating JWS to sign App Store requests](https://developer.apple.com/documentation/storekit/generating-jws-to-sign-app-store-requests), [Win-back offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-win-back-offers), [Supporting win-back offers](https://developer.apple.com/documentation/storekit/supporting-win-back-offers-in-your-app), [Offer codes](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-offer-codes), [Supporting offer codes](https://developer.apple.com/documentation/storekit/supporting-offer-codes-in-your-app), [App Store Server Library for Swift](https://github.com/apple/app-store-server-library-swift)
- 2025 and 2026: [WWDC25 "What's new in StoreKit and In-App Purchase"](https://developer.apple.com/videos/play/wwdc2025/241/), [WWDC26 "What's new in Apple In-App Purchase"](https://developer.apple.com/videos/play/wwdc2026/210/), [WWDC26 Retention Messaging](https://developer.apple.com/videos/play/wwdc2026/309/), [WWDC26 groups and organisations](https://developer.apple.com/videos/play/wwdc2026/391/), [Monthly subscriptions with a 12-month commitment](https://developer.apple.com/documentation/storekit/supporting-monthly-subscriptions-with-a-12-month-commitment), [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes), [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- Rules: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [Developer Program License Agreement, Schedule 2](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
- Testing: [Setting up StoreKit Testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode), [`SKTestSession`](https://developer.apple.com/documentation/storekittest/sktestsession), [Testing win-back offers in Xcode](https://developer.apple.com/documentation/storekit/testing-win-back-offers-in-xcode), [Sandbox account settings](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/manage-sandbox-apple-account-settings), [Testing failing renewals](https://developer.apple.com/documentation/storekit/testing-failing-subscription-renewals-and-in-app-purchases)
- Reported, not Apple's word `[check]`: Apple developer forums threads [696329](https://developer.apple.com/forums/thread/696329) (family entitlements), [726200](https://developer.apple.com/forums/thread/726200) and [721252](https://developer.apple.com/forums/thread/721252) (renewals and expiry on `updates`), [766872](https://developer.apple.com/forums/thread/766872) (upgrades still listed), [716661](https://developer.apple.com/forums/thread/716661) (stale introductory eligibility); [Superwall on the introductory override](https://superwall.com/docs/ios/guides/intro-offer-eligibility-override)
