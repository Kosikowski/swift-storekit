import Foundation
import PurchaseCore
import StoreKit
import Synchronization
import Testing

@testable import PurchaseStoreKit

private let pro: ProductID = "com.example.pro"
private let trial: ProductID = "com.example.trial"
private let foreign: ProductID = "com.somebody.elses"
private let catalogue: Catalogue = [.unlock(pro), .trial(trial, of: [pro], lasting: .seconds(14 * 86_400))]

private final class Log: PurchaseLogging {
    let events = Mutex<[PurchaseEvent]>([])
    func log(_ event: PurchaseEvent) { events.withLock { $0.append(event) } }
}

/// StoreKit as it was measured to treat a cancelled task: asked for products, it
/// answers with none; asked what is owned, likewise.
private final class CancellationSensitiveGateway: StoreKitGateway {
    let sold: [StoreProduct]
    init(products: [StoreProduct]) { sold = products }

    func products(for identifiers: Set<ProductID>) async throws -> [StoreProduct] { Task.isCancelled ? [] : sold }
    func currentEntitlements() async -> [TransactionSnapshot] { [] }
    func unfinished() async -> [TransactionSnapshot] { [] }
    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws -> GatewayPurchaseResult? { nil }
    func sync() async throws {}
    func updates() -> AsyncStream<TransactionSnapshot> { AsyncStream { $0.finish() } }
    func subscriptionStatuses(for group: SubscriptionGroupID) async throws -> [StatusSnapshot] { [] }
    func statusUpdates() -> AsyncStream<StatusSnapshot> { AsyncStream { $0.finish() } }
}

@Suite("App Store front", .timeLimit(.minutes(1)))
struct AppStoreFrontTests {
    private let gateway = FakeStoreKitGateway()
    private let log = Log()
    private var front: AppStoreFront { AppStoreFront(catalogue: catalogue, gateway: gateway, logger: log) }

    // MARK: - Reading

    /// Answering on the first match held for exactly as long as there was one product:
    /// a second one, listed after it, was never seen.
    @Test("the WHOLE listing is read: a product listed after the first match still counts")
    func wholeListing() async {
        gateway.state.withLock {
            $0.entitlements = [gateway.transaction(foreign), gateway.transaction(pro), gateway.transaction(trial)]
        }
        #expect(await front.ownedProducts().map(\.id) == [pro, trial])
    }

    @Test("what does not verify, what has been taken back and what is somebody else's are not counted")
    func notCounted() async {
        gateway.state.withLock {
            $0.entitlements = [
                gateway.transaction(foreign),
                gateway.transaction(trial, verification: .unverified),
                gateway.transaction(pro, isRevoked: true),
            ]
        }
        #expect(await front.ownedProducts().isEmpty)
    }

    /// The listing is where an owner whose transaction will not verify is locked out,
    /// and it was the one path that said nothing about it: buying and the updates
    /// stream both logged, reading did not, and the only trace was a diagnosis nobody
    /// had thought to run. Somebody else's product is *not* logged here — it is in the
    /// listing at every read, for good, and is no news.
    @Test("an entitlement that does not verify is LOGGED when the listing is read, not dropped in silence")
    func unverifiedListingIsLogged() async {
        gateway.state.withLock {
            $0.entitlements = [gateway.transaction(foreign), gateway.transaction(pro, verification: .unverified)]
        }
        #expect(await front.ownedProducts().isEmpty)
        #expect(log.events.withLock { $0 } == [.unverifiedTransactionIgnored(pro)])
    }

    @Test("reading what is owned FINISHES NOTHING")
    func readingHasNoSideEffects() async {
        gateway.state.withLock { $0.entitlements = [gateway.transaction(pro), gateway.transaction(foreign)] }
        _ = await front.ownedProducts()
        #expect(gateway.finished.isEmpty)
    }

