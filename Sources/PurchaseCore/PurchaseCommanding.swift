//
//  PurchaseCommanding.swift
//  PurchaseCore
//
//  Layer: Application
//

/// What a button may ask for.
///
/// Every command **returns what came of it to its caller**, as a value or a typed
/// error, and records it nowhere shared. Keep that result in the state of the view
/// whose button was pressed.
@MainActor
public protocol PurchaseCommanding: AnyObject, Sendable {
    /// Begins listening for transactions and reads what is owned. Call it as the app
    /// launches; calling it again does nothing. It does **not** load prices.
    func start() async

    /// Reads what is owned again. For when the app becomes active, in case the wall
    /// clock was changed while it was not.
    func refresh() async

    /// Asks the store what it sells. Independent of `start()`, and nothing about
    /// what a person may use waits for it. A failure keeps the last good answer.
    /// Called while a load is under way, it joins that load; called from a task that
    /// is then cancelled, the load carries on and is not reported as a failure.
    func loadProducts() async

    /// The same, unless they are loaded already. For everything but a Retry button.
    func loadProductsIfNeeded() async

    /// Buys `id`, and returns what came of it **to whoever asked**: owned, a trial now
    /// running or already used, pending someone's approval, cancelled, or completed and
    /// not counted for this account. A failure is thrown, typed, and says nothing about
    /// what was already owned. One at a time: a second purchase, or a restore, while one
    /// is under way throws `alreadyInProgress` rather than queueing behind it.
    ///
    /// - Parameter confirmation: where the payment sheet goes. With more than one
    ///   window open, say; `PurchaseButton` does.
    @discardableResult
    func purchase(_ id: ProductID, confirmation: PurchaseConfirmation) async throws(PurchaseError) -> PurchaseCompletion

    /// Throws `alreadyInProgress` if a purchase **or a restore** is under way — read
    /// `activity` to say which, or, better, say nothing: the button that was pressed
    /// should have been disabled (`activity.isBusy`), and the person already knows.
    ///
    /// For a Restore Purchases button only: on the App Store this asks for a password.
    /// A failure never takes away what was already known to be owned.
    @discardableResult
    func restorePurchases() async throws(PurchaseError) -> RestoreOutcome
}

extension PurchaseCommanding {
    @discardableResult
    public func purchase(_ id: ProductID) async throws(PurchaseError) -> PurchaseCompletion {
        try await purchase(id, confirmation: .automatic)
    }
}
