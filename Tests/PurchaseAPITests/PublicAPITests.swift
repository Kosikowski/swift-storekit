//
//  PublicAPITests.swift
//  PurchaseAPITests
//
//  The package as an app sees it: StoreKit and SwiftUI imported beside every module, and
//  nothing `@testable`.
//
//  **Two mistakes fail this target's build rather than an app's.**
//
//  · **A public name StoreKit also has at the top level.** StoreKit 18.4 added
//    `SubscriptionInfo`, `SubscriptionStatus`, `SubscriptionPeriod` and more, and
//    libraries with those names stopped compiling in apps that imported both (D44).
//    Every public type is named below unqualified, beside `import StoreKit`, so a name
//    that becomes ambiguous is a compile error here — with whichever SDK builds this,
//    which on CI is the older one.
//  · **A public type an app cannot make.** A value whose initialiser is internal passes
//    every `@testable` test in the package, and is no use to an app's previews and tests.
//
//  The last test keeps the list whole: a public type added and not named here fails it.
//

import Foundation
import PurchaseCore
import PurchaseDebugUI
import PurchaseDirectDistribution
import PurchaseLaunch
import PurchaseStoreKit
import PurchaseTestKit
import PurchaseUI
import StoreKit
import SwiftUI
import Testing
// What an app gets unasked when a file imports StoreKit and SwiftUI, under Xcode:
// `SubscriptionStoreView`, `PurchaseAction` and the rest. SwiftPM loads it only by name.
import _StoreKit_SwiftUI

@Suite("What an app sees")
struct PublicAPITests {
    /// Every public top-level type, named as an app names it.
    static let named: [Any.Type] = [
        AppliedOffer.self, AppStoreFront.self, Catalogue.self, CatalogueEntry.self,
        EverythingOwnedStoreFront.self, HeldSubscription.self, ManageSubscriptionsButton<Text>.self,
        ManualClock.self, OfferID.self, OwnedProduct.self, Ownership.self, (any OwnershipReading).self,
        ProductAccess.self, (any ProductCatalogueLoading).self, ProductID.self, ProductLoadState.self,
        (any ProductPurchasing).self, PurchaseActivity.self, PurchaseButton<Text>.self,
        (any PurchaseCommanding).self, PurchaseCompletion.self, PurchaseConfirmation.self,
        PurchaseDebugPanel.self, PurchaseError.self, PurchaseEvent.self, (any PurchaseLogging).self,
        PurchaseOptions.self, PurchaseOutcome.self, (any PurchaseRestoring).self,
        (any PurchaseStateProviding).self, PurchaseStore.self, RecordingPurchaseLogger.self, Renewal.self,
        RestoreOutcome.self, RestorePurchasesButton<Text>.self, SilentPurchaseLogger.self, Standing.self,
        StandingResolver.self, (any StoreDiagnosing).self, StoreDiagnosis.self, (any StoreFront).self,
        StoreKitConfiguration.self, StoreKitConfigurationError.self, StoreKitConfigurationProblem.self,
        StoreLaunch.self, StoreProduct.self, SubscriptionGroupID.self, SubscriptionStanding.self,
        (any SubscriptionStatusReading).self, SubscriptionTerms.self, SystemClock.self,
        (any TimeProviding).self, (any TransactionObserving).self, TransactionUpdate.self, TrialPeriod.self,
        TrialStatus.self, TrialTerms.self, OfferKind.self, OfferPaymentMode.self, OfferTerms.self,
        BillingPeriod.self, IntroductoryEligibility.self, WinBackOffer.self,
        (any IntroductoryEligibilityReading).self, (any OfferSigning).self, OfferSignatureRequest.self,
        NonRenewingTerms.self, NonRenewingPeriod.self, NonRenewingStatus.self, RequestedPurchase.self,
        BillingPlan.self, BillingPlanTerms.self, SubscriptionCommitment.self, CommitmentRenewal.self,
        BundleMembership.self, BundledSubscription.self, StoreMessageReason.self,
    ]

    #if DEBUG
    /// The simulated store's, which exist only in a debug build.
    static let namedInDebug: [Any.Type] = [
        AnswerGate.self, Scenario.self, ScenarioError.self, SimulatedStoreFront.self,
    ]
    #endif

    /// The work is done by the compiler, which must find each name in `named` unqualified
    /// beside StoreKit; the count only says the list was not emptied.
    @Test("every public type is nameable beside StoreKit")
    func names() {
        #expect(Self.named.count > 50)
    }

