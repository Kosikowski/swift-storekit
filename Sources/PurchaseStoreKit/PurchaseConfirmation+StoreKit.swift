//
//  PurchaseConfirmation+StoreKit.swift
//  PurchaseStoreKit
//
//  Names for the anchors the App Store adapter understands.
//
//  With one window, `.automatic` is fine. With several — an iPad in Split View, a Mac
//  with a document per window — say which one the purchase was started from, or the
//  payment sheet may appear over a different one.
//

public import PurchaseCore
public import StoreKit
public import SwiftUI
// Where `PurchaseAction` lives. Xcode loads this overlay unasked when a file imports
// both StoreKit and SwiftUI; SwiftPM does not, so it is named.
public import _StoreKit_SwiftUI

#if os(macOS)
public import AppKit
#elseif canImport(UIKit)
public import UIKit
#endif

extension PurchaseConfirmation {
    /// SwiftUI's `@Environment(\.purchase)`. Apple's recommended route in SwiftUI on
    /// every platform: the action knows the scene of the view it was read in.
    /// `PurchaseUI`'s `PurchaseButton` passes this for you.
    public static func action(_ action: PurchaseAction) -> PurchaseConfirmation {
        PurchaseConfirmation(anchor: action)
    }

    #if os(macOS)
    public static func window(_ window: NSWindow) -> PurchaseConfirmation {
        PurchaseConfirmation(anchor: window)
    }
    #elseif canImport(UIKit)
    public static func viewController(_ controller: UIViewController) -> PurchaseConfirmation {
        PurchaseConfirmation(anchor: controller)
    }

    public static func scene(_ scene: UIScene) -> PurchaseConfirmation {
        PurchaseConfirmation(anchor: scene)
    }
    #endif
}
