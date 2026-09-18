//
//  StoreFront.swift
//  PurchaseCore
//
//  Layer: Port
//

/// A whole store: everything `PurchaseStore` needs, from one object.
///
/// The five roles are separate protocols because their consumers are separate — a
/// screen that only lists prices needs one of them — and `PurchaseStore`'s designated
/// initialiser takes them one by one. This is the convenience for the usual case,
/// where one object plays all five.
public typealias StoreFront = ProductCatalogueLoading & OwnershipReading & ProductPurchasing
    & PurchaseRestoring & TransactionObserving
