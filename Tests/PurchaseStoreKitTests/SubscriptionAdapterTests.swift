import Foundation
import PurchaseCore
import StoreKit
import Synchronization
import Testing

@testable import PurchaseStoreKit

private let group: SubscriptionGroupID = "21700001"
private let monthly: ProductID = "com.example.pro.monthly"
private let premium: ProductID = "com.example.premium.monthly"
private let pro: ProductID = "com.example.pro"
private let catalogue: Catalogue = [
    .unlock(pro),
    .subscription(monthly, in: group, level: 2),
    .subscription(premium, in: group, level: 1),
]

private final class Log: PurchaseLogging {
    let events = Mutex<[PurchaseEvent]>([])
    func log(_ event: PurchaseEvent) { events.withLock { $0.append(event) } }
}

private let start = Date(timeIntervalSince1970: 2_000_000)
private let end = start.addingTimeInterval(30 * 86_400)

private func renewal(
    willRenew: Bool = true, reason: Product.SubscriptionInfo.RenewalInfo.ExpirationReason? = nil, retrying: Bool = false,
    grace: Date? = nil, next: String? = "com.example.pro.monthly", winBack: [String] = [],
    offer: (StoreKit.Transaction.OfferType, String?, StoreKit.Transaction.Offer.PaymentMode)? = nil
) -> RenewalSnapshot {
    RenewalSnapshot(
        willAutoRenew: willRenew, autoRenewPreference: next, expirationReason: reason, isInBillingRetry: retrying,
        gracePeriodExpirationDate: grace, priceIncreaseStatus: .noIncreasePending, renewalPrice: 15.99,
        currencyCode: "USD", eligibleWinBackOfferIDs: winBack, offerType: offer?.0, offerID: offer?.1,
        offerPaymentMode: offer?.2)
}

@Suite("App Store front: subscriptions", .timeLimit(.minutes(1)))
struct SubscriptionAdapterTests {
    private let gateway = FakeStoreKitGateway()
    private let log = Log()
    private var front: AppStoreFront { AppStoreFront(catalogue: catalogue, gateway: gateway, logger: log) }

    private func status(
        _ state: Product.SubscriptionInfo.RenewalState, _ renewal: RenewalSnapshot? = renewal(),
        product: ProductID = monthly, verification: TransactionSnapshot.Verification = .verified
    ) -> StatusSnapshot {
        StatusSnapshot(
            state: state, transaction: gateway.subscription(product, from: start, to: end, verification: verification),
            renewal: renewal)
    }

    private func held(_ snapshot: StatusSnapshot) -> HeldSubscription? {
        if case let .status(held) = SubscriptionTriage.verdict(for: snapshot, catalogue: catalogue) { return held }
        return nil
    }

    // MARK: - What a status means

    @Test("each of StoreKit's renewal states, and one it adds later, becomes the package's")
    func states() {
        #expect(held(status(.subscribed))?.state == .subscribed)
        #expect(held(status(.inBillingRetryPeriod))?.state == .inBillingRetry)
        #expect(held(status(.revoked))?.state == .revoked)
        #expect(held(status(.expired, renewal(willRenew: false, reason: .autoRenewDisabled)))?.state == .expired(.autoRenewDisabled))
        #expect(held(status(Product.SubscriptionInfo.RenewalState(rawValue: 99)))?.state == .unrecognised)
    }

    @Test("a grace period lasts until the date the renewal info vouches for, or, unvouched for, only to the period's end")
    func grace() {
        let until = end.addingTimeInterval(16 * 86_400)
        #expect(held(status(.inGracePeriod, renewal(retrying: true, grace: until)))?.state == .inGracePeriod(until: until))
        #expect(held(status(.inGracePeriod, nil))?.state == .inGracePeriod(until: end))
    }

    /// Measured in the iOS simulator: after a grace period the state says expired while
    /// the renewal info still says retrying. Apple's own table calls that billing retry.
    @Test("EXPIRED while still retrying is billing retry, by Apple's table")
    func expiredButRetrying() {
        #expect(held(status(.expired, renewal(reason: .billingError, retrying: true)))?.state == .inBillingRetry)
    }

    @Test("an expiry with no reason is UNSTATED — what the moment at a renewal looks like — and a reason added later is unrecognised")
    func lapses() {
        #expect(held(status(.expired, renewal(willRenew: false, reason: nil)))?.state == .expired(.unstated))
        #expect(SubscriptionTriage.lapse(.billingError) == .billingError)
        #expect(SubscriptionTriage.lapse(.didNotConsentToPriceIncrease) == .didNotConsentToPriceIncrease)
        #expect(SubscriptionTriage.lapse(.productUnavailable) == .productUnavailable)
        #expect(SubscriptionTriage.lapse(.unknown) == .unknown)
        #expect(SubscriptionTriage.lapse(Product.SubscriptionInfo.RenewalInfo.ExpirationReason(rawValue: 99)) == .unrecognised)
    }

