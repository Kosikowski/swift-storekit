//
//  StoreKitErrorMapping.swift
//  PurchaseStoreKit
//
//  StoreKit's errors, reduced to which kind they were.
//
//  Two things this exists to get right.
//
//  **Cancellation arrives two ways.** As `Product.PurchaseResult.userCancelled`, and
//  also as a *thrown* `StoreKitError.userCancelled`. An adapter that handles only the
//  first reports the second as a failure, and someone who simply changed their mind
//  is shown "something went wrong".
//
//  **Nothing of the error's text survives.** Some StoreKit errors echo App Store
//  account identifiers in their `localizedDescription`, so it is never read. For an
//  error this does not recognise, what crosses the boundary is the name of its type.
//

import Foundation
import PurchaseCore
import StoreKit

enum StoreKitErrorMapping {
    enum Verdict: Hashable, Sendable {
        /// The person chose this. Not an error, and nothing to say.
        case cancelled
        case failure(PurchaseCore.PurchaseError)
    }

    static func verdict(for error: any Error) -> Verdict {
        switch error {
        case let error as StoreKitError:
            return verdict(for: error)
        case let error as Product.PurchaseError:
            return .failure(failure(for: error))
        case is URLError:
            return .failure(.network)
        case is CancellationError:
            return .cancelled
        case let error as PurchaseCore.PurchaseError:
            return .failure(error)
        default:
            return .failure(.unknown(typeName: String(reflecting: type(of: error))))
        }
    }

    private static func verdict(for error: StoreKitError) -> Verdict {
        switch error {
        case .userCancelled: return .cancelled
        case .networkError: return .failure(.network)
        case .systemError: return .failure(.system)
        case .notAvailableInStorefront: return .failure(.notAvailableInStorefront)
        case .notEntitled, .unsupported: return .failure(.unsupported)
        case .unknown: return .failure(.unknown(typeName: "StoreKitError.unknown"))
        default:
            // `invalidPresentationContext` arrived with the 27 SDK. It is matched by
            // name so that this still compiles against the 26 one — which is also why
            // this is a plain `default`: `@unknown` would warn, on 27, about a case
            // that cannot be spelt on 26. A case name with no payload is all
            // `String(describing:)` gives here, so nothing leaks.
            if String(describing: error) == "invalidPresentationContext" {
                return .failure(.invalidConfirmation)
            }
            return .failure(.unknown(typeName: "StoreKitError"))
        }
    }

    private static func failure(for error: Product.PurchaseError) -> PurchaseCore.PurchaseError {
        switch error {
        case .productUnavailable: .productUnavailable
        case .purchaseNotAllowed: .purchaseNotAllowed
        case .invalidQuantity: .system
        // Offers belong to subscriptions, which this package does not sell.
        case .ineligibleForOffer, .invalidOfferIdentifier, .invalidOfferPrice, .invalidOfferSignature,
             .missingOfferParameters:
            .unsupported
        // Plain, for the same reason as above: the 26.5 SDK added a case the 26.0 one lacks.
        default: .unknown(typeName: "Product.PurchaseError")
        }
    }
}
