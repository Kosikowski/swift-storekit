//
//  PurchaseDebugPanel.swift
//  PurchaseDebugUI
//
//  A panel for poking at purchases in a running debug build.
//
//  The question it exists to answer is "what does my app do when…": when a trial has
//  five minutes left and then none, when a purchase is refunded, when a parent has not
//  approved yet, when the store has not answered, when the network is slow. Every one
//  of those is a relaunch and a fiddle with Xcode's transaction manager against real
//  StoreKit, and some of them — a trial nearly over — cannot always be arranged there:
//  backdating a non-consumable's purchase depends on the OS (spike/README.md).
//
//  The top section shows **facts from whatever store the app is running on**, the real
//  one included. The controls appear only when the app is running on a simulated store
//  and hands it in.
//
//  **The panel itself exists only in DEBUG builds**, like the store it drives. What is
//  here in every build is its *name*: `PurchaseDebugPanel(launch)` compiles in release and
//  draws nothing, so that an app puts the panel in a sheet or a window without an `#if`
//  of its own and without importing anything that is missing from a release build.
//  `PurchaseDebugPanel.isAvailable` says which build this is, for the button that opens it.
//

public import PurchaseLaunch
public import SwiftUI

// Only the debug panel speaks of the store's own types; in release it draws nothing,
// and a public import it did not use would be warned about.
#if DEBUG
public import PurchaseCore
public import PurchaseSimulator
#endif

/// Shows where purchases stand, and — on a simulated store — changes it. **Draws nothing in
/// a release build.**
///
///     // A window of its own on the Mac (the scene is the app's to guard: a scene cannot
///     // be conditional, and an empty window would still be in the Window menu):
///     #if DEBUG
///     Window("Purchases", id: "purchase-debug") { PurchaseDebugPanel(launch) }
///     #endif
///
///     // A sheet anywhere, with no `#if` at all:
///     if PurchaseDebugPanel.isAvailable {
///         Button("Purchases…") { showsPanel = true }
///             .sheet(isPresented: $showsPanel) { PurchaseDebugPanel(launch) }
///     }
public struct PurchaseDebugPanel: View {
    /// Whether there is a panel to show: true in a DEBUG build and false in a release one.
    public static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    #if DEBUG
    private let content: PanelContent
    #endif

    /// The panel for this launch: the facts, and the controls when it is on a simulated store.
    public init(_ launch: StoreLaunch) {
        #if DEBUG
        let store = launch.store
        content = PanelContent(store: store, simulated: launch.simulated) { await store.diagnose() }
        #endif
    }

    #if DEBUG
    /// For an app that wrote its own composition root over `SimulatedStoreFront`.
    ///
    /// - Parameters:
    ///   - simulated: the simulated store the app is running on, if it is. Nil shows
    ///     the facts and no controls.
    ///   - diagnostics: something to ask what this build receives. Most useful
    ///     against the real store, on the afternoon Buy does nothing.
    public init(
        store: any PurchaseStateProviding & PurchaseCommanding,
        simulated: SimulatedStoreFront? = nil,
        diagnostics: (any StoreDiagnosing)? = nil
    ) {
        let diagnoser = diagnostics ?? simulated
        if let diagnoser {
            content = PanelContent(store: store, simulated: simulated) { await diagnoser.diagnose() }
        } else {
            content = PanelContent(store: store, simulated: simulated, diagnose: nil)
        }
    }
    #endif

    public var body: some View {
        #if DEBUG
        content
        #else
        EmptyView()
        #endif
    }
}

#if DEBUG

private struct PanelContent: View {
    private let store: any PurchaseStateProviding & PurchaseCommanding
    private let simulated: SimulatedStoreFront?
    private let diagnose: (@MainActor () async -> StoreDiagnosis?)?

    @State private var remainingSeconds = 300.0
    @State private var diagnosis: StoreDiagnosis?
    @State private var asked = false
    @State private var lastResult = ""

    init(
        store: any PurchaseStateProviding & PurchaseCommanding,
        simulated: SimulatedStoreFront?,
        diagnose: (@MainActor () async -> StoreDiagnosis?)?
    ) {
        self.store = store
        self.simulated = simulated
        self.diagnose = diagnose
    }