    @Test("the renewal info is carried across: what it renews to, at what price, and the win-back offers Apple allows")
    func renewalInfo() {
        let info = held(status(.expired, renewal(willRenew: false, reason: .autoRenewDisabled, next: nil, winBack: ["winback.three"])))?.renewal
        #expect(info == Renewal(
            willRenew: false, nextProduct: nil, price: 15.99, currencyCode: "USD", priceIncrease: .none,
            winBackOffers: ["winback.three"]))
        #expect(held(status(.subscribed, nil))?.renewal == nil)
    }

    /// A promotional offer bought by a current subscriber waits for the next renewal
    /// [Apple]: the renewal info says so, and without it the offer reads as not applied.
    @Test("the status carries StoreKit's identifier for its transaction")
    func transactionID() {
        var snapshot = status(.subscribed)
        var transaction = snapshot.transaction
        transaction.id = 7_001
        snapshot = StatusSnapshot(state: .subscribed, transaction: transaction, renewal: snapshot.renewal)
        #expect(held(snapshot)?.transactionID == 7_001)
    }

    /// On a 12-month commitment the renewal says it will renew after a cancellation, and only
    /// the commitment's own renewal says it ends [Apple]: both are carried across, apart.
    @Test("a commitment is carried across: which month of how many, and what happens when it ends")
    func commitment() {
        var transaction = gateway.subscription(monthly, from: start, to: end)
        transaction.commitment = SubscriptionCommitment(
            plan: .monthly, billingPeriod: 12, billingPeriods: 12, endsAt: end, price: 179.88)
        var info = renewal()
        info.commitment = CommitmentRenewal(willRenew: false, nextProduct: monthly, plan: .monthly, renewsAt: end, price: 179.88)
        let held = held(StatusSnapshot(state: .subscribed, transaction: transaction, renewal: info))
        #expect(held?.commitment == transaction.commitment)
        #expect(held?.renewal?.commitment == info.commitment)
        #expect(held?.renewal?.willRenew == true)
        #expect(held?.willRenewAtPeriodEnd == false)
    }

    @Test("a subscription held through a BUNDLE says which, and whether it leaves it; leaving it is a lapse of its own")
    func bundle() {
        var info = renewal()
        info.bundle = BundleMembership(product: "com.example.bundle", group: "21799999", willLeave: true)
        #expect(held(StatusSnapshot(state: .subscribed, transaction: gateway.subscription(monthly, from: start, to: end), renewal: info))?.bundle
            == BundleMembership(product: "com.example.bundle", group: "21799999", willLeave: true))
        #expect(SubscriptionTriage.lapse(Product.SubscriptionInfo.RenewalInfo.ExpirationReason(rawValue: 6)) == .unbundled)
    }

    @Test("an offer the next renewal is at is read from the renewal info")
    func renewalOffer() {
        let waiting = held(status(.subscribed, renewal(offer: (.promotional, "promo.returning", .payAsYouGo))))
        #expect(waiting?.renewal?.offer == AppliedOffer(kind: .promotional, id: "promo.returning", paymentMode: .payAsYouGo))
        #expect(held(status(.subscribed))?.renewal?.offer == nil)
    }

    @Test("the offer a period was bought with is read from the transaction, and a kind StoreKit adds later is said")
    func offers() {
        let intro = gateway.subscription(monthly, from: start, to: end, offer: (.introductory, nil, .payAsYouGo))
        #expect(SubscriptionTriage.offer(of: intro) == AppliedOffer(kind: .introductory, paymentMode: .payAsYouGo))
        let winBack = gateway.subscription(monthly, from: start, to: end, offer: (.winBack, "winback.three", .payAsYouGo))
        #expect(SubscriptionTriage.offer(of: winBack) == AppliedOffer(kind: .winBack, id: "winback.three", paymentMode: .payAsYouGo))
        let later = gateway.subscription(monthly, from: start, to: end, offer: (StoreKit.Transaction.OfferType(rawValue: 99), nil, .freeTrial))
        #expect(SubscriptionTriage.offer(of: later)?.kind == .unrecognised)
        #expect(SubscriptionTriage.paymentMode(.payUpFront) == .payUpFront)
        #expect(SubscriptionTriage.paymentMode(.oneTime) == .oneTime)
        #expect(SubscriptionTriage.offer(of: gateway.subscription(monthly, from: start, to: end)) == nil)
    }

    @Test("a status whose transaction does not verify is not counted; one for somebody else's product is not ours")
    func unverifiedAndForeign() {
        #expect(SubscriptionTriage.verdict(for: status(.subscribed, verification: .unverified), catalogue: catalogue) == .unverified)
        #expect(SubscriptionTriage.verdict(for: status(.subscribed, product: "somebody.elses"), catalogue: catalogue) == .foreign)
        #expect(SubscriptionTriage.verdict(for: status(.subscribed, product: pro), catalogue: catalogue) == .foreign)
    }

    // MARK: - Reading statuses

    @Test("statuses are read per group; one that does not verify is logged; a group that cannot be read is LEFT OUT, never empty")
    func reading() async {
        let other: SubscriptionGroupID = "21700002"
        gateway.state.withLock {
            $0.statuses[group] = .success([
                status(.subscribed), status(.expired, product: premium, verification: .unverified),
            ])
            $0.statuses[other] = .failure(StoreKitError.networkError(URLError(.notConnectedToInternet)))
        }
        let answer = await front.subscriptionStatuses(in: [group, other])
        #expect(answer.keys.sorted() == [group])
        #expect(answer[group]?.map(\.product) == [monthly])
        #expect(log.events.withLock { $0 } == [.unverifiedTransactionIgnored(premium), .subscriptionStatusUnavailable(other)])
    }

    /// A status read from a cancelled task answers "never subscribed" (measured).
    @Test("a CANCELLED caller is still answered from a task nobody cancels")
    func cancelledCaller() async {
        gateway.state.withLock { $0.statuses[group] = .success([status(.subscribed)]) }
        let front = front
        let answer = await Task { () -> [SubscriptionGroupID: [HeldSubscription]] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await front.subscriptionStatuses(in: [group])
        }.value
        #expect(answer[group]?.count == 1)
    }

    // MARK: - The listing and the stream

    @Test("a subscription in the listing carries its period's end; an unlock never has one")
    func listingCarriesExpiry() async {
        gateway.state.withLock {
            $0.entitlements = [gateway.subscription(monthly, from: start, to: end), gateway.transaction(pro)]
        }
        let owned = await front.ownedProducts()
        #expect(owned.first { $0.id == monthly }?.expirationDate == end)
        #expect(owned.first { $0.id == pro }?.expirationDate == nil)
    }

    @Test("a transaction UPGRADED AWAY FROM is not counted in the listing, and is finished, unannounced, on the stream")
    func upgradedAwayFrom() async {
        let old = gateway.subscription(monthly, from: start, to: end, isUpgraded: true)
        gateway.state.withLock { $0.entitlements = [old, gateway.subscription(premium, from: start, to: end)] }
        #expect(await front.ownedProducts().map(\.id) == [premium])

        var updates = front.transactionUpdates().makeAsyncIterator()
        gateway.deliver(old)
        gateway.deliver(gateway.transaction(pro))
        #expect(await updates.next()?.productID == pro)
        #expect(gateway.finished == [monthly, pro])
    }

    /// Measured: refunding the first period of a subscription that has renewed revokes
    /// that transaction only, and the subscription carries on.
    @Test("a PAST PERIOD refunded is finished and not announced; the current period refunded is a withdrawal")
    func refunds() async {
        var updates = front.transactionUpdates().makeAsyncIterator()
        gateway.deliver(gateway.subscription(monthly, from: start, to: end, revoked: end.addingTimeInterval(3_600)))
        gateway.deliver(gateway.subscription(monthly, from: end, to: end.addingTimeInterval(30 * 86_400), revoked: end.addingTimeInterval(3_600)))
        gateway.deliver(gateway.transaction(pro))
        // One withdrawal, the current period's, and then whatever came next.
        #expect(await updates.next() == .withdrawn(monthly))
        #expect(await updates.next()?.productID == pro)
        #expect(gateway.finished == [monthly, monthly, pro])
    }

    /// An expiry, a cancellation and a grace period send no transaction at all (measured):
    /// a status change is how they are heard.
    @Test("a status change is announced with its facts")
    func statusChangeAnnounced() async {
        var updates = front.transactionUpdates().makeAsyncIterator()
        await Task.yield()
        gateway.announce(status(.expired, renewal(willRenew: false, reason: .autoRenewDisabled)))
        guard case let .subscriptionChanged(held)? = await updates.next() else {
            Issue.record("expected a status change")
            return
        }
        #expect(held.state == .expired(.autoRenewDisabled))
    }

    @Test("a subscription bought is handed back with its period's end, and the offer it was bought with")
    func purchase() async throws {
        let bought = gateway.subscription(monthly, from: start, to: end, offer: (.winBack, "winback.three", .payAsYouGo))
        gateway.state.withLock { $0.purchase = .success(.success(bought)) }
        guard case let .purchased(owned) = try await front.purchase(monthly, confirmation: .automatic) else {
            Issue.record("expected purchased")
            return
        }
        #expect(owned.expirationDate == end)
        #expect(owned.offer == AppliedOffer(kind: .winBack, id: "winback.three", paymentMode: .payAsYouGo))
    }

    @Test("the offer and the store's signature reach StoreKit as they were asked for")
    func purchaseWithOffer() async throws {
        gateway.state.withLock { $0.purchase = .success(.success(gateway.subscription(monthly, from: start, to: end))) }
        var options = PurchaseOptions(offer: .promotional("promo.returning"), billingPlan: .monthly)
        options.signature = "compact.jws"
        _ = try await front.purchase(monthly, options: options, confirmation: .automatic)
        #expect(gateway.state.withLock { $0.purchaseOptions } == options)
    }

    // MARK: - Purchases asked for outside the app

    @Test("a purchase asked for outside the app is announced as a request, a win-back offer with it; somebody else's is not")
    func purchaseRequested() async {
        var updates = front.transactionUpdates().makeAsyncIterator()
        await Task.yield()
        gateway.request(IntentSnapshot(productID: "somebody.elses"))
        gateway.request(IntentSnapshot(productID: monthly, offerType: .winBack, offerID: "winback.three"))
        gateway.request(IntentSnapshot(productID: pro))
        #expect(await updates.next() == .purchaseRequested(RequestedPurchase(product: monthly, offer: .winBack("winback.three"))))
        #expect(await updates.next() == .purchaseRequested(RequestedPurchase(product: pro)))
    }

    @Test("a promotional offer chosen outside the app goes with the request; an introductory one needs no asking")
    func purchaseRequestedOffers() {
        let promotional = IntentSnapshot(productID: monthly, offerType: .promotional, offerID: "promo")
        #expect(AppStoreFront.request(from: promotional, logger: log) == RequestedPurchase(product: monthly, offer: .promotional("promo")))
        let introductory = IntentSnapshot(productID: monthly, offerType: .introductory, offerID: nil)
        #expect(AppStoreFront.request(from: introductory, logger: log) == RequestedPurchase(product: monthly))
        #expect(log.events.withLock { $0 }.isEmpty)
    }

    @Test("an offer that cannot be asked for — a kind StoreKit added later, or one with no identifier — is left off, and said")
    func purchaseRequestedUnrecognisedOffer() {
        let later = IntentSnapshot(productID: monthly, offerType: .init(rawValue: "LATER"), offerID: "later")
        #expect(AppStoreFront.request(from: later, logger: log) == RequestedPurchase(product: monthly))
        let unnamed = IntentSnapshot(productID: monthly, offerType: .winBack, offerID: nil)
        #expect(AppStoreFront.request(from: unnamed, logger: log) == RequestedPurchase(product: monthly))
        #expect(log.events.withLock { $0 } == [.requestedOfferUnrecognised(monthly), .requestedOfferUnrecognised(monthly)])
    }

    // MARK: - Introductory eligibility

    /// Apple's eligibility is the Apple Account's own [Apple].
    @Test("a FAMILY MEMBER's transaction bought with the introductory offer uses up nothing of this account's")
    func introductoryEligibilityShared() async {
        gateway.state.withLock {
            $0.history[group] = [
                gateway.subscription(monthly, from: start, to: end, ownership: .familyShared, offer: (.introductory, nil, .freeTrial)),
            ]
        }
        #expect(await front.introductoryEligibility(in: [group]) == [group: true])
    }

    /// Measured: StoreKit's answer keeps its first value for the life of the process, and
    /// said "eligible" after the purchase that used the offer.
    @Test("StoreKit's word on the introductory offer stands UNLESS a verified transaction in the group was bought with it")
    func introductoryEligibility() async {
        let other: SubscriptionGroupID = "21700002"
        let third: SubscriptionGroupID = "21700003"
        gateway.state.withLock {
            $0.history[group] = [gateway.subscription(monthly, from: start, to: end, offer: (.introductory, nil, .freeTrial))]
            $0.history[other] = [
                gateway.subscription(monthly, from: start, to: end, verification: .unverified, offer: (.introductory, nil, .freeTrial)),
                gateway.subscription(monthly, from: start, to: end, offer: (.promotional, "promo", .payAsYouGo)),
            ]
            $0.eligible[third] = false
        }
        #expect(await front.introductoryEligibility(in: [group, other, third]) == [group: false, other: true, third: false])
    }

    /// Read from a cancelled task, the transactions would be none, and "none" would offer
    /// again an introductory offer already used.
    @Test("introductory eligibility is read in a task nobody cancels")
    func introductoryEligibilityCancelled() async {
        gateway.state.withLock {
            $0.history[group] = [gateway.subscription(monthly, from: start, to: end, offer: (.introductory, nil, .freeTrial))]
        }
        let front = front
        let answer = await Task { () -> [SubscriptionGroupID: Bool] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await front.introductoryEligibility(in: [group])
        }.value
        #expect(answer == [group: false])
    }
}
