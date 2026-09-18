import Foundation
import StoreKit
import StoreKitTest
import Testing

@Suite("SKTestSession in a package test target", .serialized)
struct SKTestSessionSpike {
    private func session() throws -> SKTestSession {
        let file = try #require(Bundle.module.url(forResource: "Spike", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: file)
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    @Test("the session loads and the products come back")
    func loadsProducts() async throws {
        let session = try session()
        let products = try await Product.products(for: ["spike.pro", "spike.trial"])
        print("SPIKE products:", products.map(\.id).sorted())
        #expect(products.count == 2)
        withExtendedLifetime(session) {}
    }

    @Test("buyProduct goes through and is listed as an entitlement")
    func buys() async throws {
        let session = try session()
        let transaction = try await session.buyProduct(identifier: "spike.pro")
        print("SPIKE bought:", transaction.productID, transaction.originalPurchaseDate)
        var listed: [String] = []
        for _ in 0 ..< 50 where listed.isEmpty {
            for await result in Transaction.currentEntitlements {
                if case let .verified(t) = result { listed.append(t.productID) }
            }
            if listed.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        print("SPIKE listed:", listed)
        #expect(listed == ["spike.pro"])
        withExtendedLifetime(session) {}
    }

    @Test("the test-only purchaseDate option backdates a non-consumable")
    func backdates() async throws {
        let session = try session()
        let then = Date(timeIntervalSinceNow: -13 * 86_400)
        let transaction = try await session.buyProduct(identifier: "spike.trial", options: [.purchaseDate(then)])
        print("SPIKE backdated:", transaction.originalPurchaseDate, "wanted", then)
        #expect(abs(transaction.originalPurchaseDate.timeIntervalSince(then)) < 5)
        withExtendedLifetime(session) {}
    }

    @Test("what a CANCELLED task reads from currentEntitlements")
    func cancelledRead() async throws {
        let session = try session()
        _ = try await session.buyProduct(identifier: "spike.pro")
        // Wait until an ordinary read lists it, so an empty answer below means cancellation.
        var seen = 0
        for _ in 0 ..< 50 where seen == 0 {
            for await _ in Transaction.currentEntitlements { seen += 1 }
            if seen == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(seen == 1)
        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            var count = 0
            for await _ in Transaction.currentEntitlements { count += 1 }
            return count
        }
        let cancelledCount = await task.value
        print("SPIKE cancelled read saw:", cancelledCount, "of", seen)
        withExtendedLifetime(session) {}
    }
}
