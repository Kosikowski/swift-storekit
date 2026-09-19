import Foundation
import PurchaseCore
import PurchaseTestKit
import Synchronization
import Testing

private let pro: ProductID = "com.example.pro"
private let trial: ProductID = "com.example.trial"
private let catalogue: Catalogue = [.unlock(pro), .trial(trial, of: [pro], lasting: .seconds(14 * 86_400))]

/// A file Xcode wrote, or one broken on purpose, from `Fixtures/`.
private func fixture(_ name: String) throws -> StoreKitConfiguration {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "storekit", subdirectory: "Fixtures"))
    return try StoreKitConfiguration(contentsOf: url)
}

/// A version 4 file with these entries as its root `products`.
private func configuration(products: String) throws -> StoreKitConfiguration {
    let json = #"{"version": {"major": 4, "minor": 0}, "products": [\#(products)]}"#
    return try StoreKitConfiguration(data: Data(json.utf8))
}

@Suite("StoreKit configuration file")
struct StoreKitConfigurationTests {
    // MARK: - Reading

    @Test("every schema version Xcode has written parses, NEWER ROOT KEYS and all", arguments: [
        ("v3", 3, 0, [pro]),
        ("v4", 4, 0, [pro, trial]),
        ("v6", 6, 3, [pro, trial]),
    ])
    func parses(name: String, major: Int, minor: Int, identifiers: [ProductID]) throws {
        let file = try fixture(name)
        #expect(file.version.major == major)
        #expect(file.version.minor == minor)
        #expect(file.products.map(\.id) == identifiers)
    }

    @Test("a product is read as the file spells it, the price as a number too")
    func product() throws {
        let file = try fixture("v4")
        let product = try #require(file.products.first)
        #expect(product.id == pro)
        #expect(product.type == "NonConsumable")
        #expect(product.displayPrice == "19.99")
        #expect(product.price == Decimal(string: "19.99"))
        #expect(product.isFamilyShareable)
        #expect(product.referenceName == "Pro")
        #expect(product.displayName == "Example Pro")
        #expect(product.localizedDescription == "Everything, once, for good.")
    }

