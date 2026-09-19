# Catalogue and standing

The values an app writes (`ProductID`, `Catalogue`) and the values it reads (`Standing`, `ProductAccess`, and the store's observable properties). All of them are in `PurchaseCore`, all are `Hashable` and `Sendable`, and none of them imports StoreKit.

**The package reports store facts and performs store actions; the app owns product policy.** Everything on this page is a store fact. What a fact *unlocks* is yours to decide, and the last sections show where that decision goes.

Evidence tags (`[ran]`, `[Apple]`, `[check]`) mark statements about real StoreKit; the [checklist](checklist.md) explains them.

## `ProductID`

A product identifier, exactly as it is spelt in App Store Connect and in the `.storekit` file.

It is a type and not a `String` because everything in the package is keyed by one, and a bare string is also a display name, a price and an error message. Letting the compiler tell them apart is the cheapest test there is.

```swift
let pro: ProductID = "com.example.app.pro"          // string literal
let archive = ProductID("com.example.app.archive")  // or init(_:), or init(rawValue:)
```

It is `RawRepresentable`, `Comparable` (by spelling, only so that listings and logs come out in a stable order) and `CustomStringConvertible`.

## `Catalogue`

Every product the app sells, said once.

```swift
static let catalogue = Catalogue([
    .unlock(pro),                                   // Family Sharing honoured (the default)
    .unlock(archive, familySharing: .ignored),      // a family member's purchase does not count
    .trial(trial, of: [pro, archive], lasting: .seconds(14 * 86_400)),
])
```

An array literal works too: `let catalogue: Catalogue = [.unlock(pro)]`.

The catalogue is the single source of identifiers, and four things follow from it:

- the store is asked for exactly these products;
- only these are counted as owned;
- only their transactions are finished, so another handler's transactions are left for it ([the adapter](08-storekit-adapter.md));
- a `.storekit` file can be checked against it in a plain unit test ([App Store Connect](09-app-store-connect.md)).

| Member | Returns |
|---|---|
| `entries` | `[CatalogueEntry]`, in the order written. Loaded products keep this order |
| `identifiers` | `Set<ProductID>` |
| `contains(_:)` | `Bool` |
| `entry(for:)` | `CatalogueEntry?` |
| `trials(of:)` | The trials that stand in for an unlock, in catalogue order |

### Validation, and why it traps

`Catalogue.init` checks the entries and **traps** with the problems in the message. A catalogue is a constant written by a programmer, so a bad one is a bug, and a bug found at the first launch in development is better than a product that never loads in production.

`Catalogue.problems(in:)` runs the same check without trapping. Use it first for a list that comes from anywhere other than a literal:

```swift
static func catalogue(from entries: [CatalogueEntry]) -> Catalogue? {
    let problems = Catalogue.problems(in: entries)
    guard problems.isEmpty else { return nil }
    return Catalogue(entries)
}
```

| `Catalogue.Problem` | Meaning |
|---|---|
| `.duplicateIdentifier(ProductID)` | The same identifier twice |
| `.trialWithoutTargets(ProductID)` | A trial of nothing |
| `.trialTargetMissing(trial:target:)` | A trial names something the catalogue does not list |
| `.trialTargetIsNotAnUnlock(trial:target:)` | A trial names another trial. A trial stands in for something kept |

## `CatalogueEntry`

An entry is an identifier and the one thing about the product that the store cannot tell the package.

| Factory | Kind |
|---|---|
| `.unlock(_ id:, familySharing:)` | `.unlock(familySharing:)`: a one-time purchase that is kept. `familySharing` defaults to `.honoured` |
| `.trial(_ id:, of:, lasting:)` | `.trial(TrialTerms)`: a free non-consumable standing in for other unlocks for a while ([trials](04-trials.md)) |

`entry.trialTerms` is the terms if the entry is a trial, and nil otherwise.

The trial's `targets` are the one relation between products that the package knows about. It is there because a store fact depends on it: a trial is not on offer to someone who already owns everything it would lend.

## Family Sharing, restated in code

`CatalogueEntry.FamilySharing` is `.honoured` or `.ignored`. It mirrors a switch in App Store Connect, and the package restates it in code for three reasons.

1. **Nothing in a transaction says how the product is configured.** A transaction says only how *it* arrived (`Ownership`). `StoreProduct.isFamilyShareable` does report the switch, but it comes with prices, over the network, and ownership must never wait for that.
2. **The switch cannot be turned off once it is on** `[Apple]`. A mistake in App Store Connect is permanent; the same mistake guarded in code costs nothing.
3. **A family-shared transaction carries the purchaser's dates.** For an unlock that is harmless. For a trial it is not: every member of the family would be handed the organiser's trial, over already as likely as not, and lose their own, since a trial that is owned cannot be started.

So whether a transaction *counts* is decided by `StandingResolver.counts(_:in:)`, from the entry's kind and the transaction's `Ownership`:

| Entry | `.purchased` | `.familyShared` | `.assigned` | `.unrecognised` |
|---|---|---|---|---|
| `.unlock(familySharing: .honoured)` | counts | counts | counts | counts |
| `.unlock(familySharing: .ignored)` | counts | no | counts | no |
| `.trial` | counts | **no** | **no** | **no** |

`.assigned` is a purchase made in volume by an organisation. `.unrecognised` is an ownership type the App Store has added since the package was written; it is treated like `.familyShared`. A product the catalogue does not list never counts.

A trial never honours Family Sharing, and there is no option to make it. The same rule is applied to the store's listing, to a purchase's own transaction and to a transaction that arrives on its own, so the three can never disagree.

## `Standing`: a value about a moment

Everything the store has said about this account, as one value.

```swift
let standing = store.standing                 // observable; .unknown until the store answers
let known = await store.knownStanding()       // waits for the answer
```

**Every question that depends on time takes the date as a parameter, and nothing in a standing reads a clock.** That is what makes a trial's expiry testable without waiting for it. It is also honest: a standing resolved at noon can be asked about half past, and answers correctly without being resolved again.

| Member | Answers |
|---|---|
| `phase`, `isKnown` | `.unknown` or `.known`: whether the store has answered |
| `asOf` | When the store last resolved to something that *reads* differently. A later read that found nothing new is not published — it would redraw every view that watches the standing, for nothing — so this is not "when the store was last asked". A trial running out is news, though nothing held has changed, and is published |
| `catalogue` | The catalogue it was resolved against |
| `access(to:at:)` | `ProductAccess` for one unlock at a date |
| `trial(_:at:)` | `TrialStatus` for one trial at a date ([trials](04-trials.md)) |
| `ownedProducts` | `[OwnedProduct]` that count, in identifier order |
| `ownership(of:)` | `OwnedProduct?` for one product |
| `nextExpiry` | `Date?`: the next moment an answer changes by itself |
| `access(to:)`, `trial(_:)` | The same questions, asked for `asOf` |

The no-date overloads are right for a view that draws the current state. The store resolves again at the moment a trial ends, which replaces the standing, so a view reading `standing.access(to:)` redraws then. Pass a date when you hold a standing for a while, draw a countdown, or decide something: `knownStanding()` returns a snapshot, and a snapshot asked about *now* must be given now.

### `ProductAccess`, and why there is no `Bool`

```swift
public enum ProductAccess: Hashable, Sendable {
    case unknown
    case owned(OwnedProduct)
    case onTrial(TrialPeriod, via: ProductID)
    case none
}
```

| Case | Meaning |
|---|---|
| `.unknown` | The store has not answered yet. **Not the same as `.none`** |
| `.owned(OwnedProduct)` | Held, and counted for this account |
| `.onTrial(TrialPeriod, via:)` | Lent by a trial that is still running at the date asked; `via` is the trial product |
| `.none` | The store has answered, and there is no right to it |

There is deliberately no `Bool`. Collapsing this to "is it unlocked" throws away `.unknown`, and `.unknown` read as "no" is the bug where a paying customer meets the paywall at every launch. An app that wants a `Bool` decides what `.unknown` means for the thing being asked, which is usually "wait", and says so itself:

```swift
enum Plan: Equatable {
    case free
    case trial(endsAt: Date)
    case pro

    /// Nil while the store has not answered.
    init?(_ standing: Standing, at date: Date) {
        switch standing.access(to: Shop.pro, at: date) {
        case .unknown: return nil
        case .owned: self = .pro
        case let .onTrial(period, _): self = .trial(endsAt: period.endsAt)
        case .none: self = .free
        }
    }
}
```

`Plan` is policy: it belongs to the app, and so does every limit and lock hung from it.

Three details of `access(to:at:)`:

- Owning the unlock beats a trial, running or over.
- If several trials lend the same unlock, the one that runs longest decides.
- It is a question about unlocks. Asked about a trial product it answers `.none`; ask `trial(_:at:)` instead.

### `ownedProducts` and `ownership(of:)`

`OwnedProduct` is one thing the store vouches for this account holding:

| Property | Meaning |
|---|---|
| `id` | The product |
| `originalPurchaseDate` | When the account first bought it. For a non-consumable bought again, on another device or after a reinstall, this is still the first date |
| `purchaseDate` | This transaction's date |
| `ownership` | `.purchased`, `.familyShared`, `.assigned` or `.unrecognised` |

An `OwnedProduct` is only ever built from a transaction the store has verified and has not taken back. A standing holds only the ones that count, by the table above.

A trial product is in `ownedProducts` from the day it is taken and **stays there after it ends**. Holding the trial product is a fact; whether it still lends anything is `trial(_:at:)`'s answer.

### `nextExpiry`

The end of the running trial that ends soonest after `asOf`, or nil when the standing is unknown or no trial is running.

Nothing observable happens when a trial runs out: no transaction arrives. Whoever holds a standing therefore has to look again at that moment, or nothing locks until something unrelated redraws or the app is relaunched. `PurchaseStore` does this for the standing it publishes. `nextExpiry` is public for code that keeps a standing of its own.

### Building a standing without a store

An app's policy can be tested with no store at all, because `StandingResolver` is public and pure:

```swift
let bought = Date(timeIntervalSince1970: 1_000_000)
let standing = StandingResolver().standing(
    owned: [OwnedProduct(id: Shop.trial, originalPurchaseDate: bought)],
    catalogue: Shop.catalogue,
    asOf: bought)

Plan(standing, at: bought)                                     // .trial(endsAt:)
Plan(standing, at: bought.addingTimeInterval(14 * 86_400))     // .free: over AT its end
Plan(.unknown(catalogue: Shop.catalogue), at: bought)          // nil
```

`Standing.unknown(catalogue:asOf:)` is the standing before the store has said anything. For anything involving the order of events, use a [simulated store](06-simulated-store.md).

## The store has not answered yet

`PurchaseStore.standing` starts as `.unknown(catalogue:)` and stays so until the first read of ownership returns. Every launch passes through this state.

| Must wait for `knownStanding()` | Need not wait |
|---|---|
| Feature gates and limits | Drawing: show neither "Pro" nor "Free", neither locks nor a paywall |
| Whether to present the paywall | Loading prices |
| Locking or dimming content | |
| Every way of opening gated content: selection, shortcuts, deep links, state restoration, App Intents | |

Otherwise a click in the first moments opens something that should be locked or, worse and more often, a paying customer is shown the paywall until the answer arrives `[ran]`.

`knownStanding()` starts the store if nothing has, returns once the store has answered, and does not wait for prices. The read underneath it runs in a task nobody can cancel, because real StoreKit answers a **cancelled** task with nothing at all: 0 of 1 entitlements `[ran]`. Nothing at all reads as "owns nothing", and SwiftUI cancels `.task` whenever a view goes away. A cancelled caller of `knownStanding()` waits for the read like anyone else and receives the whole answer.

## `pendingApprovals`

`Set<ProductID>`: purchases sent to someone else for approval (Ask to Buy) and not yet settled.

A product enters the set when `purchase` returns `.pending`. It leaves when a grant for it arrives on the updates stream, or when a resolved standing owns it.

**It is for this session only.** StoreKit has no API that lists purchases awaiting approval `[Apple]`, so after a relaunch the set is empty even if a request is still open. The approval itself is not lost: it arrives as a transaction update whenever it comes, and the adapter asks for anything left unfinished as it starts listening. If the request is declined, nothing arrives — measured on macOS 26.6 `[ran]`; the iOS 27 simulator delivers a decline as a purchase, which is its fault and not a behaviour to build on — and the product stays in the set until the app is relaunched. Word "waiting for approval" accordingly: as a status, not a promise.

## `activity`

| `PurchaseActivity` | |
|---|---|
| `.idle` | |
| `.purchasing(ProductID)` | |
| `.restoring` | |

`isBusy` is true for anything but `.idle`. The store does one thing at a time: a second purchase or a restore begun while one is under way throws `.alreadyInProgress` and is not queued, because a queue would put a second payment sheet behind the first. `PurchaseButton` and `RestorePurchasesButton` disable themselves while `isBusy`.

## `productLoad` is separate from the standing

| `ProductLoadState` | |
|---|---|
| `.notLoaded` | `loadProducts()` has not been called |
| `.loading` | |
| `.loaded` | `products` holds what the store returned, in catalogue order |
| `.failed(PurchaseError)` | The last load failed. **Products from an earlier, successful load are kept** |

Prices come over the network, and offline the request can take a long time to fail. Ownership is answered from StoreKit's own cache, offline included `[Apple]`. So the two are separate states, `start()` reads ownership and does not load prices, and nothing about what a person may use ever waits for `productLoad`. Hand-written code that waits for the catalogue before it knows what is owned locks an owner out whenever the network is slow.

A failed reload changes `productLoad` and nothing else. The standing is not touched, and a price that was right a minute ago stays on screen, which is better than an empty paywall.

Fewer products than were asked for is not an error: a product not yet approved is absent. `.loaded` with an empty `products` nearly always means a development build the App Store has never heard of ([getting started](02-getting-started.md#the-development-build-trap)).

`StoreProduct` is the store's description of a product, for this person's language and currency:

| Property | Use |
|---|---|
| `id`, `displayName`, `description` | As the store states them |
| `displayPrice` | **Show this.** Never a price formatted from a number of your own |
| `price` | A `Decimal`, for comparing with zero and nothing else |
| `isFamilyShareable` | The App Store Connect switch, as the store reports it |
