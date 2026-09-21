//
//  RealNonRenewingTests.swift
//  DemoTests
//
//  A non-renewing subscription through the real adapter, against real StoreKit: the habits
//  phase 3 measured (spike/README.md, n01–n03), each held to what is written down, and the
//  store end to end — bought, and bought again.
//

@testable import Demo
import Foundation
import PurchaseCore
import PurchaseStoreKit
import PurchaseTestKit
import StoreKit
import StoreKitTest
import Testing

extension RealStoreKit {
    @MainActor
    @Suite("Real StoreKit: non-renewing subscriptions, through the real adapter", .serialized, .timeLimit(.minutes(2)))
    struct RealNonRenewingTests {
        private static func configurationURL() throws -> URL {
            let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
            return try #require(bundle.url(forResource: "Demo", withExtension: "storekit"))
        }

        private func session() throws -> SKTestSession {
            let session = try SKTestSession(contentsOf: Self.configurationURL())
            session.resetToDefaultState()
            session.disableDialogs = true
            session.clearTransactions()
            return session
        }

        private var front: AppStoreFront { AppStoreFront(catalogue: Shop.catalogue) }

        private func listed() async -> Int {
            await front.ownedProducts().filter { $0.id == Shop.season }.count
        }

        @Test("NON-RENEWING: bought, it runs at once for the catalogue's thirty days — and HABIT: StoreKit gives it no end")
        func bought() async throws {
            let session = try session()
            let store = PurchaseStore(catalogue: Shop.catalogue, front: front)
            await store.start()
            guard case let .nonRenewing(period) = try await store.purchase(Shop.season) else {
                Issue.record("expected a non-renewing period")
                return
            }
            #expect(period.endsAt.timeIntervalSince(period.startedAt) == 30 * 86_400)
            #expect(store.standing.access(to: Shop.season).isGranted == true)
            #expect(await waitUntil(timeout: .seconds(10)) { await listed() == 1 })
            var ends: [Date?] = []
            for await result in Transaction.currentEntitlements where result.unsafePayloadValue.productID == Shop.season.rawValue {
                ends.append(result.unsafePayloadValue.expirationDate)
            }
            #expect(ends == [nil], "HABIT: a non-renewing transaction has no expiration date")
            withExtendedLifetime(session) {}
        }

        /// Measured: bought again, a new transaction, and the listing keeps both — though the
        /// iOS simulator sometimes hands back the one before and buys nothing (n03), which the
        /// store says is a failure (D52).
        @Test("NON-RENEWING: bought again, the days add up — and HABIT: the listing keeps both purchases")
        func boughtAgain() async throws {
            let session = try session()
            let store = PurchaseStore(catalogue: Shop.catalogue, front: front)
            await store.start()
            try await store.purchase(Shop.season)
            #expect(await waitUntil(timeout: .seconds(10)) { await listed() == 1 })
            try await Task.sleep(for: .seconds(1.5))
            let completion: PurchaseCompletion
            do throws(PurchaseError) {
                completion = try await store.purchase(Shop.season)
            } catch .system {
                #if os(iOS)
                // Excused only where StoreKit itself says nothing was bought.
                #expect(session.allTransactions().filter { $0.productIdentifier == Shop.season.rawValue }.count == 1)
                withKnownIssue("the iOS simulator handed back the purchase before, and bought nothing", isIntermittent: true) {
                    Issue.record("bought nothing")
                }
                return
                #else
                Issue.record("the Mac handed back the purchase before")
                return
                #endif
            }
            guard case let .nonRenewing(period) = completion else {
                Issue.record("expected a non-renewing period, got \(completion)")
                return
            }
            #expect(period.endsAt.timeIntervalSince(period.startedAt) == 60 * 86_400)
            #expect(await waitUntil(timeout: .seconds(10)) { await listed() == 2 }, "HABIT: both purchases are listed")
            withExtendedLifetime(session) {}
        }
    }
}