    var body: some View {
        Form {
            // Ticks, so that a trial can be watched running out. The standing is asked
            // about *this* second without being resolved again: its questions take the
            // date as a parameter.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                facts(at: timeline.date)
            }
            if let simulated {
                products(simulated)
                behaviour(simulated)
            }
            actions
            if diagnose != nil { probe }
        }
        .formStyle(.grouped)
    }

    // MARK: - Facts

    @ViewBuilder
    private func facts(at date: Date) -> some View {
        Section("Standing") {
            row("Store has answered", store.standing.isKnown ? "yes" : "NOT YET")
            ForEach(store.catalogue.entries) { entry in
                row(entry.id.rawValue, describe(entry, at: date))
            }
            row("Pending approval", store.pendingApprovals.isEmpty ? "none" : list(store.pendingApprovals))
            row("Activity", String(describing: store.activity))
        }
        Section("Catalogue") {
            row("Load", String(describing: store.productLoad))
            ForEach(store.products) { product in
                row(product.displayName, product.displayPrice)
            }
        }
    }

    private func describe(_ entry: CatalogueEntry, at date: Date) -> String {
        if entry.trialTerms != nil {
            switch store.standing.trial(entry.id, at: date) {
            case .unknown: return "unknown"
            case .available: return "trial available"
            case let .running(period): return "running, \(remaining(period, at: date)) left"
            case let .used(period): return "used, ended \(period.endsAt.formatted(date: .abbreviated, time: .standard))"
            case .notOffered: return "not offered"
            }
        }
        switch store.standing.access(to: entry.id, at: date) {
        case .unknown: return "unknown"
        case let .owned(owned): return "owned (\(owned.ownership))"
        case let .onTrial(period, via): return "on trial via \(via), \(remaining(period, at: date)) left"
        case let .subscribed(held): return "subscribed (\(held.state)), until \(held.accessEnds.formatted(date: .abbreviated, time: .standard))"
        case .none: return "none"
        }
    }

    private func remaining(_ period: TrialPeriod, at date: Date) -> String {
        Duration.seconds(max(0, period.endsAt.timeIntervalSince(date)).rounded())
            .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow))
    }

    // MARK: - Simulated store

    @ViewBuilder
    private func products(_ simulated: SimulatedStoreFront) -> some View {
        ForEach(store.catalogue.entries) { entry in
            Section(entry.id.rawValue) {
                if entry.trialTerms != nil {
                    HStack {
                        Text("Seconds left")
                        TextField("Seconds left", value: $remainingSeconds, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Trial with that long left") {
                        simulated.deliverTrial(entry.id, remaining: .seconds(remainingSeconds))
                    }
                    Button("Trial that ended a day ago") {
                        simulated.deliverTrial(entry.id, remaining: .seconds(-86_400))
                    }
                    Button("Trial through Family Sharing (must not count)") {
                        simulated.deliver(entry.id, ownership: .familyShared)
                    }
                } else {
                    Button("Bought on another device") { simulated.deliver(entry.id) }
                    Button("Shared by a family member") { simulated.deliver(entry.id, ownership: .familyShared) }
                }
                Button("Approve Ask to Buy") { simulated.approvePending(entry.id) }
                Button("Refund", role: .destructive) { simulated.revoke(entry.id) }
            }
        }
    }

    @ViewBuilder
    private func behaviour(_ simulated: SimulatedStoreFront) -> some View {
        Section("Next purchase") {
            scriptButton("Succeeds", simulated) { $0.purchase = .succeeds }
            scriptButton("Ask to Buy: pending", simulated) { $0.purchase = .pending }
            scriptButton("Person cancels", simulated) { $0.purchase = .cancelled }
            scriptButton("Fails: unverified", simulated) { $0.purchase = .fails(.unverified) }
            scriptButton("Fails: network", simulated) { $0.purchase = .fails(.network) }
            scriptButton("Fails: product unavailable", simulated) { $0.purchase = .fails(.productUnavailable) }
            // Held open, a purchase ends however the script above says when it is let go.
            Button("Hold purchases open (the payment sheet is up)") { simulated.purchaseGate.close() }
            Button("Let purchases finish") { simulated.purchaseGate.open() }
        }
        Section("The store itself") {
            Button("Hold \"what is owned\" shut") { simulated.ownershipGate.close() }
            Button("Let it answer") { simulated.ownershipGate.open() }
            Button("Hold the catalogue shut (slow network)") { simulated.catalogueGate.close() }
            Button("Let the catalogue load") { simulated.catalogueGate.open() }
            scriptButton("Catalogue loads", simulated) { $0.catalogue = .loads }
            scriptButton("Catalogue is empty (unknown build)", simulated) { $0.catalogue = .loadsOnly([]) }
            scriptButton("Catalogue fails: network", simulated) { $0.catalogue = .fails(.network) }
            scriptButton("Restore fails: network", simulated) { $0.restore = .fails(.network) }
            scriptButton("Restore succeeds", simulated) { $0.restore = .succeeds }
            Button("Hold restores open (asking for a password)") { simulated.restoreGate.close() }
            Button("Let restores finish") { simulated.restoreGate.open() }
            Button("Forget every purchase", role: .destructive) {
                simulated.reset()
                Task { await store.refresh() }
            }
        }
    }

    private func scriptButton(
        _ title: String, _ simulated: SimulatedStoreFront,
        _ change: @escaping (inout SimulatedStoreFront.Behaviour) -> Void
    ) -> some View {
        Button(title) { change(&simulated.behaviour) }
    }

    // MARK: - Commands, through the app's own store

    private var actions: some View {
        Section("Commands") {
            ForEach(store.catalogue.entries) { entry in
                Button("Buy \(entry.id.rawValue)") {
                    Task {
                        do throws(PurchaseError) {
                            lastResult = String(describing: try await store.purchase(entry.id))
                        } catch {
                            lastResult = "threw \(error)"
                        }
                    }
                }
            }
            Button("Restore purchases") {
                Task {
                    do throws(PurchaseError) {
                        lastResult = String(describing: try await store.restorePurchases())
                    } catch {
                        lastResult = "threw \(error)"
                    }
                }
            }
            Button("Read what is owned again") { Task { await store.refresh() } }
            Button("Load prices again") { Task { await store.loadProducts() } }
            if !lastResult.isEmpty { row("Last result", lastResult) }
        }
    }

    // MARK: - Probe

    private var probe: some View {
        Section("What this build receives") {
            Button("Ask the store") {
                Task {
                    diagnosis = await diagnose?()
                    asked = true
                }
            }
            if asked, diagnosis == nil {
                row("Received", "this store cannot say")
            }
            if let diagnosis {
                row("Asked for", list(diagnosis.requested))
                if let failure = diagnosis.catalogueFailure {
                    row("Received", "COULD NOT ASK (\(failure))")
                } else {
                    row("Received", diagnosis.received.isEmpty ? "NOTHING" : list(diagnosis.received))
                }
                row("Entitlements", "\(diagnosis.verifiedEntitlements) verified, \(diagnosis.unverifiedEntitlements) unverified, \(diagnosis.foreignEntitlements) foreign")
                row("Environment", diagnosis.environment ?? "unknown until something is owned")
                ForEach(diagnosis.hints, id: \.self) { hint in
                    Text(advice(for: hint)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func advice(for hint: StoreDiagnosis.Hint) -> String {
        switch hint {
        case let .catalogueLoadFailed(error):
            "The store could not be asked what it sells (\(error)). That says nothing about the products or this build: check the connection and ask again."
        case .storeSellsNothingToThisBuild:
            "The store returned no products at all. Attach a StoreKit configuration file to the scheme's Run action, or sign this build with a team that has the app in App Store Connect."
        case let .someProductsMissing(missing):
            "Not returned: \(list(missing)). Misspelt, or not yet ready for sale."
        case let .unverifiedEntitlementsPresent(count):
            "\(count) entitlement(s) did not verify and are being ignored."
        }
    }

    // MARK: - Bits

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled) }
    }

    private func list(_ identifiers: Set<ProductID>) -> String {
        identifiers.sorted().map(\.rawValue).joined(separator: ", ")
    }
}

#Preview("On a simulated store") {
    let catalogue: Catalogue = [
        .unlock("com.example.pro"),
        .trial("com.example.trial", of: ["com.example.pro"], lasting: .seconds(14 * 86_400)),
    ]
    let front = SimulatedStoreFront(catalogue: catalogue)
    let store = PurchaseStore(catalogue: catalogue, front: front)
    PurchaseDebugPanel(store: store, simulated: front)
        .task {
            await store.start()
            await store.loadProducts()
        }
}

#endif
