//
//  ManageSubscriptionsButton.swift
//  PurchaseUI
//
//  The way to Apple's own page for a subscription: change plan, cancel, see the renewal.
//
//  App Review expects an easy route to it, and it is where a cancellation happens — which
//  sends the app nothing at all, measured (spike/README.md). So when the person comes back
//  from it, the store reads again.
//
//  **iOS has a sheet and macOS does not.** `manageSubscriptionsSheet` and
//  `AppStore.showManageSubscriptions` are unavailable on the Mac, and Apple says not to
//  show the sheet in a Mac Catalyst app, or in an iPhone or iPad app running there, either
//  `[Apple]`. There, and on macOS, this opens Apple's subscriptions page in the App Store
//  instead, and "back" is the app becoming active again. Not the scene phase: a Mac window
//  left visible behind the App Store stays `.active` throughout, so a change of phase never
//  comes.
//

public import PurchaseCore
public import SwiftUI
import Combine
import Foundation
import StoreKit
// `manageSubscriptionsSheet` lives in the overlay that joins StoreKit to SwiftUI. Xcode loads
// it unasked when a file imports both; SwiftPM does not, so it is named.
import _StoreKit_SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Opens Apple's page for managing subscriptions, and reads the store again afterwards.
public struct ManageSubscriptionsButton<Label: View>: View {
    @Environment(\.purchaseCommands) private var commands
    @Environment(\.openURL) private var openURL
    /// Sent to the App Store, and not yet back.
    @State private var isAway = false
    @State private var isPresented = false

    private let group: SubscriptionGroupID?
    private let label: Label

    /// - Parameter group: the group to open the page at, where the platform can; nil for
    ///   every subscription the person has with the app.
    public init(group: SubscriptionGroupID? = nil, @ViewBuilder label: () -> Label) {
        self.group = group
        self.label = label()
    }

    /// Apple's page for managing subscriptions, where the platform has no sheet.
    public static var manageSubscriptionsURL: URL { URL(string: "https://apps.apple.com/account/subscriptions")! }

    /// Whether this runs where Apple's sheet may not be shown — on macOS, in a Mac Catalyst
    /// app, or as an iPhone or iPad app on a Mac — and so opens `manageSubscriptionsURL`
    /// instead. Catalyst is known when it is built, as Apple asks; an iPhone or iPad app on a
    /// Mac is the same binary as on iOS, so it is known only when it runs.
    static var opensThePage: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    public var body: some View {
        #if os(macOS)
        page
        #else
        if Self.opensThePage { page } else { sheet }
        #endif
    }

    private var page: some View {
        Button {
            isAway = true
            openURL(Self.manageSubscriptionsURL)
        } label: {
            label
        }
        // The App Store took the app's place in front; coming back is when anything changed
        // there is found.
        .onReceive(NotificationCenter.default.publisher(for: Self.becameActive)) { _ in
            guard isAway else { return }
            isAway = false
            refresh()
        }
    }

    private static var becameActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    #if !os(macOS)
    private var sheet: some View {
        Button {
            isPresented = true
        } label: {
            label
        }
        .modifier(ManageSheet(isPresented: $isPresented, group: group))
        .onChange(of: isPresented) { _, presented in
            if !presented { refresh() }
        }
    }
    #endif

    private func refresh() {
        guard let commands else { return }
        Task { await commands.refresh() }
    }
}

extension ManageSubscriptionsButton where Label == Text {
    public init(_ titleKey: LocalizedStringKey, group: SubscriptionGroupID? = nil) {
        self.init(group: group) { Text(titleKey) }
    }
}

#if !os(macOS)
/// In a `ViewModifier`, for the reason `purchaseStore(_:)`'s task is: a public function
/// returning `some View` built straight from SwiftUI's emitted-into-client modifiers has
/// failed to link in Release (docs/10-decisions.md, D25).
private struct ManageSheet: ViewModifier {
    @Binding var isPresented: Bool
    let group: SubscriptionGroupID?

    func body(content: Content) -> some View {
        if let group {
            content.manageSubscriptionsSheet(isPresented: $isPresented, subscriptionGroupID: group.rawValue)
        } else {
            content.manageSubscriptionsSheet(isPresented: $isPresented)
        }
    }
}
#endif
