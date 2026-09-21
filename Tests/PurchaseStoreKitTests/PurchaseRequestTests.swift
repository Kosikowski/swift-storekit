import Foundation
import PurchaseCore
import StoreKit
import Synchronization
import Testing

@testable import PurchaseStoreKit

@Suite("What a purchase asks StoreKit for")
struct PurchaseRequestTests {
    private let offers: [OfferID: String] = ["winback.three": "the win-back offer"]

    private func request(_ options: PurchaseOptions, billingPlans: Bool = true) throws(PurchaseError) -> PurchaseRequest<String> {
        try PurchaseRequest(options, winBackOffers: offers, billingPlans: billingPlans)
    }

    @Test("a plain purchase asks for nothing more, and an account token goes as it is")
    func plain() throws {
        let token = UUID()
        let plain = try request(PurchaseOptions(appAccountToken: token))
        #expect(plain.appAccountToken == token)
        #expect(plain.billingPlan == nil)
        #expect(plain.offer == nil)
    }

    @Test("a billing plan is asked for where the system can buy on one, and refused where it cannot, or is not known")
    func billingPlan() throws {
        #expect(try request(PurchaseOptions(billingPlan: .monthly)).billingPlan == .monthly)
        #expect(throws: PurchaseError.unsupported) { try request(PurchaseOptions(billingPlan: .monthly), billingPlans: false) }
        #expect(throws: PurchaseError.unsupported) { try request(PurchaseOptions(billingPlan: .unrecognised)) }
    }

    @Test("a win-back offer is the product's own; one it does not have is refused as unknown")
    func winBack() throws {
        #expect(try request(PurchaseOptions(offer: .winBack("winback.three"))).offer == .winBack("the win-back offer"))
        #expect(throws: PurchaseError.offerRefused(.unknownOffer)) {
            try request(PurchaseOptions(offer: .winBack("winback.none")))
        }
    }

    @Test("a promotional offer and the override go with their signature, and without one are refused")
    func signed() throws {
        var promotional = PurchaseOptions(offer: .promotional("promo"))
        var override = PurchaseOptions(offer: .introductoryOverride)
        #expect(throws: PurchaseError.offerRefused(.missingParameters)) { try request(promotional) }
        #expect(throws: PurchaseError.offerRefused(.missingParameters)) { try request(override) }
        promotional.signature = "jws.promo"
        override.signature = "jws.override"
        #expect(try request(promotional).offer == .promotional("promo", signature: "jws.promo"))
        #expect(try request(override).offer == .introductoryOverride(signature: "jws.override"))
    }
}

@Suite("StoreKit's values, crossed as the package's")
struct StoreKitValueTests {
    @Test("each offer type crosses as itself, and one StoreKit adds later as unrecognised")
    func kinds() {
        #expect(LiveStoreKitGateway.kind(.introductory) == .introductory)
        #expect(LiveStoreKitGateway.kind(.promotional) == .promotional)
        #expect(LiveStoreKitGateway.kind(.winBack) == .winBack)
        #expect(LiveStoreKitGateway.kind(.init(rawValue: "LATER")) == .unrecognised)
    }

    @Test("each payment mode crosses as itself, and one StoreKit adds later as unrecognised")
    func paymentModes() {
        #expect(LiveStoreKitGateway.paymentMode(.freeTrial) == .freeTrial)
        #expect(LiveStoreKitGateway.paymentMode(.payAsYouGo) == .payAsYouGo)
        #expect(LiveStoreKitGateway.paymentMode(.payUpFront) == .payUpFront)
        #expect(LiveStoreKitGateway.paymentMode(.init(rawValue: "LATER")) == .unrecognised)
    }

    @Test("each billing plan crosses as itself, and one StoreKit adds later as unrecognised")
    func plans() {
        guard #available(macOS 26.4, iOS 26.4, *) else { return }
        #expect(LiveStoreKitGateway.plan(.monthly) == .monthly)
        #expect(LiveStoreKitGateway.plan(.upFront) == .upFront)
        #expect(LiveStoreKitGateway.plan(.init(rawValue: "LATER")) == .unrecognised)
    }

    @Test("a result from one of Apple's views crosses as itself")
    func results() {
        guard case .pending = LiveStoreKitGateway.result(of: .pending) else {
            Issue.record("expected pending")
            return
        }
        guard case .userCancelled = LiveStoreKitGateway.result(of: .userCancelled) else {
            Issue.record("expected userCancelled")
            return
        }
    }
}

