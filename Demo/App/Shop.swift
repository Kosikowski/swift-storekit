//
//  Shop.swift
//  Demo
//
//  Every product identifier, written once. `DemoTests` imports this and checks
//  Demo.storekit against it, so a product renamed here and not there fails a test.
//

import PurchaseCore

enum Shop {
    static let pro: ProductID = "com.example.purchasedemo.pro"
    static let trial: ProductID = "com.example.purchasedemo.trial"

    /// A membership, sold as a subscription beside the unlock: monthly or yearly at one
    /// level, and Plus above them. The monthly plan has the offers of the example the
    /// subscription work began from — 10.99 for two months, then 15.99; and 10.99 for three
    /// months to win a lapsed member back.
    static let membership: SubscriptionGroupID = "21482000"
    static let monthly: ProductID = "com.example.purchasedemo.membership.monthly"
    static let yearly: ProductID = "com.example.purchasedemo.membership.yearly"
    static let plus: ProductID = "com.example.purchasedemo.membership.plus"

    /// A season pass: thirty days, bought again to go on — a non-renewing subscription, whose
    /// length is the app's to say. Bought while one runs, the days add up.
    static let season: ProductID = "com.example.purchasedemo.season"

    static let catalogue: Catalogue = [
        .unlock(pro),
        .trial(trial, of: [pro], lasting: .seconds(14 * 86_400)),
        .subscription(monthly, in: membership, level: 2),
        .subscription(yearly, in: membership, level: 2),
        .subscription(plus, in: membership, level: 1),
        .nonRenewing(season, lasting: .seconds(30 * 86_400)),
    ]
}
