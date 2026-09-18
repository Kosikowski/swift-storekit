//
//  PurchaseStateProviding.swift
//  PurchaseCore
//
//  Layer: Application
//

public import Observation

/// What a view may read. No commands: a view that only shows where things stand
/// should not be able to start a purchase.
///
/// **Only global facts live here.** Where the account stands, what the store sells,
/// what is waiting for someone's approval, whether something is under way. The
/// *result* of a purchase is not among them — it is returned to whoever asked
/// (`PurchaseCommanding`), because a result published here is a result every view
/// watching here announces at once.
@MainActor
public protocol PurchaseStateProviding: AnyObject, Observable, Sendable {
    var catalogue: Catalogue { get }

    /// Where the account stands. `unknown` until the store first answers — read
    /// `knownStanding()` instead wherever the answer decides something.
    var standing: Standing { get }

    /// What the store sells, once loaded. Empty until then, and kept across a failed
    /// reload.
    var products: [StoreProduct] { get }
    var productLoad: ProductLoadState { get }

    /// Purchases sent to someone else for approval (Ask to Buy) and not yet settled.
    /// For this session only: the store has no way to list them after a relaunch.
    var pendingApprovals: Set<ProductID> { get }

    var activity: PurchaseActivity { get }

    /// The standing, **once the store has answered**. Starts the store if nothing has.
    ///
    /// Every gate, limit, lock and "open this" path should come through here rather
    /// than read `standing` during launch. Otherwise a click in the first moments
    /// opens something that should be locked — or, worse and more often, a paying
    /// customer is shown the paywall until the answer arrives.
    func knownStanding() async -> Standing
}
