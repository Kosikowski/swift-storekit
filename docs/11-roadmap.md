# Not implemented, deliberately

What the package does not do, and why not yet.

| Not here | Why | If you need it now |
|---|---|---|
| **Consumables** | Need a balance the app must keep, and delivery before finishing. | — |
| **An offer-code redemption button** | A redeemed code is taken already: from the updates stream, or from the 27 SDK's sheet with `takeRedemption(_:)` ([offers](16-offers.md#offer-codes)). A button would present the sheet, and nothing more; SwiftUI has the modifier. | SwiftUI's `offerCodeRedemption` modifier. |
| **Paid-to-free grandfathering** (`AppTransaction`) | `originalAppVersion` means different things on macOS and iOS and is always "1.0" in the sandbox; it deserves its own port and its own tests. | `AppTransaction.shared`, with care. |
| **In-app refund requests** | SwiftUI's `refundRequestSheet` needs nothing from this package. | Use it directly. |
| **Feature gates, quotas, paywalls** | Product policy. [The one rule](01-architecture.md#the-one-rule). | They are your app's. |
| **tvOS, watchOS, visionOS** | Untested. On visionOS `purchase(options:)` is unavailable, so the automatic anchor would need another route. | — |
| **Server-side verification, App Store Server Notifications** | Out of scope for a client package. | Apple's App Store Server Library. |

## Known limits

- `requestedPurchases` lasts for the session too: a purchase asked for on the App Store and not acted on is not remembered past it.
- Purchase intents, the 12-month commitment, Apple's messages and subscription bundles are built on Apple's documented API and have not been measured: Xcode's environment could not be made to produce any of them ([spike](../spike/README.md#phase-3-what-else-storekit-does-and-what-xcodes-environment-could-not-be-made-to-do)). They are tried in the sandbox, by hand.
- `pendingApprovals` lasts for the session. StoreKit has no way to list purchases awaiting approval after a relaunch; the approval itself still arrives.
- A trial's expiry is scheduled on the continuous clock. A wall clock *changed* while the app is running is noticed at the next read: call `refresh()` when the app becomes active.
- Someone who sets their clock back extends a trial for as long as they keep it there. Nothing on the device can prevent that.
