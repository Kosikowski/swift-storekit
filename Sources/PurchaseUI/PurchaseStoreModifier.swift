//
//  PurchaseStoreModifier.swift
//  PurchaseUI
//
//  Puts a store in the environment and starts it.
//

public import PurchaseCore
public import SwiftUI

extension View {
    /// Makes `store` available below and starts it. Apply it once, at the root.
    ///
    /// What is owned is read first, and prices second: nothing about what a person may
    /// use should wait for a network request that can take a long time to fail.
    ///
    /// SwiftUI cancels this task if the view goes away, and that is safe. The store
    /// reads what is owned in a task of its own, because the real store answers a
    /// cancelled one with nothing — which would read as owning nothing.
    ///
    /// - Parameter loadsProducts: false to leave prices until a paywall asks for them.
    public func purchaseStore(
        _ store: some PurchaseStateProviding & PurchaseCommanding, loadsProducts: Bool = true
    ) -> some View {
        environment(\.purchaseState, store)
            .environment(\.purchaseCommands, store)
            .modifier(StartPurchaseStore(store: store, loadsProducts: loadsProducts))
    }
}

/// `.task`, kept out of `purchaseStore(_:)`'s own return type — **or an app that uses
/// this package does not link in Release.**
///
/// In the 27 SDK `task(name:priority:file:line:_:)` is emitted into whoever calls it,
/// so the opaque type it returns has no descriptor in SwiftUI itself. Written straight
/// into a public function that returns `some View` — any such function: generic or
/// not, a method or a free function — that type becomes part of this module's public
/// signature, the app refers to its descriptor, and the linker cannot find it:
/// "Undefined symbols … opaque type descriptor for … View.task(name:…)". Only in an
/// optimised build, so the first anyone hears of it is the archive. Inside a modifier
/// the type stays in here, and what an app sees is `ModifiedContent`.
/// (docs/10-decisions.md, D25; `make demo` links a Release build to keep it so.)
private struct StartPurchaseStore<Store: PurchaseStateProviding & PurchaseCommanding>: ViewModifier {
    let store: Store
    let loadsProducts: Bool

    func body(content: Content) -> some View {
        content.task {
            await store.start()
            if loadsProducts { await store.loadProducts() }
        }
    }
}
