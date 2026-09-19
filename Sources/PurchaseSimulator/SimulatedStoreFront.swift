//
//  SimulatedStoreFront.swift
//  PurchaseSimulator
//
//  A store with no StoreKit in it, and with StoreKit's awkwardness left in.
//
//  For unit tests, SwiftUI previews, UI tests, screenshots, and a debug build being
//  poked at by hand. It is a *fake*, not a stub: it remembers what was bought, the
//  way the real store does for the account, and it keeps the real store's bad habits
//  on purpose, because a politer fake hides the bugs those habits cause.
//
//  · **It lists a purchase one read late.** The real store lists a purchase about a
//    second after `purchase()` returns. The first fake written for this listed at
//    once, and the bug it hid — Buy appearing to do nothing until relaunch — shipped.
//  · **It answers a cancelled task with nothing**, as the real store was measured to —
//    about what is owned, and about what is for sale: a cancelled request for products
//    comes back as an empty list, not an error.
//  · **Buying something already owned hands back the original**, original date and
//    all. That is what makes a trial one trial.
//  · **The account may own things this device has not heard of** — bought on another
//    device, or before a reinstall — which turn up when bought again or restored.
//
//  **The whole file exists only in DEBUG builds.** A store that hands out purchases
//  for nothing must not be in a binary that ships, and a preprocessor guard round a
//  call site is a guard somebody can move. Absent is safer than disabled. Note that
//  Xcode gives a package target `DEBUG` by the *name* of the build configuration: a
//  configuration called `Screenshots` does not get it, one called
//  `Debug-Screenshots` does (spike/README.md).
//

#if DEBUG

import Foundation
public import PurchaseCore
import Synchronization