private let group: SubscriptionGroupID = "21700001"
private let monthly: ProductID = "com.example.pro.monthly"
private let otherPlan: ProductID = "com.example.other.monthly"
private let catalogue: Catalogue = [
    .subscription(monthly, in: group, level: 1),
    .subscription(otherPlan, in: "21700002", level: 1),
]
private let start = Date(timeIntervalSince1970: 2_000_000)
private let end = start.addingTimeInterval(30 * 86_400)

@MainActor
@Suite("Purchases made in Apple's views, handed to the store", .timeLimit(.minutes(1)))
struct AppleViewResultTests {
    private let gateway = FakeStoreKitGateway()
    private let store: PurchaseStore

    init() {
        store = PurchaseStore(catalogue: catalogue, front: AppStoreFront(catalogue: catalogue, gateway: gateway))
    }

    @Test("Ask to Buy in the view is pending; backing out, returned or thrown, is a cancellation")
    func pendingAndCancelled() async throws {
        #expect(try await store.takePurchase(.success(.pending), productID: monthly) == .pending)
        #expect(store.pendingApprovals == [monthly])
        #expect(try await store.takePurchase(.success(.userCancelled), productID: monthly) == .cancelled)
        #expect(try await store.takePurchase(.failure(StoreKitError.userCancelled), productID: monthly) == .cancelled)
    }

    @Test("a view's failure is thrown as its kind")
    func failed() async {
        await #expect(throws: PurchaseError.network) {
            try await store.takePurchase(.failure(URLError(.timedOut)), productID: monthly)
        }
    }

    @Test("an offer code sheet dismissed is a cancellation; one that failed is thrown as its kind")
    func redemption() async throws {
        #expect(try await store.takeRedemption(.failure(StoreKitError.userCancelled)) == .cancelled)
        await #expect(throws: PurchaseError.network) { try await store.takeRedemption(.failure(URLError(.timedOut))) }
    }
}

@Suite("App Store front: what a subscription transaction amounts to", .timeLimit(.minutes(1)))
struct SubscriptionOutcomeTests {
    private let gateway = FakeStoreKitGateway()

    @Test("a plan upgraded away from, handed back, is finished and a purchase: the status says the rest")
    func superseded() async throws {
        let snapshot = gateway.subscription(monthly, from: start, to: end, isUpgraded: true)
        let outcome = try await AppStoreFront.outcome(of: .success(snapshot), catalogue: catalogue, logger: SilentPurchaseLogger())
        #expect(outcome.purchasedProduct == monthly)
        #expect(gateway.finished == [monthly])
    }

    @Test("a period refunded once it had ended, handed back, is finished and refused")
    func pastPeriodWithdrawn() async {
        let snapshot = gateway.subscription(monthly, from: start, to: end, revoked: end)
        await #expect(throws: PurchaseError.revoked) {
            try await AppStoreFront.outcome(of: .success(snapshot), catalogue: catalogue, logger: SilentPurchaseLogger())
        }
        #expect(gateway.finished == [monthly])
        #expect(TransactionTriage.verdict(for: snapshot, catalogue: catalogue) == .pastPeriodWithdrawn)
        let during = gateway.subscription(monthly, from: start, to: end, revoked: end.addingTimeInterval(-1))
        #expect(TransactionTriage.verdict(for: during, catalogue: catalogue) == .withdrawn)
    }

    @Test("a status for a plan of another group, read for this one, is left out of it")
    func otherGroup() async {
        let front = AppStoreFront(catalogue: catalogue, gateway: gateway)
        let own = StatusSnapshot(state: .subscribed, transaction: gateway.subscription(monthly, from: start, to: end), renewal: nil)
        let other = StatusSnapshot(state: .subscribed, transaction: gateway.subscription(otherPlan, from: start, to: end), renewal: nil)
        gateway.state.withLock { $0.statuses[group] = .success([own, other]) }
        #expect(await front.subscriptionStatuses(in: [group])[group]?.map(\.product) == [monthly])
    }
}

extension PurchaseOutcome {
    fileprivate var purchasedProduct: ProductID? {
        if case let .purchased(owned) = self { owned.id } else { nil }
    }
}
