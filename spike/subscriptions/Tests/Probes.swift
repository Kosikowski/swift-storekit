//
//  Probes.swift
//  HostTests
//
//  Phase 0 of docs/14-subscriptions-plan.md: what real StoreKit does with auto-renewable
//  subscriptions, asked one question at a time. Each probe prints what it saw, prefixed
//  `PROBE qNN`, and asserts nothing it does not have to: the answers are what is being
//  found out. Times are seconds from the probe's start; dates a long way off are in days.
//
//  The test environment is one, shared, and outlives the process (../README.md), so the
//  suite is serial and every probe but q04b starts from `resetToDefaultState()`.
//

import CryptoKit
import Foundation
import StoreKit
import StoreKitTest
import Synchronization
import Testing

let monthly = "probe.monthly"
let yearly = "probe.yearly"
let premium = "probe.premium"
let plain = "probe.plain"
let proGroup = "5B1F2A01"
let plainGroup = "5B1F2A02"

/// q04 runs as two processes: `PROBE_PHASE=leave`, then, a while later, `PROBE_PHASE=return`.
let phase = ProcessInfo.processInfo.environment["PROBE_PHASE"]

func say(_ question: String, _ text: String) {
    print("PROBE \(question): \(text)")
}

@MainActor
@Suite("Subscriptions against real StoreKit", .serialized, .timeLimit(.minutes(3)))
struct Probes {
    // MARK: - q02: is a subscription purchase listed late?

    @Test func q02_purchaseIsListedLate() async throws {
        let session = try makeSession()
        let ref = Date()
        let product = try await load(monthly)
        say("q02", "product: \(describe(product))")
        let bought = try await buy(product)
        say("q02", "bought: \(describe(bought, ref))")
        say("q02", "listed at once: \(await listing(ref))")
        say("q02", "listed by \(await waitForListing(bought.id, ref))")
        withExtendedLifetime(session) {}
    }

    // MARK: - q01, q03, q05: a renewal, second by second

    @Test func q01_renewalTimeline() async throws {
        let session = try makeSession(rate: .oneRenewalEveryTenSeconds)
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        let bought = try await buy(try await load(monthly))
        recorder.note("bought \(describe(bought, ref))")
        await recorder.watch(for: 35)
        recorder.stop()
        recorder.dump("q01")
        withExtendedLifetime(session) {}
    }

    // MARK: - q04: a renewal while nothing is running

    @Test(.enabled(if: phase == "leave")) func q04a_subscribeAndLeave() async throws {
        let session = try makeSession(rate: .oneRenewalEveryTenSeconds)
        let ref = Date()
        let bought = try await buy(try await load(monthly))
        say("q04a", "bought at \(Date()) \(describe(bought, ref)); leaving without a reset")
        withExtendedLifetime(session) {}
    }

    @Test(.enabled(if: phase == "return")) func q04b_comeBack() async throws {
        let url = try configurationURL()
        // No reset: what the previous process left is the question.
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        let ref = Date()
        say("q04b", "back at \(ref)")
        var unfinished: [String] = []
        for await result in Transaction.unfinished { unfinished.append(describe(result, ref)) }
        say("q04b", "unfinished: \(unfinished)")
        let recorder = Recorder(ref)
        recorder.listen()
        await recorder.watch(for: 6)
        recorder.stop()
        recorder.dump("q04b")
        var all: [String] = []
        for await result in Transaction.all { all.append(describe(result, ref)) }
        say("q04b", "all: \(all)")
        withExtendedLifetime(session) {}
    }

    // MARK: - q05, q14: which events Status.updates reports; expire and force-renew

    @Test func q05_eventsOnTheStreams() async throws {
        let session = try makeSession()
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        let product = try await load(monthly)
        let bought = try await buy(product)
        recorder.note("bought \(describe(bought, ref))")
        try await pause(3)

        recorder.note("-- auto-renew off: \(attempt { try session.disableAutoRenewForTransaction(identifier: UInt(bought.id)) })")
        try await pause(3)
        recorder.note("status \(await statuses(proGroup, ref))")
        recorder.note("-- auto-renew on: \(attempt { try session.enableAutoRenewForTransaction(identifier: UInt(bought.id)) })")
        try await pause(3)
        recorder.note("status \(await statuses(proGroup, ref))")

        recorder.note("-- force renewal (q14): \(attempt { try session.forceRenewalOfSubscription(productIdentifier: monthly) })")
        try await pause(3)
        recorder.note("listing \(await listing(ref))")
        recorder.note("status \(await statuses(proGroup, ref))")

        recorder.note("-- refund: \(attempt { try session.refundTransaction(identifier: UInt(bought.id)) })")
        try await pause(3)
        recorder.note("listing \(await listing(ref))")
        recorder.note("status \(await statuses(proGroup, ref))")

        let again = try await buy(product)
        recorder.note("bought again \(describe(again, ref))")
        try await pause(3)
        recorder.note("-- expire (q14): \(attempt { try session.expireSubscription(productIdentifier: monthly) })")
        try await pause(3)
        recorder.note("listing \(await listing(ref))")
        recorder.note("status \(await statuses(proGroup, ref))")
        recorder.stop()
        recorder.dump("q05")
        withExtendedLifetime(session) {}
    }

