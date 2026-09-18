//
//  RealStoreKitTests.swift
//  DemoTests
//
//  The real adapter against real StoreKit — the dozen lines `swift test` cannot reach.
//
//  Hosted by the Demo app because nothing else works: from a package test target
//  SKTestSession cannot save its configuration and every purchase fails
//  (../spike/README.md). StoreKit's test environment is one, shared by every session
//  and outliving the process, so the suite is serial, and each test resets it first and
//  keeps its session alive to the end.
//
//  Backdating depends on the OS, though Apple documents it without saying so: on macOS
//  26.6 `SKTestSession.buyProduct` fails, and `product.purchase(options:
//  [.purchaseDate(…)])` succeeds and ignores the date; in the iOS 27 simulator both
//  work. So a trial nearly over is tested twice — with a trial a second and a half
//  long, everywhere, and with a real fortnight bought thirteen days ago, as a known
//  issue where that cannot pass.
//
//  Runs on the Mac (`make integration`) and in an iOS simulator (`make integration-ios`).
//
//  The product identifiers are the app's own (`Shop`), not a second copy of them: the
//  point of checking the file against the catalogue is that there is one catalogue.
//

@testable import Demo
import Foundation
import PurchaseCore
import PurchaseStoreKit
import PurchaseTestKit
import StoreKit
import StoreKitTest
import Testing

@MainActor
@Suite("Real StoreKit, through the real adapter", .serialized, .timeLimit(.minutes(2)))
struct RealStoreKitTests {
    static let pro = Shop.pro
    static let trial = Shop.trial

    /// The app's catalogue, or the same one with a trial short enough to watch end.
    static func catalogue(trialLasting duration: Duration? = nil) -> Catalogue {
        guard let duration else { return Shop.catalogue }
        return [.unlock(pro), .trial(trial, of: [pro], lasting: duration)]
    }

    private static func configurationURL() throws -> URL {
        let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
        return try #require(bundle.url(forResource: "Demo", withExtension: "storekit"))
    }