    @Test("an app can make every value it needs for a preview or a test of its own")
    @MainActor
    func values() {
        let group: SubscriptionGroupID = "21482000"
        let monthly: ProductID = "com.example.monthly"
        let yearly: ProductID = "com.example.yearly"
        let catalogue: Catalogue = [
            .subscription(monthly, in: group, level: 2),
            .subscription(yearly, in: group, level: 1, familySharing: .ignored),
        ]
        let start = Date(timeIntervalSince1970: 1_000_000)
        let held = HeldSubscription(
            product: monthly, group: group, ownership: .familyShared,
            state: .inGracePeriod(until: start.addingTimeInterval(86_400 * 33)),
            firstSubscribed: start, periodStarted: start, periodEnds: start.addingTimeInterval(86_400 * 30),
            offer: AppliedOffer(kind: .introductory, paymentMode: .freeTrial),
            renewal: Renewal(
                willRenew: true, nextProduct: yearly, price: 9.99, currencyCode: "GBP",
                priceIncrease: .awaitingConsent, winBackOffers: ["come-back"]))
        let standing = SubscriptionStanding.active(held, all: [held])
        #expect(standing.isActive == true)
        #expect(catalogue.entry(for: yearly)?.subscriptionTerms == SubscriptionTerms(group: group, level: 1, familySharing: .ignored))

        let product = StoreProduct(
            id: monthly, displayName: "Monthly", displayPrice: "£4.99", price: 4.99, isFamilyShareable: true)
        let owned = OwnedProduct(id: monthly, originalPurchaseDate: start, expirationDate: start.addingTimeInterval(60))
        let options = PurchaseOptions(appAccountToken: UUID())
        #expect(product.id == owned.id)
        #expect(options.appAccountToken != nil)

        _ = PurchaseButton("Subscribe", buying: monthly, options: options) { _ in }
        _ = ManageSubscriptionsButton("Manage", group: group)
        _ = RestorePurchasesButton("Restore") { _ in }
    }

    @Test("an app can play any role of the store itself")
    func conformances() async throws {
        let store = AppsOwnStore()
        #expect(try await store.products().isEmpty)
        #expect(await store.subscriptionStatuses(in: ["21482000"]).isEmpty)
    }

    /// A type added to a public module and left out of `named` fails here, with its name.
    /// Read from the sources, because nothing at run time lists a module's types.
    @Test("every public type in the package is named in this file")
    func everyNameIsHere() throws {
        let here = URL(filePath: #filePath)
        let this = try String(contentsOf: here, encoding: .utf8)
        let sources = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let declaration = /^(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\s+(?:final\s+)?(?:indirect\s+)?(?:struct|enum|class|protocol|actor|typealias)\s+(\w+)/
            .anchorsMatchLineEndings()
        var declared: Set<String> = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: declaration) { declared.insert(String(match.1)) }
        }
        #expect(declared.count > 50, "the sources were not found at \(sources.path)")
        // Whole names: `Standing` is not named by `SubscriptionStanding.self`.
        let missing = try declared.filter { name in
            try !this.contains(Regex("\\b\(name)(?:\\.self|<)|any \(name)\\)\\.self"))
        }
        #expect(missing.isEmpty, "public, and not named here: \(missing.sorted())")
    }
}

/// A store an app writes for itself — on a server of its own, say. Conformed to from
/// outside the package, so every requirement is one an app can meet.
private struct AppsOwnStore: StoreFront, SubscriptionStatusReading, StoreDiagnosing {
    func products() async throws(PurchaseError) -> [StoreProduct] { [] }
    func ownedProducts() async -> [OwnedProduct] { [] }
    func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseOutcome { .cancelled }
    func restorePurchases() async throws(PurchaseError) -> RestoreOutcome { .completed }
    func transactionUpdates() -> AsyncStream<TransactionUpdate> { AsyncStream { $0.finish() } }
    func subscriptionStatuses(in groups: Set<SubscriptionGroupID>) async -> [SubscriptionGroupID: [HeldSubscription]] {
        [:]
    }
    func diagnose() async -> StoreDiagnosis {
        StoreDiagnosis(
            requested: [], received: [], catalogueFailure: nil, verifiedEntitlements: 0, unverifiedEntitlements: 0,
            foreignEntitlements: 0, environment: nil)
    }
}