    // MARK: - q06: billing retry, with and without a grace period

    @Test(arguments: [false, true]) func q06_billingRetry(grace: Bool) async throws {
        let session = try makeSession(rate: .oneRenewalEveryTenSeconds)
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = grace
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        let bought = try await buy(try await load(monthly))
        recorder.note("bought \(describe(bought, ref)); grace \(grace)")
        await recorder.watch(for: 30)
        let latest = await latestTransaction(monthly)
        recorder.note("-- resolve issue for \(latest.map { String($0) } ?? "nil"): \(attempt { try session.resolveIssueForTransaction(identifier: UInt(latest ?? bought.id)) })")
        await recorder.watch(for: 15)
        recorder.stop()
        recorder.dump(grace ? "q06-grace" : "q06-retry")
        withExtendedLifetime(session) {}
    }

    // MARK: - q07: upgrade, downgrade, crossgrade

    @Test func q07_planChanges() async throws {
        let session = try makeSession()
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        let first = try await buy(try await load(monthly))
        recorder.note("bought monthly \(describe(first, ref))")
        try await pause(2)
        for (label, id) in [("upgrade to premium", premium), ("downgrade to monthly", monthly), ("crossgrade to yearly", yearly)] {
            let product = try await load(id)
            recorder.note("-- \(label): \(await attemptPurchase(product, ref))")
            try await pause(3)
            recorder.note("listing \(await listing(ref))")
            recorder.note("status \(await statuses(proGroup, ref))")
        }
        var all: [String] = []
        for await result in Transaction.all { all.append(describe(result, ref)) }
        recorder.note("all \(all)")
        recorder.stop()
        recorder.dump("q07")
        withExtendedLifetime(session) {}
    }

    // MARK: - q08: reads from a cancelled task

