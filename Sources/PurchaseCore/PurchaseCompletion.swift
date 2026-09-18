//
//  PurchaseCompletion.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  What a purchase came to, for whoever pressed the button.
//
//  This is returned to the caller and deliberately not published anywhere shared. A
//  result kept in one flag watched by several views — a paywall sheet, a settings
//  pane, a second window — raises the same alert in all of them at once. The button
//  that was pressed is the only thing that should speak.
//

/// What a purchase amounted to for this account.
public enum PurchaseCompletion: Hashable, Sendable {
    /// An unlock, now held.
    case owned(OwnedProduct)
    /// A trial, now running.
    case trialRunning(TrialPeriod)
    /// The trial was bought and the store handed back one **already over** — taken
    /// on another device, or before a reinstall, and not listed here until now.
    /// Buying an owned non-consumable returns the original transaction, original
    /// date included. Tell the person when it ended; do not just let the button go
    /// grey under their pointer.
    case trialUsed(TrialPeriod)
    /// The store completed it and it gives this account nothing — a trial that
    /// arrived through Family Sharing, say. Rare, and worth a sentence.
    case notCounted(OwnedProduct)
    /// Ask to Buy. The product is in `pendingApprovals` until it is settled.
    case pending
    case cancelled
}
