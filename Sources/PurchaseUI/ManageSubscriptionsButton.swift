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
//  show the sheet in an iPad app running there either; on macOS this opens Apple's
//  subscriptions page in the App Store instead `[Apple]`.
//

public import PurchaseCore
public import SwiftUI
import StoreKit
// `manageSubscriptionsSheet` lives in the overlay that joins StoreKit to SwiftUI. Xcode loads
// it unasked when a file imports both; SwiftPM does not, so it is named.
import _StoreKit_SwiftUI

/// Opens Apple's page for managing subscriptions, and reads the store again afterwards.
public struct ManageSubscriptionsButton<Label: View>: View {
    @Environment(\.purchaseCommands) private var commands
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    /// Sent to the App Store, and not yet back.
    @State private var isAway = false
    #endif
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

    public var body: some View {
        #if os(macOS)
        Button {
            isAway = true
            openURL(Self.manageSubscriptionsURL)
        } label: {
            label
        }
        // The App Store took focus; coming back is when anything changed there is found.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isAway else { return }
            isAway = false
            refresh()
        }
        #else
        Button {
            isPresented = true
        } label: {
            label
        }
        .modifier(ManageSheet(isPresented: $isPresented, group: group))
        .onChange(of: isPresented) { _, presented in
            if !presented { refresh() }
        }
        #endif
    }

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