    @Test func q08_cancelledReads() async throws {
        let session = try makeSession()
        let ref = Date()
        let bought = try await buy(try await load(monthly))
        _ = await waitForListing(bought.id, ref)
        let control = await cancellableReads()
        say("q08", "control: \(control)")
        let cancelled = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancellableReads()
        }.value
        say("q08", "cancelled: \(cancelled)")
        say("q08", "control after: \(await cancellableReads())")
        withExtendedLifetime(session) {}
    }

    // MARK: - q09: introductory eligibility

    @Test func q09_introductoryEligibility() async throws {
        let session = try makeSession()
        let ref = Date()
        let product = try await load(monthly)
        let plainProduct = try await load(plain)
        say("q09", "monthly offer: \(product.subscription.map { describe($0.introductoryOffer) } ?? "not a subscription")")
        say("q09", "plain offer: \(plainProduct.subscription.map { describe($0.introductoryOffer) } ?? "not a subscription")")
        say("q09", "before: \(await eligibility())")
        let bought = try await buy(product)
        say("q09", "bought \(describe(bought, ref))")
        say("q09", "after buying: \(await eligibility())")
        session.clearTransactions()
        say("q09", "after clearTransactions: \(await eligibility())")
        session.resetToDefaultState()
        session.disableDialogs = true
        say("q09", "after resetToDefaultState: \(await eligibility())")
        withExtendedLifetime(session) {}
    }

    // MARK: - q10: win-back

    @Test func q10_winBack() async throws {
        let session = try makeSession(rate: .oneRenewalEveryTenSeconds)
        let ref = Date()
        let product = try await load(monthly)
        say("q10", "win-back offers on the product: \(product.subscription?.winBackOffers.map(describe) ?? [])")
        let bought = try await buy(product)
        say("q10", "bought \(describe(bought, ref))")
        say("q10", "auto-renew off: \(attempt { try session.disableAutoRenewForTransaction(identifier: UInt(bought.id)) })")
        // Let it lapse by itself: expireSubscription is a separate question (q05).
        for second in stride(from: 0, to: 20, by: 2) {
            try await pause(2)
            say("q10", "t+\(second + 2) status \(await statuses(proGroup, ref))")
        }
        let reloaded = try await load(monthly)
        let offer = reloaded.subscription?.winBackOffers.first
        if let offer {
            say("q10", "buy with win-back \(describe(offer)): \(await attemptPurchase(reloaded, ref, options: [.winBackOffer(offer)]))")
        } else {
            say("q10", "no win-back offer on the product to buy with")
        }
        try await pause(2)
        say("q10", "status after \(await statuses(proGroup, ref))")
        withExtendedLifetime(session) {}
    }

    // MARK: - q11: signed offers, and the test-only one

    @Test func q11_signedOffers() async throws {
        let session = try makeSession()
        let ref = Date()
        let product = try await load(monthly)
        let bought = try await buy(product)
        say("q11", "subscribed \(describe(bought, ref))")
        let promotional = try compactJWS([
            "aud": "promotional-offer", "productId": monthly, "offerIdentifier": "promo.returning",
        ])
        let options = Set(Product.PurchaseOption.promotionalOffer("promo.returning", compactJWS: promotional))
        say("q11", "promotional, JWS signed with a key Xcode never saw: \(await attemptPurchase(product, ref, options: options))")
        say("q11", "promotional, the test-only option: \(await attemptBuyProduct(session, monthly, [.promotionalOffer(id: "promo.returning")], ref))")

        // The override: introductory eligibility given back, after it has been used and lapsed.
        _ = attempt { try session.expireSubscription(productIdentifier: monthly) }
        try await pause(2)
        say("q11", "eligible after using it: \(await eligibility())")
        let override = try compactJWS([
            "aud": "introductory-offer-eligibility", "productId": monthly, "allowIntroductoryOffer": true,
        ])
        say("q11", "override, JWS signed with a key Xcode never saw: \(await attemptPurchase(product, ref, options: [.introductoryOfferEligibility(compactJWS: override)]))")
        withExtendedLifetime(session) {}
    }

    // MARK: - q13: an offer code redeemed outside the app

    @Test func q13_codeRedeemedElsewhere() async throws {
        let session = try makeSession()
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        recorder.note("buyProduct with a code: \(await attemptBuyProduct(session, monthly, [.codeOffer(referenceName: "RETURN3")], ref))")
        await recorder.watch(for: 5)
        recorder.stop()
        recorder.dump("q13")
        withExtendedLifetime(session) {}
    }
}

// MARK: - The session and the store

func configurationURL() throws -> URL {
    let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
    return try #require(bundle.url(forResource: "Subscriptions", withExtension: "storekit"))
}

@MainActor
func makeSession(rate: SKTestSession.TimeRate = .realTime) throws -> SKTestSession {
    let session = try SKTestSession(contentsOf: configurationURL())
    session.resetToDefaultState()
    session.disableDialogs = true
    session.clearTransactions()
    session.timeRate = rate
    return session
}

func load(_ id: String) async throws -> Product {
    try #require(try await Product.products(for: [id]).first, "no product \(id): did the file load?")
}

@MainActor
func buy(_ product: Product, options: Set<Product.PurchaseOption> = []) async throws -> Transaction {
    let result = try await product.purchase(options: options)
    guard case let .success(.verified(transaction)) = result else {
        Issue.record("purchase of \(product.id) came to \(result)")
        throw CancellationError()
    }
    await transaction.finish()
    return transaction
}

@MainActor
func attemptPurchase(_ product: Product, _ ref: Date, options: Set<Product.PurchaseOption> = []) async -> String {
    do {
        let result = try await product.purchase(options: options)
        switch result {
        case let .success(verification):
            if case let .verified(transaction) = verification { await transaction.finish() }
            return "success \(describe(verification, ref))"
        case .pending: return "pending"
        case .userCancelled: return "userCancelled"
        @unknown default: return "unknown result"
        }
    } catch {
        return "threw \(String(reflecting: error))"
    }
}

func attemptBuyProduct(_ session: SKTestSession, _ id: String, _ options: Set<Product.PurchaseOption>, _ ref: Date) async -> String {
    do {
        let transaction = try await session.buyProduct(identifier: id, options: options)
        return "ok \(describe(transaction, ref))"
    } catch {
        return "threw \(String(reflecting: error))"
    }
}

func attempt(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "ok"
    } catch {
        return "threw \(String(reflecting: error))"
    }
}

