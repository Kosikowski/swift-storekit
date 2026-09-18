//
//  EnvironmentValues+Purchase.swift
//  PurchaseUI
//
//  The store, in the environment, as the two things a view may want from it.
//
//  Two entries rather than one on purpose. A view that shows where things stand reads
//  `purchaseState` and cannot start a purchase; a button reads `purchaseCommands`.
//  Both are protocols, so a preview or a test puts in whatever it likes.
//

public import PurchaseCore
public import SwiftUI

extension EnvironmentValues {
    /// Where the account stands. Nil until `purchaseStore(_:)` is applied above.
    @Entry public var purchaseState: (any PurchaseStateProviding)? = nil

    /// What a button may ask for. Nil until `purchaseStore(_:)` is applied above.
    @Entry public var purchaseCommands: (any PurchaseCommanding)? = nil
}
