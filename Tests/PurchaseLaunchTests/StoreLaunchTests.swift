import Foundation
import PurchaseCore
import PurchaseLaunch
import PurchaseTestKit
import Testing

private let pro: ProductID = "com.example.pro"
private let trial: ProductID = "com.example.trial"
private let catalogue: Catalogue = [.unlock(pro), .trial(trial, of: [pro], lasting: .seconds(14 * 86_400))]

/// A store in which everything is owned, to tell the live path from the simulated one
/// without asking the App Store anything.
private struct OwnsPro: StoreFront {
    func products() async throws(PurchaseError) -> [StoreProduct] { [] }
    func ownedProducts() async -> [OwnedProduct] { [OwnedProduct(id: pro, originalPurchaseDate: .distantPast)] }
    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome { .cancelled }
    func restorePurchases() async throws(PurchaseError) -> RestoreOutcome { .completed }
    func transactionUpdates() -> AsyncStream<TransactionUpdate> { AsyncStream { _ in } }
}

/// What an app gets by calling one function, in whatever configuration this is built. The
/// first suite holds in every build; the second only where there is a simulator to choose.
@MainActor
@Suite("The store for this launch", .timeLimit(.minutes(1)))
struct StoreLaunchTests {
    @Test("with NO scenario the launch is on the live store, and says it is not simulated")
    func live() async {
        let launch = StoreLaunch.make(catalogue: catalogue, live: { _, _ in OwnsPro() }, arguments: [], environment: [:])
        #expect(!launch.isSimulated)
        #expect(await launch.store.knownStanding().access(to: pro).isGranted == true)
    }

    @Test("the logger is handed to whoever makes the live store, as well as to the store")
    func loggerReachesTheFront() async {
        let log = RecordingPurchaseLogger()
        var handed: (any PurchaseLogging)?
        let launch = StoreLaunch.make(
            catalogue: catalogue, logger: log, live: { _, logger in handed = logger; return OwnsPro() },
            arguments: [], environment: [:])
        #expect(handed is RecordingPurchaseLogger)
        await launch.store.start()
        #expect(log.events.contains(.standingResolved(owned: [pro])))
    }

    #if DEBUG
    @Test("a scenario chooses a SIMULATED store and what it starts with, by argument or by environment")
    func scenario() async {
        let byArgument = StoreLaunch.make(
            catalogue: catalogue, live: { _, _ in OwnsPro() },
            arguments: ["App", "-PurchaseScenario", "owns=trial@13d23h55m"], environment: [:])
        #expect(byArgument.isSimulated)
        let standing = await byArgument.store.knownStanding()
        guard case .onTrial = standing.access(to: pro, at: .now) else {
            Issue.record("expected the trial to lend Pro, got \(standing.access(to: pro, at: .now))")
            return
        }

        let byEnvironment = StoreLaunch.make(
            catalogue: catalogue, live: { _, _ in OwnsPro() }, arguments: [], environment: ["PURCHASE_SCENARIO": ""])
        #expect(byEnvironment.isSimulated)
        #expect(await byEnvironment.store.knownStanding().access(to: pro).isGranted == false)
    }

    @Test("a preview's store is arranged by a scenario's text, and names nothing a release build lacks")
    func preview() async {
        let store = StoreLaunch.preview(catalogue: catalogue, scenario: "owns=pro")
        #expect(await store.knownStanding().access(to: pro).isGranted == true)
        #expect(await StoreLaunch.preview(catalogue: catalogue).knownStanding().access(to: pro).isGranted == false)
    }
    #else
    /// The point of the whole arrangement: in a release build an argument has nothing to
    /// switch on. On macOS anyone can pass a shipped app launch arguments.
    @Test("in a RELEASE build a scenario is not honoured, however it is passed")
    func releaseIgnoresScenarios() async {
        let launch = StoreLaunch.make(
            catalogue: catalogue, live: { _, _ in OwnsPro() },
            arguments: ["App", "-PurchaseScenario", "owns=nothing-that-parses!!"], environment: ["PURCHASE_SCENARIO": "owns=pro"])
        #expect(!launch.isSimulated)
        #expect(await StoreLaunch.preview(catalogue: catalogue, scenario: "owns=pro").knownStanding().access(to: pro).isGranted == false)
    }
    #endif
}