    @Test("how a transaction was come by is carried through, so the core can refuse a shared trial")
    func ownershipCarried() async {
        gateway.state.withLock { $0.entitlements = [gateway.transaction(trial, ownership: .familyShared)] }
        #expect(await front.ownedProducts().map(\.ownership) == [.familyShared])
    }

    // MARK: - Buying

    @Test("a verified purchase is finished and handed back, dates and all")
    func purchase() async throws {
        let date = Date(timeIntervalSince1970: 42)
        gateway.state.withLock { $0.purchase = .success(.success(gateway.transaction(pro, date: date))) }
        let outcome = try await front.purchase(pro, confirmation: .automatic)
        #expect(outcome == .purchased(OwnedProduct(id: pro, originalPurchaseDate: date)))
        #expect(gateway.finished == [pro])
    }

    /// Reported as a cancellation, someone who has just paid is shown nothing at all.
    @Test("a purchase that does not verify is a FAILURE, never a cancellation, and is left unfinished")
    func unverified() async {
        gateway.state.withLock { $0.purchase = .success(.success(gateway.transaction(pro, verification: .unverified))) }
        await #expect(throws: PurchaseError.unverified) { try await front.purchase(pro, confirmation: .automatic) }
        #expect(gateway.finished.isEmpty)
        #expect(log.events.withLock { $0 } == [.unverifiedTransactionIgnored(pro)])
    }

    @Test("a purchase the store has already taken back is finished and refused")
    func revoked() async {
        gateway.state.withLock { $0.purchase = .success(.success(gateway.transaction(pro, isRevoked: true))) }
        await #expect(throws: PurchaseError.revoked) { try await front.purchase(pro, confirmation: .automatic) }
        #expect(gateway.finished == [pro])
    }

    @Test("Ask to Buy is pending; the person backing out is a cancellation")
    func pendingAndCancelled() async throws {
        gateway.state.withLock { $0.purchase = .success(.pending) }
        #expect(try await front.purchase(pro, confirmation: .automatic) == .pending)
        gateway.state.withLock { $0.purchase = .success(.userCancelled) }
        #expect(try await front.purchase(pro, confirmation: .automatic) == .cancelled)
    }

