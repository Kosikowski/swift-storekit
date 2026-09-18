import Foundation
import PurchaseCore

/// The catalogue most suites share: one unlock, and a fortnight's trial of it.
enum Shop {
    static let pro: ProductID = "com.example.pro"
    static let trial: ProductID = "com.example.trial"
    static let fortnight: Duration = .seconds(14 * 86_400)

    static let catalogue: Catalogue = [
        .unlock(pro),
        .trial(trial, of: [pro], lasting: fortnight),
    ]

    static let epoch = Date(timeIntervalSince1970: 1_000_000)
}
