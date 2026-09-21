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
        /// Held beside any other of the same product, and settled by its own date.
        let alongside: Bool
    }

    private var holds: [Hold] = []

    var held: [OwnedProduct] { holds.map(\.product) }

    /// When the hold that lapses soonest does so.
    var nextLapse: Date? { holds.map(\.until).min() }

    /// - Parameter alongside: keep every other hold of the product. Each purchase of a
    ///   non-renewing subscription is time bought, and the listing keeps them all
    ///   (measured); a second one held in place of the first would lose the first.
    mutating func hold(_ product: OwnedProduct, until deadline: Date, alongside: Bool = false) {
        holds.removeAll { $0.product.id == product.id && (!alongside || $0.product.purchaseDate == product.purchaseDate) }
        holds.append(Hold(product: product, until: deadline, alongside: alongside))
    }

    /// The store has listed these, or their time is up: its listing speaks for itself.
    ///
    /// - Parameter listing: what the store lists **and the resolver counts**. A listing
    ///   that has the product without counting it has not taken over from the hold. A hold
    ///   kept alongside others is taken over only by the listing of that purchase.
    mutating func settle(listedIn listing: [OwnedProduct], at now: Date) {
        holds.removeAll { hold in
            hold.until <= now
                || listing.contains { $0.id == hold.product.id && (!hold.alongside || $0.purchaseDate == hold.product.purchaseDate) }
        }
    }

    /// The store has withdrawn this product.
    mutating func drop(_ id: ProductID) {
        holds.removeAll { $0.product.id == id }
    }
}
