//
//  ScenarioUITests.swift
//  DemoUITests
//
//  The app, launched already owning something — which is what a scenario is for. A UI
//  test cannot reach into the app, and should not tap its way to a trial with five
//  minutes left.
//
//  **Every test asserts the "Simulated store" badge first.** A scenario that does not
//  parse crashes the app; a scenario the *build cannot honour* — a test plan in a
//  Release configuration, where the simulated store does not exist — is silent: the
//  app runs on the real store, and the pictures are of the wrong thing.
//
//  XCTest, because UI testing has no Swift Testing equivalent. The argument is spelt
//  out rather than taken from `Scenario.launchArgument` so that this bundle needs
//  nothing from the package, and builds in any configuration — to fail, in the wrong
//  one, on the badge, with a sentence that says why.
//

import XCTest

final class ScenarioUITests: XCTestCase {
    @MainActor
    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-PurchaseScenario", scenario]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["simulated-store"].waitForExistence(timeout: 10),
            "Not on the simulated store. Is the Test action built in a configuration whose name begins with Debug?")
        return app
    }

    /// The status, once there is one. Until the store has answered the same identifier
    /// is on a spinner, which is not a static text — so a label read at once races it.
    @MainActor
    private func status(in app: XCUIApplication) -> String {
        let status = app.staticTexts["pro-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "The store never answered: no status was shown.")
        return status.label
    }

    @MainActor
    func testAnOwnerSeesPro() {
        let app = launch("owns=pro")
        XCTAssertEqual(status(in: app), "Pro")
    }

    @MainActor
    func testATrialNearlyOverSaysWhenItEnds() {
        let app = launch("owns=trial@13d23h55m")
        XCTAssertTrue(status(in: app).hasPrefix("Trial until"))
    }

    /// The state a person looks at for longest: the payment sheet is up. Both buttons
    /// must be out of reach for as long as it is.
    @MainActor
    func testWhileAPurchaseIsUnderWayNothingElseCanBeBought() {
        let app = launch("purchase=held")
        XCTAssertEqual(status(in: app), "Free")
        let buy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Buy Pro'")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        buy.tap()
        let disabled = NSPredicate(format: "isEnabled == false")
        expectation(for: disabled, evaluatedWith: buy)
        expectation(for: disabled, evaluatedWith: app.buttons["Start 14-day Trial"])
        waitForExpectations(timeout: 5)
    }
}
