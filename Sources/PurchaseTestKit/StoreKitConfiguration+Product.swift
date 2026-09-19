//
//  StoreKitConfiguration+Product.swift
//  PurchaseTestKit
//
//  One product as a `.storekit` file describes it.
//
//  Read leniently, because the format is Xcode's own and is written down nowhere:
//  keys come and go between schema versions, so every key but the identifier may be
//  absent, and whatever else is in the entry is ignored. The type is kept as the
//  string Xcode wrote rather than an enum of the four known today — a fifth would
//  otherwise fail to parse a file whose only fault is being newer than this code.
//

public import Foundation
public import PurchaseCore

extension StoreKitConfiguration {
    /// A product in a StoreKit configuration file.
    public struct Product: Hashable, Sendable, Identifiable {
        public let id: ProductID

        /// As Xcode writes it: `NonConsumable`, `Consumable`, `NonRenewingSubscription`,
        /// `RecurringSubscription`. Empty if the entry has none.
        public let type: String

        /// The price as the file spells it — a bare number such as `19.99` or `0.00`,
        /// with no currency. Empty if the entry has none.
        public let displayPrice: String

        /// `displayPrice` as a number, or nil if it is not one. **Nil is not zero**: a
        /// price that cannot be read has not been shown to be free.
        public let price: Decimal?

        public let isFamilyShareable: Bool

        /// The name the product goes by in App Store Connect. Never shown to anyone.
        public let referenceName: String

        /// The first localisation's name, which is the one Xcode's test environment
        /// serves unless the file's locale says otherwise.
        public let displayName: String?

        /// The first localisation's description.
        public let localizedDescription: String?

        /// For a subscription, the group the file puts it in.
        public let subscriptionGroupID: SubscriptionGroupID?

        /// For a subscription, its level in the group as the file ranks it (Xcode's
        /// `groupNumber`): 1 is the highest.
        public let groupLevel: Int?

        /// - Parameters:
        ///   - section: where the entry was found, for the error alone.
        ///   - index: its place there, likewise.
        init(json: [String: Any], section: String, index: Int) throws(StoreKitConfigurationError) {
            guard let identifier = json["productID"] as? String, !identifier.isEmpty else {
                throw .productWithoutIdentifier(section: section, index: index)
            }
            let localization = (json["localizations"] as? [[String: Any]])?.first
            // Xcode writes the price as a string. A number is accepted as well, since
            // a file edited by hand or by a script may well have one.
            let displayPrice =
                json["displayPrice"] as? String
                ?? (json["displayPrice"] as? NSNumber)?.stringValue
                ?? ""
            self.id = ProductID(identifier)
            self.type = json["type"] as? String ?? ""
            self.displayPrice = displayPrice
            self.price = Self.price(from: displayPrice)
            self.isFamilyShareable = json["familyShareable"] as? Bool ?? false
            self.referenceName = json["referenceName"] as? String ?? ""
            self.displayName = localization?["displayName"] as? String
            self.localizedDescription = localization?["description"] as? String
            self.subscriptionGroupID = (json["subscriptionGroupID"] as? String).map(SubscriptionGroupID.init(rawValue:))
            self.groupLevel = json["groupNumber"] as? Int
        }

        /// Digits and at most one point, or nothing. `Decimal(string:)` alone would
        /// read `0.99 or so` as 0.99 and `0,99` as 0 — the second of which is a paid
        /// trial passing for a free one.
        private static func price(from text: String) -> Decimal? {
            let digits = text.filter { $0 != "." }
            guard !digits.isEmpty, text.count - digits.count <= 1,
                digits.allSatisfy({ $0.isASCII && $0.isNumber })
            else { return nil }
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        }
    }
}
