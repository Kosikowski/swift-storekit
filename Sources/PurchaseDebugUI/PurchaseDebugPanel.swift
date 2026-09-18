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
//  **The whole file exists only in DEBUG builds**, like the store it drives.
//

#if DEBUG

public import PurchaseCore
public import PurchaseTestKit
public import SwiftUI

/// Shows where purchases stand, and — given a simulated store — changes it.
///
///     Window("Purchases", id: "purchase-debug") {
///         PurchaseDebugPanel(store: purchases, simulated: simulatedFront)
///     }
///
/// `Window` scenes are the Mac's. On iOS, present it in a sheet:
///
///     .sheet(isPresented: $showsDebugPanel) {
///         PurchaseDebugPanel(store: purchases, simulated: simulatedFront)
///     }
public struct PurchaseDebugPanel: View {
    private let store: any PurchaseStateProviding & PurchaseCommanding
    private let simulated: SimulatedStoreFront?
    private let diagnostics: (any StoreDiagnosing)?

    @State private var remainingSeconds = 300.0
    @State private var diagnosis: StoreDiagnosis?
    @State private var lastResult = ""

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
        self.store = store
        self.simulated = simulated
        self.diagnostics = diagnostics ?? simulated
    }

    public var body: some View {
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
            if diagnostics != nil { probe }
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
                Task { diagnosis = await diagnostics?.diagnose() }
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
