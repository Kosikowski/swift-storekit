//
//  PurchaseIntentProbes.swift
//  HostTests
//
//  Phase 3 of docs/14-subscriptions-plan.md: does a purchase started outside the app — a
//  promoted in-app purchase on the App Store, or a win-back offer with streamlined
//  purchasing off — reach the app as a `PurchaseIntent`, and what does it carry? Xcode's
//  environment is said to deliver one for an `itms-services://?action=purchaseIntent` URL;
//  whether it does, per platform, is the first question. Prefixed `PROBE iNN`.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite("Purchase intents against real StoreKit", .serialized, .timeLimit(.minutes(2)))
struct PurchaseIntentProbes {
    private func open(_ query: String) async -> String {
        let bundle = Bundle.main.bundleIdentifier ?? "spike.storekit.subscriptions.host"
        guard let url = URL(string: "itms-services://?action=purchaseIntent&bundleId=\(bundle)&\(query)") else { return "bad URL" }
        #if os(macOS)
        return NSWorkspace.shared.open(url) ? "opened \(url)" : "NOT opened \(url)"
        #else
        return await UIApplication.shared.open(url) ? "opened \(url)" : "NOT opened \(url)"
        #endif
    }

    private func intents(for seconds: Double, _ ref: Date) async -> [String] {
        let heard = Heard()
        let task = Task { @MainActor in
            for await intent in PurchaseIntent.intents {
                var text = "\(String(format: "%.2f", Date().timeIntervalSince(ref)))s \(intent.product.id)"
                if let offer = intent.offer { text += " offer \(name(offer.type))/\(offer.id ?? "-")" }
                heard.items.append(text)
            }
        }
        try? await pause(seconds)
        task.cancel()
        return heard.items
    }

    // MARK: - i01: a promoted purchase

    @Test func i01_promoted() async throws {
        let session = try makeSession()
        let ref = Date()
        let listening = Task { await intents(for: 8, ref) }
        try await pause(0.5)
        say("i01", await open("productIdentifier=\(monthly)"))
        say("i01", "intents \(await listening.value)")
        withExtendedLifetime(session) {}
    }

    // MARK: - i02: sent before anybody listens

    @Test func i02_beforeListening() async throws {
        let session = try makeSession()
        let ref = Date()
        say("i02", await open("productIdentifier=\(yearly)"))
        try await pause(3)
        say("i02", "intents heard by a listener started 3 s later: \(await intents(for: 4, ref))")
        withExtendedLifetime(session) {}
    }

    // MARK: - i03: a win-back offer

    @Test func i03_winBack() async throws {
        let session = try makeSession()
        let ref = Date()
        let bought = try await buy(try await load(monthly))
        say("i03", "lapse: \(attempt { try session.expireSubscription(productIdentifier: monthly) })")
        try await pause(2)
        _ = bought
        let listening = Task { await intents(for: 8, ref) }
        try await pause(0.5)
        say("i03", await open("productIdentifier=\(monthly)&offerIdentifier=winback.three"))
        say("i03", "intents \(await listening.value)")
        withExtendedLifetime(session) {}
    }
}

@MainActor
final class Heard {
    var items: [String] = []
}

func name(_ type: Product.SubscriptionOffer.OfferType) -> String {
    switch type {
    case .introductory: "introductory"
    case .promotional: "promotional"
    case .winBack: "winBack"
    default: "other(\(type.rawValue))"
    }
}
