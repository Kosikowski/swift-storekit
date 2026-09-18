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

    static let catalogue: Catalogue = [
        .unlock(pro),
        .trial(trial, of: [pro], lasting: .seconds(14 * 86_400)),
    ]
}