    /// It used to come out as a cancellation, which is answered with silence — the one
    /// answer that must never be given to someone who may have been charged.
    @Test("a result StoreKit has ADDED SINCE is a failure that gets said, never a cancellation")
    func unrecognisedResult() async {
        gateway.state.withLock { $0.purchase = .success(.unrecognised) }
        await #expect(throws: PurchaseError.unknown(typeName: "Product.PurchaseResult")) {
            try await front.purchase(pro, confirmation: .automatic)
        }
    }

    /// StoreKit reports a cancellation two ways. Handle only the returned one and the
    /// thrown one reads as "something went wrong" to someone who changed their mind.
    @Test("a cancellation that arrives THROWN is still a cancellation")
    func thrownCancellation() async throws {
        gateway.state.withLock { $0.purchase = .failure(StoreKitError.userCancelled) }
        #expect(try await front.purchase(pro, confirmation: .automatic) == .cancelled)
    }

    @Test("a product the store does not have, or the catalogue does not list, is unavailable")
    func unavailable() async {
        gateway.state.withLock { $0.purchase = .success(nil) }
        await #expect(throws: PurchaseError.productUnavailable) { try await front.purchase(pro, confirmation: .automatic) }
        await #expect(throws: PurchaseError.productUnavailable) { try await front.purchase(foreign, confirmation: .automatic) }
    }

    @Test("a failed purchase is thrown as its kind and nothing else")
    func purchaseFailure() async {
        gateway.state.withLock { $0.purchase = .failure(StoreKitError.networkError(URLError(.notConnectedToInternet))) }
        await #expect(throws: PurchaseError.network) { try await front.purchase(pro, confirmation: .automatic) }
    }

    // MARK: - Restoring, prices

    @Test("a restore completes; dismissing the sign-in prompt is a cancellation; anything else is thrown")
    func restore() async throws {
        #expect(try await front.restorePurchases() == .completed)
        gateway.state.withLock { $0.sync = StoreKitError.userCancelled }
        #expect(try await front.restorePurchases() == .cancelled)
        gateway.state.withLock { $0.sync = StoreKitError.networkError(URLError(.timedOut)) }
        await #expect(throws: PurchaseError.network) { try await front.restorePurchases() }
    }

    @Test("prices are the catalogue's only, and a failure is thrown as its kind")
    func products() async throws {
        let sold = StoreProduct(id: pro, displayName: "Pro", displayPrice: "£9.99", price: 9.99)
        let stray = StoreProduct(id: foreign, displayName: "Stray", displayPrice: "£1", price: 1)
        gateway.state.withLock { $0.products = .success([stray, sold]) }
        #expect(try await front.products() == [sold])
        gateway.state.withLock { $0.products = .failure(URLError(.timedOut)) }
        await #expect(throws: PurchaseError.network) { try await front.products() }
    }

    /// Nobody backs out of a price list. A request cancelled under the adapter must
    /// come out as a failure: as an empty list it would be an *answer*, and the answer
    /// "this store sells nothing" sends a developer to fix a scheme that is fine.
    @Test("a products request CANCELLED under the adapter is a failure, never an empty catalogue")
    func cancelledProductsRequest() async {
        gateway.state.withLock { $0.products = .failure(CancellationError()) }
        await #expect(throws: PurchaseError.system) { try await front.products() }
        gateway.state.withLock { $0.products = .failure(StoreKitError.userCancelled) }
        await #expect(throws: PurchaseError.system) { try await front.products() }
    }

    /// Measured against the real store: a cancelled request for products is answered
    /// with an empty list. So the adapter does not ask in its caller's task.
    @Test("a CANCELLED caller still gets the products, and a diagnosis that is true")
    func cancelledCaller() async throws {
        let sold = StoreProduct(id: pro, displayName: "Pro", displayPrice: "£9.99", price: 9.99)
        let gateway = CancellationSensitiveGateway(products: [sold])
        let front = AppStoreFront(catalogue: catalogue, gateway: gateway)
        let asked = Task { () -> ([StoreProduct]?, StoreDiagnosis) in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? await front.products(), await front.diagnose())
        }
        let (products, diagnosis) = await asked.value
        #expect(products == [sold])
        #expect(diagnosis.received == [pro])
        #expect(!diagnosis.hints.contains(.storeSellsNothingToThisBuild))
    }

    // MARK: - Updates

    /// A grant arrives before the store's listing has it, so it carries its own facts.
    @Test("an arriving transaction is finished and announced WITH ITS FACTS; a refund as a withdrawal")
    func updates() async {
        var updates = front.transactionUpdates().makeAsyncIterator()
        let date = Date(timeIntervalSince1970: 99)
        gateway.deliver(gateway.transaction(pro, ownership: .familyShared, date: date))
        gateway.deliver(gateway.transaction(trial, isRevoked: true))
        #expect(await updates.next() == .granted(OwnedProduct(id: pro, originalPurchaseDate: date, ownership: .familyShared)))
        #expect(await updates.next() == .withdrawn(trial))
        #expect(gateway.finished == [pro, trial])
    }

    /// Finishing takes a transaction off the store's redelivery queue for good, so
    /// finishing somebody else's means their own handler never sees it.
    @Test("a FOREIGN or unverified transaction is neither finished nor announced")
    func updatesLeftAlone() async {
        var updates = front.transactionUpdates().makeAsyncIterator()
        gateway.deliver(gateway.transaction(foreign))
        gateway.deliver(gateway.transaction(pro, verification: .unverified))
        gateway.deliver(gateway.transaction(trial))
        #expect(await updates.next()?.productID == trial)
        #expect(gateway.finished == [trial])
        #expect(log.events.withLock { $0 } == [.foreignTransactionIgnored(foreign), .unverifiedTransactionIgnored(pro)])
    }

    /// Apple says unfinished transactions are handed over once, as the app launches.
    /// This listener starts with the first command, which may be much later, and one
    /// started just after an unfinished purchase was measured to be handed nothing.
    @Test("what was left UNFINISHED before anyone listened is asked for, adopted and finished")
    func unfinishedBacklog() async {
        gateway.state.withLock {
            $0.unfinished = [gateway.transaction(pro), gateway.transaction(foreign), gateway.transaction(trial, isRevoked: true)]
        }
        var updates = front.transactionUpdates().makeAsyncIterator()
        #expect(await updates.next() == .granted(OwnedProduct(id: pro, originalPurchaseDate: Date(timeIntervalSince1970: 1_000_000))))
        #expect(await updates.next() == .withdrawn(trial))
        #expect(gateway.finished == [pro, trial])          // and somebody else's is left alone
        // …and the stream carries on with what arrives afterwards.
        gateway.deliver(gateway.transaction(trial))
        #expect(await updates.next()?.productID == trial)
    }

    // MARK: - Diagnosis

    @Test("a build the store sells nothing to is diagnosed as exactly that")
    func diagnosis() async {
        gateway.state.withLock { $0.entitlements = [gateway.transaction(foreign)] }
        let diagnosis = await front.diagnose()
        #expect(diagnosis.hints == [.storeSellsNothingToThisBuild])
        #expect(diagnosis.foreignEntitlements == 1)
        #expect(diagnosis.environment == "Xcode")
    }

    /// The failure used to be swallowed, and an offline Mac was told to attach a
    /// StoreKit configuration file to its scheme.
    @Test("a store that could NOT BE ASKED is not diagnosed as one that sells nothing")
    func diagnosisOffline() async {
        gateway.state.withLock { $0.products = .failure(StoreKitError.networkError(URLError(.notConnectedToInternet))) }
        let diagnosis = await front.diagnose()
        #expect(diagnosis.catalogueFailure == .network)
        #expect(diagnosis.hints == [.catalogueLoadFailed(.network)])
    }
}

