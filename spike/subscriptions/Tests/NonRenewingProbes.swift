//
//  NonRenewingProbes.swift
//  HostTests
//
//  Phase 3 of docs/14-subscriptions-plan.md, measured first as phase 0 was: what real
//  StoreKit does with a non-renewing subscription. The design leans on four things — that
//  StoreKit gives it no end, that it never leaves the listing, what buying it again comes
//  to, and what a refund of one purchase of several does — so each is asked. Prints, as
//  the other probes do, prefixed `PROBE nNN`.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing

let season = "probe.season"

@MainActor
@Suite("Non-renewing subscriptions against real StoreKit", .serialized, .timeLimit(.minutes(3)))
struct NonRenewingProbes {
    // MARK: - n01: what the product and a purchase of it look like

    @Test func n01_bought() async throws {
        let session = try makeSession()
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        let product = try await load(season)
        say("n01", "type \(product.type.rawValue); subscription info \(product.subscription == nil ? "none" : "present")")
        let bought = try await buy(product)
        say("n01", "bought \(describe(bought, ref)); expirationDate \(at(bought.expirationDate, ref)); type \(bought.productType.rawValue)")
        say("n01", "listed at once: \(await listing(ref))")
        say("n01", "listed by \(await waitForListing(bought.id, ref))")
        await recorder.watch(for: 3)
        recorder.stop()
        recorder.dump("n01")
        withExtendedLifetime(session) {}
    }

    // MARK: - n02: bought again

    @Test func n02_boughtAgain() async throws {
        let session = try makeSession()
        let ref = Date()
        let product = try await load(season)
        let first = try await buy(product)
        _ = await waitForListing(first.id, ref)
        try await pause(1.5)
        let second = try await buy(product)
        say("n02", "first \(describe(first, ref))")
        say("n02", "second \(describe(second, ref)); same transaction \(first.id == second.id)")
        _ = await waitForListing(second.id, ref)
        say("n02", "listing \(await listing(ref))")
        say("n02", "history \(await history(season, ref))")
        withExtendedLifetime(session) {}
    }

    // MARK: - n03: one of two refunded

    @Test func n03_refundOne() async throws {
        let session = try makeSession()
        let ref = Date()
        let recorder = Recorder(ref)
        let product = try await load(season)
        let first = try await buy(product)
        _ = await waitForListing(first.id, ref)
        try await pause(1.5)
        let second = try await buy(product)
        say("n03", "bought #\(first.id) then #\(second.id)")
        _ = await waitForListing(second.id, ref)
        recorder.listen()
        say("n03", "refund the FIRST: \(attempt { try session.refundTransaction(identifier: UInt(first.id)) })")
        await recorder.watch(for: 3)
        say("n03", "listing \(await listing(ref))")
        await recorder.watch(for: 3)
        say("n03", "listing after the first's refund settled \(await listing(ref))")
        say("n03", "refund the SECOND: \(attempt { try session.refundTransaction(identifier: UInt(second.id)) })")
        await recorder.watch(for: 3)
        recorder.stop()
        recorder.dump("n03")
        say("n03", "listing \(await listing(ref))")
        say("n03", "history \(await history(season, ref))")
        withExtendedLifetime(session) {}
    }
}

/// Every transaction for `id`, oldest first.
func history(_ id: String, _ ref: Date) async -> String {
    var items: [(Date, String)] = []
    for await result in Transaction.all where result.unsafePayloadValue.productID == id {
        items.append((result.unsafePayloadValue.purchaseDate, describe(result, ref)))
    }
    return "[" + items.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " | ") + "]"
}
