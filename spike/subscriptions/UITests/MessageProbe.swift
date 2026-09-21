//
//  MessageProbe.swift
//  HostUITests
//
//  Phase 3: StoreKit's messages — a price rise to agree to — which an app may hold back and
//  show when it is ready (`Message.messages`, iOS only). Does a price-increase consent asked
//  for through the runner's session reach the app as one? Prefixed `PROBE m`.
//

import StoreKitTest
import XCTest

final class MessageProbe: XCTestCase {
    #if os(iOS)
    @MainActor
    func testM01PriceIncrease() async throws {
        let session = try SKTestSession(configurationFileNamed: "Subscriptions")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        let app = XCUIApplication()
        app.launchArguments += ["-probe-messages"]
        app.launch()
        let label = app.staticTexts["messages"]
        _ = label.waitForExistence(timeout: 10)
        for attempt in 1 ... 3 where session.allTransactions().isEmpty {
            do {
                _ = try await session.buyProduct(identifier: "probe.monthly", options: [])
            } catch {
                print("PROBE m01: buyProduct, attempt \(attempt), threw \(error)")
                try await Task.sleep(for: .seconds(2))
            }
        }
        guard let bought = session.allTransactions().filter({ $0.productIdentifier == "probe.monthly" }).max(by: { $0.identifier < $1.identifier })
        else {
            print("PROBE m01: nothing bought: \(label.label)")
            return
        }
        print("PROBE m01: bought #\(bought.identifier)")
        do {
            try session.requestPriceIncreaseConsentForTransaction(identifier: bought.identifier)
            print("PROBE m01: consent requested")
        } catch {
            print("PROBE m01: consent request threw \(error)")
        }
        let heard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'reason'"), object: label)
        let result = await XCTWaiter().fulfillment(of: [heard], timeout: 15)
        print("PROBE m01: \(result == .completed ? "" : "NOTHING in 15 s; ")\(label.label)")
        withExtendedLifetime(session) {}
    }
    #endif
}
