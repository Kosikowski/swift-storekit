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
//  mechanism: messages wait while the app says so, and are shown when it stops saying so.
//  The Mac has no such messages `[Apple]`, and there this does nothing.
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
    @State private var waiting: [Message] = []
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .task {
                for await message in Message.messages {
                    guard showing(Self.reason(message.reason)) else { continue }
                    if isDeferred { waiting.append(message) } else { try? display(message) }
                }
            }
            .onChange(of: isDeferred) { _, deferred in
                guard !deferred else { return }
                let ready = waiting
                waiting = []
                for message in ready { try? display(message) }
            }
        #else
        content
        #endif
    }

    #if os(iOS)
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