    @Test("an entry with NOTHING BUT an identifier parses, and unknown keys are ignored")
    func lenient() throws {
        let file = try configuration(products: #"{"productID": "com.example.pro", "invented": [1, 2]}"#)
        let product = try #require(file.products.first)
        #expect(product.id == pro)
        #expect(product.type == "")
        #expect(product.displayPrice == "")
        #expect(product.price == nil)
        #expect(!product.isFamilyShareable)
        #expect(product.displayName == nil)
    }

    @Test("a version with no minor is minor zero")
    func noMinor() throws {
        let file = try StoreKitConfiguration(data: Data(#"{"version": {"major": 7}}"#.utf8))
        #expect(file.version.major == 7)
        #expect(file.version.minor == 0)
        #expect(file.products.isEmpty)
    }

    @Test("products are collected from EVERY section, not only the root list")
    func everySection() throws {
        let file = try StoreKitConfiguration(data: Data(#"""
            {
              "version": {"major": 4, "minor": 0},
              "products": [{"productID": "a", "type": "NonConsumable"}],
              "subscriptionGroups": [
                {"subscriptions": [{"productID": "b", "type": "RecurringSubscription"}]},
                {"subscriptions": [{"productID": "c", "type": "RecurringSubscription"}]}
              ],
              "nonRenewingSubscriptions": [{"productID": "d", "type": "NonRenewingSubscription"}]
            }
            """#.utf8))
        #expect(file.products.map(\.id) == ["a", "b", "c", "d"])
        #expect(file.products.map(\.type).last == "NonRenewingSubscription")
    }

    @Test("a price is a number only if ALL of it is one", arguments: [
        ("0", Decimal(0)), ("0.0", 0), ("0.00", 0), ("19.99", Decimal(string: "19.99")),
        ("0,99", nil), ("0.99 or so", nil), ("free", nil), ("1.2.3", nil), (".", nil), ("", nil),
    ])
    func price(text: String, expected: Decimal?) throws {
        let file = try configuration(products: #"{"productID": "p", "displayPrice": "\#(text)"}"#)
        #expect(file.products.first?.price == expected)
    }

    @Test("a price written as a JSON number is read too")
    func numericPrice() throws {
        let file = try configuration(products: #"{"productID": "p", "displayPrice": 2.5}"#)
        #expect(file.products.first?.displayPrice == "2.5")
        #expect(file.products.first?.price == Decimal(string: "2.5"))
    }

    // MARK: - Failing to read

    @Test("data that is not JSON is .notJSON")
    func garbage() {
        #expect(throws: StoreKitConfigurationError.notJSON) {
            try StoreKitConfiguration(data: Data("// not a configuration".utf8))
        }
        #expect(throws: StoreKitConfigurationError.notJSON) { try StoreKitConfiguration(data: Data()) }
    }

    @Test("JSON that is not a configuration is .notAStoreKitConfiguration", arguments: [
        "[1, 2, 3]",
        #"{"products": []}"#,
        #"{"version": "4.0", "products": []}"#,
        #"{"version": {"minor": 0}}"#,
    ])
    func notAConfiguration(json: String) {
        #expect(throws: StoreKitConfigurationError.notAStoreKitConfiguration) {
            try StoreKitConfiguration(data: Data(json.utf8))
        }
    }

    @Test("an entry WITHOUT AN IDENTIFIER is an error naming where it is, not a product skipped")
    func noIdentifier() {
        #expect(throws: StoreKitConfigurationError.productWithoutIdentifier(section: "products", index: 1)) {
            try configuration(products: #"{"productID": "a"}, {"type": "NonConsumable"}"#)
        }
    }

    @Test("a file that is not there is .unreadableFile, with its path")
    func noFile() {
        let url = URL(fileURLWithPath: "/nowhere/App.storekit")
        #expect(throws: StoreKitConfigurationError.unreadableFile(path: "/nowhere/App.storekit")) {
            try StoreKitConfiguration(contentsOf: url)
        }
    }

    // MARK: - Checking against a catalogue

    @Test("a sound file has no problems", arguments: ["v4", "v6"])
    func sound(name: String) throws {
        #expect(try fixture(name).problems(against: catalogue) == [])
    }

    @Test("a sound file selling one unlock that is NOT shared has no problems either")
    func soundUnshared() throws {
        #expect(try fixture("v3").problems(against: [.unlock(pro, familySharing: .ignored)]) == [])
    }

    @Test("each broken file has exactly the problem it was broken to have", arguments: [
        ("renamed-identifier", [.missing(pro), .unexpected("com.example.professional")]),
        ("consumable", [.notNonConsumable(pro, type: "Consumable")]),
        ("hiding-in-subscription-group", [.notNonConsumable(pro, type: "RecurringSubscription")]),
        ("trial-priced", [.trialNotFree(trial, displayPrice: "0.99")]),
        ("trial-family-shareable", [.trialFamilyShareable(trial)]),
        ("unlock-not-shareable", [.familySharingMismatch(pro, catalogueHonours: true, fileShares: false)]),
    ] as [(String, [StoreKitConfigurationProblem])])
    func broken(name: String, expected: [StoreKitConfigurationProblem]) throws {
        #expect(try fixture(name).problems(against: catalogue) == expected)
    }

    // MARK: - Subscriptions

    /// The spike's file (spike/subscriptions), which real StoreKit loaded: a group of three
    /// plans, and a second group of one. None of them is family-shareable.
    private static let plans: Catalogue = [
        .subscription("probe.monthly", in: "5B1F2A01", level: 2, familySharing: .ignored),
        .subscription("probe.yearly", in: "5B1F2A01", level: 2, familySharing: .ignored),
        .subscription("probe.premium", in: "5B1F2A01", level: 1, familySharing: .ignored),
        .subscription("probe.plain", in: "5B1F2A02", level: 1, familySharing: .ignored),
    ]

    @Test("a file with subscriptions agrees with a catalogue that names their groups and levels")
    func soundSubscriptions() throws {
        let file = try fixture("subscriptions")
        #expect(file.problems(against: Self.plans) == [])
        let monthly = try #require(file.products.first { $0.id == "probe.monthly" })
        #expect(monthly.subscriptionGroupID == "5B1F2A01")
        #expect(monthly.groupLevel == 2)
    }

    @Test("a subscription's period and offers are read as Xcode wrote them, and served to a simulated store")
    func subscriptionOffers() throws {
        let file = try fixture("subscriptions")
        let monthly = try #require(file.products.first { $0.id == "probe.monthly" })
        let tenNinetyNine = { (kind: OfferKind, id: OfferID?, count: Int) in
            OfferTerms(
                kind: kind, id: id, paymentMode: .payAsYouGo, period: .months(1), periodCount: count,
                displayPrice: "10.99", price: Decimal(string: "10.99")!)
        }
        #expect(monthly.subscriptionPeriod == .months(1))
        #expect(monthly.introductoryOffer == tenNinetyNine(.introductory, nil, 2))
        #expect(monthly.promotionalOffers == [tenNinetyNine(.promotional, "promo.returning", 3)])
        #expect(monthly.winBackOffers == [tenNinetyNine(.winBack, "winback.three", 3)])
        let yearly = try #require(file.products.first { $0.id == "probe.yearly" })
        #expect(yearly.subscriptionPeriod == .years(1))
        #expect(yearly.introductoryOffer == nil)

        let served = try #require(file.storeProducts(for: Self.plans).first { $0.id == "probe.monthly" })
        #expect(served.subscription == StoreProduct.Subscription(
            group: "5B1F2A01", period: .months(1), introductoryOffer: monthly.introductoryOffer,
            promotionalOffers: monthly.promotionalOffers, winBackOffers: monthly.winBackOffers))
    }

    @Test("a period is ISO 8601 with one unit, as Xcode writes it, or nothing", arguments: [
        ("P1W", BillingPeriod.weeks(1)), ("P3D", .days(3)), ("P6M", .months(6)), ("P1Y", .years(1)),
        ("P1M2D", nil), ("1M", nil), ("P0M", nil), ("P", nil),
    ])
    func periods(text: String, period: BillingPeriod?) {
        #expect(StoreKitConfiguration.Product.period(text) == period)
    }

    @Test("an offer the app names and the file lacks, on that product, is a problem; one it has is not")
    func namedOffers() throws {
        let file = try fixture("subscriptions")
        #expect(file.problems(against: Self.plans, offers: ["probe.monthly": ["promo.returning", "winback.three"]]) == [])
        #expect(file.problems(against: Self.plans, offers: ["probe.yearly": ["winback.three"], "probe.monthly": ["promo.typo"]]) == [
            .offerMissing("promo.typo", product: "probe.monthly"),
            .offerMissing("winback.three", product: "probe.yearly"),
        ])
        #expect(StoreKitConfigurationProblem.offerMissing("promo.typo", product: "probe.monthly").description.contains("promo.typo"))
    }

    @Test("a subscription in another group, at another level, or shared when the catalogue says not, is each a problem")
    func subscriptionMismatches() throws {
        let wrong: Catalogue = [
            .subscription("probe.monthly", in: "5B1F2A02", level: 2, familySharing: .ignored),
            .subscription("probe.yearly", in: "5B1F2A01", level: 1, familySharing: .ignored),
            .subscription("probe.premium", in: "5B1F2A01", level: 1),
            .subscription("probe.plain", in: "5B1F2A02", level: 1, familySharing: .ignored),
        ]
        #expect(try fixture("subscriptions").problems(against: wrong) == [
            .subscriptionGroupMismatch("probe.monthly", catalogue: "5B1F2A02", file: "5B1F2A01"),
            .subscriptionLevelMismatch("probe.yearly", catalogue: 1, file: 2),
            .familySharingMismatch("probe.premium", catalogueHonours: true, fileShares: false),
        ])
    }

    @Test("a catalogue subscription the file sells as a non-consumable is not auto-renewable, and in no group")
    func subscriptionAsNonConsumable() throws {
        let file = try configuration(products: """
            {"productID": "com.example.pro", "type": "NonConsumable", "familyShareable": true}
            """)
        #expect(file.problems(against: [.subscription(pro, in: "g", level: 1)]) == [
            .notAutoRenewable(pro, type: "NonConsumable"),
            .subscriptionGroupMismatch(pro, catalogue: "g", file: nil),
            .subscriptionLevelMismatch(pro, catalogue: 1, file: nil),
        ])
    }

    @Test("every subscription problem is said in words, naming the product")
    func subscriptionWords() {
        let problems: [StoreKitConfigurationProblem] = [
            .notAutoRenewable(pro, type: "NonConsumable"),
            .subscriptionGroupMismatch(pro, catalogue: "g", file: nil),
            .subscriptionLevelMismatch(pro, catalogue: 1, file: 2),
        ]
        for problem in problems { #expect(problem.description.contains(pro.rawValue)) }
    }

    @Test("Family Sharing on in the file and IGNORED by the catalogue is a mismatch too")
    func sharedButIgnored() throws {
        let ignoring: Catalogue = [
            .unlock(pro, familySharing: .ignored), .trial(trial, of: [pro], lasting: .seconds(60)),
        ]
        #expect(
            try fixture("v4").problems(against: ignoring)
                == [.familySharingMismatch(pro, catalogueHonours: false, fileShares: true)])
    }

    @Test("a trial whose price CANNOT BE READ is not free", arguments: ["0,00", "free", ""])
    func unreadablePrice(text: String) throws {
        let file = try configuration(products: """
            {"productID": "com.example.pro", "type": "NonConsumable", "familyShareable": true},
            {"productID": "com.example.trial", "type": "NonConsumable", "displayPrice": "\(text)"}
            """)
        #expect(file.problems(against: catalogue) == [.trialNotFree(trial, displayPrice: text)])
    }

    @Test("everything wrong is reported AT ONCE: catalogue order, then the unexpected, sorted")
    func order() throws {
        let file = try configuration(products: """
            {"productID": "com.example.zebra", "type": "NonConsumable"},
            {"productID": "com.example.trial", "type": "Consumable", "displayPrice": "1",
             "familyShareable": true},
            {"productID": "com.example.aardvark", "type": "NonConsumable"}
            """)
        #expect(
            file.problems(against: catalogue) == [
                .missing(pro),
                .notNonConsumable(trial, type: "Consumable"),
                .trialNotFree(trial, displayPrice: "1"),
                .trialFamilyShareable(trial),
                .unexpected("com.example.aardvark"),
                .unexpected("com.example.zebra"),
            ])
    }

    @Test("an identifier in the file TWICE is checked in both places, and no fault is said twice")
    func twice() throws {
        let file = try StoreKitConfiguration(data: Data(#"""
            {
              "version": {"major": 4, "minor": 0},
              "products": [
                {"productID": "com.example.pro", "type": "NonConsumable", "familyShareable": true},
                {"productID": "com.example.trial", "type": "NonConsumable", "displayPrice": "0.00"},
                {"productID": "com.example.extra"}, {"productID": "com.example.extra"}
              ],
              "subscriptionGroups": [{"subscriptions": [
                {"productID": "com.example.pro", "type": "RecurringSubscription", "familyShareable": true}
              ]}]
            }
            """#.utf8))
        #expect(
            file.problems(against: catalogue) == [
                .notNonConsumable(pro, type: "RecurringSubscription"), .unexpected("com.example.extra"),
            ])
    }

    @Test("every problem's description names the product it is about", arguments: [
        .missing(pro), .unexpected(pro), .notNonConsumable(pro, type: "Consumable"),
        .notNonConsumable(pro, type: ""), .trialNotFree(pro, displayPrice: "0.99"),
        .trialFamilyShareable(pro),
        .familySharingMismatch(pro, catalogueHonours: true, fileShares: false),
    ] as [StoreKitConfigurationProblem])
    func descriptions(problem: StoreKitConfigurationProblem) {
        #expect(problem.description.contains("com.example.pro"))
        #expect(problem.description.hasSuffix(".") || problem.description.hasSuffix("?"))
    }

    // MARK: - As a test says it

    @Test("a sound file records nothing", arguments: ["v4", "v6"])
    func expectsNothing(name: String) throws {
        try fixture(name).expectNoProblems(against: catalogue)
    }

    @Test("a broken file records ONE ISSUE PER PROBLEM, each in words, each at the line that asked")
    func expectsEachProblem() throws {
        let file = try configuration(products: """
            {"productID": "com.example.trial", "type": "Consumable", "displayPrice": "1"},
            {"productID": "com.example.aardvark", "type": "NonConsumable"}
            """)
        let recorded = Mutex<[(comment: String, line: Int?)]>([])

        let asked = #line + 2
        withKnownIssue {
            file.expectNoProblems(against: catalogue)
        } matching: { issue in
            recorded.withLock { $0.append((issue.comments.map(\.rawValue).joined(), issue.sourceLocation?.line)) }
            return true
        }

        let issues = recorded.withLock { $0 }
        #expect(issues.map(\.comment) == file.problems(against: catalogue).map(\.description))
        #expect(issues.count == 4, "missing pro, the trial not a non-consumable and not free, aardvark")
        #expect(issues.allSatisfy { $0.line == asked })
    }

    // MARK: - Serving

    @Test("store products come out in CATALOGUE order, with the file's names and prices")
    func storeProducts() throws {
        // The file has pro first. The catalogue, here, has the trial first.
        let trialFirst: Catalogue = [.trial(trial, of: [pro], lasting: .seconds(60)), .unlock(pro)]
        #expect(
            try fixture("v4").storeProducts(for: trialFirst) == [
                StoreProduct(
                    id: trial, displayName: "14-day Trial",
                    description: "Every Pro feature for fourteen days, once.", displayPrice: "0.0",
                    price: 0, isFamilyShareable: false),
                StoreProduct(
                    id: pro, displayName: "Example Pro", description: "Everything, once, for good.",
                    displayPrice: "19.99", price: Decimal(string: "19.99")!, isFamilyShareable: true),
            ])
    }

    @Test("a catalogue product the file does not have is LEFT OUT, not made up; nor is anything added")
    func storeProductsLeavesOut() throws {
        #expect(try fixture("renamed-identifier").storeProducts(for: catalogue).map(\.id) == [trial])
    }

    @Test("with no localisation the reference name is served, and an unreadable price is NOT zero")
    func storeProductsFallbacks() throws {
        let file = try configuration(
            products: #"{"productID": "com.example.pro", "referenceName": "Pro", "displayPrice": "free"}"#)
        let product = try #require(file.storeProducts(for: [.unlock(pro)]).first)
        #expect(product.displayName == "Pro")
        #expect(product.displayPrice == "free")
        #expect(product.price != 0)
        #expect(product.price.isNaN)
    }

    #if DEBUG
    @Test("a simulated store built from the file serves the FILE'S products, not made-up ones")
    func simulatedStore() async throws {
        let file = try fixture("v4")
        let store = SimulatedStoreFront(catalogue: catalogue, configuration: file, clock: ManualClock())
        let served = try await store.products()
        #expect(served == file.storeProducts(for: catalogue))
        #expect(served.map(\.displayPrice) == ["19.99", "0.0"])
        #expect(served.map(\.displayName) == ["Example Pro", "14-day Trial"])
    }

    @Test("it keeps the behaviour it was given")
    func simulatedStoreBehaviour() async throws {
        var behaviour = SimulatedStoreFront.Behaviour()
        behaviour.catalogue = .fails(.network)
        let store = SimulatedStoreFront(
            catalogue: catalogue, configuration: try fixture("v4"), behaviour: behaviour)
        await #expect(throws: PurchaseError.network) { try await store.products() }
    }
    #endif
}
