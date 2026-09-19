#if DEBUG

import Foundation
import PurchaseCore
import PurchaseTestKit
import PurchaseTestSupport
import Testing

private let pro: ProductID = "com.example.pro"
private let trial: ProductID = "com.example.trial"
private let fortnight: Duration = .seconds(14 * 86_400)
private let catalogue: Catalogue = [.unlock(pro), .trial(trial, of: [pro], lasting: fortnight)]

private func parse(_ text: String) throws(PurchaseTestKitError) -> Scenario {
    try Scenario(parsing: text, catalogue: catalogue)
}

/// As `Scenario.fromLaunchArguments`, with nothing of the real process in it.
private func launched(
    _ arguments: [String], environment: [String: String] = [:]
) throws(PurchaseTestKitError) -> Scenario? {
    try Scenario.fromLaunchArguments(arguments, environment: environment, catalogue: catalogue)
}

private func invalid(
    _ clause: String, _ fault: PurchaseTestKitError.ScenarioFault
) -> PurchaseTestKitError {
    .invalidScenario(clause: clause, reason: fault)
}

@Suite("Scenario", .timeLimit(.minutes(1)))
struct ScenarioTests {
    typealias Behaviour = SimulatedStoreFront.Behaviour
    typealias Fault = PurchaseTestKitError.ScenarioFault

    // MARK: - Clauses

    @Test("no clauses at all is a scenario: a store on a good day that owns nothing", arguments: [
        "", "   ", ";", " ; ;; ",
    ])
    func empty(text: String) throws {
        #expect(try parse(text) == Scenario())
        #expect(Scenario().behaviour == Behaviour())
    }

    @Test("owns= lists holdings, in the order written")
    func owns() throws {
        let scenario = try parse("owns=pro,trial@13d23h55m")
        #expect(scenario.owns == [.init(pro), .init(trial, age: fortnight - .seconds(300))])
        #expect(scenario.earlier.isEmpty)
    }

