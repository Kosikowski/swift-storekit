import Foundation
import StoreKit
import StoreKitTest
import Testing

@MainActor
@Suite("SKTestSession in a hosted test bundle", .serialized)
struct SKTestSessionSpike {
    private func session() throws -> SKTestSession {
        let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
        let file = try #require(bundle.url(forResource: "Spike", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: file)
        // The environment outlives the process: what one run armed, the next inherits.
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    private func listed() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.currentEntitlements {
            if case let .verified(t) = result { ids.append(t.productID) }
        }
        return ids.sorted()
    }

    private func waitForListing(_ expected: [String]) async throws -> [String] {
        var ids: [String] = []
        for _ in 0 ..< 50 {
            ids = await listed()
            if ids == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ids
    }

    @Test("route A: product.purchase() with dialogs disabled")
    func productPurchase() async throws {
        let session = try session()
        let product = try #require(try await Product.products(for: ["spike.pro"]).first)
        let result = try await product.purchase()
        guard case let .success(.verified(transaction)) = result else {
            Issue.record("unexpected result: \(result)")
            return
        }
        await transaction.finish()
        let immediately = await listed()
        print("SPIKE A bought:", transaction.productID, "listed at once:", immediately)
        let later = try await waitForListing(["spike.pro"])
        print("SPIKE A listed later:", later)
        #expect(later == ["spike.pro"])
        withExtendedLifetime(session) {}
    }

    @Test("route B: session.buyProduct, with and without the purchaseDate option")
    func sessionBuy() async throws {
        let session = try session()
        do {
            let t = try await session.buyProduct(identifier: "spike.pro")
            print("SPIKE B plain buyProduct ok:", t.productID)
        } catch {
            print("SPIKE B plain buyProduct failed:", String(reflecting: error))
        }
        let then = Date(timeIntervalSinceNow: -13 * 86_400)
        do {
            let t = try await session.buyProduct(identifier: "spike.trial", options: [.purchaseDate(then)])
            print("SPIKE B backdated buyProduct ok: original", t.originalPurchaseDate, "purchase", t.purchaseDate, "wanted", then)
        } catch {
            print("SPIKE B backdated buyProduct failed:", String(reflecting: error))
        }
        withExtendedLifetime(session) {}
    }

    @Test("route C: product.purchase(options:) with the test-only purchaseDate")
    func backdatedProductPurchase() async throws {
        let session = try session()
        let then = Date(timeIntervalSinceNow: -13 * 86_400)
        let product = try #require(try await Product.products(for: ["spike.trial"]).first)
        do {
            let result = try await product.purchase(options: [.purchaseDate(then)])
            if case let .success(.verified(t)) = result {
                await t.finish()
                print("SPIKE C backdated purchase ok: original", t.originalPurchaseDate, "purchase", t.purchaseDate, "wanted", then)
            } else {
                print("SPIKE C unexpected result:", result)
            }
        } catch {
            print("SPIKE C backdated purchase failed:", String(reflecting: error))
        }
        withExtendedLifetime(session) {}
    }

    @Test("what a CANCELLED task reads from currentEntitlements")
    func cancelledRead() async throws {
        let session = try session()
        let product = try #require(try await Product.products(for: ["spike.pro"]).first)
        if case let .success(.verified(t)) = try await product.purchase() { await t.finish() }
        let seen = try await waitForListing(["spike.pro"])
        #expect(seen == ["spike.pro"])
        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            var count = 0
            for await _ in Transaction.currentEntitlements { count += 1 }
            return count
        }
        let cancelledCount = await task.value
        print("SPIKE D cancelled read saw:", cancelledCount, "of", seen.count)
        withExtendedLifetime(session) {}
    }

    private func buy(_ label: String) async {
        do {
            let product = try #require(try await Product.products(for: ["spike.pro"]).first)
            switch try await product.purchase() {
            case let .success(.verified(t)):
                await t.finish()
                print("SPIKE \(label): verified")
            case .success(.unverified):
                print("SPIKE \(label): UNVERIFIED")
            case let other:
                print("SPIKE \(label):", other)
            }
        } catch {
            print("SPIKE \(label): threw", String(reflecting: error))
        }
    }

    @Test("route E: setSimulatedError — a load, a purchase and a verification failure, each from a clean environment")
    func simulatedErrors() async throws {
        let session = try session()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        do { print("SPIKE E load returned", try await Product.products(for: ["spike.pro"]).count) }
        catch { print("SPIKE E load threw:", String(reflecting: error)) }

        session.resetToDefaultState()
        session.disableDialogs = true
        try await session.setSimulatedError(.purchase(.purchaseNotAllowed), forAPI: .purchase)
        await buy("E purchase armed")

        session.resetToDefaultState()
        session.disableDialogs = true
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        await buy("E verification armed")
        var listed: [String] = []
        for _ in 0 ..< 30 {
            listed = []
            for await result in Transaction.currentEntitlements {
                if case .unverified = result { listed.append("unverified") } else { listed.append("verified") }
            }
            if !listed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("SPIKE E listing while verification is armed:", listed)
        session.resetToDefaultState()
        withExtendedLifetime(session) {}
    }

    @Test("route F: is a simulated error disarmed by passing nil, as documented?")
    func disarmingWithNil() async throws {
        let session = try session()
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await buy("F after nil for loadProducts")
        session.resetToDefaultState()
        session.disableDialogs = true
        try await session.setSimulatedError(nil, forAPI: .verification)
        await buy("F after nil for verification")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        try await session.setSimulatedError(nil, forAPI: .purchase)
        await buy("F after nil for purchase")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        await buy("F after resetToDefaultState")
        withExtendedLifetime(session) {}
    }
}
