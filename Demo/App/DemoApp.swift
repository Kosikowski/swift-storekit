//
//  DemoApp.swift
//  Demo
//
//  The composition root is one line: `StoreLaunch.make(catalogue:)`.
//
//  **Decided by the build, not by an argument — and not decided here.** In a debug build
//  `-PurchaseScenario` chooses a simulated store and what it starts with; otherwise, and
//  always in a release build, the launch is on the App Store. That decision lives in
//  PurchaseLaunch, under an `#if DEBUG` of its own, reaching a simulator this app never
//  imports. So there is no `#if` about purchases in this app, and nothing imported that is
//  missing from a release build.
//
//      -PurchaseScenario "owns=trial@13d23h55m"       a trial with five minutes left
//      -PurchaseScenario "owns=pro"                   an owner
//      -PurchaseScenario "purchase=pending"           Ask to Buy
//      -PurchaseScenario "ownership=held"             the store has not answered
//

import PurchaseCore
import PurchaseDebugUI
import PurchaseLaunch
import PurchaseUI
import SwiftUI

@main
struct DemoApp: App {
    /// Hosting the integration tests, the app stays out of the way: its own store would
    /// listen for transactions too, and finish the ones the tests are waiting to see.
    private let launch: StoreLaunch? =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? StoreLaunch.make(catalogue: Shop.catalogue) : nil

    var body: some Scene {
        WindowGroup {
            if let launch {
                ContentView(launch: launch).purchaseStore(launch.store)
            } else {
                Text("Hosting tests")
            }
        }
        // A scene cannot be conditional, and in a release build this one would be an empty
        // window with a place in the Window menu. So this is the one `#if` the panel costs,
        // and it is the app's own: the panel itself compiles everywhere. `Window` scenes are
        // the Mac's; on iOS the panel is a sheet (ContentView), with no `#if` at all.
        #if DEBUG && os(macOS)
        Window("Purchases", id: "purchase-debug") {
            if let launch { PurchaseDebugPanel(launch) }
        }
        .defaultSize(width: 460, height: 760)
        #endif
    }
}
