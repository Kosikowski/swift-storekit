//
//  PurchaseTestKit.swift
//  PurchaseTestKit
//
//  Everything a test of purchasing needs, behind one import — and **nothing an app
//  imports**. It is to this package what StoreKitTest is to StoreKit.
//
//  · the simulated store, its gates and its scenarios, which live in PurchaseSimulator
//    (DEBUG only) and are re-exported here, so that a test writes `import PurchaseTestKit`
//    and not the name of a module it has no other reason to know;
//  · a clock that moves when told, a wait on a condition, a logger that remembers, and a
//    reader for the `.storekit` file — none of which grants anything, so none of which is
//    guarded, and all of which work in a release test run.
//
//  An app gets its store from PurchaseLaunch, which reaches the simulator itself, in
//  DEBUG, without the app naming it. `swift package release-check --app` fails an app
//  that has linked this module: Xcode links a package product into every configuration
//  of a target or none, so linked into an app this would ship.
//

@_exported public import PurchaseSimulator