@Suite("StoreKit error mapping")
struct StoreKitErrorMappingTests {
    private struct Surprise: Error {
        let secret = "account-12345"
    }

    @Test("each StoreKit error is reduced to which kind it was", arguments: [
        (StoreKitError.userCancelled, StoreKitErrorMapping.Verdict.cancelled),
        (.networkError(URLError(.timedOut)), .failure(.network)),
        (.systemError(URLError(.unknown)), .failure(.system)),
        (.notAvailableInStorefront, .failure(.notAvailableInStorefront)),
        (.notEntitled, .failure(.unsupported)),
        (.unknown, .failure(.unknown(typeName: "StoreKitError.unknown"))),
    ])
    func storeKitErrors(error: StoreKitError, expected: StoreKitErrorMapping.Verdict) {
        #expect(StoreKitErrorMapping.verdict(for: error) == expected)
    }

    @Test("each purchase error likewise", arguments: [
        (Product.PurchaseError.productUnavailable, PurchaseCore.PurchaseError.productUnavailable),
        (.purchaseNotAllowed, .purchaseNotAllowed),
        (.invalidQuantity, .system),
        (.ineligibleForOffer, .unsupported),
    ])
    func purchaseErrors(error: Product.PurchaseError, expected: PurchaseCore.PurchaseError) {
        #expect(StoreKitErrorMapping.verdict(for: error) == .failure(expected))
    }

    /// Some StoreKit errors echo account identifiers in their description.
    @Test("an unrecognised error crosses as its TYPE NAME, and nothing it contains comes with it")
    func privacy() {
        let verdict = StoreKitErrorMapping.verdict(for: Surprise())
        guard case let .failure(.unknown(typeName)) = verdict else {
            Issue.record("expected an unknown failure, got \(verdict)")
            return
        }
        #expect(typeName.hasSuffix("Surprise"))
        #expect(!typeName.contains("account-12345"))
    }

