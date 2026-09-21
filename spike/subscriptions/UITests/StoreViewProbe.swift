//
//  StoreViewProbe.swift
//  HostUITests
//
//  q12 of docs/14-subscriptions-plan.md: a purchase made through Apple's own views —
//  `SubscriptionStoreView`, and `ProductView` for a one-time unlock — pressed as a person
//  presses it. Does it reach `Transaction.updates`, `Status.updates`, the listing, the
//  view's completion — and is it finished?
//
//  The host shows what reached it (HostApp.swift); this presses the button, confirms the
//  sheet, and prints what the host says, prefixed `PROBE q12`. It asserts only that a
//  purchase happened at all, since what reached the app is the question.
//

import StoreKitTest
import XCTest

final class StoreViewProbe: XCTestCase {
    @MainActor
    func testWithoutCompletion() throws {
        try probe("-probe-storeview", "q12a")
    }

    @MainActor
    func testWithCompletion() throws {
        try probe("-probe-storeview-completion", "q12b")
    }

    /// A one-time unlock bought in `ProductView`: is anything announced at all?
    @MainActor
    func testProductView() throws {
        try probe("-probe-productview", "q12c", product: "probe.unlock")
    }

    @MainActor
    private func probe(_ argument: String, _ question: String, product: String = "probe.plain") throws {
        // Whether a session made here reaches the app under test is itself a question:
        // if it does, the environment is clean and there is no sheet to confirm.
        let session = try? SKTestSession(configurationFileNamed: "Subscriptions")
        session?.resetToDefaultState()
        session?.clearTransactions()
        session?.disableDialogs = true
        print("PROBE \(question): runner session \(session == nil ? "not made" : "made")")

        let app = XCUIApplication()
        app.launchArguments += [argument]
        app.launch()

        let subscribe = product == "probe.plain"
            ? app.buttons["Subscription Store View Button"]
            : app.buttons.matching(NSPredicate(format: "label CONTAINS '9.99'")).firstMatch
        guard subscribe.waitForExistence(timeout: 20) else {
            print("PROBE \(question): no subscribe button. Hierarchy:\n\(app.debugDescription)")
            XCTFail("no subscribe button")
            return
        }
        print("PROBE \(question): pressing '\(subscribe.label)'")
        subscribe.tap()
        let pressed = Date()

        // The payment sheet, if there is one: in the app, or drawn by the system over it.
        #if os(iOS)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        #else
        let system = app
        #endif
        let confirm = NSPredicate(format: "label IN {'Subscribe', 'Confirm', 'Purchase', 'Buy', 'OK', 'Done'}")
        for _ in 0 ..< 3 {
            let inApp = app.buttons.matching(confirm).firstMatch
            let inSystem = system.buttons.matching(confirm).firstMatch
            if inSystem.waitForExistence(timeout: 4) {
                print("PROBE \(question): confirming '\(inSystem.label)' in the system sheet at \(elapsed(pressed))")
                inSystem.tap()
            } else if inApp.exists, inApp.label != subscribe.label {
                print("PROBE \(question): confirming '\(inApp.label)' in the app at \(elapsed(pressed))")
                inApp.tap()
            }
        }

        let updates = app.staticTexts["updates"]
        let listed = app.staticTexts["listed"]
        // A static text's string is its label on iOS and its value on the Mac.
        let bought = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", product, product)
        let heard = XCTNSPredicateExpectation(predicate: bought, object: listed)
        let result = XCTWaiter().wait(for: [heard], timeout: 15)
        print("PROBE \(question): listed \(result == .completed ? "by \(elapsed(pressed))" : "NEVER, in 15 s")")
        if result != .completed { print("PROBE \(question): hierarchy:\n\(app.debugDescription)") }
        // Then long enough for anything slower than the listing to arrive too.
        Thread.sleep(forTimeInterval: 5)
        for text in [
            updates, app.staticTexts["statuses"], app.staticTexts["completions"], listed,
            app.staticTexts["first-listed"], app.staticTexts["unfinished"],
        ] {
            print("PROBE \(question): \((text.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.label)")
        }
        XCTAssertEqual(result, .completed, "no purchase was made: nothing to measure")
        withExtendedLifetime(session) {}
    }

    private func elapsed(_ since: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(since))
    }
}
