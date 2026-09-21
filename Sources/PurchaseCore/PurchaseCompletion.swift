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

public import Foundation

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
    /// A subscription, now held: bought, upgraded to, or already held and handed back.
    case subscribed(HeldSubscription)
    /// A subscription, now held — and **the offer asked for was not applied**: it was bought
    /// at the regular price. Measured, StoreKit can do this and say nothing: an introductory
    /// override it could not check went through at the full price (spike/README.md). Never
    /// report it as the offer. An offer that waits for the next renewal, as a promotional
    /// offer bought by a current subscriber does `[Apple]`, counts as applied.
    case offerNotApplied(HeldSubscription)
    /// A change of plan that takes effect at the renewal: a downgrade, or a crossgrade to
    /// another duration. **Nothing has changed yet**, and the person keeps what they have
    /// until `at`. Measured: StoreKit reports such a purchase as a plain success with the
    /// subscription already held (spike/README.md), so taken at its word it says the
    /// cheaper plan was bought.
    case planChangeScheduled(to: ProductID, at: Date?)
    /// A non-renewing subscription, now running: the period it is part of, extended by
    /// this purchase if one was already running and the terms say they stack.
    case nonRenewing(NonRenewingPeriod)
    /// Ask to Buy. The product is in `pendingApprovals` until it is settled.
    case pending
    case cancelled
}
