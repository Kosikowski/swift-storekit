// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too: under `swift build --build-tests -c release`, or a test
// plan in a Release configuration, it would not compile. `make check` builds the tests
// for release to keep this true.
#if DEBUG

import Foundation
import Observation
import PurchaseCore
import PurchaseDirectDistribution
import PurchaseTestKit
import Synchronization
import Testing

/// Everything here runs against the simulated store and a clock that moves only when
/// told to, so nothing waits and nothing touches StoreKit.
@MainActor
@Suite("Purchase store", .timeLimit(.minutes(1)))
struct PurchaseStoreTests {
    let clock = ManualClock(now: Shop.epoch)
    let front: SimulatedStoreFront
    let logger = RecordingPurchaseLogger()
    let store: PurchaseStore

    init() {
        front = SimulatedStoreFront(catalogue: Shop.catalogue, clock: clock)
        store = PurchaseStore(catalogue: Shop.catalogue, front: front, clock: clock, logger: logger)
    }

    // MARK: - The first answer

    @Test("building a store reaches for nothing: no listener, no read, until it is started")
    func constructionTouchesNothing() {
        #expect(front.listenerCount == 0)
        #expect(!store.standing.isKnown)
        #expect(store.standing.access(to: Shop.pro) == .unknown)
        #expect(store.productLoad == .notLoaded)
    }

    @Test("an owner is known as one once the store has answered")
    func ownerAtLaunch() async {
        front.seed(Shop.pro)
        await store.start()
        #expect(store.standing.isKnown)
        #expect(store.standing.ownership(of: Shop.pro) != nil)
        #expect(front.listenerCount == 1)
    }

    @Test("starting twice listens once")
    func startIsIdempotent() async {
        await store.start()
        await store.start()
        #expect(front.listenerCount == 1)
    }

    /// The paywall-at-every-launch bug: judging by the standing before it is known.
    @Test("knownStanding WAITS for the answer, and starts the store if nobody has")
    func knownStandingWaits() async {
        front.seed(Shop.pro)
        front.ownershipGate.close()
        let asked = Task { await store.knownStanding() }
        await waitUntil { front.ownershipGate.waiterCount == 1 }
        #expect(!store.standing.isKnown)
        front.ownershipGate.open()
        let standing = await asked.value
        #expect(standing.ownership(of: Shop.pro) != nil)
    }

