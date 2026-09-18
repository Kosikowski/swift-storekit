//
//  PurchaseConfirmation.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  Where the payment sheet should appear, without this module knowing what a window is.
//
//  StoreKit wants to be told which window, scene or view controller a purchase is
//  being confirmed over; with several windows open it otherwise has to guess. Those
//  are AppKit, UIKit and SwiftUI types, and this module imports none of them. So the
//  anchor crosses the boundary type-erased: the view that starts a purchase puts it
//  in, the StoreKit adapter takes it out, and a store that shows no sheet — the
//  simulated one — never looks.
//
//  `NSWindow`, `UIViewController`, `UIScene` and SwiftUI's `PurchaseAction` are all
//  `Sendable` (main-actor classes are, implicitly), so nothing here is unchecked.
//

/// Where a purchase is confirmed.
public struct PurchaseConfirmation: Sendable {
    /// A window, scene, view controller or `PurchaseAction`. `PurchaseStoreKit` and
    /// `PurchaseUI` provide named constructors; an anchor the adapter does not
    /// recognise is treated as `automatic`, and logged.
    public let anchor: (any Sendable)?

    public init(anchor: (any Sendable)?) {
        self.anchor = anchor
    }

    /// Let the store choose where the sheet goes. Fine with one window.
    public static let automatic = PurchaseConfirmation(anchor: nil)
}
