//
//  SimulatedStoreFront+Configuration.swift
//  PurchaseTestKit
//
//  A simulated store that sells what the app's own `.storekit` file sells.
//
//  Left to itself the simulated store makes its products up — unlocks at 9.99,
//  trials free — which is fine for a unit test and wrong for a screenshot or a
//  preview, where the name and the price are the point. The app already has a file
//  that says what they are, and Xcode's test environment already reads it; read here
//  too, the simulated paywall and the StoreKit-testing paywall cannot drift apart.
//
//  The initialiser is here rather than beside `StoreKitConfiguration` because that
//  ships in every configuration and this, like the store it builds, only in DEBUG.
//

#if DEBUG

public import PurchaseCore

extension SimulatedStoreFront {
    /// A store selling the catalogue's products as `configuration` describes them.
    ///
    /// A catalogue product the file does not have is not sold, as with the real
    /// store and an identifier it does not recognise. Nothing here checks that the
    /// two agree: `configuration.problems(against:)` does, and belongs in a test.
    public convenience init(
        catalogue: Catalogue,
        configuration: StoreKitConfiguration,
        clock: any TimeProviding = SystemClock(),
        behaviour: Behaviour = Behaviour()
    ) {
        self.init(
            catalogue: catalogue, products: configuration.storeProducts(for: catalogue),
            clock: clock, behaviour: behaviour)
    }
}

#endif
