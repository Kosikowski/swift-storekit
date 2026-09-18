//
//  DemoApp.swift
//  Demo
//

import PurchaseCore
import PurchaseUI
import SwiftUI

#if DEBUG
import PurchaseDebugUI
#endif

@main
struct DemoApp: App {
    /// Hosting the integration tests, the app stays out of the way: its own store would
    /// listen for transactions too, and finish the ones the tests are waiting to see.
    private let purchases: AppPurchases? =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? AppPurchases.forThisLaunch() : nil

    var body: some Scene {
        WindowGroup {
            if let purchases {
                #if DEBUG
                ContentView(debug: purchases).purchaseStore(purchases.store)
                #else
                ContentView().purchaseStore(purchases.store)
                #endif
            } else {
                Text("Hosting tests")
            }
        }
        // `Window` scenes are the Mac's. On iOS the panel is a sheet (ContentView).
        #if DEBUG && os(macOS)
        Window("Purchases", id: "purchase-debug") {
            if let purchases {
                PurchaseDebugPanel(
                    store: purchases.store, simulated: purchases.simulated,
                    diagnostics: purchases.diagnostics)
            }
        }
        .defaultSize(width: 460, height: 760)
        #endif
    }
}