func pause(_ seconds: Double) async throws {
    try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

func listing(_ ref: Date) async -> String {
    var items: [String] = []
    for await result in Transaction.currentEntitlements { items.append(describe(result, ref)) }
    return "[" + items.joined(separator: " | ") + "]"
}

func waitForListing(_ id: UInt64, _ ref: Date) async -> String {
    let start = Date()
    for _ in 0 ..< 100 {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result, transaction.id == id { found = true }
        }
        if found { return String(format: "%.2fs", Date().timeIntervalSince(start)) }
        try? await pause(0.1)
    }
    return "never, in 10s"
}

func statuses(_ group: String, _ ref: Date) async -> String {
    do {
        let all = try await Product.SubscriptionInfo.status(for: group)
        return "[" + all.map { describe($0, ref) }.joined(separator: " | ") + "]"
    } catch {
        return "threw \(String(reflecting: error))"
    }
}

func latestTransaction(_ id: String) async -> UInt64? {
    var latest: Transaction?
    for await result in Transaction.all {
        if case let .verified(transaction) = result, transaction.productID == id,
           transaction.purchaseDate >= (latest?.purchaseDate ?? .distantPast) {
            latest = transaction
        }
    }
    return latest?.id
}

func eligibility() async -> String {
    let pro = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: proGroup)
    let plainGroupEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: plainGroup)
    return "pro group \(pro), plain group (no introductory offer) \(plainGroupEligible)"
}

func cancellableReads() async -> String {
    let isCancelled = Task.isCancelled
    var listed = 0
    for await _ in Transaction.currentEntitlements { listed += 1 }
    let status: String
    do {
        status = "\(try await Product.SubscriptionInfo.status(for: proGroup).count) statuses"
    } catch {
        status = "status threw \(String(reflecting: error))"
    }
    let eligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: plainGroup)
    let ineligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: proGroup)
    return "cancelled \(isCancelled): listed \(listed); \(status); eligible plain \(eligible), pro \(ineligible)"
}

// MARK: - A JWS signed with a key nobody has registered

func compactJWS(_ claims: [String: Any]) throws -> String {
    let key = P256.Signing.PrivateKey()
    var payload = claims
    payload["iss"] = "probe-issuer"
    payload["iat"] = Int(Date().timeIntervalSince1970)
    payload["bid"] = Bundle.main.bundleIdentifier ?? "spike.storekit.subscriptions.host"
    payload["nonce"] = UUID().uuidString.lowercased()
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "PROBE00001", "typ": "JWT"])
    let body = try JSONSerialization.data(withJSONObject: payload)
    let input = base64URL(header) + "." + base64URL(body)
    let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
    return input + "." + base64URL(signature)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - A timeline of both streams, the listing and the statuses

final class Recorder: Sendable {
    let ref: Date
    private let lines = Mutex<[String]>([])
    private let tasks = Mutex<[Task<Void, Never>]>([])

    init(_ ref: Date) { self.ref = ref }

    func note(_ text: String) {
        let at = String(format: "%6.2fs", Date().timeIntervalSince(ref))
        lines.withLock { $0.append("\(at) \(text)") }
    }

    /// Transactions are finished as an app would finish them: renewals included.
    func listen() {
        let ref = ref
        let updates = Task.detached { [self] in
            for await result in Transaction.updates {
                note("UPDATE \(describe(result, ref))")
                if case let .verified(transaction) = result { await transaction.finish() }
            }
        }
        let statuses = Task.detached { [self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                note("STATUS-UPDATE \(describe(status, ref))")
            }
        }
        tasks.withLock { $0 += [updates, statuses] }
    }

    /// Polls the listing every quarter second and the statuses every second, noting changes.
    func watch(for seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        var lastListing = ""
        var lastStatus = ""
        var tick = 0
        while Date() < end {
            let now = await listing(ref)
            if now != lastListing {
                note("listing \(now)")
                lastListing = now
            }
            if tick % 4 == 0 {
                let status = await statuses(proGroup, ref)
                if status != lastStatus {
                    note("status \(status)")
                    lastStatus = status
                }
            }
            tick += 1
            try? await pause(0.25)
        }
    }

    func stop() { tasks.withLock { for task in $0 { task.cancel() } } }

    func dump(_ question: String) {
        for line in lines.withLock({ $0 }) { say(question, line) }
    }
}

// MARK: - Descriptions

func at(_ date: Date?, _ ref: Date) -> String {
    guard let date else { return "nil" }
    let seconds = date.timeIntervalSince(ref)
    return abs(seconds) < 3_600 ? String(format: "%+.1fs", seconds) : String(format: "%+.2fd", seconds / 86_400)
}