    // The case arrived with the 27 SDK and is matched by its *name*, so that the
    // adapter still compiles against the 26 one. A name is a string, and a string
    // that stops matching fails silently — into `.unknown`, losing the one error
    // that tells a developer their window anchor is wrong. Where the case can be
    // spelt, this pins it. 816 is StoreKit's module version in the 27.0 SDK.
    //
    // And where it can be *made*: the case is unavailable before the 27 releases, so on
    // an older OS this is skipped, and shows as skipped — returning early, it used to
    // report a pass having asserted nothing. `Demo/Tests` runs the same check in the
    // iOS 27 simulator, which is the one place here it actually executes.
    #if canImport(StoreKit, _version: 816)
    private static var isOn27: Bool { if #available(iOS 27.0, macOS 27.0, *) { true } else { false } }

    @Test("the presentation-context error, matched by NAME for the 26 SDK's sake, still matches", .enabled(if: isOn27))
    func invalidPresentationContext() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        #expect(
            StoreKitErrorMapping.verdict(for: StoreKitError.invalidPresentationContext)
                == .failure(.invalidConfirmation))
    }
    #endif

    @Test("a bare network error and a task cancellation are recognised too")
    func others() {
        #expect(StoreKitErrorMapping.verdict(for: URLError(.notConnectedToInternet)) == .failure(.network))
        #expect(StoreKitErrorMapping.verdict(for: CancellationError()) == .cancelled)
    }
}

@Suite("Ownership types")
struct OwnershipTypeTests {
    /// By raw value, so that the adapter compiles against the 26 SDK, which has the
    /// value and not the name. A raw value is a string, and a string that stops
    /// matching fails silently — an organisation's purchase would become `unrecognised`,
    /// and stop counting for an unlock that ignores Family Sharing.
    @Test("each of StoreKit's ownership types crosses as itself, and one it adds later as unrecognised")
    func mapping() {
        #expect(LiveStoreKitGateway.ownership(.purchased) == .purchased)
        #expect(LiveStoreKitGateway.ownership(.familyShared) == .familyShared)
        #expect(LiveStoreKitGateway.ownership(.init(rawValue: "ASSIGNED")) == .assigned)
        #expect(LiveStoreKitGateway.ownership(.init(rawValue: "SOMETHING_NEW")) == .unrecognised)
    }

    // Where the name can be spelt, check that it is still the value matched above.
    #if canImport(StoreKit, _version: 816)
    @Test("the 27 SDK's `.assigned` is the raw value the adapter matches")
    func assignedByName() {
        #expect(LiveStoreKitGateway.ownership(.assigned) == .assigned)
    }
    #endif
}

@Suite("Transaction triage")
struct TransactionTriageTests {
    private let gateway = FakeStoreKitGateway()

    @Test("foreign is decided FIRST: whether somebody else's transaction verifies is not our business")
    func foreignFirst() {
        let snapshot = gateway.transaction(foreign, verification: .unverified, isRevoked: true)
        #expect(TransactionTriage.verdict(for: snapshot, catalogue: catalogue) == .foreign)
    }

    @Test("then unverified, then withdrawn, and only then adopted")
    func order() {
        #expect(TransactionTriage.verdict(for: gateway.transaction(pro, verification: .unverified, isRevoked: true), catalogue: catalogue) == .unverified)
        #expect(TransactionTriage.verdict(for: gateway.transaction(pro, isRevoked: true), catalogue: catalogue) == .withdrawn)
        let date = Date(timeIntervalSince1970: 7)
        #expect(TransactionTriage.verdict(for: gateway.transaction(pro, date: date), catalogue: catalogue)
            == .adopt(OwnedProduct(id: pro, originalPurchaseDate: date)))
    }
}
