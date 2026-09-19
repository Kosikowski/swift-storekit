//
//  LinksTheTestKit.swift
//  LinksTheTestKit
//
//  An app that links PurchaseTestKit, and uses nothing of it — which is what an app
//  that picked the wrong product from Xcode's list would do. `make demo` requires
//  that it does NOT build, and that the reason is the test kit: an app cannot link
//  a module that calls Swift Testing (docs/10-decisions.md, D34).
//
//  So this is a test, and its passing is a failed build. Nothing here is ever run.
//

import SwiftUI

@main
struct LinksTheTestKit: App {
    var body: some Scene {
        WindowGroup { Text(verbatim: "Never built") }
    }
}
