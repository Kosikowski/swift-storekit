//
//  RestorePurchasesButton.swift
//  PurchaseUI
//
//  The Restore Purchases button App Review expects to find.
//
//  On the paywall *and* somewhere in settings. It is rarely needed — the store keeps
//  itself up to date — but one case does need it: a non-consumable whose Family
//  Sharing was switched on after it was bought reaches the rest of the family only
//  through a restore. It asks for a password, so it is never pressed for the person.
//

public import PurchaseCore
public import SwiftUI

/// Restores purchases, and tells only its caller what came of it.
public struct RestorePurchasesButton<Label: View>: View {
    @Environment(\.purchaseState) private var state
    @Environment(\.purchaseCommands) private var commands

    private let onCompletion: @MainActor (Result<RestoreOutcome, PurchaseError>) -> Void
    private let label: Label

    public init(
        onCompletion: @escaping @MainActor (Result<RestoreOutcome, PurchaseError>) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.onCompletion = onCompletion
        self.label = label()
    }

    public var body: some View {
        Button {
            guard let commands else { return }
            Task {
                do throws(PurchaseError) {
                    onCompletion(.success(try await commands.restorePurchases()))
                } catch {
                    onCompletion(.failure(error))
                }
            }
        } label: {
            label
        }
        .disabled(commands == nil || state?.activity.isBusy != false)
    }
}

extension RestorePurchasesButton where Label == Text {
    public init(
        _ titleKey: LocalizedStringKey,
        onCompletion: @escaping @MainActor (Result<RestoreOutcome, PurchaseError>) -> Void
    ) {
        self.init(onCompletion: onCompletion) { Text(titleKey) }
    }
}
