//
//  CommitmentProbes.swift
//  HostTests
//
//  Phase 3 of docs/14-subscriptions-plan.md: monthly billing with a 12-month commitment
//  (iOS and macOS 26.4). A yearly subscription gains a monthly billing plan; what does the
//  product say of its plans, what does a purchase on the monthly plan carry, what happens at
//  each monthly billing, and — the trap Apple documents — does `willAutoRenew` stay true
//  after the person cancels, with only the commitment's own saying so? Prefixed `PROBE cNN`.
//

import Foundation
import StoreKit
import StoreKitTest
import Testing

@MainActor
@Suite("Monthly billing with a 12-month commitment against real StoreKit", .serialized, .timeLimit(.minutes(3)))
struct CommitmentProbes {
    @Test func c00_fileShape() async throws { if #available(macOS 26.4, iOS 26.4, *) { try await Commitment.c00() } }
    @Test func c01_terms() async throws { if #available(macOS 26.4, iOS 26.4, *) { try await Commitment.c01() } }
    @Test func c02_boughtMonthly() async throws { if #available(macOS 26.4, iOS 26.4, *) { try await Commitment.c02() } }
    @Test func c03_billings() async throws { if #available(macOS 26.4, iOS 26.4, *) { try await Commitment.c03() } }
    @Test func c04_cancelled() async throws { if #available(macOS 26.4, iOS 26.4, *) { try await Commitment.c04() } }
}

/// The probes themselves, in a type that can say it needs 26.4: Swift Testing takes no
/// `@available` on a suite or a test.
@MainActor
@available(macOS 26.4, iOS 26.4, *)
enum Commitment {
    /// Which shape of `billingPlans`, at which schema version, makes the yearly product load
    /// with its plans. Variants of the probe's own file, written to a temporary directory.
    static func c00() async throws {
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: configurationURL())) as! [String: Any]
        func plan(_ type: String, enabled: Bool?) -> [String: Any] {
            var plan: [String: Any] = ["billingPlanType": type, "commitmentDisplayPrice": "179.88", "displayPrice": "14.99",
                                       "internalID": "5B000201"]
            if let enabled { plan["isEnabled"] = enabled }
            return plan
        }
        let plans: [String: [[String: Any]]?] = [
            "none (control)": nil,
            "MONTHLY": [plan("MONTHLY", enabled: true)],
            "MONTHLY, no isEnabled": [plan("MONTHLY", enabled: nil)],
            "monthly, no isEnabled": [plan("monthly", enabled: nil)],
            "Monthly": [plan("Monthly", enabled: true)],
        ]
        for major in [4] {
            for (name, plan) in plans.sorted(by: { $0.key < $1.key }) {
                var file = original
                file["version"] = ["major": major, "minor": 0]
                // The monthly plan is not offered in the United States [Apple].
                var settings = file["settings"] as? [String: Any] ?? [:]
                settings["_storefront"] = "GBR"
                settings["_locale"] = "en_GB"
                file["settings"] = settings
                var groups = file["subscriptionGroups"] as! [[String: Any]]
                for g in groups.indices {
                    var subs = groups[g]["subscriptions"] as! [[String: Any]]
                    for i in subs.indices where subs[i]["productID"] as? String == yearly { subs[i]["billingPlans"] = plan ?? [] }
                    groups[g]["subscriptions"] = subs
                }
                file["subscriptionGroups"] = groups
                let url = FileManager.default.temporaryDirectory.appending(path: "plans-\(major)-\(name).storekit")
                try JSONSerialization.data(withJSONObject: file).write(to: url)
                let session = try SKTestSession(contentsOf: url)
                session.resetToDefaultState()
                let product = try await Product.products(for: [yearly]).first
                say("c00", "v\(major) \(name): \(product == nil ? "NO PRODUCT" : "loaded, \(product!.subscription?.pricingTerms.count ?? -1) pricing terms: \(product.map(terms) ?? "")")")
                withExtendedLifetime(session) {}
            }
        }
    }

    private static func terms(_ product: Product) -> String {
        guard let info = product.subscription else { return "no subscription" }
        return info.pricingTerms.map { terms in
            "\(terms.billingPlanType.rawValue): \(terms.billingDisplayPrice) per \(describe(terms.billingPeriod))"
                + ", commitment \(terms.commitmentInfo.displayPrice) for \(describe(terms.commitmentInfo.period))"
                + ", offers \(terms.subscriptionOffers.count)"
        }.joined(separator: " | ")
    }

    private static func commitment(_ transaction: Transaction) -> String {
        let plan = transaction.billingPlanType?.rawValue ?? "nil"
        guard let info = transaction.commitmentInfo else { return "plan \(plan), no commitment" }
        return "plan \(plan), billing period \(info.billingPeriodNumber)/\(info.totalBillingPeriods), commitment ends \(info.expirationDate), price \(info.price)"
    }

    private static func renewal(_ group: String) async -> String {
        guard let status = try? await Product.SubscriptionInfo.status(for: group).first else { return "no status" }
        guard case let .verified(info) = status.renewalInfo else { return "renewal unverified" }
        var text = "\(name(status.state)) willAutoRenew \(info.willAutoRenew), plan \(info.renewalBillingPlanType?.rawValue ?? "nil")"
        if let commitment = info.commitmentInfo {
            text += ", commitment: willAutoRenew \(commitment.willAutoRenew), renews as \(commitment.autoRenewPreference)"
                + " on plan \(commitment.renewalBillingPlanType.rawValue) at \(commitment.renewalPrice) on \(commitment.renewalDate)"
        } else {
            text += ", no commitment info"
        }
        if case let .verified(transaction) = status.transaction { text += " | transaction \(commitment(transaction))" }
        return text
    }

    // MARK: - c01: the plans a product has

    static func c01() async throws {
        let session = try makeSession()
        say("c01", "yearly: \(terms(try await load(yearly)))")
        say("c01", "monthly (no plans): \(terms(try await load(monthly)))")
        withExtendedLifetime(session) {}
    }

    // MARK: - c02: bought on the monthly plan

    static func c02() async throws {
        let session = try makeSession()
        let ref = Date()
        let product = try await load(yearly)
        let result = await attemptPurchase(product, ref, options: [.billingPlanType(.monthly)])
        say("c02", "bought on the monthly plan: \(result)")
        if let latest = await latestTransaction(yearly) {
            for await item in Transaction.all where item.unsafePayloadValue.id == latest {
                say("c02", "transaction \(commitment(item.unsafePayloadValue))")
            }
        }
        say("c02", "status \(await renewal(proGroup))")
        say("c02", "listing \(await listing(ref))")
        withExtendedLifetime(session) {}
    }

    // MARK: - c03: each monthly billing, fast

    static func c03() async throws {
        let session = try makeSession(rate: .oneRenewalEveryTenSeconds)
        let ref = Date()
        let recorder = Recorder(ref)
        recorder.listen()
        let bought = try await buy(try await load(yearly), options: [.billingPlanType(.monthly)])
        say("c03", "bought \(describe(bought, ref)) \(commitment(bought))")
        for second in [5.0, 12, 22, 32] {
            try await pause(second - (Date().timeIntervalSince(ref)))
            say("c03", "t+\(Int(second)) \(await renewal(proGroup))")
        }
        recorder.stop()
        recorder.dump("c03")
        withExtendedLifetime(session) {}
    }

    // MARK: - c04: cancelled in the middle of the commitment

    static func c04() async throws {
        let session = try makeSession()
        let bought = try await buy(try await load(yearly), options: [.billingPlanType(.monthly)])
        try await pause(1)
        say("c04", "before: \(await renewal(proGroup))")
        say("c04", "auto-renew off: \(attempt { try session.disableAutoRenewForTransaction(identifier: UInt(bought.id)) })")
        try await pause(2)
        say("c04", "after: \(await renewal(proGroup))")
        withExtendedLifetime(session) {}
    }
}
