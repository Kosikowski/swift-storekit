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
public final class SimulatedStoreFront: StoreFront, StoreDiagnosing {
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

    private let clock: any TimeProviding
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
            State(behaviour: behaviour, products: products ?? Self.plausibleProducts(for: catalogue), listed: owned))
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
                pending: $0.pending, unverified: $0.unverified)
        }
    }

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

    // MARK: - Things that happen by themselves

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
            return (Self.buy(id, at: now, in: &state), Array(state.listeners.values))
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
            state.listed.append(contentsOf: state.unlisted.map(\.product))
            state.unlisted = []
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
        return state.withLock { state in
            // As measured against the real store: a cancelled task is told nothing,
            // which reads exactly like owning nothing.
            if cancelled, state.behaviour.answersNothingWhenCancelled { return [] }
            let answer = state.listed
            // Listed for the *next* read, not this one.
            for index in state.unlisted.indices { state.unlisted[index].readsUntilListed -= 1 }
            let ready = state.unlisted.filter { $0.readsUntilListed <= 0 }.map(\.product)
            state.unlisted.removeAll { $0.readsUntilListed <= 0 }
            state.listed.append(contentsOf: ready)
            return answer
        }
    }

    public func purchase(
        _ id: ProductID, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome {
        guard catalogue.contains(id) else { throw .productUnavailable }
        await purchaseGate.pass()
        // Dated when it goes through, not when the sheet went up.
        let now = clock.now
        let result: Result<PurchaseOutcome, PurchaseError> = state.withLock { state in
            switch state.behaviour.purchases[id] ?? state.behaviour.purchase {
            case let .fails(error):
                return .failure(error)
            case .cancelled:
                return .success(.cancelled)
            case .pending:
                state.pending.insert(id)
                return .success(.pending)
            case .succeeds:
                return .success(.purchased(Self.buy(id, at: now, in: &state)))
            }
        }
        return try result.get()
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
    private static func buy(_ id: ProductID, at now: Date, in state: inout State) -> OwnedProduct {
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

    private static func plausibleProducts(for catalogue: Catalogue) -> [StoreProduct] {
        catalogue.entries.map { entry in
            let name = entry.id.rawValue.split(separator: ".").last.map(String.init) ?? entry.id.rawValue
            let isTrial = entry.trialTerms != nil
            var shareable = false
            if case .unlock(.honoured) = entry.kind { shareable = true }
            return StoreProduct(
                id: entry.id, displayName: name.capitalized, description: "",
                displayPrice: isTrial ? "Free" : "$9.99", price: isTrial ? 0 : Decimal(string: "9.99")!,
                isFamilyShareable: shareable)
        }
    }
}

#endif
