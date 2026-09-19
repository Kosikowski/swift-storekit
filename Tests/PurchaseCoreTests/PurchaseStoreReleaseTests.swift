import Foundation
import PurchaseCore
import PurchaseTestKit
import Synchronization
import Testing

// `PurchaseStore` is the one stateful, concurrent type in the package, and every other
// test of it needs the simulated store, which does not exist in a release build. So in
// release none of them ran — in a package whose one release-only failure so far (D25)
// was found by accident. These few run optimised. Their store front lives here, in
// Tests/, where nothing ships and so nothing needs a guard; it is as small as it can be
// and still be awkward in the two ways that matter: it answers a cancelled task with
// nothing, and it can be held.

private final class StubStoreFront: StoreFront {
    private struct State {
        var listed: [OwnedProduct] = []
        var reads = 0
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var reads: Int { state.withLock { $0.reads } }
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func list(_ product: OwnedProduct) { state.withLock { $0.listed.append(product) } }
    func hold() { state.withLock { $0.held = true } }

    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.held = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for continuation in waiting { continuation.resume() }
    }

    func products() async throws(PurchaseError) -> [StoreProduct] { [] }

    func ownedProducts() async -> [OwnedProduct] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state -> Bool in
                guard state.held else { return false }
                state.waiters.append(continuation)
                return true
            }
            if !waits { continuation.resume() }
        }
        // As the real store was measured to: a cancelled task is told nothing.
        if Task.isCancelled { return [] }
        return state.withLock { state in
            state.reads += 1
            return state.listed
        }
    }

    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws(PurchaseError) -> PurchaseOutcome {
        .cancelled
    }

    func restorePurchases() async throws(PurchaseError) -> RestoreOutcome { .completed }
    func transactionUpdates() -> AsyncStream<TransactionUpdate> { AsyncStream { _ in } }
}

@MainActor
@Suite("Purchase store, in whatever configuration this is built", .timeLimit(.minutes(1)))
struct PurchaseStoreReleaseTests {
    private let clock = ManualClock(now: Shop.epoch)
    private let front = StubStoreFront()

    private func store() -> PurchaseStore {
        PurchaseStore(catalogue: Shop.catalogue, front: front, clock: clock)
    }

    @Test("a caller CANCELLED mid-read still gets the whole answer")
    func cancelledCaller() async {
        front.list(OwnedProduct(id: Shop.pro, originalPurchaseDate: Shop.epoch))
        front.hold()
        let store = store()
        let asked = Task { await store.knownStanding() }
        await waitUntil { front.waiterCount == 1 }
        asked.cancel()
        front.release()
        #expect(await asked.value.ownership(of: Shop.pro) != nil)
    }

    @Test("many callers at once share one read")
    func singleFlight() async {
        front.hold()
        let store = store()
        let callers = (0 ..< 20).map { _ in Task { await store.knownStanding() } }
        await waitUntil { front.waiterCount == 1 }
        front.release()
        for caller in callers { #expect(await caller.value.isKnown) }
        // The pass that was held, and at most the one re-run the late callers asked for.
        #expect(front.reads <= 2)
    }

    @Test("with five minutes left, the unlock is taken back five minutes later, by itself")
    func expiry() async {
        let bought = Shop.epoch.addingTimeInterval(-(Shop.fortnight.timeInterval - 300))
        front.list(OwnedProduct(id: Shop.trial, originalPurchaseDate: bought))
        let store = store()
        await store.start()
        if case .onTrial = store.standing.access(to: Shop.pro) {} else { Issue.record("the trial should lend the unlock") }
        await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(300))
        await waitUntil { store.standing.access(to: Shop.pro) == .none }
        #expect(store.standing.access(to: Shop.pro) == .none)
    }
}
