//
//  ContentView.swift
//  Demo
//
//  A paywall of the plainest kind, to show where the app's half of the work goes.
//
//  Everything here that is *wording* or *policy* is the app's and not the package's:
//  what "Pro" means, what to say when a purchase is pending or does not verify, and
//  how to write the end of a trial — with its time, because a trial ends at an
//  instant and "until the 30th" is wrong by evening for someone who began in the
//  evening.
//

import PurchaseCore
import PurchaseDebugUI
import PurchaseLaunch
import PurchaseUI
import SwiftUI

struct ContentView: View {
    @Environment(\.purchaseState) private var purchases
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var showsDebugPanel = false
    #endif

    /// The launch this view belongs to: whether it is on a simulated store, and what the
    /// debug panel needs. Nil in a preview, which has neither.
    var launch: StoreLaunch?

    /// The result of *this view's* buttons, kept here. Published somewhere shared, it
    /// would be announced by every view watching.
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Said out loud, and the first thing a UI test looks for: in a build that
            // cannot honour a scenario the app runs on the real store and nothing fails,
            // so a test that did not check would photograph the wrong thing. Never true in
            // a release build, so this needs no `#if`.
            if launch?.isSimulated == true {
                Text("Simulated store").font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("simulated-store")
            }
            // Asked afresh every second, so the view changes when a trial runs out. The
            // standing is not resolved again for this: its questions take the date.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                status(at: timeline.date).accessibilityIdentifier("pro-status")
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            HStack {
                PurchaseButton(Shop.pro) { notice = Self.words(for: $0) } label: {
                    Text("Buy Pro\(price(of: Shop.pro))")
                }
                trialButton
                RestorePurchasesButton("Restore Purchases") { result in
                    if case let .failure(error) = result { notice = Self.words(for: error) }
                }
            }
            debugPanelButton
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 520, alignment: .leading)
        #endif
    }

    /// A window of its own on the Mac; a sheet on iOS, which has no `Window` scenes. Not
    /// there at all in a release build, where there is no panel to open — asked of the
    /// panel, not of the preprocessor.
    @ViewBuilder
    private var debugPanelButton: some View {
        if PurchaseDebugPanel.isAvailable, let launch {
            #if os(macOS)
            Button("Purchase debug panel…") { openWindow(id: "purchase-debug") }
            #else
            Button("Purchase debug panel…") { showsDebugPanel = true }
                .sheet(isPresented: $showsDebugPanel) { PurchaseDebugPanel(launch) }
            #endif
        }
    }

    @ViewBuilder
    private func status(at date: Date) -> some View {
        switch purchases?.standing.access(to: Shop.pro, at: date) {
        case nil, .unknown?:
            // Not "free": the store has not answered, and nothing is judged yet.
            ProgressView()
        case .owned?:
            Label("Pro", systemImage: "checkmark.seal.fill").font(.title2)
        case let .onTrial(period, _)?:
            Label("Trial until \(Self.moment(period.endsAt))", systemImage: "hourglass").font(.title2)
        case .subscribed?:
            Label("Pro", systemImage: "checkmark.seal.fill").font(.title2)
        case .none?:
            Label("Free", systemImage: "lock").font(.title2)
        }
    }

    /// Three states, not two: once used, the button stays, disabled, saying when the
    /// trial ended. Hidden, people wonder where it went.
    @ViewBuilder
    private var trialButton: some View {
        switch purchases?.standing.trial(Shop.trial) {
        case .available?:
            PurchaseButton("Start 14-day Trial", buying: Shop.trial) { notice = Self.words(for: $0) }
        case let .used(period)?:
            Button("Trial ended \(Self.moment(period.endsAt))") {}.disabled(true)
        default:
            EmptyView()
        }
    }

    private func price(of id: ProductID) -> String {
        purchases?.products.first { $0.id == id }.map { " for \($0.displayPrice)" } ?? ""
    }

    private static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func words(for result: Result<PurchaseCompletion, PurchaseError>) -> String? {
        switch result {
        case .success(.owned), .success(.trialRunning), .success(.subscribed), .success(.cancelled): nil
        case let .success(.planChangeScheduled(_, at)):
            "Your plan changes at your next renewal\(at.map { ", on \(moment($0))" } ?? "")."

        case .success(.pending): "Waiting for approval. Pro unlocks as soon as it is given."
        case let .success(.trialUsed(period)): "Your trial ended on \(moment(period.endsAt))."
        case .success(.notCounted): "That purchase was completed, but it does not unlock anything for this account."
        case let .failure(error): words(for: error)
        }
    }

    private static func words(for error: PurchaseError) -> String {
        switch error {
        case .unverified:
            "The App Store could not verify this purchase, so nothing has been unlocked. Try Restore Purchases, and contact support if you were charged."
        case .productUnavailable, .notAvailableInStorefront:
            "This is not available from the App Store at the moment."
        case .purchaseNotAllowed: "Purchases are switched off on this device."
        case .network: "The App Store could not be reached. Try again in a moment."
        case .alreadyInProgress: "A purchase is already under way."
        // Not "nothing has been charged": for this one, that is not known.
        case .revoked: "The App Store completed this purchase and then took it back, so nothing has been unlocked. Contact support if you were charged."
        default: "Something went wrong, and nothing has been unlocked. Try again in a moment."
        }
    }
}
