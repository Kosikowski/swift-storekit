//
//  AppleStoreViewUITests.swift
//  DemoUITests
//
//  Purchases made in Apple's own views, against real StoreKit.
//
//  Measured in the iOS simulator (spike/README.md, q12): an unlock bought in `ProductView`
//  is announced **nowhere** — not on `Transaction.updates`, and an unlock has no status.
//  The store hears of it only because the Demo hands it over from the view's completion
//  (`PurchaseStore.takePurchase(_:of:)`); take that line out and the first test fails,
//  with "Free" on screen. A subscription bought in `SubscriptionStoreView` is heard
//  either way, from the status updates, and the second test holds that to the real thing.
//
//  The only UI tests here that do not run on the simulated store: Apple's views buy from
//  StoreKit whatever store the app has. An `SKTestSession` made in this runner governs the
//  app under test — measured — so the environment starts clean and no sheet asks to be
//  confirmed. Labels as iOS gives them: `make ui-tests` runs in the iOS simulator.
//

import StoreKitTest
import XCTest

final class AppleStoreViewUITests: XCTestCase {
    @MainActor
    private func launch() throws -> (XCUIApplication, SKTestSession) {
        let session = try SKTestSession(configurationFileNamed: "Demo")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        let app = XCUIApplication()
        app.launch()
        app.buttons["apple-store"].tap()
        return (app, session)
    }

    @MainActor
    func testAnUnlockBoughtInProductViewIsSeenAtOnce() throws {
        let (app, session) = try launch()
        let buy = app.buttons.matching(NSPredicate(format: "label == '$19.99'")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 20), "Apple's view showed no price")
        buy.tap()
        let status = app.staticTexts["pro-status"]
        expectation(for: NSPredicate(format: "label == 'Pro'"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        withExtendedLifetime(session) {}
    }

    @MainActor
    func testAMembershipBoughtInSubscriptionStoreViewIsSeenAtOnce() throws {
        let (app, session) = try launch()
        let subscribe = app.buttons["Subscription Store View Button"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 20), "Apple's view showed no plans")
        subscribe.tap()
        // "Monthly member", or whichever plan the view had chosen: a member, at once.
        let status = app.staticTexts["membership-status"]
        let member = NSPredicate(format: "label CONTAINS 'member' AND NOT (label BEGINSWITH 'Not')")
        expectation(for: member, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        withExtendedLifetime(session) {}
    }
}