func describe(_ result: VerificationResult<Transaction>, _ ref: Date) -> String {
    switch result {
    case let .verified(transaction): describe(transaction, ref)
    case let .unverified(transaction, error): "UNVERIFIED(\(error)) \(describe(transaction, ref))"
    }
}

func describe(_ transaction: Transaction, _ ref: Date) -> String {
    var text = "\(transaction.productID)#\(transaction.id)/\(transaction.originalID)"
    text += " \(transaction.reason == .renewal ? "renewal" : transaction.reason == .purchase ? "purchase" : "reason?")"
    text += " bought\(at(transaction.purchaseDate, ref)) ends\(at(transaction.expirationDate, ref))"
    if transaction.ownershipType != .purchased { text += " owner:\(transaction.ownershipType.rawValue)" }
    if transaction.isUpgraded { text += " UPGRADED" }
    if let revoked = transaction.revocationDate { text += " REVOKED\(at(revoked, ref))" }
    if let offer = transaction.offer {
        text += " offer:\(name(offer.type))/\(offer.id ?? "-")/\(offer.paymentMode.map { "\($0.rawValue)" } ?? "-")"
    }
    if let price = transaction.price { text += " price:\(price)" }
    return text
}

func describe(_ status: Product.SubscriptionInfo.Status, _ ref: Date) -> String {
    var text = name(status.state)
    switch status.transaction {
    case let .verified(transaction): text += " tx:\(describe(transaction, ref))"
    case .unverified: text += " tx:UNVERIFIED"
    }
    switch status.renewalInfo {
    case let .verified(info):
        text += " willRenew:\(info.willAutoRenew) current:\(info.currentProductID) next:\(info.autoRenewPreference ?? "nil")"
        if let reason = info.expirationReason { text += " why:\(name(reason))" }
        if info.isInBillingRetry { text += " IN-RETRY" }
        if let grace = info.gracePeriodExpirationDate { text += " grace-until\(at(grace, ref))" }
        if let renewal = info.renewalDate { text += " renewalDate\(at(renewal, ref))" }
        if !info.eligibleWinBackOfferIDs.isEmpty { text += " winBack:\(info.eligibleWinBackOfferIDs)" }
        if info.priceIncreaseStatus != .noIncreasePending { text += " priceIncrease:\(info.priceIncreaseStatus)" }
        if let price = info.renewalPrice { text += " renewalPrice:\(price)" }
    case .unverified: text += " renewal:UNVERIFIED"
    }
    return text
}

func describe(_ product: Product) -> String {
    guard let subscription = product.subscription else { return "\(product.id) is not a subscription" }
    return "\(product.id) \(product.displayPrice) every \(describe(subscription.subscriptionPeriod)); level \(subscription.groupLevel)"
        + "; introductory \(describe(subscription.introductoryOffer))"
        + "; promotional \(subscription.promotionalOffers.map(describe))"
        + "; win-back \(subscription.winBackOffers.map(describe))"
}

func describe(_ offer: Product.SubscriptionOffer?) -> String {
    guard let offer else { return "none" }
    return "\(offer.id ?? "-") \(offer.type.rawValue) \(offer.paymentMode.rawValue) \(offer.displayPrice)"
        + " × \(offer.periodCount) of \(describe(offer.period))"
}

func describe(_ period: Product.SubscriptionPeriod) -> String {
    "\(period.value) \(period.unit)"
}

func name(_ state: Product.SubscriptionInfo.RenewalState) -> String {
    switch state {
    case .subscribed: "subscribed"
    case .expired: "expired"
    case .inBillingRetryPeriod: "inBillingRetry"
    case .inGracePeriod: "inGracePeriod"
    case .revoked: "revoked"
    default: "state(\(state.rawValue))"
    }
}

func name(_ reason: Product.SubscriptionInfo.RenewalInfo.ExpirationReason) -> String {
    switch reason {
    case .autoRenewDisabled: "autoRenewDisabled"
    case .billingError: "billingError"
    case .didNotConsentToPriceIncrease: "didNotConsentToPriceIncrease"
    case .productUnavailable: "productUnavailable"
    case .unknown: "unknown"
    default: "reason(\(reason.rawValue))"
    }
}

func name(_ type: Transaction.OfferType) -> String {
    switch type {
    case .introductory: "introductory"
    case .promotional: "promotional"
    case .code: "code"
    case .winBack: "winBack"
    default: "type(\(type.rawValue))"
    }
}
