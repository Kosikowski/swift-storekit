# Not implemented, deliberately

What the package does not do, and why not yet.

| Not here | Why | If you need it now |
|---|---|---|
| **Auto-renewable subscriptions** | A different problem: status, renewal, grace periods, billing retry, offers, upgrade paths. Doing non-consumables well first. | StoreKit's `SubscriptionStoreView` covers a great deal unaided. |
| **Consumables** | Need a balance the app must keep, and delivery before finishing. | — |
| **Non-renewing subscriptions** | Expiry is the app's to compute; close to the trial model, and a candidate. | — |
| **Offer-code redemption** | The updates listener already receives a redeemed transaction. A redemption button would use `presentOfferCodeRedeemSheet(from:options:)`, which is SDK 27 only. | SwiftUI's `offerCodeRedemption` modifier. |
| **Promoted in-app purchases** (`PurchaseIntent`) | Not supported by the Mac App Store; iOS only. | Iterate `PurchaseIntent.intents` and call `purchase(_:)`. |
| **Paid-to-free grandfathering** (`AppTransaction`) | `originalAppVersion` means different things on macOS and iOS and is always "1.0" in the sandbox; it deserves its own port and its own tests. | `AppTransaction.shared`, with care. |
| **In-app refund requests** | SwiftUI's `refundRequestSheet` needs nothing from this package. | Use it directly. |
| **Feature gates, quotas, paywalls** | Product policy. [The one rule](01-architecture.md#the-one-rule). | They are your app's. |
| **tvOS, watchOS, visionOS** | Untested. On visionOS `purchase(options:)` is unavailable, so the automatic anchor would need another route. | — |
| **Server-side verification, App Store Server Notifications** | Out of scope for a client package. | Apple's App Store Server Library. |

## Known limits

- `pendingApprovals` lasts for the session. StoreKit has no way to list purchases awaiting approval after a relaunch; the approval itself still arrives.
- A trial's expiry is scheduled on the continuous clock. A wall clock *changed* while the app is running is noticed at the next read: call `refresh()` when the app becomes active.
- Someone who sets their clock back extends a trial for as long as they keep it there. Nothing on the device can prevent that.