    /// There is one test environment, shared by every session — and **it outlives the
    /// process**: an error left armed by one run was still armed in the next. So each
    /// test puts it back first, with `resetToDefaultState()`, or a test that failed half
    /// way leaves Ask to Buy on, or an error armed, for whichever test runs next.
    ///
    /// `resetToDefaultState()` and not `setSimulatedError(nil, …)`, which is how Apple
    /// says an error is disarmed: for `.purchase`, on macOS 26.6, passing nil leaves
    /// every later purchase throwing `StoreKitError.unknown` (a canary below).
    private func session() async throws -> SKTestSession {
        let session = try SKTestSession(contentsOf: Self.configurationURL())
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    private func store(_ catalogue: Catalogue = catalogue()) -> PurchaseStore {
        PurchaseStore(catalogue: catalogue, front: AppStoreFront(catalogue: catalogue))
    }

    // MARK: - The file is the contract

    /// A renamed identifier fails silently: the product never loads, and Buy does nothing.
    @Test("the configuration file sells exactly what the catalogue declares, as the catalogue declares it")
    func fileMatchesCatalogue() throws {
        let configuration = try StoreKitConfiguration(contentsOf: Self.configurationURL())
        #expect(configuration.problems(against: Self.catalogue()) == [])
    }

    @Test("real StoreKit returns those products, with the store's own words and prices")
    func productsLoad() async throws {
        let session = try await session()
        let store = store()
        await store.loadProducts()
        #expect(store.productLoad == .loaded)
        #expect(store.products.map(\.id) == [Self.pro, Self.trial])
        #expect(store.products.first?.isFamilyShareable == true)
        #expect(store.products.last?.price == 0)
        withExtendedLifetime(session) {}
    }

    // MARK: - Buying

    @Test("buying the unlock unlocks it AT ONCE, though StoreKit has not listed it yet")
    func buyUnlock() async throws {
        let session = try await session()
        let store = store()
        #expect(await store.knownStanding().access(to: Self.pro) == .none)

        guard case .owned = try await store.purchase(Self.pro) else {
            Issue.record("expected the unlock to be owned")
            return
        }
        if case .owned = store.standing.access(to: Self.pro) {} else { Issue.record("not unlocked at once") }

        // …and it is still unlocked once StoreKit's own listing has taken over.
        await waitUntil(timeout: .seconds(10)) {
            await AppStoreFront(catalogue: Self.catalogue()).ownedProducts().map(\.id) == [Self.pro]
        }
        await store.refresh()
        if case .owned = store.standing.access(to: Self.pro) {} else { Issue.record("lost once listed") }
        withExtendedLifetime(session) {}
    }

    @Test("a refund takes it back, without a relaunch")
    func refund() async throws {
        let session = try await session()
        let store = store()
        await store.start()
        try await store.purchase(Self.pro)
        let bought = try #require(session.allTransactions().first { $0.productIdentifier == Self.pro.rawValue })
        try session.refundTransaction(identifier: bought.identifier)
        await waitUntil(timeout: .seconds(10)) { store.standing.access(to: Self.pro) == .none }
        #expect(store.standing.access(to: Self.pro) == .none)
        withExtendedLifetime(session) {}
    }

    @Test("Ask to Buy is pending, and unlocks when approved — through the updates stream")
    func askToBuy() async throws {
        let session = try await session()
        session.askToBuyEnabled = true
        let store = store()
        await store.start()
        #expect(try await store.purchase(Self.pro) == .pending)
        #expect(store.pendingApprovals == [Self.pro])

        let waiting = try #require(session.allTransactions().first { $0.productIdentifier == Self.pro.rawValue })
        try session.approveAskToBuyTransaction(identifier: waiting.identifier)
        await waitUntil(timeout: .seconds(10)) { store.standing.ownership(of: Self.pro) != nil }
        #expect(store.standing.ownership(of: Self.pro) != nil)
        #expect(store.pendingApprovals.isEmpty)
        withExtendedLifetime(session) {}
    }

    // MARK: - Trials

    @Test("a trial bought from real StoreKit lends the unlock, then ends BY ITSELF")
    func trialEnds() async throws {
        let session = try await session()
        let store = store(Self.catalogue(trialLasting: .milliseconds(1_500)))
        await store.start()
        guard case let .trialRunning(period) = try await store.purchase(Self.trial) else {
            Issue.record("expected the trial to be running")
            return
        }
        #expect(store.standing.access(to: Self.pro) == .onTrial(period, via: Self.trial))
        await waitUntil(timeout: .seconds(10)) { store.standing.access(to: Self.pro) == .none }
        #expect(store.standing.access(to: Self.pro) == .none)
        #expect(store.standing.trial(Self.trial) == .used(period))
        withExtendedLifetime(session) {}
    }

    /// What makes a trial one trial: buying it again does not start it again.
    @Test("buying the trial AGAIN hands back the original transaction, original date and all")
    func trialTwice() async throws {
        let session = try await session()
        let store = store(Self.catalogue(trialLasting: .milliseconds(1_500)))
        await store.start()
        guard case let .trialRunning(first) = try await store.purchase(Self.trial) else {
            Issue.record("expected the trial to be running")
            return
        }
        await waitUntil(timeout: .seconds(10)) { store.standing.trial(Self.trial) == .used(first) }
        #expect(try await store.purchase(Self.trial) == .trialUsed(first))
        withExtendedLifetime(session) {}
    }

    // MARK: - Failures, from real StoreKit

    /// The error mapping is otherwise only ever shown errors a test built by hand. These
    /// are StoreKit's own, made by `setSimulatedError`, through the real adapter.
    ///
    /// *Which* error comes back is the Mac's to say. There, the error armed is the error
    /// thrown. The iOS simulator throws one of its own whatever was armed — a system
    /// error for a load, `unknown` for a purchase — so on iOS these prove that a failure
    /// is a failure and changes nothing, and the mapping is proved on the Mac. **[ran]**
    @Test("a catalogue StoreKit cannot load is a FAILURE, diagnosed as one, and the standing is untouched")
    func loadFailure() async throws {
        let session = try await session()
        try await session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let store = store()
        await store.loadProducts()
        guard case let .failed(failure) = store.productLoad else {
            Issue.record("expected the load to fail, got \(store.productLoad)")
            return
        }
        #if os(macOS)
        #expect(failure == .network)
        #endif
        #expect(await store.knownStanding().isKnown)
        // Could not be asked — which is not "sells nothing to this build".
        #expect(await AppStoreFront(catalogue: Self.catalogue()).diagnose().hints == [.catalogueLoadFailed(failure)])
        withExtendedLifetime(session) {}
    }

    @Test("a purchase StoreKit refuses is thrown as its kind, and nothing is unlocked")
    func purchaseFailure() async throws {
        let session = try await session()
        let store = store()
        await store.loadProducts()      // while it still can: the purchase needs the product
        try await session.setSimulatedError(.purchase(.purchaseNotAllowed), forAPI: .purchase)
        #if os(macOS)
        await #expect(throws: PurchaseError.purchaseNotAllowed) { try await store.purchase(Self.pro) }
        #else
        await #expect(throws: PurchaseError.self) { try await store.purchase(Self.pro) }
        #endif
        #expect(await store.knownStanding().access(to: Self.pro) == .none)
        #expect(store.activity == .idle)
        withExtendedLifetime(session) {}
    }

    /// The failure the adapter takes most care over, from StoreKit itself: the signature
    /// does not check out, and the person may have been charged.
    @Test("a purchase that does NOT VERIFY is a failure, never a cancellation, and unlocks nothing")
    func unverifiedPurchase() async throws {
        let session = try await session()
        let store = store()
        await store.loadProducts()
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        await #expect(throws: PurchaseError.unverified) { try await store.purchase(Self.pro) }
        #expect(await store.knownStanding().access(to: Self.pro) == .none)

        // The listing has it, unverified; it is not counted, and the diagnosis says why
        // a customer who paid is looking at the paywall.
        let front = AppStoreFront(catalogue: Self.catalogue())
        await waitUntil(timeout: .seconds(10)) { await front.diagnose().unverifiedEntitlements == 1 }
        let diagnosis = await front.diagnose()
        #expect(diagnosis.unverifiedEntitlements == 1)
        #expect(diagnosis.hints == [.unverifiedEntitlementsPresent(1)])
        #expect(await front.ownedProducts().isEmpty)
        withExtendedLifetime(session) {}
    }

    // MARK: - Where StoreKit's test environment differs from one OS to the next

    /// Two faults in StoreKit's test environment that the 27 releases fixed. Measured:
    /// both present on macOS 26.6, both gone in the iOS 27.0 simulator, with the same
    /// Xcode (27.0) — so it is the OS that decides, not the tools. Each is written as
    /// a *known issue* where it is expected, which is a canary both ways: the test
    /// fails if the fault turns up where it should not, and if it has gone from where
    /// it was.
    private static var hasThe27Fixes: Bool {
        if #available(macOS 27, iOS 27, *) { true } else { false }
    }

    /// The test this package could not write on macOS 26, and the reason `trialEnds`
    /// shortens the trial instead: a real fortnight, bought thirteen days, twenty-three
    /// hours and fifty-five minutes ago. Apple documents the route —
    /// `Product.PurchaseOption.purchaseDate(_:)` with `buyProduct(identifier:options:)` —
    /// and Xcode 27's release notes list `buyProduct` throwing `StoreKitError.unknown` as
    /// fixed (FB24168768).
    @Test("a FORTNIGHT'S trial with five minutes left, against real StoreKit, where it can be backdated")
    func trialNearlyOver() async throws {
        let session = try await session()
        let store = store()
        await store.start()
        let bought = Date(timeIntervalSinceNow: -(14 * 86_400 - 300))
        try await withKnownIssue("before the 27 releases, buyProduct throws StoreKitError.unknown") {
            _ = try await session.buyProduct(identifier: Self.trial.rawValue, options: [.purchaseDate(bought)])
            await waitUntil(timeout: .seconds(10)) {
                await store.refresh()
                return store.standing.ownership(of: Self.trial) != nil
            }
            guard case let .running(period) = store.standing.trial(Self.trial) else {
                Issue.record("expected the trial to be running, got \(store.standing.trial(Self.trial))")
                return
            }
            // The store's date, not this test's: five minutes left, give or take the test.
            #expect(abs(period.endsAt.timeIntervalSinceNow - 300) < 10)
            #expect(store.standing.access(to: Self.pro) == .onTrial(period, via: Self.trial))
        } when: {
            !Self.hasThe27Fixes
        }
        withExtendedLifetime(session) {}
    }

    /// Disarming is documented as passing nil. Before the 27 releases, for `.purchase`,
    /// it does the opposite — and the damage outlives the process, which is why
    /// `session()` resets the whole environment rather than disarming what it armed.
    @Test("a simulated purchase error is DISARMED by passing nil, where that works; resetToDefaultState always")
    func disarmingWithNil() async throws {
        let session = try await session()
        let store = store()
        await store.loadProducts()
        try await session.setSimulatedError(nil, forAPI: .purchase)
        try await withKnownIssue("before the 27 releases, nil arms StoreKitError.unknown instead of disarming") {
            try await store.purchase(Self.pro)
        } when: {
            !Self.hasThe27Fixes
        }
        session.resetToDefaultState()
        session.disableDialogs = true
        guard case .owned = try await store.purchase(Self.pro) else {
            Issue.record("expected the purchase to go through once the environment was reset")
            return
        }
        withExtendedLifetime(session) {}
    }

    // MARK: - What this build receives, and a canary

    @Test("the probe reports what this build receives, and from which environment")
    func probe() async throws {
        let session = try await session()
        let store = store()
        try await store.purchase(Self.pro)
        let front = AppStoreFront(catalogue: Self.catalogue())
        await waitUntil(timeout: .seconds(10)) { await front.diagnose().verifiedEntitlements == 1 }
        let diagnosis = await front.diagnose()
        #expect(diagnosis.received == [Self.pro, Self.trial])
        #expect(diagnosis.hints.isEmpty)
        #expect(diagnosis.environment == "Xcode")
        withExtendedLifetime(session) {}
    }

    /// The reason `PurchaseStore` reads what is owned in a task nobody can cancel. If
    /// this ever starts failing, Apple has changed the behaviour — good news, and
    /// worth knowing.
    @Test("CANARY: real StoreKit answers a cancelled task with nothing at all")
    func cancelledRead() async throws {
        let session = try await session()
        let store = store()
        try await store.purchase(Self.pro)
        let front = AppStoreFront(catalogue: Self.catalogue())
        await waitUntil(timeout: .seconds(10)) { await front.ownedProducts().count == 1 }
        let cancelled = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return await front.ownedProducts().count
        }
        #expect(await cancelled.value == 0)
        // …and the store, asked by a cancelled caller, still answers in full.
        let asked = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.knownStanding().ownership(of: Self.pro) != nil
        }
        #expect(await asked.value)
        withExtendedLifetime(session) {}
    }
}
