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
        /// Renewals still to come at the offer the status carries.
        var offerPeriodsLeft = 0
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
        /// Waiting for approval, with what the purchase asked for.
        var pending: [ProductID: PurchaseOptions] = [:]
        var unverified: Set<ProductID> = []
        var subscriptions: [SubscriptionRecord] = []
        /// Groups whose introductory offer the account has used, here or anywhere else.
        var usedIntroductoryOffer: Set<SubscriptionGroupID> = []
        /// The first answer given about each group, kept as StoreKit keeps it.
        var firstEligibility: [SubscriptionGroupID: Bool] = [:]
        var lastPurchaseOptions: PurchaseOptions?
        var nextListener = 0
        var listeners: [Int: AsyncStream<TransactionUpdate>.Continuation] = [:]
        /// Asked for outside the app while nobody listened: handed to the first who does.
        var unheardRequests: [RequestedPurchase] = []
        var nextTransactionID: UInt64 = 1_000
        /// Whether `products` were made up from the catalogue, and so follow the behaviour.
        var madeUpProducts: Bool

        /// A subscription transaction's identifier, new each time, as the real store's are.
        mutating func transactionID() -> UInt64 {
            nextTransactionID += 1
            return nextTransactionID
        }
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
                listed: owned, madeUpProducts: products == nil))
    }

    // MARK: - Arranging

    /// How the store misbehaves. Change it at any time.
    public var behaviour: Behaviour {
        get { state.withLock { $0.behaviour } }
        set {
            state.withLock { state in
                state.behaviour = newValue
                if state.madeUpProducts { state.products = Self.plausibleProducts(for: catalogue, behaviour: newValue) }
            }
        }
    }

    /// What the store holds at this instant: listed, bought and not yet listed, owned
    /// elsewhere, and pending approval. For a test to assert on; reading it does not
    /// count as a read of what is owned, and lists nothing sooner.
    public var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                listed: $0.listed, unlisted: $0.unlisted.map(\.product), earlier: $0.earlier,
                pending: Set($0.pending.keys), unverified: $0.unverified, subscriptions: $0.subscriptions.map(\.status))
        }
    }

    /// What the store sells, as `products()` answers: names, prices, and a subscription's
    /// period and offers. Change it to put an offer on sale, or take one off.
    public var productsOnSale: [StoreProduct] {
        get { state.withLock { $0.products } }
        set {
            state.withLock { state in
                state.products = newValue
                state.madeUpProducts = false
            }
        }
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
    ///
    /// **During a 12-month commitment the monthly billing goes on**: the renewal still says it
    /// will renew, and only the commitment's own renewal says it ends with the commitment
    /// `[Apple]`.
    public func cancelAutoRenew(_ id: ProductID) {
        change(id) { status in
            if status.renewal?.commitment != nil {
                status.renewal?.commitment?.willRenew = false
            } else {
                status.renewal = Self.renewal(of: status).with { $0.willRenew = false }
            }
        }
    }

    /// Auto-renew switched back on, before the period — or the commitment — ended.
    public func resumeAutoRenew(_ id: ProductID) {
        change(id) { status in
            status.renewal = Self.renewal(of: status).with { renewal in
                renewal.willRenew = true
                renewal.commitment?.willRenew = true
            }
        }
    }

    /// The price is going up: awaiting consent, or only notified of. Unagreed, the
    /// subscription lapses at the end of its period `[Apple]`.
    public func raisePrice(_ id: ProductID, needsConsent: Bool) {
        change(id) { status in
            status.renewal = Self.renewal(of: status).with { $0.priceIncrease = needsConsent ? .awaitingConsent : .agreed }
        }
    }

    /// It lapses now, as `SKTestSession.expireSubscription` makes it: expired, auto-renew
    /// off, no longer listed.
    public func lapse(_ id: ProductID) {
        let now = clock.now
        let products = productsOnSale
        change(id) { status in
            status.periodEnds = min(status.periodEnds, now)
            status = Self.lapsed(status, .autoRenewDisabled, products: products)
        }
    }

    /// A new period begins now, as `SKTestSession.forceRenewalOfSubscription` makes one — or
    /// as a failed charge finally goes through, which sets a new billing date. The renewal
    /// is announced, and listed late, as a purchase is.
    public func renewNow(_ id: ProductID) {
        let now = clock.now
        update { state -> ((), [TransactionUpdate]) in
            guard let index = Self.index(of: id, in: state) else { return ((), []) }
            let record = state.subscriptions[index]
            let current = record.renewal ?? record.status
            let (next, offerPeriodsLeft) = Self.renewed(current, startingAt: now, offerPeriodsLeft: record.offerPeriodsLeft, in: &state)
            Self.unlist(record.status, in: &state)
            state.subscriptions[index] = SubscriptionRecord(status: next, isSaid: true, offerPeriodsLeft: offerPeriodsLeft)
            let product = Self.owned(next)
            Self.hold(product, in: &state)
            return ((), [.granted(product)])
        }
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
        update { state -> ((), [TransactionUpdate]) in
            let status = HeldSubscription(
                product: id, group: terms.group, ownership: ownership, state: .subscribed, firstSubscribed: now,
                periodStarted: now, periodEnds: now.addingTimeInterval(state.behaviour.subscriptionPeriod.timeInterval),
                renewal: Renewal(willRenew: true, nextProduct: id), transactionID: state.transactionID())
            let product = Self.owned(status)
            state.subscriptions.removeAll { $0.status.product == id && $0.status.ownership == ownership }
            state.subscriptions.append(SubscriptionRecord(status: status, isSaid: false, renewal: nil))
            // The account's own copy is not put aside for a family member's, as with `deliver(_:)`.
            if let held = Self.held(id, in: state), Self.outranks(held, product) { return ((), [.granted(product)]) }
            Self.hold(product, in: &state)
            if state.listed.contains(product) { Self.say([product], in: &state) }
            return ((), [.granted(product)])
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
        // A non-renewing subscription's purchases are each time bought, and all stay.
        let alongside = catalogue.entry(for: product.id)?.nonRenewingTerms != nil
        announce(.granted(product)) { state in
            state.pending[product.id] = nil
            if !alongside, let held = Self.held(product.id, in: state), Self.outranks(held, product) { return }
            Self.hold(product, in: &state, alongside: alongside)
        }
    }

    /// The person asks, outside the app, to buy `id` — a promoted purchase tapped on the App
    /// Store, or a win-back offer taken there with streamlined purchasing off. Announced as a
    /// request; nothing is bought until the app buys it. Asked while nothing listens — the
    /// app launched by the request — it waits for the first listener `[Apple]`.
    public func requestPurchase(_ id: ProductID, offer: PurchaseOptions.Offer? = nil) {
        precondition(catalogue.contains(id), "\(id) is not in this catalogue")
        let request = RequestedPurchase(product: id, offer: offer)
        update { state -> ((), [TransactionUpdate]) in
            if state.listeners.isEmpty { state.unheardRequests.append(request) }
            return ((), [.purchaseRequested(request)])
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
        let catalogue = catalogue
        return update { state -> (Bool, [TransactionUpdate]) in
            guard let options = state.pending.removeValue(forKey: id) else { return (false, []) }
            let product = Self.buy(id, offer: options.offer, plan: options.billingPlan, at: now, in: &state, catalogue: catalogue)
            return (true, [.granted(product)])
        }
    }

    /// Someone declines it. **Nothing is announced**, because nothing is: measured
    /// against the real store, a declined Ask to Buy sends no transaction, and the app
    /// is left believing it pending until it is relaunched. What an app does about
    /// that is what this is for testing.
    ///
    /// - Returns: whether there was anything to decline.
    @discardableResult
    public func declinePending(_ id: ProductID) -> Bool {
        state.withLock { $0.pending.removeValue(forKey: id) != nil }
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
    ///
    /// A non-renewing subscription's **latest purchase** is the one taken back, and any
    /// others stay: measured, refunding one of two leaves the other listed (spike/README.md,
    /// n03).
    public func revoke(_ id: ProductID) {
        let catalogue = catalogue
        announce(.withdrawn(id)) { state in
            if catalogue.entry(for: id)?.nonRenewingTerms != nil {
                let purchases = state.listed.filter { $0.id == id } + state.unlisted.map(\.product).filter { $0.id == id }
                guard let latest = purchases.max(by: { $0.purchaseDate < $1.purchaseDate }) else { return }
                if let index = state.listed.firstIndex(of: latest) {
                    state.listed.remove(at: index)
                } else if let index = state.unlisted.firstIndex(where: { $0.product == latest }) {
                    state.unlisted.remove(at: index)
                }
                return
            }
            if let index = Self.index(of: id, in: state) {
                // The subscription this device holds; one that reached the account another way stays.
                let ownership = state.subscriptions[index].status.ownership
                for index in state.subscriptions.indices
                where state.subscriptions[index].status.product == id && state.subscriptions[index].status.ownership == ownership {
                    state.subscriptions[index].status.state = .revoked
                    state.subscriptions[index].renewal = nil
                    state.subscriptions[index].isSaid = true
                }
                state.listed.removeAll { $0.id == id && $0.ownership == ownership }
                state.unlisted.removeAll { $0.product.id == id && $0.product.ownership == ownership }
                return
            }
            let held = Self.held(id, in: state)
            state.listed.removeAll { $0.id == id }
            state.unlisted.removeAll { $0.product.id == id }
            state.earlier.removeAll { $0.id == id && (held == nil || $0.ownership == held?.ownership) }
        }
    }

    /// Forget every purchase. Listeners stay subscribed; behaviour is kept.
    public func reset() {
        state.withLock { state in
            state.listed = []
            state.unlisted = []
            state.earlier = []
            state.pending = [:]
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
        let result: Result<PurchaseOutcome, PurchaseError> = update { state in
            state.lastPurchaseOptions = options
            let script = state.behaviour.purchases[id] ?? state.behaviour.purchase
            switch script {
            case let .fails(error):
                return (.failure(error), [])
            case .cancelled:
                return (.success(.cancelled), [])
            case .pending, .succeeds:
                // Refused before anything is bought, or anybody is asked.
                if let refusal = Self.refusal(of: options, for: id, in: state, catalogue: catalogue) {
                    return (.failure(.offerRefused(refusal)), [])
                }
                if let plan = options.billingPlan, plan != .upFront,
                    state.products.first(where: { $0.id == id })?.subscription?.billingPlans.contains(where: { $0.plan == plan }) != true
                {
                    return (.failure(.unsupported), [])
                }
                guard script == .succeeds else {
                    state.pending[id] = options
                    return (.success(.pending), [])
                }
                return (.success(.purchased(
                    Self.buy(id, offer: options.offer, plan: options.billingPlan, at: now, in: &state, catalogue: catalogue))), [])
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
            for request in state.unheardRequests { continuation.yield(.purchaseRequested(request)) }
            state.unheardRequests = []
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
    private func announce(_ announced: TransactionUpdate, _ change: (inout State) -> Void) {
        update { state -> ((), [TransactionUpdate]) in
            change(&state)
            return ((), [announced])
        }
    }

    /// Changes the state as it is now — what the clock has done to every subscription
    /// first — and tells every listener what happened, outside the lock.
    private func update<Result>(_ change: (inout State) -> (Result, [TransactionUpdate])) -> Result {
        let now = clock.now
        let (result, updates, listeners) = state.withLock { state in
            var updates = Self.advanceSubscriptions(to: now, in: &state)
            let (result, more) = change(&state)
            updates += more
            return (result, updates, Array(state.listeners.values))
        }
        for update in updates { for listener in listeners { listener.yield(update) } }
        return result
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
        _ id: ProductID, offer: PurchaseOptions.Offer?, plan: BillingPlan? = nil, at now: Date, in state: inout State,
        catalogue: Catalogue
    ) -> OwnedProduct {
        if let terms = catalogue.entry(for: id)?.subscriptionTerms {
            return subscribe(id, terms, offer: offer, plan: plan, at: now, in: &state, catalogue: catalogue)
        }
        if catalogue.entry(for: id)?.nonRenewingTerms != nil {
            // Time bought, every time: a new transaction, listed late beside the others, as
            // measured (spike/README.md, n02) — and never at the same instant as another.
            let dates = Set((state.listed + state.unlisted.map(\.product)).filter { $0.id == id }.map(\.purchaseDate))
            var date = now
            while dates.contains(date) { date = date.addingTimeInterval(0.001) }
            let product = OwnedProduct(id: id, originalPurchaseDate: date)
            Self.hold(product, in: &state, alongside: true)
            return product
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
        _ id: ProductID, _ terms: SubscriptionTerms, offer asked: PurchaseOptions.Offer?, plan: BillingPlan? = nil,
        at now: Date, in state: inout State, catalogue: Catalogue
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
        let offer = applied(asked, to: id, in: terms.group, plan: plan, state)
        if let current, current.product == id || level(id) >= level(current.product) {
            // Nothing changes until the renewal, a promotional offer included; the plan
            // held is what comes back (measured).
            var renewal = current.renewal ?? Renewal(willRenew: true, nextProduct: current.product)
            if current.product != id {
                renewal.willRenew = true
                renewal.nextProduct = id
            }
            if case .promotional? = asked, let offer { renewal.offer = offer }
            if renewal != current.renewal {
                var changed = current
                changed.renewal = renewal
                record(changed, in: &state, listing: false)
            }
            return owned(current)
        }
        if offer?.kind == .introductory { state.usedIntroductoryOffer.insert(terms.group) }
        // On the monthly plan, a commitment of twelve periods of `subscriptionPeriod` each.
        let commitment = plan == .monthly ? commitment(for: id, month: 1, startingAt: now, in: state) : nil
        // The group's subscription is one subscription, lapsed and resubscribed or not `[Apple]`.
        let first = state.subscriptions.filter { $0.status.group == terms.group && $0.status.ownership == .purchased }
            .map(\.status.firstSubscribed).min()
        let status = HeldSubscription(
            product: id, group: terms.group, state: .subscribed, firstSubscribed: first ?? now,
            periodStarted: now, periodEnds: now.addingTimeInterval(period), offer: offer,
            renewal: Renewal(willRenew: true, nextProduct: id, commitment: commitment.map { renewal(of: $0, product: id) }),
            transactionID: state.transactionID(), commitment: commitment)
        if let current {
            // An upgrade: the plan left behind is no longer listed, and its status gives way.
            state.listed.removeAll { $0.id == current.product }
            state.unlisted.removeAll { $0.product.id == current.product }
            state.subscriptions.removeAll { $0.status.product == current.product && $0.status.ownership == .purchased }
        }
        state.subscriptions.removeAll { $0.status.product == id && $0.status.ownership == .purchased }
        state.subscriptions.append(
            SubscriptionRecord(status: status, isSaid: false, renewal: nil, offerPeriodsLeft: periods(of: offer, for: id, in: state) - 1))
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

    /// Every offer `id` has: the product's own, and its billing plans'.
    private static func offers(of id: ProductID, in state: State) -> [OfferTerms] {
        guard let terms = state.products.first(where: { $0.id == id })?.subscription else { return [] }
        return [terms.introductoryOffer].compactMap(\.self) + terms.promotionalOffers + terms.winBackOffers
            + terms.billingPlans.flatMap(\.offers)
    }

    /// How many periods `offer` runs for: every one of them, paid as you go; otherwise one.
    private static func periods(of offer: AppliedOffer?, for id: ProductID, in state: State) -> Int {
        guard let offer, offer.paymentMode == .payAsYouGo else { return 1 }
        let terms = offers(of: id, in: state).first { $0.kind == offer.kind && $0.id == offer.id }
        return max(terms?.periodCount ?? 1, 1)
    }

    /// Why the store refuses the offer `options` asks for, if it does — before anything is
    /// bought, as StoreKit refuses it.
    private static func refusal(
        of options: PurchaseOptions, for id: ProductID, in state: State, catalogue: Catalogue
    ) -> PurchaseError.OfferRefusal? {
        guard let offer = options.offer else { return nil }
        guard let group = catalogue.entry(for: id)?.subscriptionTerms?.group,
            state.products.first(where: { $0.id == id })?.subscription != nil
        else { return .unknownOffer }
        let offers = Self.offers(on: options.billingPlan, of: id, in: state)
        let own = state.subscriptions.map(\.status).filter { $0.group == group && $0.ownership == .purchased }
        switch offer {
        case let .winBack(offer):
            guard offers.contains(where: { $0.kind == .winBack && $0.id == offer }) else { return .unknownOffer }
            // Only while Apple says so: lapsed from this very plan `[Apple]`.
            let eligible = own.contains { $0.product == id && !$0.isEntitled && $0.renewal?.winBackOffers.contains(offer) == true }
            return eligible ? nil : .notEligible
        case let .promotional(offer):
            guard offers.contains(where: { $0.kind == .promotional && $0.id == offer }) else { return .unknownOffer }
            guard options.signature != nil else { return .missingParameters }
            guard state.behaviour.acceptsOfferSignatures else { return .invalidSignature }
            // For current and former subscribers only `[Apple]`.
            return own.isEmpty ? .notEligible : nil
        case .introductoryOverride:
            guard options.signature != nil else { return .missingParameters }
            return state.behaviour.acceptsOfferSignatures ? nil : .invalidSignature
        }
    }

    /// The offer a subscription bought with `asked` carries, if the product — or the billing
    /// plan bought on — has it.
    private static func applied(
        _ asked: PurchaseOptions.Offer?, to id: ProductID, in group: SubscriptionGroupID, plan: BillingPlan?, _ state: State
    ) -> AppliedOffer? {
        let offers = offers(on: plan, of: id, in: state)
        let introductory = offers.first { $0.kind == .introductory }
        let found: OfferTerms?
        switch asked {
        case nil: found = state.usedIntroductoryOffer.contains(group) ? nil : introductory
        case .introductoryOverride?: found = introductory
        case let .winBack(offer)?: found = offers.first { $0.kind == .winBack && $0.id == offer }
        case let .promotional(offer)?: found = offers.first { $0.kind == .promotional && $0.id == offer }
        }
        return found.map { AppliedOffer(kind: $0.kind, id: $0.id, paymentMode: $0.paymentMode) }
    }

    /// The offers a purchase on `plan` can have: the billing plan's own first, then the
    /// product's.
    private static func offers(on plan: BillingPlan?, of id: ProductID, in state: State) -> [OfferTerms] {
        guard let terms = state.products.first(where: { $0.id == id })?.subscription else { return [] }
        let planned = terms.billingPlans.first { $0.plan == plan }?.offers ?? []
        return planned + [terms.introductoryOffer].compactMap(\.self) + terms.promotionalOffers + terms.winBackOffers
    }

    /// A commitment of twelve `subscriptionPeriod`s on the monthly plan, at the price the
    /// product's plan states.
    private static func commitment(for id: ProductID, month: Int, startingAt start: Date, in state: State) -> SubscriptionCommitment {
        let period = state.behaviour.subscriptionPeriod.timeInterval
        let price = state.products.first { $0.id == id }?.subscription?.billingPlans.first { $0.plan == .monthly }?.commitmentPrice
        return SubscriptionCommitment(
            plan: .monthly, billingPeriod: month, billingPeriods: 12,
            endsAt: start.addingTimeInterval(period * TimeInterval(12 - month + 1)), price: price ?? 0)
    }

    private static func renewal(of commitment: SubscriptionCommitment, product: ProductID) -> CommitmentRenewal {
        CommitmentRenewal(willRenew: true, nextProduct: product, plan: commitment.plan, renewsAt: commitment.endsAt, price: commitment.price)
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
        let offerPeriodsLeft = state.subscriptions.first { same($0.status) && $0.status.offer == status.offer }?.offerPeriodsLeft ?? 0
        state.subscriptions.removeAll { same($0.status) }
        state.subscriptions.append(SubscriptionRecord(status: status, isSaid: true, renewal: nil, offerPeriodsLeft: offerPeriodsLeft))
        if listing { relist(status, in: &state) }
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

    /// Changes a subscription's status as it is now, and announces the change. Nothing for one
    /// that is over: there is nothing left to change.
    private func change(_ id: ProductID, _ transform: @escaping (inout HeldSubscription) -> Void) {
        update { state -> ((), [TransactionUpdate]) in
            guard let index = Self.index(of: id, in: state) else { return ((), []) }
            // A renewal made at the moment and not yet listed is the subscription now.
            Self.finishRenewal(at: index, in: &state)
            var status = state.subscriptions[index].status
            switch status.state {
            case .subscribed, .inGracePeriod, .inBillingRetry: break
            case .expired, .revoked, .unrecognised: return ((), [])
            }
            transform(&status)
            state.subscriptions[index].status = status
            Self.relist(status, in: &state)
            return ((), [.subscriptionChanged(status)])
        }
    }

    /// The record of `id` a control acts on: the account's own, and the one that is entitled,
    /// before a family member's or a lapsed one.
    private static func index(of id: ProductID, in state: State) -> Int? {
        let rank = { (status: HeldSubscription) in (status.ownership == .purchased ? 2 : 0) + (status.isEntitled ? 1 : 0) }
        return state.subscriptions.indices.filter { state.subscriptions[$0].status.product == id }
            .max { rank(state.subscriptions[$0].status) < rank(state.subscriptions[$1].status) }
    }

    /// The renewal waiting at the moment becomes the status, listed.
    private static func finishRenewal(at index: Int, in state: inout State) {
        guard let renewal = state.subscriptions[index].renewal else { return }
        state.subscriptions[index].status = renewal
        state.subscriptions[index].renewal = nil
        state.subscriptions[index].isSaid = true
        relist(renewal, in: &state)
    }

    /// Listed if it is entitled, and not if it is not.
    private static func relist(_ status: HeldSubscription, in state: inout State) {
        unlist(status, in: &state)
        if status.isEntitled { state.listed.append(owned(status)) }
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
        for index in state.subscriptions.indices where state.subscriptions[index].renewal == nil {
            let status = state.subscriptions[index].status
            let retry = retryPeriod(of: status, state.behaviour)
            switch status.state {
            case .subscribed where now >= status.periodEnds:
                updates += renewOrLapse(at: index, until: now, in: &state)
            case let .inGracePeriod(until) where now >= until:
                let next =
                    now < status.periodEnds.addingTimeInterval(retry)
                    ? status.with { $0.state = .inBillingRetry }
                    : lapsed(status, .billingError, products: state.products)
                unlist(status, in: &state)
                state.subscriptions[index].status = next
                updates.append(.subscriptionChanged(next))
            case .inBillingRetry where now >= status.periodEnds.addingTimeInterval(retry):
                let next = lapsed(status, .billingError, products: state.products)
                state.subscriptions[index].status = next
                updates.append(.subscriptionChanged(next))
            default:
                break
            }
        }
        return updates
    }

    /// Period by period up to `now`: each that ends renews — a plan change waiting for the
    /// renewal taking effect with it — until one that is not to renew lapses, or a charge fails.
    private static func renewOrLapse(at index: Int, until now: Date, in state: inout State) -> [TransactionUpdate] {
        let behaviour = state.behaviour
        let status = state.subscriptions[index].status
        var current = status
        var offerPeriodsLeft = state.subscriptions[index].offerPeriodsLeft
        var renewals: [HeldSubscription] = []
        var ended: HeldSubscription?
        while current.periodEnds <= now {
            if let reason = lapse(of: current) {
                ended = lapsed(current, reason, products: state.products)
                break
            }
            if behaviour.renewal == .fails {
                let retry = retryPeriod(of: current, behaviour)
                if current.commitment == nil, let grace = behaviour.gracePeriod,
                    now < current.periodEnds.addingTimeInterval(grace.timeInterval)
                {
                    ended = current.with { $0.state = .inGracePeriod(until: current.periodEnds.addingTimeInterval(grace.timeInterval)) }
                } else if now < current.periodEnds.addingTimeInterval(retry) {
                    ended = current.with { $0.state = .inBillingRetry }
                } else {
                    ended = lapsed(current, .billingError, products: state.products)
                }
                break
            }
            (current, offerPeriodsLeft) = renewed(current, startingAt: current.periodEnds, offerPeriodsLeft: offerPeriodsLeft, in: &state)
            renewals.append(current)
        }
        state.subscriptions[index].offerPeriodsLeft = offerPeriodsLeft
        let updates = renewals.reversed().map { TransactionUpdate.granted(owned($0)) }
        if let ended {
            unlist(status, in: &state)
            if ended.isEntitled { state.listed.append(owned(ended)) }
            state.subscriptions[index].status = ended
            return updates + [.subscriptionChanged(ended)]
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
                state.subscriptions[index].status = status.with {
                    $0.state = .expired(.unstated)
                    $0.renewal = Renewal(willRenew: false, nextProduct: nil)
                }
                state.subscriptions[index].renewal = current
            } else {
                state.subscriptions[index].status = current
            }
        }
        return updates
    }

    /// Why a subscription whose period has ended does not renew, if it does not.
    private static func lapse(of status: HeldSubscription) -> HeldSubscription.Lapse? {
        if status.renewal?.willRenew == false { return .autoRenewDisabled }
        if let commitment = status.commitment, commitment.billingPeriod >= commitment.billingPeriods,
            status.renewal?.commitment?.willRenew == false
        {
            return .autoRenewDisabled
        }
        if status.renewal?.priceIncrease == .awaitingConsent { return .didNotConsentToPriceIncrease }
        return nil
    }

    /// Over, for `reason`: auto-renew off, and the win-back offers a lapse makes eligible.
    private static func lapsed(_ status: HeldSubscription, _ reason: HeldSubscription.Lapse, products: [StoreProduct]) -> HeldSubscription {
        status.with {
            $0.state = .expired(reason)
            $0.renewal = Renewal(willRenew: false, nextProduct: nil, winBackOffers: winBackOffers(after: status, in: products))
        }
    }

    /// How long Apple retries a failed charge: 90 days on a commitment `[Apple]`, otherwise
    /// the behaviour's.
    private static func retryPeriod(of status: HeldSubscription, _ behaviour: Behaviour) -> TimeInterval {
        status.commitment == nil ? behaviour.billingRetryPeriod.timeInterval : 90 * 86_400
    }

    /// The period after `current`, from `start`: a new transaction for the plan it was to
    /// renew as; a commitment a month on, or a new one after the last; an offer waiting for
    /// the renewal, or one paid as you go with periods still to run.
    private static func renewed(
        _ current: HeldSubscription, startingAt start: Date, offerPeriodsLeft: Int, in state: inout State
    ) -> (HeldSubscription, offerPeriodsLeft: Int) {
        let product = current.renewal?.nextProduct ?? current.product
        var next = current
        next.product = product
        next.state = .subscribed
        next.periodStarted = start
        next.periodEnds = start.addingTimeInterval(state.behaviour.subscriptionPeriod.timeInterval)
        next.transactionID = state.transactionID()
        var left = 0
        if let waiting = current.renewal?.offer {
            next.offer = waiting
            left = periods(of: waiting, for: product, in: state) - 1
        } else if offerPeriodsLeft > 0, product == current.product {
            left = offerPeriodsLeft - 1
        } else {
            next.offer = nil
        }
        next.commitment = current.commitment.map { held in
            guard held.billingPeriod < held.billingPeriods else { return commitment(for: product, month: 1, startingAt: start, in: state) }
            return held.with { $0.billingPeriod += 1 }
        }
        var renewal = Self.renewal(of: current)
        renewal.nextProduct = product
        renewal.offer = nil
        renewal.priceIncrease = .none
        renewal.winBackOffers = []
        renewal.commitment = next.commitment.map { commitment in
            let willRenew = commitment.billingPeriod == 1 ? true : current.renewal?.commitment?.willRenew ?? true
            return Self.renewal(of: commitment, product: product).with { $0.willRenew = willRenew }
        }
        next.renewal = renewal
        return (next, left)
    }

    /// What `status` says of its renewal, or that it renews as itself if it says nothing.
    private static func renewal(of status: HeldSubscription) -> Renewal {
        status.renewal ?? Renewal(willRenew: true, nextProduct: status.product)
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
    /// - Parameter alongside: keep every other purchase of the product listed, as the real
    ///   store keeps a non-renewing subscription's.
    private static func hold(_ product: OwnedProduct, in state: inout State, alongside: Bool = false) {
        let same = { (other: OwnedProduct) in other.id == product.id && (!alongside || other == product) }
        state.listed.removeAll(where: same)
        state.unlisted.removeAll { same($0.product) }
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

/// A copy, changed.
protocol Changeable {}

extension Changeable {
    func with(_ change: (inout Self) -> Void) -> Self {
        var copy = self
        change(&copy)
        return copy
    }
}

extension HeldSubscription: Changeable {}
extension Renewal: Changeable {}
extension SubscriptionCommitment: Changeable {}
extension CommitmentRenewal: Changeable {}

#endif