    /// Measured against the real store: a cancelled task reads 0 of 1 entitlements.
    /// SwiftUI cancels `.task` when a view goes away. Were the read made in the
    /// caller's task, this owner would be told they own nothing.
    @Test("a caller CANCELLED mid-read still gets the whole answer, and so does everyone else")
    func cancelledCaller() async {
        front.seed(Shop.pro)
        front.ownershipGate.close()
        let asked = Task { await store.knownStanding() }
        await waitUntil { front.ownershipGate.waiterCount == 1 }
        asked.cancel()
        front.ownershipGate.open()
        let standing = await asked.value
        #expect(standing.ownership(of: Shop.pro) != nil)
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    @Test("many callers at once share one read rather than queueing one each")
    func singleFlight() async {
        front.ownershipGate.close()
        let callers = (0 ..< 5).map { _ in Task { await store.knownStanding() } }
        await waitUntil { front.ownershipGate.waiterCount == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(front.ownershipGate.waiterCount == 1)
        front.ownershipGate.open()
        for caller in callers { #expect(await caller.value.isKnown) }
    }

    /// A caller arriving while a pass is under way is promised a pass that *started
    /// after it asked*. Without the re-run it is handed the pass already in flight,
    /// whose read may be older than the thing it came to report.
    @Test("a caller arriving MID-PASS gets a second read, started after it asked")
    func rerunsForALateCaller() async {
        await store.start()
        let resolved = { self.logger.events.filter { if case .standingResolved = $0 { true } else { false } }.count }
        #expect(resolved() == 1)

        front.ownershipGate.close()
        let first = Task { await store.refresh() }
        await waitUntil { front.ownershipGate.waiterCount == 1 }
        // Arrives mid-pass, and asks. Logged before it asks, with nothing awaited between.
        front.deliver(Shop.pro)
        await waitUntil { logger.events.contains(.transactionUpdated(Shop.pro)) }
        front.ownershipGate.open()
        await first.value
        await waitUntil { resolved() == 3 }
        #expect(resolved() == 3)        // the pass that was under way, and one more
    }

    /// An app reads again whenever it becomes active, and whenever a settings pane opens.
    /// Almost every one of those reads finds what the last one found, and republishing it
    /// all the same redrew every view that watches the standing — every lock on a rail,
    /// every gate — for nothing, each time.
    @Test("a read that finds NOTHING NEW does not tell anyone; one that does, does")
    func quietWhenNothingChanged() async {
        front.seed(Shop.pro)
        await store.start()
        let told = Flag()
        withObservationTracking { _ = store.standing; _ = store.pendingApprovals } onChange: { told.raise() }
        clock.advance(by: .seconds(3_600))
        await store.refresh()
        #expect(!told.isRaised)

        // The control: the same watch does hear a real change.
        front.revoke(Shop.pro)
        await waitUntil { told.isRaised }
        #expect(told.isRaised)
    }

    /// Nothing the store holds has changed when a trial runs out; only the time has. That
    /// is still news, and the one kind of nothing-new that must be told.
    @Test("a trial ENDING is told, though what is held has not changed")
    func toldWhenATrialEnds() async {
        front.seedTrial(Shop.trial, remaining: .seconds(300))
        await store.start()
        let told = Flag()
        withObservationTracking { _ = store.standing } onChange: { told.raise() }
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(300))
        await waitUntil { told.isRaised }
        #expect(told.isRaised)
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    // MARK: - Buying

    /// The store lists a purchase a moment after `purchase()` returns. Read straight
    /// back, the account owns nothing, and Buy appears to have done nothing.
    @Test("a purchase unlocks AT ONCE, while the store still has not listed it")
    func unlocksBeforeListed() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        let completion = try await store.purchase(Shop.pro)
        let owned = OwnedProduct(id: Shop.pro, originalPurchaseDate: clock.now)
        #expect(completion == .owned(owned))
        #expect(store.standing.access(to: Shop.pro) == .owned(owned))
        #expect(front.snapshot.listed.isEmpty)
        #expect(store.activity == .idle)
    }

    @Test("a refund that OVERTAKES the listing still takes the purchase back")
    func refundBeforeListing() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        try await store.purchase(Shop.pro)
        front.revoke(Shop.pro)
        await waitUntil { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    @Test("once listed, a refund takes it back too")
    func refundAfterListing() async throws {
        await store.start()
        try await store.purchase(Shop.pro)
        await store.refresh()
        #expect(front.snapshot.listed.map(\.id) == [Shop.pro])
        front.revoke(Shop.pro)
        await waitUntil { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    /// Measured: an approved Ask to Buy arrives as an update while the real listing is
    /// still empty. A store that answers the update by reading the listing finds
    /// nothing — and has no reason ever to look again.
    @Test("a grant that ARRIVES ON ITS OWN unlocks at once, though the store has not listed it")
    func deliveredElsewhere() async {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        front.deliver(Shop.pro)
        await waitUntil { store.standing.ownership(of: Shop.pro) != nil }
        #expect(store.standing.ownership(of: Shop.pro) != nil)
        #expect(front.snapshot.listed.isEmpty)
    }

    @Test("a second word from the store about a product just bought does not wipe the purchase")
    func strayUpdate() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        await store.start()
        let completion = try await store.purchase(Shop.pro)
        guard case let .owned(owned) = completion else { return }
        front.announceWithoutListing(owned)
        await waitUntil { logger.events.contains(.transactionUpdated(Shop.pro)) }
        await store.refresh()
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    /// The listing is the last word. A grant the store announces and never lists — a
    /// shared purchase withdrawn without a date has been reported to look like one —
    /// is believed for a moment, not for the session.
    @Test("a grant the store NEVER goes on to list lapses when its time is up")
    func unlistedGrantLapses() async {
        await store.start()
        front.announceWithoutListing(OwnedProduct(id: Shop.pro, originalPurchaseDate: clock.now))
        await waitUntil { store.standing.ownership(of: Shop.pro) != nil }
        #expect(store.standing.ownership(of: Shop.pro) != nil)
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(29))
        #expect(store.standing.ownership(of: Shop.pro) != nil)
        clock.advance(by: .seconds(1))
        await waitUntil { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    @Test("a purchase the store DID list stays, long after the hold has lapsed")
    func listedPurchaseStays() async throws {
        await store.start()
        try await store.purchase(Shop.pro)
        clock.advance(by: .seconds(3_600))
        await waitUntil { clock.sleeperCount == 0 }
        await store.refresh()
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    @Test("Ask to Buy is PENDING — not a failure, not silence — and clears when approved")
    func askToBuy() async throws {
        front.behaviour.purchase = .pending
        await store.start()
        #expect(try await store.purchase(Shop.pro) == .pending)
        #expect(store.pendingApprovals == [Shop.pro])
        #expect(store.standing.access(to: Shop.pro) == .none)
        front.approvePending(Shop.pro)
        await waitUntil { store.pendingApprovals.isEmpty }
        #expect(store.pendingApprovals.isEmpty)
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    @Test("backing out says nothing and changes nothing")
    func cancelled() async throws {
        front.behaviour.purchase = .cancelled
        await store.start()
        #expect(try await store.purchase(Shop.pro) == .cancelled)
        #expect(store.standing.access(to: Shop.pro) == .none)
        #expect(store.pendingApprovals.isEmpty)
    }

    @Test("a failure is thrown to whoever asked, typed, and the standing is left alone", arguments: [
        PurchaseError.unverified, .productUnavailable, .network, .purchaseNotAllowed, .revoked,
    ])
    func failure(error: PurchaseError) async {
        front.seed(Shop.trial)
        front.behaviour.purchase = .fails(error)
        await store.start()
        let before = store.standing
        await #expect(throws: error) { try await store.purchase(Shop.pro) }
        #expect(store.standing == before)
        #expect(store.activity == .idle)
        #expect(logger.events.contains(.purchaseFailed(Shop.pro, error)))
    }

    /// The listener starts with the first command, whichever it is. An app that buys
    /// before it has called `start()` — a paywall shown at once — must still hear the
    /// refund.
    @Test("a purchase made BEFORE start() is still listened for: its refund is heard")
    func purchaseStartsListening() async throws {
        front.behaviour.listsPurchasesAfterReads = 5
        try await store.purchase(Shop.pro)
        #expect(front.listenerCount == 1)
        front.revoke(Shop.pro)
        await waitUntil { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    @Test("an account token of the app's own reaches the store untouched")
    func accountToken() async throws {
        let token = UUID()
        try await store.purchase(Shop.pro, options: PurchaseOptions(appAccountToken: token))
        #expect(front.lastPurchaseOptions == PurchaseOptions(appAccountToken: token))
        try await store.purchase(Shop.trial)
        #expect(front.lastPurchaseOptions == PurchaseOptions())
    }

    // MARK: - Asked for outside the app

    @Test("a purchase asked for OUTSIDE THE APP waits for the app, once, and buys nothing by itself")
    func requested() async throws {
        await store.start()
        front.requestPurchase(Shop.pro)
        front.requestPurchase(Shop.pro)
        // A third, to know the two before it have been heard: the stream keeps its order.
        front.requestPurchase(Shop.trial)
        #expect(await waitUntil { store.requestedPurchases.contains(RequestedPurchase(product: Shop.trial)) })
        #expect(store.requestedPurchases == [RequestedPurchase(product: Shop.pro), RequestedPurchase(product: Shop.trial)])
        #expect(store.standing.access(to: Shop.pro) == .none)
        #expect(front.lastPurchaseOptions == nil)
    }

    @Test("bought here, however it ends, the request is dealt with; dismissed, it is let go")
    func requestedThenBought() async throws {
        await store.start()
        front.requestPurchase(Shop.pro)
        front.requestPurchase(Shop.trial)
        #expect(await waitUntil { store.requestedPurchases.count == 2 })
        let request = store.requestedPurchases[0]
        front.behaviour.purchase = .cancelled
        try await store.purchase(request.product, options: request.options)
        #expect(store.requestedPurchases == [RequestedPurchase(product: Shop.trial)])
        store.dismissRequestedPurchase(RequestedPurchase(product: Shop.trial))
        #expect(store.requestedPurchases.isEmpty)
    }

    @Test("something the catalogue does not sell cannot be bought")
    func notInCatalogue() async {
        await #expect(throws: PurchaseError.productUnavailable) { try await store.purchase("nowhere") }
    }

    @Test("a second purchase while one is under way is refused, not queued behind it")
    func oneAtATime() async throws {
        await store.start()
        front.purchaseGate.close()              // the payment sheet is up
        let first = Task { try await store.purchase(Shop.pro) }
        await waitUntil { front.purchaseGate.waiterCount == 1 }
        #expect(store.activity == .purchasing(Shop.pro))
        await #expect(throws: PurchaseError.alreadyInProgress) { try await store.purchase(Shop.trial) }
        await #expect(throws: PurchaseError.alreadyInProgress) { try await store.restorePurchases() }
        front.purchaseGate.open()
        _ = try await first.value
        #expect(store.activity == .idle)
    }

    // MARK: - Trials

    @Test("buying the trial starts it from the store's date and lends the unlock")
    func startTrial() async throws {
        await store.start()
        #expect(store.standing.trial(Shop.trial) == .available)
        let completion = try await store.purchase(Shop.trial)
        let period = TrialPeriod(startedAt: clock.now, endsAt: clock.now.addingTimeInterval(14 * 86_400))
        #expect(completion == .trialRunning(period))
        #expect(store.standing.access(to: Shop.pro) == .onTrial(period, via: Shop.trial))
        #expect(store.standing.trial(Shop.trial) == .running(period))
    }

    /// No transaction arrives when a trial runs out. Without a scheduled re-read
    /// nothing locks until something unrelated redraws, or the app is relaunched.
    @Test("with five minutes left, the unlock is taken back five minutes later, BY ITSELF")
    func expiresByItself() async {
        front.seedTrial(Shop.trial, remaining: .seconds(300))
        await store.start()
        #expect(store.standing.nextExpiry == clock.now.addingTimeInterval(300))
        await waitUntil { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(299))
        #expect(store.standing.access(to: Shop.pro) != .none)

        clock.advance(by: .seconds(1))
        await waitUntil { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
        if case .used = store.standing.trial(Shop.trial) {} else { Issue.record("the trial should be used") }
        #expect(clock.sleeperCount == 0)
    }

    @Test("a wake that lands a moment EARLY finds the trial running and waits again")
    func earlyWake() async {
        front.seedTrial(Shop.trial, remaining: .seconds(300))
        await store.start()
        await waitUntil { clock.sleeperCount == 1 }
        clock.wakeSleepers()
        await waitUntil { clock.sleeperCount == 1 }
        #expect(clock.sleeperCount == 1)
        #expect(store.standing.access(to: Shop.pro) != .none)
    }

    /// Buying an owned non-consumable returns the original transaction. The button
    /// that was pressed is told when that trial ended, so it can say so.
    @Test("a trial used up on another device comes back USED, with when it ended")
    func usedElsewhere() async throws {
        front.seedEarlierPurchase(Shop.trial, age: .seconds(20 * 86_400))
        await store.start()
        #expect(store.standing.trial(Shop.trial) == .available)
        let completion = try await store.purchase(Shop.trial)
        let started = clock.now.addingTimeInterval(-20 * 86_400)
        let period = TrialPeriod(startedAt: started, endsAt: started.addingTimeInterval(14 * 86_400))
        #expect(completion == .trialUsed(period))
        #expect(store.standing.trial(Shop.trial) == .used(period))
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    @Test("a trial started on another device is the same trial here, picked up without a relaunch")
    func trialElsewhere() async {
        await store.start()
        let started = clock.now.addingTimeInterval(-86_400)
        front.deliver(OwnedProduct(id: Shop.trial, originalPurchaseDate: started))
        await waitUntil { store.standing.access(to: Shop.pro) != .none }
        #expect(store.standing.nextExpiry == started.addingTimeInterval(14 * 86_400))
    }

    /// A shared trial carries the purchaser's start date: it would hand the family a
    /// trial that is probably over, and take away their own.
    @Test("a FAMILY-SHARED trial is not counted, however it arrives")
    func familySharedTrial() async throws {
        await store.start()
        front.deliver(OwnedProduct(id: Shop.trial, originalPurchaseDate: clock.now, ownership: .familyShared))
        await waitUntil { logger.events.contains(.transactionUpdated(Shop.trial)) }
        await store.refresh()
        #expect(store.standing.access(to: Shop.pro) == .none)

        let shared = OwnedProduct(id: Shop.trial, originalPurchaseDate: clock.now, ownership: .familyShared)
        #expect(try await store.purchase(Shop.trial) == .notCounted(shared))
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    /// The debug panel's "Trial through Family Sharing", pressed during the account's
    /// own trial. The simulated store swapped the account's copy for the shared one,
    /// and the trial, taken and still running, was offered again.
    @Test("a family member's copy of a trial the account is ON neither ends nor restarts it")
    func sharedCopyBesideOwnTrial() async {
        front.seedTrial(Shop.trial, remaining: .seconds(300))
        await store.start()
        guard case let .running(period) = store.standing.trial(Shop.trial) else {
            Issue.record("the trial should be running")
            return
        }
        front.deliver(Shop.trial, ownership: .familyShared)
        await waitUntil { logger.events.contains(.transactionUpdated(Shop.trial)) }
        await store.refresh()
        await store.refresh()
        #expect(front.snapshot.listed.map(\.ownership) == [.purchased])
        #expect(store.standing.trial(Shop.trial) == .running(period))
    }

    /// The hold used to end as soon as the listing had the same *identifier*, whatever
    /// the listing said about it. Here the listing has the trial and it does not count
    /// — a family member's — so the account's own copy was let go the moment it
    /// arrived, and with no hold left there was nothing to schedule another look:
    /// Buy "did nothing" until the next launch, which is the bug the hold exists for.
    @Test("a listing that has the product but does NOT COUNT it leaves the hold on one that does")
    func holdOutlastsAListingThatDoesNotCount() async {
        front.seed(Shop.trial, ownership: .familyShared)
        await store.start()
        #expect(store.standing.trial(Shop.trial) == .available)

        let own = OwnedProduct(id: Shop.trial, originalPurchaseDate: clock.now)
        front.announceWithoutListing(own)
        await waitUntil { store.standing.ownership(of: Shop.trial) == own }
        #expect(store.standing.ownership(of: Shop.trial) == own)
        if case .onTrial = store.standing.access(to: Shop.pro) {} else { Issue.record("the trial should lend the unlock") }
    }

    @Test("buying the unlock during a trial ends the waiting: there is nothing left to expire")
    func buyDuringTrial() async throws {
        front.seedTrial(Shop.trial, remaining: .seconds(300))
        await store.start()
        try await store.purchase(Shop.pro)
        clock.advance(by: .seconds(301))
        await waitUntil { clock.sleeperCount == 0 }
        if case .owned = store.standing.access(to: Shop.pro) {} else { Issue.record("the unlock should be owned") }
    }

    // MARK: - Restoring

    @Test("a restore brings what was bought elsewhere")
    func restore() async throws {
        front.seedEarlierPurchase(Shop.pro, age: .seconds(60))
        await store.start()
        #expect(store.standing.access(to: Shop.pro) == .none)
        #expect(try await store.restorePurchases() == .completed)
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    /// The store could not be reached, which is no evidence anything stopped being owned.
    @Test("a restore that FAILS never takes away what was owned", arguments: [
        PurchaseError.network, .system, .unknown(typeName: "SomeError"),
    ])
    func failedRestore(error: PurchaseError) async {
        front.seed(Shop.pro)
        await store.start()
        front.behaviour.restore = .fails(error)
        await #expect(throws: error) { try await store.restorePurchases() }
        #expect(store.standing.ownership(of: Shop.pro) != nil)
        #expect(store.activity == .idle)
    }

    /// D9: a restore that throws reads again all the same. The store could not be
    /// reached for the restore, which says nothing about whether it can be read.
    @Test("a restore that FAILS still reads again, and finds what has turned up meanwhile")
    func failedRestoreReadsAgain() async {
        await store.start()
        #expect(store.standing.access(to: Shop.pro) == .none)
        front.seed(Shop.pro)                          // listed since, and nobody was told
        front.behaviour.restore = .fails(.network)
        await #expect(throws: PurchaseError.network) { try await store.restorePurchases() }
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    @Test("dismissing the sign-in prompt is a cancellation, not an error")
    func cancelledRestore() async throws {
        front.behaviour.restore = .cancelled
        #expect(try await store.restorePurchases() == .cancelled)
    }

    // MARK: - Prices

    @Test("prices load separately, in the catalogue's order")
    func loadProducts() async {
        await store.loadProducts()
        #expect(store.products.map(\.id) == [Shop.pro, Shop.trial])
        #expect(store.productLoad == .loaded)
        #expect(!store.standing.isKnown)
    }

    /// Offline, the catalogue can take a long time to fail. An owner clicking on
    /// something gated must not be made to wait for it.
    @Test("what is owned is known while the catalogue is STILL being waited for")
    func ownershipDoesNotWaitForPrices() async {
        front.seed(Shop.pro)
        front.catalogueGate.close()
        let prices = Task { await store.loadProducts() }
        await waitUntil { front.catalogueGate.waiterCount == 1 }
        let standing = await store.knownStanding()
        #expect(standing.ownership(of: Shop.pro) != nil)
        #expect(store.productLoad == .loading)
        front.catalogueGate.open()
        await prices.value
        #expect(store.productLoad == .loaded)
    }

    @Test("a reload that fails keeps the last good prices, and never touches the standing")
    func failedReload() async {
        front.seed(Shop.pro)
        await store.start()
        await store.loadProducts()
        front.behaviour.catalogue = .fails(.network)
        await store.loadProducts()
        #expect(store.productLoad == .failed(.network))
        #expect(store.products.count == 2)
        #expect(store.standing.ownership(of: Shop.pro) != nil)
    }

    /// Two loads in flight finish in whichever order the network likes. The slow one
    /// used to win by being last: a first load timing out *after* a retry had
    /// succeeded left the paywall saying "could not load" over prices it had.
    @Test("a load asked for while one is UNDER WAY joins it, rather than racing it")
    func loadsAreSingleFlight() async {
        front.catalogueGate.close()
        let first = Task { await store.loadProducts() }
        await waitUntil { front.catalogueGate.waiterCount == 1 }
        let second = Task { await store.loadProducts() }
        // Long enough for a second request to have reached the gate, had one been made.
        await waitUntil(timeout: .milliseconds(50)) { front.catalogueGate.waiterCount == 2 }
        #expect(front.catalogueGate.waiterCount == 1)
        front.catalogueGate.open()
        await first.value
        await second.value
        #expect(store.productLoad == .loaded)
        #expect(logger.events.filter { $0 == .catalogueLoaded(Shop.catalogue.identifiers) }.count == 1)
    }

    /// SwiftUI cancels `.task` whenever its view goes away, and the real store answers a
    /// cancelled request for products with an *empty list* — measured, 0 of 2 — which
    /// reads as a store that sells this build nothing. Made in the caller's task, one
    /// paywall closing at the wrong moment emptied every other view's prices.
    @Test("a caller CANCELLED mid-load still gets the prices, and so does everyone else")
    func cancelledLoad() async {
        front.catalogueGate.close()
        let asked = Task { await store.loadProducts() }
        await waitUntil { front.catalogueGate.waiterCount == 1 }
        asked.cancel()
        front.catalogueGate.open()
        await asked.value
        #expect(store.productLoad == .loaded)
        #expect(store.products.map(\.id) == [Shop.pro, Shop.trial])
        #expect(!logger.events.contains(.catalogueLoadedEmpty(requested: Shop.catalogue.identifiers)))
    }

    /// A paywall asks for prices every time it opens, and a second scene asks again. Asked
    /// for once they are here, that was a network request each time, for an answer in hand.
    @Test("prices already loaded are not asked for again, unless they are asked for by name")
    func loadsOnlyIfNeeded() async {
        await store.loadProductsIfNeeded()
        #expect(store.productLoad == .loaded)
        let loaded = { self.logger.events.filter { $0 == .catalogueLoaded(Shop.catalogue.identifiers) }.count }
        #expect(loaded() == 1)
        await store.loadProductsIfNeeded()
        #expect(loaded() == 1)
        await store.loadProducts()              // by name: go and ask
        #expect(loaded() == 2)

        // A load that failed is needed again.
        front.behaviour.catalogue = .fails(.network)
        await store.loadProducts()
        front.behaviour.catalogue = .loads
        await store.loadProductsIfNeeded()
        #expect(store.productLoad == .loaded)
    }

    @Test("the store passes on what its front can say about this build, and says when it cannot")
    func diagnosis() async {
        front.behaviour.catalogue = .loadsOnly([])
        #expect(await store.diagnose()?.hints == [.storeSellsNothingToThisBuild])
        // A front with nothing to say about the build it is in.
        let mute = PurchaseStore(catalogue: Shop.catalogue, front: EverythingOwnedStoreFront(catalogue: Shop.catalogue))
        #expect(await mute.diagnose() == nil)
    }

    /// An ad-hoc build the App Store has never heard of, with no configuration file
    /// on the scheme: nothing loads, and to its developer Buy "does nothing".
    @Test("a store that sells this build NOTHING is logged as exactly that")
    func emptyCatalogue() async {
        front.behaviour.catalogue = .loadsOnly([])
        await store.loadProducts()
        #expect(store.products.isEmpty)
        #expect(logger.events.contains(.catalogueLoadedEmpty(requested: Shop.catalogue.identifiers)))
    }
}

@MainActor
@Suite("Purchase store, lifetime and the real clock", .timeLimit(.minutes(1)))
struct PurchaseStoreLifetimeTests {
    @Test("dropping the store ends its listener, rather than leaving it parked on the stream")
    func deinitCancels() async {
        let front = SimulatedStoreFront(catalogue: Shop.catalogue)
        do {
            let store = PurchaseStore(catalogue: Shop.catalogue, front: front)
            await store.start()
            #expect(front.listenerCount == 1)
        }
        await waitUntil { front.listenerCount == 0 }
        #expect(front.listenerCount == 0)
    }

    /// The manual clock proves the logic. This proves the re-read actually fires.
    @Test("on the REAL clock, a trial a third of a second long ends by itself")
    func realClock() async throws {
        let catalogue: Catalogue = [.unlock(Shop.pro), .trial(Shop.trial, of: [Shop.pro], lasting: .milliseconds(300))]
        let front = SimulatedStoreFront(catalogue: catalogue)
        let store = PurchaseStore(catalogue: catalogue, front: front)
        await store.start()
        guard case .trialRunning = try await store.purchase(Shop.trial) else {
            Issue.record("the trial should be running")
            return
        }
        #expect(store.standing.access(to: Shop.pro) != .none)
        await waitUntil(timeout: .seconds(5)) { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
    }

    @Test("a build sold some other way owns every unlock, offers no trial, and sells nothing")
    func everythingOwned() async {
        let store = PurchaseStore(catalogue: Shop.catalogue, front: EverythingOwnedStoreFront(catalogue: Shop.catalogue))
        let standing = await store.knownStanding()
        #expect(standing.ownership(of: Shop.pro) != nil)
        #expect(standing.trial(Shop.trial) == .notOffered)
        await #expect(throws: PurchaseError.purchaseNotAllowed) { try await store.purchase(Shop.pro) }
    }
}

/// Raised from an observation's `onChange`, which may be called from anywhere.
private final class Flag: Sendable {
    private let raised = Mutex(false)
    var isRaised: Bool { raised.withLock { $0 } }
    func raise() { raised.withLock { $0 = true } }
}

#endif
