// The simulated store exists only in DEBUG builds (docs/07-release-safety.md), so a
// test that names it does too: under `swift build --build-tests -c release`, or a test
// plan in a Release configuration, it would not compile. `make check` builds the tests
// for release to keep this true.
#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

private let pro: ProductID = "com.example.pro"
private let trial: ProductID = "com.example.trial"
private let catalogue: Catalogue = [.unlock(pro), .trial(trial, of: [pro], lasting: .seconds(14 * 86_400))]

@Suite("Simulated store", .timeLimit(.minutes(1)))
struct SimulatedStoreFrontTests {
    private let clock = ManualClock()

    private func store(_ behaviour: SimulatedStoreFront.Behaviour = .init()) -> SimulatedStoreFront {
        SimulatedStoreFront(catalogue: catalogue, clock: clock, behaviour: behaviour)
    }

    @Test("it lists a purchase ONE READ LATE, as the real store does")
    func listsLate() async throws {
        let store = store()
        let outcome = try await store.purchase(pro, confirmation: .automatic)
        #expect(outcome == .purchased(OwnedProduct(id: pro, originalPurchaseDate: clock.now)))
        #expect(await store.ownedProducts().isEmpty)
        #expect(await store.ownedProducts().map(\.id) == [pro])
    }

    @Test("a cancelled task is told nothing, as the real store was measured to")
    func cancelledRead() async {
        let store = store()
        store.seed(pro)
        let cancelled = Task { () -> [OwnedProduct] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.ownedProducts()
        }
        #expect(await cancelled.value.isEmpty)
        #expect(await store.ownedProducts().map(\.id) == [pro])
    }

    @Test("buying what is already owned hands back the original, original date and all")
    func rebuy() async throws {
        let store = store()
        let first = try await store.purchase(trial, confirmation: .automatic)
        clock.advance(by: .seconds(86_400))
        let again = try await store.purchase(trial, confirmation: .automatic)
        #expect(first == again)
    }

    @Test("something bought on another device comes back with ITS date when bought here")
    func earlierPurchase() async throws {
        let store = store()
        store.seedEarlierPurchase(trial, age: .seconds(20 * 86_400))
        #expect(await store.ownedProducts().isEmpty)
        let outcome = try await store.purchase(trial, confirmation: .automatic)
        let expected = OwnedProduct(id: trial, originalPurchaseDate: clock.now.addingTimeInterval(-20 * 86_400))
        #expect(outcome == .purchased(expected))
    }

    /// It used to grant whatever it was given. A test that approved the wrong product,
    /// or approved before buying, passed — with the app's pending state never exercised.
    @Test("approving what was NEVER PENDING grants nothing")
    func approveWithoutPending() async {
        let store = store()
        #expect(!store.approvePending(pro))
        #expect(store.snapshot.unlisted.isEmpty)
        #expect(store.snapshot.listed.isEmpty)
    }

    /// An approval is the purchase going through, so it is the purchase `purchase()`
    /// would have made: for something the account already owns, the original. Made up
    /// afresh, an approved trial restarted from today — which the real store never does.
    @Test("an approved Ask to Buy for something bought elsewhere arrives with ITS date, not today's")
    func approveEarlierPurchase() async throws {
        let store = store(.init())
        store.seedEarlierPurchase(trial, age: .seconds(20 * 86_400))
        store.behaviour.purchase = .pending
        #expect(try await store.purchase(trial, confirmation: .automatic) == .pending)
        #expect(store.approvePending(trial))
        let expected = OwnedProduct(id: trial, originalPurchaseDate: clock.now.addingTimeInterval(-20 * 86_400))
        #expect(store.snapshot.unlisted == [expected])
        #expect(store.snapshot.earlier.isEmpty)
        #expect(store.snapshot.pending.isEmpty)
    }

    @Test("a restore brings earlier purchases here")
    func restore() async throws {
        let store = store()
        store.seedEarlierPurchase(pro, age: .seconds(60))
        #expect(try await store.restorePurchases() == .completed)
        #expect(await store.ownedProducts().map(\.id) == [pro])
    }

    @Test("a trial can be seeded with exactly five minutes left")
    func fiveMinutesLeft() async {
        let store = store()
        store.seedTrial(trial, remaining: .seconds(300))
        let owned = await store.ownedProducts()
        let period = catalogue.entry(for: trial)?.trialTerms?.period(startingAt: owned[0].originalPurchaseDate)
        #expect(period?.endsAt == clock.now.addingTimeInterval(300))
    }

