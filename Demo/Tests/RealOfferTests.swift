//
//  RealOfferTests.swift
//  DemoTests
//
//  Offers through the real adapter, against real StoreKit: the terms as StoreKit states
//  them, introductory eligibility and the first answer StoreKit keeps, a win-back offer
//  bought, and an offer StoreKit did not apply and did not say so. Phase 2 of the plan,
//  each habit held to what phase 0 measured (spike/README.md).
//
//  Part of the subscription suite, so that it runs in that suite's order: there is one
//  test environment, and it outlives the process.
//
//  A win-back offer, and the override, need a lapse, and `expireSubscription` makes one on
//  the Mac only: in the iOS 27 simulator it had no effect within three seconds, and buying
//  again after a lapse returned the old transaction (spike/README.md, q10 and q14).
//

@testable import Demo
import CryptoKit
import Foundation
import PurchaseCore
import PurchaseStoreKit
import PurchaseTestKit
import StoreKit
import StoreKitTest
import Testing

/// The app's server, signing with a key App Store Connect — and Xcode — never saw. What
/// StoreKit does with a signature it cannot check is the question.
private struct UnregisteredSigner: OfferSigning {
    func signature(for request: OfferSignatureRequest) async throws -> String {
        var claims: [String: Any] = [
            "productId": request.product.rawValue, "iss": "demo-tests", "iat": Int(Date().timeIntervalSince1970),
            "bid": Bundle.main.bundleIdentifier ?? "com.example.purchasedemo", "nonce": UUID().uuidString.lowercased(),
        ]
        switch request.kind {
        case let .promotional(offer):
            claims["aud"] = "promotional-offer"
            claims["offerIdentifier"] = offer.rawValue
        case .introductoryOverride:
            claims["aud"] = "introductory-offer-eligibility"
            claims["allowIntroductoryOffer"] = true
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "DEMO000001", "typ": "JWT"])
        let body = try JSONSerialization.data(withJSONObject: claims)
        let input = Self.base64URL(header) + "." + Self.base64URL(body)
        let signature = try P256.Signing.PrivateKey().signature(for: Data(input.utf8)).rawRepresentation
        return input + "." + Self.base64URL(signature)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A lapse is made with `expireSubscription`, which works on the Mac alone.
#if os(macOS)
private let lapsesOnDemand = true
#else
private let lapsesOnDemand = false
#endif

extension RealStoreKit.RealSubscriptionTests {
    /// Subscribed to the monthly plan — with its introductory offer — and lapsed from it.
    private func lapsedMonthly(_ store: PurchaseStore, in session: SKTestSession) async throws {
        await store.start()
        try await store.purchase(Shop.monthly)
        #expect(await waitUntil(timeout: .seconds(10)) { await isListedMonthly() })
        try session.expireSubscription(productIdentifier: Shop.monthly.rawValue)
        #expect(await waitUntil(timeout: .seconds(15)) {
            await store.refresh()
            return membership(store).isActive == false
        })
        // As phase 0 did (q11). Asked at once, StoreKit was seen to hand back the lapsed
        // transaction and buy nothing (D51).
        try await Task.sleep(for: .seconds(2))
    }

    private func isListedMonthly() async -> Bool {
        await front.ownedProducts().contains { $0.id == Shop.monthly }
    }

    // MARK: - Terms

    @Test("OFFERS: the monthly plan's offers come with its price, as Demo.storekit states them")
    func offerTerms() async throws {
        let session = try session()
        let store = store()
        await store.loadProducts()
        let monthly = try #require(store.products.first { $0.id == Shop.monthly }?.subscription)
        let introductory = try #require(monthly.introductoryOffer)
        #expect(monthly.group == Shop.membership)
        #expect(monthly.period == .months(1))
        #expect(introductory.kind == .introductory)
        #expect(introductory.paymentMode == .payAsYouGo)
        #expect(introductory.period == .months(1))
        #expect(introductory.periodCount == 2)
        #expect(introductory.price == Decimal(string: "10.99"))
        #expect(monthly.winBackOffers.map(\.id) == ["membership.winback.three"])
        #expect(store.products.first { $0.id == Shop.yearly }?.subscription?.introductoryOffer == nil)
        withExtendedLifetime(session) {}
    }

    // MARK: - Introductory

    /// Measured: StoreKit's answer keeps its first value for the life of the process.
    /// Which is why the store also reads the group's transactions, and remembers.
    @Test("OFFERS: the introductory offer is eligible, a plain purchase applies it, and then it is USED — though StoreKit still says eligible")
    func introductoryUsed() async throws {
        let session = try session()
        let store = store()
        await store.start()
        await store.loadProducts()
        guard case .eligible = store.introductoryOffer(for: Shop.monthly) else {
            Issue.record("expected eligible, got \(store.introductoryOffer(for: Shop.monthly))")
            return
        }
        guard case let .subscribed(held) = try await store.purchase(Shop.monthly) else {
            Issue.record("expected subscribed")
            return
        }
        #expect(held.offer?.kind == .introductory)
        #expect(store.introductoryOffer(for: Shop.monthly) == .ineligible)
        // HABIT: StoreKit keeps its first answer. Held on the Mac with Xcode 27; in the iOS
        // simulator phase 0 saw it kept twice, and the hosted suite once saw "false" straight
        // after the purchase; so did the Mac with Xcode 26.6, in one run of two. The store is
        // right either way; this is here to notice StoreKit changing.
        let stillSaysEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: Shop.membership.rawValue)
        #if os(macOS)
        if RealStoreKit.builtWithXcode27 {
            #expect(stillSaysEligible, "HABIT: StoreKit's first answer is kept — if this fails, it no longer is (D46)")
        } else {
            withKnownIssue("with Xcode 26.6 the Mac does not always keep its first answer", isIntermittent: true) {
                #expect(stillSaysEligible)
            }
        }
        #else
        withKnownIssue("the iOS simulator does not always keep its first answer", isIntermittent: true) {
            #expect(stillSaysEligible)
        }
        #endif
        // A store made afresh, as at the next launch, reads the group's transactions — once
        // they have it: the Mac lists a purchase late.
        #expect(await waitUntil(timeout: .seconds(10)) { await isListedMonthly() })
        let next = self.store()
        await next.loadProducts()
        #expect(next.introductoryOffer(for: Shop.monthly) == .ineligible)
        withExtendedLifetime(session) {}
    }

    // MARK: - Win-back

    @Test("OFFERS: lapsed, the win-back offer Apple allows is there, and bought with it, it is applied", .enabled(if: lapsesOnDemand))
    func winBack() async throws {
        let session = try session()
        let store = store()
        try await lapsedMonthly(store, in: session)
        await store.loadProducts()
        let offer = try #require(store.winBackOffers(in: Shop.membership).first)
        #expect(offer.product == Shop.monthly)
        #expect(offer.id == "membership.winback.three")
        let completion = try await store.purchase(offer.product, options: PurchaseOptions(offer: .winBack(offer.id)))
        guard case let .subscribed(held) = completion else {
            Issue.record("expected subscribed, got \(completion)")
            return
        }
        #expect(held.offer?.kind == .winBack)
        #expect(held.offer?.id == offer.id)
        withExtendedLifetime(session) {}
    }

    // MARK: - Not applied

    /// Measured on the Mac: an introductory override signed with a key Xcode does not know
    /// goes through at the full price, and StoreKit says nothing of it.
    @Test("OFFERS: an override StoreKit cannot check goes through at the FULL PRICE, and the store says the offer was not applied", .enabled(if: lapsesOnDemand))
    func overrideNotApplied() async throws {
        let session = try session()
        let store = store(offerSigner: UnregisteredSigner())
        try await lapsedMonthly(store, in: session)
        let completion = try await store.purchase(Shop.monthly, options: PurchaseOptions(offer: .introductoryOverride))
        guard case let .offerNotApplied(held) = completion else {
            Issue.record("expected offerNotApplied, got \(completion)")
            return
        }
        #expect(held.product == Shop.monthly)
        #expect(held.offer == nil)
        withExtendedLifetime(session) {}
    }
}
