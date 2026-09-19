//
//  StoreKitConfiguration.swift
//  PurchaseTestKit
//
//  An Xcode `.storekit` file, read without StoreKit, so that it can be checked
//  against the app's catalogue by an ordinary unit test.
//
//  A product identifier is written in three places — App Store Connect, the
//  configuration file, the app — and nothing compares them. Rename it in one and
//  nothing fails: the product simply never loads, and to the person in front of it
//  the Buy button "does nothing". The check that would catch it cannot be made with
//  StoreKit's own test support, because `SKTestSession` does not work in a package
//  test target at all (spike/README.md). So this reads the file as the JSON it is,
//  and one line in the app's tests turns a renamed product into a failing test:
//
//      let file = try StoreKitConfiguration(contentsOf: url)
//      file.expectNoProblems(against: catalogue)
//
//  **Read leniently.** The format is undocumented; Xcode has written schema versions
//  3.0, 4.0 and 6.x so far, adding root keys as it went. Unknown keys are ignored
//  and absent optional ones tolerated, so a newer Xcode does not break an app's
//  tests by saving the file.
//
//  Not `#if DEBUG`: it grants nothing, and an app's tests need it in whatever
//  configuration they are built.
//

public import Foundation
public import PurchaseCore

/// The contents of a StoreKit configuration file.
public struct StoreKitConfiguration: Hashable, Sendable {
    /// The schema version Xcode stamped the file with.
    public struct Version: Hashable, Sendable {
        public let major: Int
        public let minor: Int
    }

    public let version: Version

    /// Every product in the file, **wherever it was found**: the root `products`,
    /// then each subscription group's subscriptions, then the non-renewing
    /// subscriptions. An identifier sitting in the wrong section is a product of the
    /// wrong type, and is only reported as one if it is seen.
    public let products: [Product]

    public init(contentsOf url: URL) throws(StoreKitConfigurationError) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadableFile(path: url.path)
        }
        try self.init(data: data)
    }

    public init(data: Data) throws(StoreKitConfigurationError) {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .notJSON
        }
        guard let root = json as? [String: Any],
            let version = root["version"] as? [String: Any],
            let major = version["major"] as? Int
        else { throw .notAStoreKitConfiguration }

        let groups = root["subscriptionGroups"] as? [[String: Any]] ?? []
        let sections: [(name: String, entries: [[String: Any]])] = [
            ("products", root["products"] as? [[String: Any]] ?? []),
            ("subscriptionGroups", groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }),
            ("nonRenewingSubscriptions", root["nonRenewingSubscriptions"] as? [[String: Any]] ?? []),
        ]
        var products: [Product] = []
        for section in sections {
            for (index, entry) in section.entries.enumerated() {
                products.append(try Product(json: entry, section: section.name, index: index))
            }
        }
        self.version = Version(major: major, minor: version["minor"] as? Int ?? 0)
        self.products = products
    }

    // MARK: - Checking

    /// Everything about the file that disagrees with `catalogue`, in a stable order:
    /// the catalogue's, then identifiers the catalogue has never heard of, sorted.
    ///
    /// Empty means the file sells exactly what the catalogue declares, as the
    /// catalogue declares it. Compare with `[]` rather than asking `isEmpty`, and a
    /// failure prints everything that is wrong at once rather than `false`.
    ///
    /// The rules: every catalogue identifier is in the file; nothing else is; every
    /// one of them is a non-consumable; a trial is priced at exactly zero and is not
    /// family-shareable; an unlock is family-shareable exactly when its entry
    /// honours Family Sharing. An identifier in the file twice is checked in both
    /// places, so one hiding under a subscription group as well is still caught.
    public func problems(against catalogue: Catalogue) -> [StoreKitConfigurationProblem] {
        var problems: [StoreKitConfigurationProblem] = []
        for entry in catalogue.entries {
            let found = products.filter { $0.id == entry.id }
            if found.isEmpty { problems.append(.missing(entry.id)) }
            for product in found {
                if product.type != "NonConsumable" {
                    problems.append(.notNonConsumable(entry.id, type: product.type))
                }
                switch entry.kind {
                case .trial:
                    // Nil fails too: a price that cannot be read is not known to be free.
                    if product.price != 0 {
                        problems.append(.trialNotFree(entry.id, displayPrice: product.displayPrice))
                    }
                    if product.isFamilyShareable { problems.append(.trialFamilyShareable(entry.id)) }
                case let .unlock(familySharing):
                    let honours = familySharing == .honoured
                    if product.isFamilyShareable != honours {
                        problems.append(
                            .familySharingMismatch(
                                entry.id, catalogueHonours: honours,
                                fileShares: product.isFamilyShareable))
                    }
                }
            }
        }
        let unexpected = Set(products.map(\.id)).subtracting(catalogue.identifiers)
        problems.append(contentsOf: unexpected.sorted().map { .unexpected($0) })
        // Two identical entries have identical faults. Say each once.
        var seen: Set<StoreKitConfigurationProblem> = []
        return problems.filter { seen.insert($0).inserted }
    }

    // MARK: - Serving

    /// The catalogue's products as the file describes them, in catalogue order, for
    /// a simulated store that sells what the app's real file sells.
    ///
    /// **A catalogue product the file does not have is left out**, not made up. That
    /// is what the real store does with an identifier it does not recognise, so a
    /// simulated store built from a file with a renamed product fails to load it
    /// just as the real one would.
    ///
    /// The price is the file's bare number, with no currency: the file has none.
    public func storeProducts(for catalogue: Catalogue) -> [StoreProduct] {
        catalogue.entries.compactMap { entry in
            guard let product = products.first(where: { $0.id == entry.id }) else { return nil }
            return StoreProduct(
                id: product.id,
                displayName: product.displayName ?? product.referenceName,
                description: product.localizedDescription ?? "",
                displayPrice: product.displayPrice,
                // Not a number rather than zero: `StoreProduct.price` exists to be
                // compared with zero, and an unreadable price must not pass for free.
                price: product.price ?? .nan,
                isFamilyShareable: product.isFamilyShareable)
        }
    }
}
