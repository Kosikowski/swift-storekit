import Foundation
import PurchaseCore
import PurchaseTestKit
import PurchaseTestSupport
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
