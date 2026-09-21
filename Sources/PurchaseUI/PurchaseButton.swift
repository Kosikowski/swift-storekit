//
//  PurchaseButton.swift
//  PurchaseUI
//
//  A button that buys one product, and tells only its caller what came of it.
//
//  It does two things a hand-written button tends not to.
//
//  **It says which window the purchase belongs to.** It hands the store SwiftUI's
//  `PurchaseAction` from its own environment — Apple's recommended route — so with
//  several windows open the payment sheet appears over the one that was clicked.
//
//  **It gives the result back, and publishes it nowhere.** Keep it in your own
//  `@State`. A result held in one shared flag is announced by every view watching
//  that flag: the paywall, the settings pane and a second window all raise the same
//  alert at once.
//
//  There is no wording in here, and no layout. What the label says, and what to say
//  when a purchase is pending, unverified or turns out to be a trial already used,
//  are the app's.
//

public import PurchaseCore
public import SwiftUI
import StoreKit
// Where `PurchaseAction` and `\.purchase` live. Xcode loads this overlay unasked when a
// file imports both StoreKit and SwiftUI; SwiftPM does not, so it is named.
import _StoreKit_SwiftUI

/// Buys a product.
///
///     @State private var result: Result<PurchaseCompletion, PurchaseError>?
///
///     PurchaseButton("com.example.pro") { result = $0 } label: {
///         Text("Buy Pro")
///     }
public struct PurchaseButton<Label: View>: View {
    @Environment(\.purchaseState) private var state
    @Environment(\.purchaseCommands) private var commands
    @Environment(\.purchase) private var purchaseAction

    private let id: ProductID
    private let options: PurchaseOptions
    private let onCompletion: @MainActor (Result<PurchaseCompletion, PurchaseError>) -> Void
    private let label: Label

    /// - Parameter options: how it is bought: an offer, a billing plan, an account token of
    ///   the app's own. The default is a plain purchase.
    public init(
        _ id: ProductID,
        options: PurchaseOptions = PurchaseOptions(),
        onCompletion: @escaping @MainActor (Result<PurchaseCompletion, PurchaseError>) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.id = id
        self.options = options
        self.onCompletion = onCompletion
        self.label = label()
    }

    public var body: some View {
        Button {
            guard let commands else { return }
            let confirmation = PurchaseConfirmation(anchor: purchaseAction)
            // Not `.task`: a purchase should not be abandoned because its button
            // scrolled out of sight while the payment sheet was up.
            Task {
                do throws(PurchaseError) {
                    onCompletion(.success(try await commands.purchase(id, options: options, confirmation: confirmation)))
                } catch {
                    onCompletion(.failure(error))
                }
            }
        } label: {
            label
        }
        // Disabled with no store above it, rather than a button that does nothing.
        .disabled(commands == nil || state?.activity.isBusy != false)
    }
}

extension PurchaseButton where Label == Text {
    public init(
        _ titleKey: LocalizedStringKey, buying id: ProductID, options: PurchaseOptions = PurchaseOptions(),
        onCompletion: @escaping @MainActor (Result<PurchaseCompletion, PurchaseError>) -> Void
    ) {
        self.init(id, options: options, onCompletion: onCompletion) { Text(titleKey) }
    }
}
