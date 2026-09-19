//
//  UnlistedPurchases.swift
//  PurchaseCore
//
//  Layer: Application
//
//  Grants the store has made and has not listed yet.
//
//  The store lists a purchase a moment *after* it says the purchase was made — about a
//  second after `purchase()` returns, about half a second after an approved Ask to Buy
//  arrives as an update. Read in that gap, the account owns nothing: the unlock stays
//  locked until the next launch, and the Buy button appears to have done nothing. So
//  the transaction the store handed over is held, and vouched for, until the store's
//  own listing takes over.
//
//  **It is held for a moment and no longer.** A hold ends when the store lists the
//  product *and that listing counts* (a family member's copy of something this account
//  has just bought for itself does not take over from the hold), when the store
//  withdraws it, or when its time is up — whichever is first. A subscription's hold is
//  let go by its status rather than the listing (docs/10-decisions.md, D36); the store
//  decides which of the two it passes to `settle`.
//  The time limit is what keeps the listing the last word: a grant the store never
//  goes on to list (a shared purchase withdrawn without a date has been reported to
//  arrive looking like one) lapses, rather than being vouched for all session.
//

import Foundation

struct UnlistedPurchases: Sendable {
    private struct Hold: Sendable {
        let product: OwnedProduct
        let until: Date
    }

    private var holds: [Hold] = []

    var held: [OwnedProduct] { holds.map(\.product) }

    /// When the hold that lapses soonest does so.
    var nextLapse: Date? { holds.map(\.until).min() }

    mutating func hold(_ product: OwnedProduct, until deadline: Date) {
        holds.removeAll { $0.product.id == product.id }
        holds.append(Hold(product: product, until: deadline))
    }

    /// The store has listed these, or their time is up: its listing speaks for itself.
    ///
    /// - Parameter listing: what the store lists **and the resolver counts**. A listing
    ///   that has the product without counting it has not taken over from the hold.
    mutating func settle(listedIn listing: [OwnedProduct], at now: Date) {
        let listed = Set(listing.map(\.id))
        holds.removeAll { listed.contains($0.product.id) || $0.until <= now }
    }

    /// The store has withdrawn this product.
    mutating func drop(_ id: ProductID) {
        holds.removeAll { $0.product.id == id }
    }
}