    @Test("earlier= lists what the account owns and THIS DEVICE has not heard of")
    func earlier() throws {
        let scenario = try parse("earlier=trial@20d/family")
        #expect(
            scenario.earlier == [.init(trial, age: .seconds(20 * 86_400), ownership: .familyShared)])
        #expect(scenario.owns.isEmpty)
    }

    @Test("purchase= scripts every ending a purchase has", arguments: [
        ("succeeds", Behaviour.PurchaseScript.succeeds), ("pending", .pending),
        ("cancelled", .cancelled), ("fails:unverified", .fails(.unverified)),
    ])
    func purchase(value: String, expected: Behaviour.PurchaseScript) throws {
        var behaviour = Behaviour()
        behaviour.purchase = expected
        #expect(try parse("purchase=\(value)") == Scenario(behaviour: behaviour))
    }

    @Test("restore= scripts every ending a restore has", arguments: [
        ("succeeds", Behaviour.RestoreScript.succeeds), ("cancelled", .cancelled),
        ("fails:network", .fails(.network)),
    ])
    func restore(value: String, expected: Behaviour.RestoreScript) throws {
        var behaviour = Behaviour()
        behaviour.restore = expected
        #expect(try parse("restore=\(value)") == Scenario(behaviour: behaviour))
    }

    @Test("catalogue= loads, fails, or loads NOTHING — which is loadsOnly([])", arguments: [
        ("loads", Behaviour.CatalogueScript.loads), ("empty", .loadsOnly([])),
        ("fails:system", .fails(.system)),
    ])
    func catalogueScript(value: String, expected: Behaviour.CatalogueScript) throws {
        var behaviour = Behaviour()
        behaviour.catalogue = expected
        #expect(try parse("catalogue=\(value)") == Scenario(behaviour: behaviour))
    }

    @Test("catalogue=held holds the catalogue and leaves its script alone")
    func catalogueHeld() throws {
        #expect(try parse("catalogue=held") == Scenario(holdsCatalogue: true))
    }

    @Test("purchase=held and restore=held hold them open and leave their scripts alone")
    func purchaseAndRestoreHeld() throws {
        #expect(try parse("purchase=held") == Scenario(holdsPurchase: true))
        #expect(try parse("restore=held") == Scenario(holdsRestore: true))
    }

    @Test("purchase= takes one outcome for everything, or one per product")
    func purchasePerProduct() throws {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.purchases = [pro: .pending, trial: .fails(.network)]
        #expect(try parse("purchase=pro:pending, trial:fails:network") == Scenario(behaviour: behaviour))
        #expect(throws: PurchaseTestKitError.invalidScenario(clause: "purchase=pro:pending,maybe", reason: .unknownValue("maybe"))) {
            try parse("purchase=pro:pending,maybe")
        }
        #expect(throws: PurchaseTestKitError.invalidScenario(clause: "purchase=trail:pending", reason: .unknownProduct("trail"))) {
            try parse("purchase=trail:pending")
        }
        #expect(throws: PurchaseTestKitError.invalidScenario(clause: "purchase=pro:pending,pro:succeeds", reason: .repeatedProduct(pro))) {
            try parse("purchase=pro:pending,pro:succeeds")
        }
    }

    @Test("unverified= lists products whose signatures do not check out")
    func unverified() async throws {
        #expect(try parse("unverified=pro") == Scenario(unverified: [pro]))
        #expect(throws: PurchaseTestKitError.invalidScenario(clause: "unverified=pro,,trial", reason: .unknownProduct(""))) {
            try parse("unverified=pro,,trial")
        }
        let store = store()
        store.apply(try parse("unverified=pro"))
        #expect(store.snapshot.unverified == [pro])
        #expect(await store.ownedProducts().isEmpty)
    }

    @Test("ownership= answers or is held")
    func ownership() throws {
        #expect(try parse("ownership=held") == Scenario(holdsOwnership: true))
        #expect(try parse("ownership=answers") == Scenario())
    }

    @Test("lag= is how many reads go by before a purchase is listed", arguments: [0, 1, 3])
    func lag(reads: Int) throws {
        var behaviour = Behaviour()
        behaviour.listsPurchasesAfterReads = reads
        #expect(try parse("lag=\(reads)") == Scenario(behaviour: behaviour))
    }

    @Test("every scriptable error has a name", arguments: [
        ("productUnavailable", PurchaseError.productUnavailable),
        ("purchaseNotAllowed", .purchaseNotAllowed),
        ("notAvailableInStorefront", .notAvailableInStorefront),
        ("network", .network), ("system", .system), ("unverified", .unverified),
        ("revoked", .revoked), ("unsupported", .unsupported),
    ])
    func errors(name: String, expected: PurchaseError) throws {
        let scenario = try parse(
            "purchase=fails:\(name); restore=fails:\(name); catalogue=fails:\(name)")
        #expect(scenario.behaviour.purchase == .fails(expected))
        #expect(scenario.behaviour.restore == .fails(expected))
        #expect(scenario.behaviour.catalogue == .fails(expected))
    }

    @Test("a holding says how it came to be held, and is PURCHASED unless it says", arguments: [
        ("pro", Ownership.purchased), ("pro/purchased", .purchased), ("pro/family", .familyShared),
        ("pro/assigned", .assigned), ("pro@3d/family", .familyShared),
    ])
    func ownerships(holding: String, expected: Ownership) throws {
        #expect(try parse("owns=\(holding)").owns.map(\.ownership) == [expected])
    }

    @Test("clauses combine, and a scenario written in code is the same value")
    func combined() throws {
        var behaviour = Behaviour()
        behaviour.purchase = .pending
        behaviour.catalogue = .loadsOnly([])
        behaviour.listsPurchasesAfterReads = 2
        let written = Scenario(
            owns: [.init(pro, ownership: .assigned)], earlier: [.init(trial, age: .seconds(3_600))],
            behaviour: behaviour, holdsOwnership: true)
        let parsed = try parse(
            "owns=pro/assigned;earlier=trial@1h;purchase=pending;catalogue=empty;lag=2;ownership=held")
        #expect(parsed == written)
    }

    // MARK: - Products

    @Test("a product goes by its full identifier or by its LAST COMPONENT")
    func shortNames() throws {
        #expect(try parse("owns=pro") == parse("owns=com.example.pro"))
        #expect(try parse("owns=trial").owns.map(\.id) == [trial])
    }

    @Test("a full identifier WINS over a short name that matches something else")
    func fullWins() throws {
        let both: Catalogue = [.unlock("com.example.pro"), .unlock("pro")]
        #expect(try Scenario(parsing: "owns=pro", catalogue: both).owns.map(\.id) == ["pro"])
    }

    @Test("a short name that fits TWO products is an error listing both; in full it is fine")
    func ambiguous() throws {
        let two: Catalogue = [.unlock("com.example.pro"), .unlock("com.other.pro")]
        let expected = invalid(
            "owns=pro", .ambiguousProduct("pro", matches: ["com.example.pro", "com.other.pro"]))
        #expect(throws: expected) { try Scenario(parsing: "owns=pro", catalogue: two) }
        let full = try Scenario(parsing: "owns=com.other.pro", catalogue: two)
        #expect(full.owns.map(\.id) == ["com.other.pro"])
    }

    @Test("a product the catalogue does not have is an error, ONE LETTER OUT or not", arguments: [
        "trail", "com.example.trail", "example.pro", "com.example", "PRO",
    ])
    func unknownProduct(name: String) {
        #expect(throws: invalid("owns=\(name)", .unknownProduct(name))) { try parse("owns=\(name)") }
    }

    // MARK: - Ages

    @Test("an age is how long AGO, in days, hours, minutes and seconds, added up", arguments: [
        ("0s", 0), ("90s", 90), ("5m", 300), ("2h", 7_200), ("1d", 86_400),
        ("13d23h55m", 14 * 86_400 - 300), ("1h30m15s", 5_415), ("5m5m", 600), ("1m1d", 86_460),
        ("007d", 7 * 86_400),
    ])
    func ages(text: String, seconds: Int) throws {
        #expect(try parse("owns=trial@\(text)").owns == [.init(trial, age: .seconds(seconds))])
    }

    @Test("with no age at all, it was bought just now")
    func noAge() throws {
        #expect(try parse("owns=trial").owns.map(\.age) == [.zero])
    }

    @Test("an age that is not one is an error, INCLUDING ONE TOO LARGE TO COUNT", arguments: [
        "", "13", "d", "3w", "1d 2h", "1.5d", "-1d", "12h30", "٣d",
        "99999999999999999999d", "9223372036854775807d", "9223372036854775807s1s",
    ])
    func badAges(text: String) {
        #expect(throws: invalid("owns=trial@\(text)", .invalidAge(text))) {
            try parse("owns=trial@\(text)")
        }
    }

    // MARK: - Errors

    @Test("a bad token is an error NAMING THE CLAUSE it is in", arguments: [
        ("owned=pro", "owned=pro", Fault.unknownClause),
        ("Owns=pro", "Owns=pro", .unknownClause),
        ("pending", "pending", .unknownClause),
        ("=pro", "=pro", .unknownClause),
        ("owns=", "owns=", .missingValue),
        ("purchase= ", "purchase=", .missingValue),
        ("purchase=maybe", "purchase=maybe", .unknownValue("maybe")),
        ("purchase=Succeeds", "purchase=Succeeds", .unknownValue("Succeeds")),
        ("restore=pending", "restore=pending", .unknownValue("pending")),
        ("catalogue=answers", "catalogue=answers", .unknownValue("answers")),
        ("ownership=loads", "ownership=loads", .unknownValue("loads")),
        ("ownership=fails:network", "ownership=fails:network", .unknownValue("fails:network")),
        ("purchase=fails:gremlins", "purchase=fails:gremlins", .unknownError("gremlins")),
        ("restore=fails:unknown", "restore=fails:unknown", .unknownError("unknown")),
        ("restore=fails:", "restore=fails:", .unknownError("")),
        ("lag=soon", "lag=soon", .invalidLag("soon")),
        ("lag=-1", "lag=-1", .invalidLag("-1")),
        ("lag=1.5", "lag=1.5", .invalidLag("1.5")),
        ("lag=99999999999999999999", "lag=99999999999999999999",
         .invalidLag("99999999999999999999")),
        ("owns=pro,,trial", "owns=pro,,trial", .unknownProduct("")),
        ("owns=pro/borrowed", "owns=pro/borrowed", .unknownOwnership("borrowed")),
        ("owns=pro/family@3d", "owns=pro/family@3d", .unknownOwnership("family@3d")),
        ("owns=pro/", "owns=pro/", .unknownOwnership("")),
        // Among several clauses, the one named is the one at fault — as written, less
        // the whitespace round it.
        ("owns=pro;  purchase = maybe ;lag=2", "purchase = maybe", .unknownValue("maybe")),
        ("lag=2;owns=trial@13", "owns=trial@13", .invalidAge("13")),
    ])
    func badTokens(text: String, clause: String, fault: Fault) {
        #expect(throws: invalid(clause, fault)) { try parse(text) }
    }

    @Test("a key given TWICE is an error on the second, even if both say the same")
    func repeatedKey() {
        #expect(throws: invalid("purchase=succeeds", .repeatedClause)) {
            try parse("purchase=pending;purchase=succeeds")
        }
        #expect(throws: invalid("owns=trial", .repeatedClause)) { try parse("owns=pro;owns=trial") }
    }

    @Test("a product held TWICE is an error on the clause that brought the second", arguments: [
        ("owns=pro,com.example.pro", "owns=pro,com.example.pro"),
        ("owns=pro;earlier=trial,pro", "earlier=trial,pro"),
        ("earlier=pro;lag=1;owns=pro", "owns=pro"),
    ])
    func repeatedProduct(text: String, clause: String) {
        #expect(throws: invalid(clause, .repeatedProduct(pro))) { try parse(text) }
    }

    @Test("an error reads as a sentence with the clause in it")
    func errorDescription() {
        #expect(
            invalid("owns=trail", .unknownProduct("trail")).description
                == #"Invalid scenario clause "owns=trail": no product in the catalogue is called "trail"."#)
    }

    @Test("whitespace round ANY token is ignored, and so are empty clauses")
    func whitespace() throws {
        let spaced = try parse(
            "  owns = pro , trial @ 13d23h55m / family ;; \t lag = 2 ;\n purchase = fails: network ; ")
        let tight = try parse("owns=pro,trial@13d23h55m/family;lag=2;purchase=fails:network")
        #expect(spaced == tight)
        #expect(tight.owns.count == 2)
        #expect(tight.behaviour.purchase == .fails(.network))
    }

    // MARK: - Launch arguments

    @Test("the scenario follows -PurchaseScenario among the arguments")
    func argument() throws {
        let scenario = try launched(["/App", "-AppleLanguages", "(en)", "-PurchaseScenario", "owns=pro"])
        #expect(scenario == Scenario(owns: [.init(pro)]))
    }

    @Test("failing that, it is read from PURCHASE_SCENARIO")
    func environment() throws {
        let scenario = try launched(
            ["/App"], environment: ["PATH": "/usr/bin", "PURCHASE_SCENARIO": "owns=trial"])
        #expect(scenario == Scenario(owns: [.init(trial)]))
    }

    @Test("the ARGUMENT WINS when both are there")
    func precedence() throws {
        let scenario = try launched(
            ["/App", "-PurchaseScenario", "owns=pro"], environment: ["PURCHASE_SCENARIO": "owns=trial"])
        #expect(scenario == Scenario(owns: [.init(pro)]))
    }

    @Test("with neither there is NO scenario, which is not the same as an empty one")
    func absent() throws {
        #expect(try launched(["/App", "owns=pro"], environment: ["HOME": "/"]) == nil)
        #expect(try launched([]) == nil)
        #expect(try launched(["/App", "-PurchaseScenario", ""]) == Scenario())
        #expect(try launched([], environment: ["PURCHASE_SCENARIO": ""]) == Scenario())
    }

    @Test("one that is present and invalid THROWS: no falling back to the environment, or to nil")
    func presentButInvalid() {
        let expected = invalid("owns=trail", .unknownProduct("trail"))
        #expect(throws: expected) {
            try launched(
                ["/App", "-PurchaseScenario", "owns=trail"],
                environment: ["PURCHASE_SCENARIO": "owns=trial"])
        }
        #expect(throws: expected) {
            try launched(["/App"], environment: ["PURCHASE_SCENARIO": "owns=trail"])
        }
    }

    @Test("-PurchaseScenario as the LAST argument, with nothing after it, is an error")
    func flagWithoutText() {
        #expect(throws: invalid("-PurchaseScenario", .missingValue)) {
            try launched(["/App", "-PurchaseScenario"], environment: ["PURCHASE_SCENARIO": "owns=trial"])
        }
    }

    @Test("the names it looks for are the ones it publishes")
    func names() {
        #expect(Scenario.launchArgument == "-PurchaseScenario")
        #expect(Scenario.environmentVariable == "PURCHASE_SCENARIO")
    }

    // MARK: - Applying

    private let clock = ManualClock()

    private func store() -> SimulatedStoreFront {
        SimulatedStoreFront(catalogue: catalogue, clock: clock)
    }

    @Test("owns=trial@13d23h55m is a fortnight's trial with EXACTLY FIVE MINUTES LEFT, by the STORE'S clock")
    func fiveMinutesLeft() async throws {
        let scenario = try parse("owns=trial@13d23h55m")
        // Parsed a day before it is applied. The age is resolved on applying.
        clock.advance(by: .seconds(86_400))
        let store = store()
        store.apply(scenario)

        let owned = await store.ownedProducts()
        #expect(owned.map(\.id) == [trial])
        let terms = try #require(catalogue.entry(for: trial)?.trialTerms)
        let period = terms.period(startingAt: try #require(owned.first).originalPurchaseDate)
        #expect(period.endsAt == clock.now.addingTimeInterval(300))
        #expect(period.isRunning(at: clock.now))
        clock.advance(by: .seconds(300))
        #expect(!period.isRunning(at: clock.now))
    }

    @Test("holdings are seeded with their age AND how they came to be held")
    func seedsOwnership() async throws {
        let store = store()
        store.apply(try parse("owns=pro@2d/family"))
        let expected = OwnedProduct(
            id: pro, originalPurchaseDate: clock.now.addingTimeInterval(-2 * 86_400),
            ownership: .familyShared)
        #expect(await store.ownedProducts() == [expected])
    }

    @Test("earlier purchases are NOT listed until a restore brings them here, age and ownership intact")
    func seedsEarlier() async throws {
        let store = store()
        store.apply(try parse("earlier=pro@30d/assigned"))
        let expected = OwnedProduct(
            id: pro, originalPurchaseDate: clock.now.addingTimeInterval(-30 * 86_400),
            ownership: .assigned)
        #expect(store.snapshot.earlier == [expected])
        #expect(await store.ownedProducts().isEmpty)
        #expect(try await store.restorePurchases() == .completed)
        #expect(await store.ownedProducts() == [expected])
    }

    @Test("the behaviour is applied: a scripted failure fails, and lag=0 lists at once")
    func appliesBehaviour() async throws {
        let failing = store()
        let scenario = try parse("purchase=fails:network;restore=cancelled;catalogue=empty")
        failing.apply(scenario)
        #expect(failing.behaviour == scenario.behaviour)
        await #expect(throws: PurchaseError.network) {
            try await failing.purchase(pro, confirmation: .automatic)
        }
        #expect(try await failing.restorePurchases() == .cancelled)
        #expect(try await failing.products().isEmpty)

        let prompt = store()
        prompt.apply(try parse("lag=0"))
        _ = try await prompt.purchase(pro, confirmation: .automatic)
        #expect(await prompt.ownedProducts().map(\.id) == [pro])
    }

    @Test("held gates are ACTUALLY CLOSED: the answer waits until the gate is opened")
    func holdsGates() async throws {
        let store = store()
        store.apply(try parse("owns=pro;ownership=held;catalogue=held"))
        #expect(!store.ownershipGate.isOpen)
        #expect(!store.catalogueGate.isOpen)

        let owned = Task { await store.ownedProducts().map(\.id) }
        let prices = Task { try? await store.products().count }
        await waitUntil { store.ownershipGate.waiterCount == 1 && store.catalogueGate.waiterCount == 1 }
        #expect(store.ownershipGate.waiterCount == 1)
        #expect(store.catalogueGate.waiterCount == 1)
        store.ownershipGate.open()
        store.catalogueGate.open()
        #expect(await owned.value == [pro])
        #expect(await prices.value == 2)
    }

    /// The payment sheet being up is the state a person looks at for longest, and it
    /// could not be held: the only way to a "Purchasing…" screenshot was to hold the
    /// *ownership* gate and catch the purchase in the read that follows it.
    @Test("purchase=held keeps a purchase UNDER WAY until the gate opens, and restore=held a restore")
    func holdsPurchaseAndRestore() async throws {
        let store = store()
        store.apply(try parse("purchase=held;restore=held"))
        let bought = Task { try await store.purchase(pro, confirmation: .automatic) }
        let restored = Task { try await store.restorePurchases() }
        await waitUntil { store.purchaseGate.waiterCount == 1 && store.restoreGate.waiterCount == 1 }
        #expect(store.purchaseGate.waiterCount == 1)
        #expect(store.restoreGate.waiterCount == 1)
        #expect(store.snapshot.unlisted.isEmpty)

        // Decided when it is let go: the person backs out of the sheet.
        store.behaviour.purchase = .cancelled
        store.purchaseGate.open()
        store.restoreGate.open()
        #expect(try await bought.value == .cancelled)
        #expect(try await restored.value == .completed)
    }

    @Test("each gate is held only if the scenario holds IT, and a gate it does not hold is left alone")
    func leavesGates() throws {
        let open = store()
        open.apply(try parse("owns=pro"))
        #expect(open.ownershipGate.isOpen)
        #expect(open.catalogueGate.isOpen)

        let one = store()
        one.apply(try parse("catalogue=held"))
        #expect(one.ownershipGate.isOpen)
        #expect(!one.catalogueGate.isOpen)

        let closedByTheTest = store()
        closedByTheTest.ownershipGate.close()
        closedByTheTest.apply(try parse("ownership=answers"))
        #expect(!closedByTheTest.ownershipGate.isOpen)
    }

    @Test("applying ADDS to what the store holds, replacing only the same product")
    func adds() async throws {
        let store = store()
        store.seed(pro, age: .seconds(60))
        store.seed(trial, age: .seconds(60))
        store.apply(try parse("owns=trial@2d"))
        let owned = await store.ownedProducts()
        #expect(owned.map(\.id) == [pro, trial])
        #expect(owned.last?.originalPurchaseDate == clock.now.addingTimeInterval(-2 * 86_400))
    }
}

#endif