    @Test("deliveries and refunds are announced WITH THEIR FACTS, to every listener")
    func announces() async {
        let store = store()
        var first = store.transactionUpdates().makeAsyncIterator()
        var second = store.transactionUpdates().makeAsyncIterator()
        #expect(store.listenerCount == 2)
        // Announced on the very next line: registration was synchronous, so nothing is lost.
        store.deliver(pro)
        store.revoke(pro)
        let granted = TransactionUpdate.granted(OwnedProduct(id: pro, originalPurchaseDate: clock.now))
        #expect(await first.next() == granted)
        #expect(await first.next() == .withdrawn(pro))
        #expect(await second.next() == granted)
        #expect(await store.ownedProducts().isEmpty)
    }

    /// Measured: when an approved Ask to Buy arrives, the real listing is still empty.
    @Test("a delivery is listed ONE READ LATE too, as the real store's are")
    func deliveryListsLate() async {
        let store = store()
        store.deliver(pro)
        #expect(await store.ownedProducts().isEmpty)
        #expect(await store.ownedProducts().map(\.id) == [pro])
    }

    @Test("a refund does not lag: it is gone from the very next read")
    func refundDoesNotLag() async {
        let store = store()
        store.seed(pro)
        store.revoke(pro)
        #expect(await store.ownedProducts().isEmpty)
    }

    @Test("a listener that goes away is forgotten")
    func listenerGoes() async {
        let store = store()
        do {
            let stream = store.transactionUpdates()
            let task = Task { for await _ in stream {} }
            #expect(store.listenerCount == 1)
            task.cancel()
            await task.value
        }
        await waitUntil { store.listenerCount == 0 }
        #expect(store.listenerCount == 0)
    }

    @Test("purchases can be scripted to end every way a real one can", arguments: [
        (SimulatedStoreFront.Behaviour.PurchaseScript.pending, PurchaseOutcome.pending),
        (.cancelled, .cancelled),
    ])
    func scriptedEndings(script: SimulatedStoreFront.Behaviour.PurchaseScript, expected: PurchaseOutcome) async throws {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.purchase = script
        let store = store(behaviour)
        #expect(try await store.purchase(pro, confirmation: .automatic) == expected)
        #expect(store.snapshot.pending == (expected == .pending ? [pro] : []))
    }

    @Test("a scripted failure is thrown as it was given", arguments: [
        PurchaseError.unverified, .productUnavailable, .network, .purchaseNotAllowed,
    ])
    func scriptedFailure(error: PurchaseError) async {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.purchase = .fails(error)
        let store = store(behaviour)
        await #expect(throws: error) { try await store.purchase(pro, confirmation: .automatic) }
    }

    @Test("a product the catalogue does not list cannot be bought")
    func unknownProduct() async {
        await #expect(throws: PurchaseError.productUnavailable) {
            try await store().purchase("nowhere", confirmation: .automatic)
        }
    }

    @Test("the catalogue can load, load in part, load nothing, or fail")
    func catalogueScripts() async throws {
        let store = store()
        #expect(try await store.products().map(\.id) == [pro, trial])
        store.behaviour.catalogue = .loadsOnly([pro])
        #expect(try await store.products().map(\.id) == [pro])
        store.behaviour.catalogue = .loadsOnly([])
        #expect(try await store.products().isEmpty)
        #expect(await store.diagnose().hints == [.storeSellsNothingToThisBuild])
        store.behaviour.catalogue = .fails(.network)
        await #expect(throws: PurchaseError.network) { try await store.products() }
        // Could not be asked, which is not the same as selling nothing.
        #expect(await store.diagnose().hints == [.catalogueLoadFailed(.network)])
    }

    @Test("the gates hold different answers: a slow catalogue does not hold what is owned")
    func gates() async {
        let store = store()
        store.seed(pro)
        store.catalogueGate.close()
        let prices = Task { try? await store.products() }
        await waitUntil { store.catalogueGate.waiterCount == 1 }
        #expect(await store.ownedProducts().map(\.id) == [pro])
        store.catalogueGate.open()
        #expect(await prices.value?.count == 2)
    }
}

#endif