/// An in-memory store for tests, previews and debug builds.
public final class SimulatedStoreFront: StoreFront, StoreDiagnosing, SubscriptionStatusReading,
    IntroductoryEligibilityReading
{
    /// What the store holds at this instant.
    public struct Snapshot: Hashable, Sendable {
        /// Listed: what `ownedProducts()` answers with.
        public let listed: [OwnedProduct]
        /// Bought, and not listed yet.
        public let unlisted: [OwnedProduct]
        /// Owned by the account, unknown to this device.
        public let earlier: [OwnedProduct]
        public let pending: Set<ProductID>
        /// Listed by the store with a signature that does not check out: counted by
        /// nobody, and reported only by `diagnose()`.
        public let unverified: Set<ProductID>
        /// Every subscription status the store keeps, whether or not it says it yet.
        public let subscriptions: [HeldSubscription]
    }

    /// A subscription's status, and whether the store says it yet: a status for a purchase
    /// is said once the purchase is listed, as it lags with the listing on the Mac.
    private struct SubscriptionRecord {
        var status: HeldSubscription
        var isSaid: Bool
        /// A renewal made and not yet listed: the status it becomes once it is.
        var renewal: HeldSubscription?
        /// Reads of the statuses still to go before this one is said (`saysStatusAfterReads`).
        var readsUntilSaid = 0
    }

    private struct Unlisted {
        var product: OwnedProduct
        var readsUntilListed: Int
    }

    private struct State {
        var behaviour: Behaviour
        var products: [StoreProduct]
        var listed: [OwnedProduct] = []
        var unlisted: [Unlisted] = []
        var earlier: [OwnedProduct] = []
        var pending: Set<ProductID> = []
        var unverified: Set<ProductID> = []
        var subscriptions: [SubscriptionRecord] = []
        /// Groups whose introductory offer the account has used, here or anywhere else.
        var usedIntroductoryOffer: Set<SubscriptionGroupID> = []
        /// The first answer given about each group, kept as StoreKit keeps it.
        var firstEligibility: [SubscriptionGroupID: Bool] = [:]
        var lastPurchaseOptions: PurchaseOptions?
        var nextListener = 0
        var listeners: [Int: AsyncStream<TransactionUpdate>.Continuation] = [:]
    }

    public let catalogue: Catalogue

    /// Close it to hold "what is owned" shut: the store has not answered yet, which
    /// is how every launch begins.
    public let ownershipGate = AnswerGate()
    /// Close it to hold the catalogue shut: a slow network. What is owned must still
    /// be answered, and nothing must wait for this.
    public let catalogueGate = AnswerGate()
    /// Close it to hold a purchase open: **the payment sheet is up**, which is the
    /// state of a purchase a person sees for longest, and the one in which a second
    /// tap, a closed window or a Buy button that has not been disabled does its
    /// damage. What the purchase comes to is decided when the gate opens, so a test
    /// can change its mind — set `behaviour.purchase = .cancelled`, then open.
    public let purchaseGate = AnswerGate()
    /// The same for a restore: the store is asking for a password.
    public let restoreGate = AnswerGate()

    /// The store's own clock: what a scenario's ages become dates against.
    let clock: any TimeProviding
    private let state: Mutex<State>

    /// - Parameters:
    ///   - products: what the store says it sells. Left out, plausible ones are made up
    ///     from the catalogue: unlocks at 9.99, trials free.
    ///   - owned: owned and listed from the start, as `seed(_:)` would make them. Every
    ///     app's tests wrote this initialiser for themselves.
    public init(
        catalogue: Catalogue,
        products: [StoreProduct]? = nil,
        owned: [OwnedProduct] = [],
        clock: any TimeProviding = SystemClock(),
        behaviour: Behaviour = Behaviour()
    ) {
        self.catalogue = catalogue
        self.clock = clock
        self.state = Mutex(
            State(
                behaviour: behaviour, products: products ?? Self.plausibleProducts(for: catalogue, behaviour: behaviour),
                listed: owned))
    }

    // MARK: - Arranging

    /// How the store misbehaves. Change it at any time.
    public var behaviour: Behaviour {
        get { state.withLock { $0.behaviour } }
        set { state.withLock { $0.behaviour = newValue } }
    }

    /// What the store holds at this instant: listed, bought and not yet listed, owned
    /// elsewhere, and pending approval. For a test to assert on; reading it does not
    /// count as a read of what is owned, and lists nothing sooner.
    public var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                listed: $0.listed, unlisted: $0.unlisted.map(\.product), earlier: $0.earlier,
                pending: $0.pending, unverified: $0.unverified, subscriptions: $0.subscriptions.map(\.status))
        }
    }

    /// What the store sells, as `products()` answers: names, prices, and a subscription's
    /// period and offers. Change it to put an offer on sale, or take one off.
    public var productsOnSale: [StoreProduct] {
        get { state.withLock { $0.products } }
        set { state.withLock { $0.products = newValue } }
    }

    /// The account has used the introductory offer in `group` — here, on another device,
    /// or years ago. One per group per account `[Apple]`.
    public func useIntroductoryOffer(in group: SubscriptionGroupID) {
        state.withLock { _ = $0.usedIntroductoryOffer.insert(group) }
    }

    /// What the last purchase asked for beyond its product — an account token — as it
    /// reached the store. Nil until something is bought.
    public var lastPurchaseOptions: PurchaseOptions? { state.withLock { $0.lastPurchaseOptions } }

    /// How many are listening to the updates stream. A store that has only been
    /// constructed should not be among them.
    public var listenerCount: Int { state.withLock { $0.listeners.count } }

    /// Owned and listed from the start, with no announcement: the account as the app
    /// finds it at launch.
    public func seed(_ product: OwnedProduct) {
        state.withLock { state in
            state.listed.removeAll { $0.id == product.id }
            state.listed.append(product)
        }
    }

    /// Owned since `age` ago. `seed("trial", age: .seconds(14 * 86_400 - 300))` is a
    /// fortnight's trial with five minutes left.
    public func seed(_ id: ProductID, age: Duration = .zero, ownership: Ownership = .purchased) {
        seed(OwnedProduct(id: id, originalPurchaseDate: date(ago: age), ownership: ownership))
    }

    /// A trial with `remaining` left to run — or, negative, over by that much.
    ///
    ///     store.seedTrial("com.example.trial", remaining: .seconds(300))
    public func seedTrial(_ id: ProductID, remaining: Duration) {
        guard let terms = catalogue.entry(for: id)?.trialTerms else {
            preconditionFailure("\(id) is not a trial in this catalogue")
        }
        seed(id, age: terms.duration - remaining)
    }

    /// Owned by the account, and **not known to this device**: bought on another
    /// device, or before a reinstall. Buying it, or a restore, brings it here with
    /// its original date.
    public func seedEarlierPurchase(_ product: OwnedProduct) {
        state.withLock { state in
            state.earlier.removeAll { $0.id == product.id }
            state.earlier.append(product)
        }
    }

    /// The same, bought `age` ago by this store's clock — and, with `ownership`, a
    /// family member's purchase this device has yet to hear of.
    public func seedEarlierPurchase(
        _ id: ProductID, age: Duration, ownership: Ownership = .purchased
    ) {
        seedEarlierPurchase(
            OwnedProduct(id: id, originalPurchaseDate: date(ago: age), ownership: ownership))
    }

    /// The store lists this product, and **its signature does not check out**: a
    /// customer who paid, and whose purchase the app must not count. `ownedProducts()`
    /// leaves it out, as the real adapter does, so the app sees someone who owns
    /// nothing; `diagnose()` is where it shows. For an app's "I paid and it is locked"
    /// support path, which nothing else here can reach.
    public func seedUnverified(_ id: ProductID) {
        state.withLock { _ = $0.unverified.insert(id) }
    }

    /// A subscription status, as the account has it at launch: said at once, and listed if
    /// it is entitled — or not listed, if it is not. Replaces the status of the same product
    /// and ownership.
    public func seedSubscription(_ status: HeldSubscription) {
        state.withLock { Self.record(status, in: &$0) }
    }

    // MARK: - Things that happen by themselves

    /// A subscription's status changes by itself — renewed, cancelled, into a grace period
    /// or billing retry, lapsed — and the store says so on the updates stream. The listing
    /// follows at once: an entitled status is listed, anything else is not.
    public func changeSubscription(_ status: HeldSubscription) {
        announce(.subscriptionChanged(status)) { Self.record(status, in: &$0) }
    }

    /// The person switches auto-renew off — in Manage Subscriptions, or anywhere else. The
    /// subscription runs to the end of its period and then lapses. Announced, as the Mac
    /// was measured to announce it; the iOS simulator says nothing until the renewal.
    public func cancelAutoRenew(_ id: ProductID) {
        change(id) { $0.with(renewal: Renewal(willRenew: false, nextProduct: nil)) }
    }

    /// Auto-renew switched back on, before the period ended.
    public func resumeAutoRenew(_ id: ProductID) {
        change(id) { $0.with(renewal: Renewal(willRenew: true, nextProduct: $0.product)) }
    }

    /// The price is going up: awaiting consent, or only notified of.
    public func raisePrice(_ id: ProductID, needsConsent: Bool) {
        change(id) { status in
            let renewal = status.renewal ?? Renewal(willRenew: true, nextProduct: status.product)
            return status.with(renewal: Renewal(
                willRenew: renewal.willRenew, nextProduct: renewal.nextProduct, price: renewal.price,
                currencyCode: renewal.currencyCode, priceIncrease: needsConsent ? .awaitingConsent : .agreed,
                winBackOffers: renewal.winBackOffers, offer: renewal.offer))
        }
    }

    /// It lapses now, as `SKTestSession.expireSubscription` makes it: expired, auto-renew
    /// off, no longer listed.
    public func lapse(_ id: ProductID) {
        let now = clock.now
        let products = productsOnSale
        change(id) { status in
            HeldSubscription(
                product: status.product, group: status.group, ownership: status.ownership,
                state: .expired(.autoRenewDisabled), firstSubscribed: status.firstSubscribed,
                periodStarted: status.periodStarted, periodEnds: min(status.periodEnds, now), offer: status.offer,
                renewal: Renewal(willRenew: false, nextProduct: nil, winBackOffers: Self.winBackOffers(after: status, in: products)))
        }
    }

    /// A new period begins now, as `SKTestSession.forceRenewalOfSubscription` makes one — or
    /// as a failed charge finally goes through, which sets a new billing date. The renewal
    /// is announced, and listed late, as a purchase is.
    public func renewNow(_ id: ProductID) {
        let now = clock.now
        let period = behaviour.subscriptionPeriod.timeInterval
        let renewed = state.withLock { state -> OwnedProduct? in
            guard let index = state.subscriptions.firstIndex(where: { $0.status.product == id }) else { return nil }
            let status = state.subscriptions[index].status
            let next = HeldSubscription(
                product: status.product, group: status.group, ownership: status.ownership, state: .subscribed,
                firstSubscribed: status.firstSubscribed, periodStarted: now, periodEnds: now.addingTimeInterval(period),
                offer: status.renewal?.offer, renewal: Renewal(willRenew: true, nextProduct: status.product))
            Self.unlist(status, in: &state)
            state.subscriptions[index] = SubscriptionRecord(status: next, isSaid: true, renewal: nil)
            let product = Self.owned(next)
            Self.hold(product, in: &state)
            return product
        }
        if let renewed { announce(.granted(renewed)) { _ in } }
    }

    /// The failed charge goes through. The same as `renewNow`.
    public func recoverBilling(_ id: ProductID) {
        renewNow(id)
    }

    /// A subscription arriving from outside the app — started on another device, or shared
    /// by a family member — for a period from now: announced, listed late as a purchase is,
    /// and its status said once it is listed.
    public func deliverSubscription(_ id: ProductID, ownership: Ownership = .purchased) {
        guard let terms = catalogue.entry(for: id)?.subscriptionTerms else {
            preconditionFailure("\(id) is not a subscription in this catalogue")
        }
        let now = clock.now
        let status = HeldSubscription(
            product: id, group: terms.group, ownership: ownership, state: .subscribed, firstSubscribed: now,
            periodStarted: now, periodEnds: now.addingTimeInterval(behaviour.subscriptionPeriod.timeInterval),
            renewal: Renewal(willRenew: true, nextProduct: id))
        let product = Self.owned(status)
        announce(.granted(product)) { state in
            state.subscriptions.removeAll { $0.status.product == id && $0.status.ownership == ownership }
            state.subscriptions.append(SubscriptionRecord(status: status, isSaid: false, renewal: nil))
            Self.hold(product, in: &state)
            if state.listed.contains(product) { Self.say([product], in: &state) }
        }
    }

    /// A transaction arriving on its own — approved by a parent, made on another
    /// device — announced on the updates stream **and listed late**, like a purchase.
    ///
    /// Measured against the real store: when an approved Ask to Buy arrives, the
    /// listing at that instant is still empty, and has the product half a second
    /// later. The first version of this listed at once, and hid the bug that causes.
    ///
    /// It takes the place of the copy this device holds — one copy of a product, as
    /// the real listing has — **unless that is the account's own and this is not**. A
    /// family member sharing what the account bought for itself is announced, and the
    /// account's own stays listed. Replacing whatever was there threw the account's own
    /// away, and for a shared trial, or an unlock whose entry ignores Family Sharing,
    /// left someone who had paid owning nothing. The shared copy is not kept: should
    /// the account's own be refunded afterwards, nothing is left, where the real store
    /// might still list the family member's.
    public func deliver(_ product: OwnedProduct) {
        announce(.granted(product)) { state in
            state.pending.remove(product.id)
            if let held = Self.held(product.id, in: state), Self.outranks(held, product) { return }
            Self.hold(product, in: &state)
        }
    }

    /// The store says a product has been granted, and then **never lists it**. Reported
    /// of shared purchases withdrawn without a date. The listing is the last word, so
    /// whoever believed the announcement should stop believing it before long.
    public func announceWithoutListing(_ product: OwnedProduct) {
        announce(.granted(product)) { _ in }
    }

    public func deliver(_ id: ProductID, ownership: Ownership = .purchased) {
        deliver(OwnedProduct(id: id, originalPurchaseDate: clock.now, ownership: ownership))
    }

    /// As `seedTrial(_:remaining:)`, but announced — for a running app, which should
    /// react without being relaunched. This is "trial ends in five minutes" for a
    /// debug build on the real clock: deliver it, and watch the app lock itself.
    public func deliverTrial(_ id: ProductID, remaining: Duration) {
        guard let terms = catalogue.entry(for: id)?.trialTerms else {
            preconditionFailure("\(id) is not a trial in this catalogue")
        }
        deliver(OwnedProduct(id: id, originalPurchaseDate: date(ago: terms.duration - remaining)))
    }

    /// Someone approves an Ask to Buy purchase that was left pending.
    ///
    /// **The purchase `purchase()` would have made, arriving on its own**: for something
    /// the account already owns — on another device, before a reinstall — that is the
    /// original, original date and all, and not a new one dated today. An approved
    /// trial does not restart.
    ///
    /// Nothing is pending unless a purchase was left so, and approving nothing grants
    /// nothing: a test that approves the wrong product should find out.
    ///
    /// - Returns: whether there was anything to approve.
    @discardableResult
    public func approvePending(_ id: ProductID) -> Bool {
        let now = clock.now
        let (product, listeners) = state.withLock { state -> (OwnedProduct?, [AsyncStream<TransactionUpdate>.Continuation]) in
            guard state.pending.remove(id) != nil else { return (nil, []) }
            return (Self.buy(id, offer: nil, at: now, in: &state, catalogue: catalogue), Array(state.listeners.values))
        }
        guard let product else { return false }
        // Outside the lock, as in `announce(_:_:)`.
        for listener in listeners { listener.yield(.granted(product)) }
        return true
    }

    /// Someone declines it. **Nothing is announced**, because nothing is: measured
    /// against the real store, a declined Ask to Buy sends no transaction, and the app
    /// is left believing it pending until it is relaunched. What an app does about
    /// that is what this is for testing.
    ///
    /// - Returns: whether there was anything to decline.
    @discardableResult
    public func declinePending(_ id: ProductID) -> Bool {
        state.withLock { $0.pending.remove(id) != nil }
    }

    /// The listing catches up **without being read**. The lag here is counted in reads,
    /// which is what makes a test of it deterministic; the real one is a matter of
    /// time, and passes whether or not anybody looks. This is that: everything bought
    /// and not yet listed is listed now, and nothing is announced.
    public func listUnlisted() {
        state.withLock { state in
            let ready = state.unlisted.map(\.product)
            state.listed.append(contentsOf: ready)
            state.unlisted = []
            Self.say(ready, in: &state)
        }
    }

    /// The store takes a purchase back, as a refund does, and says so — whether or
    /// not it had got as far as listing it. Unlike a grant, this does not lag: the
    /// real listing was already empty at the instant the refund was announced.
    ///
    /// What is taken back is the copy this device holds, and the same purchase where
    /// the account holds it elsewhere; left behind, a restore brought a refunded
    /// purchase back and buying it again handed it over as owned. A copy elsewhere
    /// that reached the account another way is another purchase, and stays: a family
    /// member's sharing ending here takes nothing the account bought for itself. With
    /// nothing held here, the copy elsewhere is the one taken back. Anything pending
    /// stays pending: nothing had been bought, and approved later it is a new purchase.
    public func revoke(_ id: ProductID) {
        announce(.withdrawn(id)) { state in
            let held = Self.held(id, in: state)
            state.listed.removeAll { $0.id == id }
            state.unlisted.removeAll { $0.product.id == id }
            state.earlier.removeAll { $0.id == id && (held == nil || $0.ownership == held?.ownership) }
            for index in state.subscriptions.indices where state.subscriptions[index].status.product == id {
                state.subscriptions[index].status = state.subscriptions[index].status.with(state: .revoked)
                state.subscriptions[index].isSaid = true
            }
        }
    }

    /// Forget every purchase. Listeners stay subscribed; behaviour is kept.
    public func reset() {
        state.withLock { state in
            state.listed = []
            state.unlisted = []
            state.earlier = []
            state.pending = []
            state.unverified = []
            state.subscriptions = []
            state.usedIntroductoryOffer = []
            state.firstEligibility = [:]
            state.lastPurchaseOptions = nil
        }
    }

    // MARK: - StoreFront

    public func products() async throws(PurchaseError) -> [StoreProduct] {
        await catalogueGate.pass()
        let cancelled = Task.isCancelled
        let (script, products, silent) = state.withLock {
            ($0.behaviour.catalogue, $0.products, $0.behaviour.answersNothingWhenCancelled)
        }
        // As measured against the real store: a cancelled request is not refused, it
        // is answered — with nothing, which reads as a store that sells nothing.
        if cancelled, silent { return [] }
        switch script {
        case .loads: return products
        case let .loadsOnly(identifiers): return products.filter { identifiers.contains($0.id) }
        case let .fails(error): throw error
        }
    }

    public func ownedProducts() async -> [OwnedProduct] {
        await ownershipGate.pass()
        let cancelled = Task.isCancelled
        let now = clock.now
        let (answer, updates, listeners) = state.withLock { state in
            // Time passes whether or not anybody is told.
            let updates = Self.advanceSubscriptions(to: now, in: &state)
            let listeners = Array(state.listeners.values)
            // As measured against the real store: a cancelled task is told nothing,
            // which reads exactly like owning nothing.
            if cancelled, state.behaviour.answersNothingWhenCancelled { return ([OwnedProduct](), updates, listeners) }
            let answer = state.listed
            // Listed for the *next* read, not this one.
            for index in state.unlisted.indices { state.unlisted[index].readsUntilListed -= 1 }
            let ready = state.unlisted.filter { $0.readsUntilListed <= 0 }.map(\.product)
            state.unlisted.removeAll { $0.readsUntilListed <= 0 }
            state.listed.append(contentsOf: ready)
            Self.say(ready, in: &state)
            return (answer, updates, listeners)
        }
        // Outside the lock, as in `announce(_:_:)`.
        for update in updates { for listener in listeners { listener.yield(update) } }
        return answer
    }

    // MARK: - SubscriptionStatusReading

    /// Every status the store says for each group asked about. Held shut with what is
    /// owned; and a cancelled task is told nothing, which for a status read is an empty
    /// array — "never subscribed" — as measured against the real store.
    public func subscriptionStatuses(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: [HeldSubscription]] {
        await ownershipGate.pass()
        let cancelled = Task.isCancelled
        let now = clock.now
        let (answer, updates, listeners) = state.withLock { state in
            let updates = Self.advanceSubscriptions(to: now, in: &state)
            let silent = cancelled && state.behaviour.answersNothingWhenCancelled
            var answer: [SubscriptionGroupID: [HeldSubscription]] = [:]
            for group in groups {
                answer[group] = silent ? [] : state.subscriptions.filter { $0.isSaid && $0.status.group == group }.map(\.status)
            }
            // Said from the *next* read of the statuses, as a listing is from the next read.
            for index in state.subscriptions.indices where state.subscriptions[index].readsUntilSaid > 0 {
                state.subscriptions[index].readsUntilSaid -= 1
                if state.subscriptions[index].readsUntilSaid == 0 { state.subscriptions[index].isSaid = true }
            }
            return (answer, updates, Array(state.listeners.values))
        }
        for update in updates { for listener in listeners { listener.yield(update) } }
        return answer
    }

    public func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        guard catalogue.contains(id) else { throw .productUnavailable }
        await purchaseGate.pass()
        // Dated when it goes through, not when the sheet went up.
        let now = clock.now
        let catalogue = catalogue
        let result: Result<PurchaseOutcome, PurchaseError> = state.withLock { state in
            state.lastPurchaseOptions = options
            switch state.behaviour.purchases[id] ?? state.behaviour.purchase {
            case let .fails(error):
                return .failure(error)
            case .cancelled:
                return .success(.cancelled)
            case .pending:
                state.pending.insert(id)
                return .success(.pending)
            case .succeeds:
                if let refusal = Self.refusal(of: options, for: id, in: state, catalogue: catalogue) {
                    return .failure(.offerRefused(refusal))
                }
                return .success(.purchased(Self.buy(id, offer: options.offer, at: now, in: &state, catalogue: catalogue)))
            }
        }
        return try result.get()
    }

    // MARK: - IntroductoryEligibilityReading

    /// Whether the account has used the introductory offer in each group, **as StoreKit
    /// answers it: the first answer about a group is kept** (`keepsFirstEligibilityAnswer`),
    /// before and after the offer is used, as measured (spike/README.md).
    public func introductoryEligibility(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: Bool] {
        state.withLock { state in
            var answer: [SubscriptionGroupID: Bool] = [:]
            for group in groups {
                let now = !state.usedIntroductoryOffer.contains(group)
                if state.behaviour.keepsFirstEligibilityAnswer {
                    answer[group] = state.firstEligibility[group] ?? now
                    state.firstEligibility[group] = answer[group]
                } else {
                    answer[group] = now
                }
            }
            return answer
        }
    }

    public func restorePurchases() async throws(PurchaseError) -> RestoreOutcome {
        await restoreGate.pass()
        let result: Result<RestoreOutcome, PurchaseError> = state.withLock { state in
            switch state.behaviour.restore {
            case let .fails(error): return .failure(error)
            case .cancelled: return .success(.cancelled)
            case .succeeds: break
            }
            if state.behaviour.restoreListsEarlierPurchases {
                // What this device already holds stays, unless the account's own copy
                // is arriving in place of somebody else's.
                for product in state.earlier {
                    if let held = Self.held(product.id, in: state), !Self.outranks(product, held) { continue }
                    state.listed.removeAll { $0.id == product.id }
                    state.unlisted.removeAll { $0.product.id == product.id }
                    state.listed.append(product)
                }
                state.earlier = []
            }
            return .success(.completed)
        }
        return try result.get()
    }

    /// Any number of listeners, each **registered before this returns** — so an
    /// event announced on the very next line is not lost to a subscription still
    /// being set up somewhere else.
    public func transactionUpdates() -> AsyncStream<TransactionUpdate> {
        let (stream, continuation) = AsyncStream<TransactionUpdate>.makeStream()
        let token = state.withLock { state -> Int in
            state.nextListener += 1
            state.listeners[state.nextListener] = continuation
            return state.nextListener
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.listeners.removeValue(forKey: token) }
        }
        return stream
    }

    // MARK: - StoreDiagnosing

    public func diagnose() async -> StoreDiagnosis {
        let (script, products, listed, unverified) = state.withLock {
            ($0.behaviour.catalogue, $0.products, $0.listed, $0.unverified.count)
        }
        // What `products()` would hand back right now, without waiting at the gate.
        let received: Set<ProductID> = switch script {
        case .loads: Set(products.map(\.id))
        case let .loadsOnly(identifiers): Set(products.map(\.id)).intersection(identifiers)
        case .fails: []
        }
        var failure: PurchaseError?
        if case let .fails(error) = script { failure = error }
        return StoreDiagnosis(
            requested: catalogue.identifiers,
            received: received.intersection(catalogue.identifiers),
            catalogueFailure: failure,
            verifiedEntitlements: listed.filter { catalogue.contains($0.id) }.count,
            unverifiedEntitlements: unverified,
            foreignEntitlements: listed.filter { !catalogue.contains($0.id) }.count,
            environment: "Simulated")
    }

    // MARK: - Private

    /// Changes the state, then tells every listener — outside the lock, because a
    /// listener going away takes the same lock to unregister.
    private func announce(_ update: TransactionUpdate, _ change: (inout State) -> Void) {
        let listeners = state.withLock { state -> [AsyncStream<TransactionUpdate>.Continuation] in
            change(&state)
            return Array(state.listeners.values)
        }
        for listener in listeners { listener.yield(update) }
    }

    /// The transaction a purchase of `id` comes to, whether it goes through at once
    /// or is approved later: the one the account already has, original date and all,
    /// or failing that a new one dated `now` — listed late, as the real store lists it.
    ///
    /// Where this device holds only a family member's copy and the account's own is
    /// elsewhere, it is the account's own, which takes the shared one's place. Handed
    /// the shared one, the store would call buying something the account owns
    /// `.notCounted`.
    private static func buy(
        _ id: ProductID, offer: PurchaseOptions.Offer?, at now: Date, in state: inout State, catalogue: Catalogue
    ) -> OwnedProduct {
        if let terms = catalogue.entry(for: id)?.subscriptionTerms {
            return subscribe(id, terms, offer: offer, at: now, in: &state, catalogue: catalogue)
        }
        let held = Self.held(id, in: state)
        if let held, held.ownership == .purchased { return held }
        if let index = state.earlier.firstIndex(where: { $0.id == id }),
           held.map({ Self.outranks(state.earlier[index], $0) }) ?? true {
            let product = state.earlier.remove(at: index)
            Self.hold(product, in: &state)
            return product
        }
        if let held { return held }
        let product = OwnedProduct(id: id, originalPurchaseDate: now)
        Self.hold(product, in: &state)
        return product
    }

    /// A subscription bought, as the real store answers it (measured, spike/README.md): the
    /// plan already held comes back as it is; a plan at a **higher level** replaces the one
    /// held at once, keeping its first date; one at the same or a lower level — a downgrade,
    /// or a change of duration — waits for the renewal, and **the plan held is what comes
    /// back**, with its renewal now naming the new one. Anything else is a new subscription,
    /// listed late, its status said once it is listed.
    ///
    /// The offer goes as the real store takes it `[Apple]`: the introductory one with a
    /// plain purchase, if the product has one and the group's is unused, or with the
    /// override whether or not it is; a promotional one bought by a current subscriber at
    /// the next renewal; and one bought with the plan already held, not at all.
    private static func subscribe(
        _ id: ProductID, _ terms: SubscriptionTerms, offer asked: PurchaseOptions.Offer?, at now: Date,
        in state: inout State, catalogue: Catalogue
    ) -> OwnedProduct {
        let period = state.behaviour.subscriptionPeriod.timeInterval
        let level = { (product: ProductID) in catalogue.entry(for: product)?.subscriptionTerms?.level ?? .max }
        let current = state.subscriptions.first {
            $0.status.group == terms.group && $0.status.ownership == .purchased && $0.status.isEntitled
        }?.status
        if current == nil, state.behaviour.handsBackTheLapsedTransaction, let lapsed = state.subscriptions.first(where: {
            $0.status.product == id && $0.status.ownership == .purchased && !$0.status.isEntitled
        })?.status {
            return owned(lapsed)
        }
        let offer = applied(asked, to: id, in: terms.group, state)
        if let current, current.product == id || level(id) >= level(current.product) {
            // Nothing changes until the renewal, a promotional offer included; the plan
            // held is what comes back (measured).
            var renewal = current.renewal ?? Renewal(willRenew: true, nextProduct: current.product)
            var changed = false
            if current.product != id {
                renewal = Renewal(willRenew: true, nextProduct: id, offer: renewal.offer)
                changed = true
            }
            if case .promotional? = asked, let offer {
                renewal = renewal.with(offer: offer)
                changed = true
            }
            if changed { record(current.with(renewal: renewal), in: &state, listing: false) }
            return owned(current)
        }
        if offer?.kind == .introductory { state.usedIntroductoryOffer.insert(terms.group) }
        let status = HeldSubscription(
            product: id, group: terms.group, state: .subscribed, firstSubscribed: current?.firstSubscribed ?? now,
            periodStarted: now, periodEnds: now.addingTimeInterval(period), offer: offer,
            renewal: Renewal(willRenew: true, nextProduct: id))
        if let current {
            // An upgrade: the plan left behind is no longer listed, and its status gives way.
            state.listed.removeAll { $0.id == current.product }
            state.unlisted.removeAll { $0.product.id == current.product }
            state.subscriptions.removeAll { $0.status.product == current.product && $0.status.ownership == .purchased }
        }
        state.subscriptions.removeAll { $0.status.product == id && $0.status.ownership == .purchased }
        state.subscriptions.append(SubscriptionRecord(status: status, isSaid: false, renewal: nil))
        let product = owned(status)
        Self.hold(product, in: &state)
        if state.listed.contains(product) { say([product], in: &state) }
        return product
    }

    /// The transaction a status stands for.
    private static func owned(_ status: HeldSubscription) -> OwnedProduct {
        OwnedProduct(
            id: status.product, originalPurchaseDate: status.firstSubscribed, purchaseDate: status.periodStarted,
            ownership: status.ownership, expirationDate: status.periodEnds, offer: status.offer)
    }

    /// Why the store refuses the offer `options` asks for, if it does — before anything is
    /// bought, as StoreKit refuses it.
    private static func refusal(
        of options: PurchaseOptions, for id: ProductID, in state: State, catalogue: Catalogue
    ) -> PurchaseError.OfferRefusal? {
        guard let offer = options.offer else { return nil }
        guard let group = catalogue.entry(for: id)?.subscriptionTerms?.group,
            let terms = state.products.first(where: { $0.id == id })?.subscription
        else { return .unknownOffer }
        let own = state.subscriptions.map(\.status).filter { $0.group == group && $0.ownership == .purchased }
        switch offer {
        case let .winBack(offer):
            guard terms.winBackOffers.contains(where: { $0.id == offer }) else { return .unknownOffer }
            // Only while Apple says so: lapsed from this very plan `[Apple]`.
            let eligible = own.contains { $0.product == id && !$0.isEntitled && $0.renewal?.winBackOffers.contains(offer) == true }
            return eligible ? nil : .notEligible
        case let .promotional(offer):
            guard terms.promotionalOffers.contains(where: { $0.id == offer }) else { return .unknownOffer }
            guard options.signature != nil else { return .missingParameters }
            guard state.behaviour.acceptsOfferSignatures else { return .invalidSignature }
            // For current and former subscribers only `[Apple]`.
            return own.isEmpty ? .notEligible : nil
        case .introductoryOverride:
            guard options.signature != nil else { return .missingParameters }
            return state.behaviour.acceptsOfferSignatures ? nil : .invalidSignature
        }
    }

    /// The offer a subscription bought with `asked` carries, if the product has it.
    private static func applied(
        _ asked: PurchaseOptions.Offer?, to id: ProductID, in group: SubscriptionGroupID, _ state: State
    ) -> AppliedOffer? {
        guard let terms = state.products.first(where: { $0.id == id })?.subscription else { return nil }
        let found: OfferTerms?
        switch asked {
        case nil: found = state.usedIntroductoryOffer.contains(group) ? nil : terms.introductoryOffer
        case .introductoryOverride?: found = terms.introductoryOffer
        case let .winBack(offer)?: found = terms.winBackOffers.first { $0.id == offer }
        case let .promotional(offer)?: found = terms.promotionalOffers.first { $0.id == offer }
        }
        return found.map { AppliedOffer(kind: $0.kind, id: $0.id, paymentMode: $0.paymentMode) }
    }

    /// The win-back offers a lapse from `status` makes eligible: the product's own, as
    /// configured, and at once, as in Xcode's environment (measured). Only the account's
    /// own: access through Family Sharing does not count towards one `[Apple]`.
    static func winBackOffers(after status: HeldSubscription, in products: [StoreProduct]) -> [OfferID] {
        guard status.ownership == .purchased else { return [] }
        let offers = products.first { $0.id == status.product }?.subscription?.winBackOffers ?? []
        return offers.compactMap(\.id)
    }

    /// Keeps `status` in place of the one for the same product and ownership, said at once;
    /// and, unless told otherwise, lists it if it is entitled and unlists it if not.
    private static func record(_ status: HeldSubscription, in state: inout State, listing: Bool = true) {
        let same = { (other: HeldSubscription) in other.product == status.product && other.ownership == status.ownership }
        state.subscriptions.removeAll { same($0.status) }
        state.subscriptions.append(SubscriptionRecord(status: status, isSaid: true, renewal: nil))
        guard listing else { return }
        state.listed.removeAll { $0.id == status.product && $0.ownership == status.ownership }
        state.unlisted.removeAll { $0.product.id == status.product && $0.product.ownership == status.ownership }
        if status.isEntitled { state.listed.append(owned(status)) }
    }

    /// The statuses of what has just been listed are said from now on — and a renewal
    /// that has just been listed is the status from now on, the moment over.
    private static func say(_ products: [OwnedProduct], in state: inout State) {
        for product in products {
            for index in state.subscriptions.indices {
                if let renewal = state.subscriptions[index].renewal, renewal.product == product.id,
                   renewal.periodStarted == product.purchaseDate {
                    state.subscriptions[index].status = renewal
                    state.subscriptions[index].renewal = nil
                }
                guard state.subscriptions[index].status.product == product.id, !state.subscriptions[index].isSaid else { continue }
                let lag = state.behaviour.saysStatusAfterReads
                if lag > 0 {
                    state.subscriptions[index].readsUntilSaid = lag
                } else {
                    state.subscriptions[index].isSaid = true
                }
            }
        }
    }

    /// Changes a subscription's status and announces the change. Nothing if there is none.
    private func change(_ id: ProductID, _ transform: @escaping (HeldSubscription) -> HeldSubscription) {
        let changed = state.withLock { state -> HeldSubscription? in
            guard let index = state.subscriptions.firstIndex(where: { $0.status.product == id }) else { return nil }
            let status = transform(state.subscriptions[index].status)
            Self.record(status, in: &state)
            return status
        }
        if let changed { announce(.subscriptionChanged(changed)) { _ in } }
    }

    /// No longer listed, by product and ownership.
    private static func unlist(_ status: HeldSubscription, in state: inout State) {
        state.listed.removeAll { $0.id == status.product && $0.ownership == status.ownership }
        state.unlisted.removeAll { $0.product.id == status.product && $0.product.ownership == status.ownership }
    }

    /// **What the store's clock has done to every subscription since it was last read**:
    /// periods that have ended renewed, lapsed, or gone into billing trouble, as
    /// `behaviour` says; a grace period run out into billing retry; billing retry run out.
    /// Returns what the real store would announce, **renewals newest first**, as measured
    /// of those missed while nothing ran.
    private static func advanceSubscriptions(to now: Date, in state: inout State) -> [TransactionUpdate] {
        var updates: [TransactionUpdate] = []
        let behaviour = state.behaviour
        let period = behaviour.subscriptionPeriod.timeInterval
        let retry = behaviour.billingRetryPeriod.timeInterval
        for index in state.subscriptions.indices where state.subscriptions[index].renewal == nil {
            let status = state.subscriptions[index].status
            let ended = { (state: HeldSubscription.State, renewal: Renewal) in
                HeldSubscription(
                    product: status.product, group: status.group, ownership: status.ownership, state: state,
                    firstSubscribed: status.firstSubscribed, periodStarted: status.periodStarted,
                    periodEnds: status.periodEnds, offer: status.offer, renewal: renewal)
            }
            let lapsedRenewal = Renewal(
                willRenew: false, nextProduct: nil, winBackOffers: winBackOffers(after: status, in: state.products))
            let expiredForBilling = ended(.expired(.billingError), lapsedRenewal)
            switch status.state {
            case .subscribed where now >= status.periodEnds:
                if status.renewal?.willRenew == false {
                    let lapsed = ended(.expired(.autoRenewDisabled), lapsedRenewal)
                    unlist(status, in: &state)
                    state.subscriptions[index].status = lapsed
                    updates.append(.subscriptionChanged(lapsed))
                } else if behaviour.renewal == .fails {
                    let trouble: HeldSubscription
                    if let grace = behaviour.gracePeriod, now < status.periodEnds.addingTimeInterval(grace.timeInterval) {
                        trouble = ended(.inGracePeriod(until: status.periodEnds.addingTimeInterval(grace.timeInterval)), status.renewal ?? Renewal(willRenew: true, nextProduct: status.product))
                    } else if now < status.periodEnds.addingTimeInterval(retry) {
                        trouble = ended(.inBillingRetry, status.renewal ?? Renewal(willRenew: true, nextProduct: status.product))
                        unlist(status, in: &state)
                    } else {
                        trouble = expiredForBilling
                        unlist(status, in: &state)
                    }
                    state.subscriptions[index].status = trouble
                    updates.append(.subscriptionChanged(trouble))
                } else {
                    // Period by period up to now; a plan change waiting for the renewal takes
                    // effect with it.
                    var renewals: [HeldSubscription] = []
                    var current = status
                    while current.periodEnds <= now {
                        let next = current.renewal?.nextProduct ?? current.product
                        // An offer waiting for the renewal is what it renews at.
                        current = HeldSubscription(
                            product: next, group: current.group, ownership: current.ownership, state: .subscribed,
                            firstSubscribed: current.firstSubscribed, periodStarted: current.periodEnds,
                            periodEnds: current.periodEnds.addingTimeInterval(period), offer: current.renewal?.offer,
                            renewal: Renewal(willRenew: true, nextProduct: next))
                        renewals.append(current)
                    }
                    unlist(status, in: &state)
                    let lag = behaviour.showsTheRenewalMoment ? behaviour.listsPurchasesAfterReads + 1 : behaviour.listsPurchasesAfterReads
                    let latest = owned(current)
                    if lag <= 0 {
                        state.listed.append(latest)
                        state.subscriptions[index].status = current
                    } else {
                        state.unlisted.append(Unlisted(product: latest, readsUntilListed: lag))
                        if behaviour.showsTheRenewalMoment {
                            state.subscriptions[index].status = ended(.expired(.unstated), Renewal(willRenew: false, nextProduct: nil))
                            state.subscriptions[index].renewal = current
                        } else {
                            state.subscriptions[index].status = current
                        }
                    }
                    updates += renewals.reversed().map { .granted(owned($0)) }
                }
            case let .inGracePeriod(until) where now >= until:
                let next = now < status.periodEnds.addingTimeInterval(retry)
                    ? ended(.inBillingRetry, status.renewal ?? Renewal(willRenew: true, nextProduct: status.product))
                    : expiredForBilling
                unlist(status, in: &state)
                state.subscriptions[index].status = next
                updates.append(.subscriptionChanged(next))
            case .inBillingRetry where now >= status.periodEnds.addingTimeInterval(retry):
                state.subscriptions[index].status = expiredForBilling
                updates.append(.subscriptionChanged(expiredForBilling))
            default:
                break
            }
        }
        return updates
    }

    /// The copy of `id` this device holds, listed or not yet.
    private static func held(_ id: ProductID, in state: State) -> OwnedProduct? {
        state.listed.first { $0.id == id } ?? state.unlisted.first { $0.product.id == id }?.product
    }

    /// Whether `copy` stays when `other` arrives: the account's own copy is never put
    /// aside for anybody else's. `StandingResolver` prefers it the same way.
    private static func outranks(_ copy: OwnedProduct, _ other: OwnedProduct) -> Bool {
        copy.ownership == .purchased && other.ownership != .purchased
    }

    /// Holds `product` in place of any copy of it this device has, listed late, as the
    /// real store lists it.
    private static func hold(_ product: OwnedProduct, in state: inout State) {
        state.listed.removeAll { $0.id == product.id }
        state.unlisted.removeAll { $0.product.id == product.id }
        let lag = state.behaviour.listsPurchasesAfterReads
        if lag <= 0 {
            state.listed.append(product)
        } else {
            state.unlisted.append(Unlisted(product: product, readsUntilListed: lag))
        }
    }

    private func date(ago age: Duration) -> Date {
        clock.now.addingTimeInterval(-age.timeInterval)
    }

    /// Unlocks at 9.99, trials free, and subscriptions at 9.99 a period — a month, or the
    /// store's `subscriptionPeriod` as near as a billing period says it — with no offers.
    private static func plausibleProducts(for catalogue: Catalogue, behaviour: Behaviour) -> [StoreProduct] {
        catalogue.entries.map { entry in
            let name = entry.id.rawValue.split(separator: ".").last.map(String.init) ?? entry.id.rawValue
            let isTrial = entry.trialTerms != nil
            var shareable = false
            if case .unlock(.honoured) = entry.kind { shareable = true }
            if case let .subscription(terms) = entry.kind { shareable = terms.familySharing == .honoured }
            return StoreProduct(
                id: entry.id, displayName: name.capitalized, description: "",
                displayPrice: isTrial ? "Free" : "$9.99", price: isTrial ? 0 : Decimal(string: "9.99")!,
                isFamilyShareable: shareable,
                subscription: entry.subscriptionTerms.map { terms in
                    StoreProduct.Subscription(group: terms.group, period: billingPeriod(behaviour.subscriptionPeriod))
                })
        }
    }

    private static func billingPeriod(_ duration: Duration) -> BillingPeriod {
        let days = max(1, Int(duration.components.seconds / 86_400))
        if days % 365 == 0 { return .years(days / 365) }
        if days % 30 == 0 { return .months(days / 30) }
        if days % 7 == 0 { return .weeks(days / 7) }
        return .days(days)
    }
}

extension Renewal {
    func with(offer: AppliedOffer?) -> Renewal {
        Renewal(
            willRenew: willRenew, nextProduct: nextProduct, price: price, currencyCode: currencyCode,
            priceIncrease: priceIncrease, winBackOffers: winBackOffers, offer: offer)
    }
}

extension HeldSubscription {
    func with(state: State) -> HeldSubscription {
        HeldSubscription(
            product: product, group: group, ownership: ownership, state: state, firstSubscribed: firstSubscribed,
            periodStarted: periodStarted, periodEnds: periodEnds, offer: offer, renewal: renewal,
            transactionID: transactionID)
    }

    func with(renewal: Renewal?) -> HeldSubscription {
        HeldSubscription(
            product: product, group: group, ownership: ownership, state: state, firstSubscribed: firstSubscribed,
            periodStarted: periodStarted, periodEnds: periodEnds, offer: offer, renewal: renewal,
            transactionID: transactionID)
    }
}

#endif
