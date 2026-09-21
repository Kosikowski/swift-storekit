@testable import PurchaseCore
import Foundation
import Testing

@Suite("Unlisted purchases")
struct UnlistedPurchasesTests {
    private let now = Shop.epoch
    private let monthly: ProductID = "com.example.pro.monthly"
    private let season: ProductID = "com.example.season"

    private func renewal(_ days: Double) -> OwnedProduct {
        OwnedProduct(
            id: monthly, originalPurchaseDate: now, purchaseDate: now.addingTimeInterval(days * 86_400),
            expirationDate: now.addingTimeInterval((days + 30) * 86_400))
    }

    private func purchase(_ days: Double) -> OwnedProduct {
        OwnedProduct(id: season, originalPurchaseDate: now.addingTimeInterval(days * 86_400))
    }

    @Test("an earlier renewal arriving after a later one does not take its place")
    func newerKept() {
        var unlisted = UnlistedPurchases()
        unlisted.hold(renewal(60), until: now.addingTimeInterval(30))
        unlisted.hold(renewal(0), until: now.addingTimeInterval(30))
        #expect(unlisted.held == [renewal(60)])
        unlisted.hold(renewal(90), until: now.addingTimeInterval(30))
        #expect(unlisted.held == [renewal(90)])
    }

    @Test("the same purchase held again is held until the later deadline")
    func heldAgain() {
        var unlisted = UnlistedPurchases()
        unlisted.hold(renewal(0), until: now.addingTimeInterval(10))
        unlisted.hold(renewal(0), until: now.addingTimeInterval(30))
        #expect(unlisted.held == [renewal(0)])
        #expect(unlisted.nextLapse == now.addingTimeInterval(30))
    }

    @Test("purchases held alongside are each held once, and each let go by its own listing")
    func alongside() {
        var unlisted = UnlistedPurchases()
        unlisted.hold(purchase(0), until: now.addingTimeInterval(30), alongside: true)
        unlisted.hold(purchase(10), until: now.addingTimeInterval(30), alongside: true)
        unlisted.hold(purchase(0), until: now.addingTimeInterval(30), alongside: true)
        #expect(Set(unlisted.held) == [purchase(0), purchase(10)])
        #expect(unlisted.held.count == 2)
        unlisted.settle(listedIn: [purchase(0)], at: now)
        #expect(unlisted.held == [purchase(10)])
    }

    @Test("a hold lapses at its deadline, and a withdrawal drops every hold of the product")
    func lapseAndDrop() {
        var unlisted = UnlistedPurchases()
        unlisted.hold(purchase(0), until: now.addingTimeInterval(30), alongside: true)
        unlisted.hold(purchase(10), until: now.addingTimeInterval(60), alongside: true)
        unlisted.settle(listedIn: [], at: now.addingTimeInterval(30))
        #expect(unlisted.held == [purchase(10)])
        unlisted.drop(season)
        #expect(unlisted.held.isEmpty)
    }
}
