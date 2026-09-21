//
//  IntentProbe.swift
//  HostUITests
//
//  Phase 3: a purchase intent opened as the system opens one — a promoted in-app purchase
//  tapped on the App Store — with `XCUIDevice.shared.system.open(_:)`. Opened from inside
//  the app, nothing arrived on either platform. Prefixed `PROBE iNN`.
//

import StoreKitTest
import XCTest

final class IntentProbe: XCTestCase {
    @MainActor
    private func launch() throws -> (XCUIApplication, SKTestSession) {
        let session = try SKTestSession(configurationFileNamed: "Subscriptions")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        let app = XCUIApplication()
        app.launchArguments += ["-probe-intents"]
        app.launch()
        return (app, session)
    }

    @MainActor
    private func open(_ query: String) {
        let url = URL(string: "itms-services://?action=purchaseIntent&bundleId=spike.storekit.subscriptions.host&\(query)")!
        #if os(iOS)
        XCUIDevice.shared.system.open(url)
        print("PROBE: opened \(url)")
        #else
        print("PROBE: no system opener on this platform")
        #endif
    }

    @MainActor
    private func heard(_ app: XCUIApplication, _ question: String) {
        app.activate()
        let label = app.staticTexts["intents"]
        _ = label.waitForExistence(timeout: 10)
        let intents = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'probe.'"), object: label)
        let result = XCTWaiter().wait(for: [intents], timeout: 10)
        print("PROBE \(question): \(result == .completed ? "" : "NOTHING in 10 s; ")\(label.label)")
    }

    @MainActor
    func testI04Promoted() throws {
        let (app, session) = try launch()
        open("productIdentifier=probe.monthly")
        heard(app, "i04")
        withExtendedLifetime(session) {}
    }

    @MainActor
    func testI05WinBack() async throws {
        let (app, session) = try launch()
        let bought = try await session.buyProduct(identifier: "probe.monthly", options: [])
        try session.expireSubscription(productIdentifier: "probe.monthly")
        print("PROBE i05: bought #\(bought.originalID) and lapsed it")
        try await Task.sleep(for: .seconds(2))
        open("productIdentifier=probe.monthly&offerIdentifier=winback.three")
        heard(app, "i05")
        withExtendedLifetime(session) {}
    }
}
