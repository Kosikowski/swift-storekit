//
//  StoreMessages.swift
//  PurchaseUI
//
//  Apple's own messages — a price rise to agree to, a billing problem, a win-back offer —
//  shown when the app is ready for them.
//
//  StoreKit shows these sheets by itself, over whatever is on screen: in the middle of
//  onboarding, a game, a form half filled. An app may hold them back and show them later
//  (`Message.messages`, iOS only) `[Apple]`. When is the app's policy, so this is only the
//  mechanism: messages wait while the app says so, and are shown when it stops saying so
//  (`MessageQueue`). The Mac has no such messages `[Apple]`, and there this does nothing.
//
//  A view-layer StoreKit call, as the manage-subscriptions sheet is: a message can only be
//  shown by the view it reached, so it cannot be moved behind `PurchaseStoreKit`.
//
//  In a `ViewModifier`, for the reason `purchaseStore(_:)`'s task is: a public function
//  returning `some View` built straight from SwiftUI's emitted-into-client modifiers has
//  failed to link in Release (docs/10-decisions.md, D25).
//

public import SwiftUI
import StoreKit
// Where `\.displayStoreKitMessage` lives. Xcode loads this overlay unasked when a file
// imports both StoreKit and SwiftUI; SwiftPM does not, so it is named.
import _StoreKit_SwiftUI

/// Why StoreKit wants to show the person something.
public enum StoreMessageReason: Hashable, Sendable {
    /// A price rise that needs their consent, or the subscription lapses.
    case priceIncreaseConsent
    /// A renewal could not be charged.
    case billingIssue
    /// A win-back offer Apple says they may have.
    case winBackOffer
    case generic
    /// A reason StoreKit added later.
    case unrecognised
}

extension View {
    /// Holds back Apple's own messages while `isDeferred` is true, and shows them, in the
    /// order they came, once it is false. Apply it once, near the root.
    ///
    ///     ContentView()
    ///         .storeMessages(deferredWhile: model.isOnboarding)
    ///
    /// - Parameter showing: which reasons to show at all — say, not the win-back sheet, for
    ///   an app that shows its own win-back offers. A message not shown is not shown later.
    public func storeMessages(
        deferredWhile isDeferred: Bool, showing: @escaping @MainActor (StoreMessageReason) -> Bool = { _ in true }
    ) -> some View {
        modifier(StoreMessages(isDeferred: isDeferred, showing: showing))
    }
}

private struct StoreMessages: ViewModifier {
    let isDeferred: Bool
    let showing: @MainActor (StoreMessageReason) -> Bool

    #if os(iOS)
    @Environment(\.displayStoreKitMessage) private var display
    @Environment(\.scenePhase) private var scenePhase
    @State private var latest = Latest()

    func body(content: Content) -> some View {
        // A task started once reads the modifier it started with; these are read through
        // `latest` so that it sees what the app says now.
        latest.isDeferred = isDeferred
        latest.showing = showing
        latest.display = display
        return content
            .task {
                for await message in Message.messages where latest.showing(Self.reason(message.reason)) {
                    latest.queue.receive(message, deferred: latest.isDeferred, display: latest.show)
                }
            }
            .onChange(of: isDeferred) { _, deferred in
                if !deferred { latest.queue.release(display: latest.show) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !latest.isDeferred { latest.queue.release(display: latest.show) }
            }
    }
    #else
    func body(content: Content) -> some View {
        content
    }
    #endif

    #if os(iOS)
    @MainActor
    private final class Latest {
        var isDeferred = false
        var showing: @MainActor (StoreMessageReason) -> Bool = { _ in true }
        var display: DisplayMessageAction?
        var queue = MessageQueue<Message>()

        func show(_ message: Message) throws {
            guard let display else { throw CannotShow() }
            try display(message)
        }

        private struct CannotShow: Error {}
    }

    /// An open set, as every StoreKit one is (D40).
    private static func reason(_ reason: Message.Reason) -> StoreMessageReason {
        switch reason {
        case .priceIncreaseConsent: .priceIncreaseConsent
        case .billingIssue: .billingIssue
        case .winBackOffer: .winBackOffer
        case .generic: .generic
        default: .unrecognised
        }
    }
    #endif
}
