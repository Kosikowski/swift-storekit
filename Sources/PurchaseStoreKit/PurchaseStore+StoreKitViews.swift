//
//  PurchaseStore+StoreKitViews.swift
//  PurchaseStoreKit
//
//  A purchase made in one of Apple's views, handed to the store.
//
//  Measured in the iOS simulator: an unlock bought in `ProductView` is announced
//  **nowhere** — not on `Transaction.updates`, and an unlock has no status — and the view
//  finishes it itself. A subscription bought in `SubscriptionStoreView` arrives on the
//  status updates, and on `Transaction.updates` only sometimes. On the Mac both are
//  announced (spike/README.md, q12). So on iOS nothing may tell the store, and a person who
//  has just paid goes on seeing the paywall until the app next reads. The view's completion
//  handler is handed the transaction, and this is what takes it from there.
//

public import PurchaseCore
public import StoreKit

extension PurchaseStore {
    /// A purchase made in one of Apple's views — `SubscriptionStoreView`, `ProductView`,
    /// `StoreView` — taken as though this store had made it. Call it from the view's
    /// completion:
    ///
    ///     SubscriptionStoreView(groupID: Shop.membership.rawValue)
    ///         .onInAppPurchaseCompletion { product, result in
    ///             do {
    ///                 show(try await store.takePurchase(result, of: product))
    ///             } catch {
    ///                 show(error)
    ///             }
    ///         }
    ///
    /// Judged as a purchase made here is: verified and in the catalogue, it is finished,
    /// believed at once, and held until the listing and the status have it; a downgrade
    /// is a change of plan waiting for the renewal; one handed back that was not made fails
    /// with `system`. Unverified, it is thrown and left unfinished — the person may have
    /// been charged, so the error is not one to swallow. Something the catalogue does not
    /// sell is not this store's, and is left alone.
    @discardableResult
    public func takePurchase(
        _ result: Result<Product.PurchaseResult, any Error>, of product: Product
    ) async throws(PurchaseError) -> PurchaseCompletion {
        try await takePurchase(result, productID: ProductID(product.id))
    }

    /// An offer code redeemed in Apple's sheet, taken as a purchase is. From iOS and macOS
    /// 27 the sheet hands the redeemed transaction back:
    ///
    ///     .offerCodeRedemption(options: [], isPresented: $redeeming) { result in
    ///         Task {
    ///             do { show(try await store.takeRedemption(result)) } catch { show(error) }
    ///         }
    ///     }
    ///
    /// Before it, and for a code redeemed in the App Store, the transaction arrives on the
    /// updates stream, which the store is already listening to: nothing else is needed.
    @discardableResult
    public func takeRedemption(
        _ result: Result<VerificationResult<Transaction>, any Error>
    ) async throws(PurchaseError) -> PurchaseCompletion {
        switch result {
        case let .success(verification):
            let id = ProductID(verification.unsafePayloadValue.productID)
            return try await takePurchase(.success(.success(verification)), productID: id)
        case let .failure(error):
            switch StoreKitErrorMapping.verdict(for: error) {
            case .cancelled: return .cancelled
            case let .failure(failure): throw failure
            }
        }
    }

    func takePurchase(
        _ result: Result<Product.PurchaseResult, any Error>, productID id: ProductID
    ) async throws(PurchaseError) -> PurchaseCompletion {
        let outcome: PurchaseOutcome
        switch result {
        case let .success(result):
            outcome = try await AppStoreFront.outcome(
                of: LiveStoreKitGateway.result(of: result), catalogue: catalogue, logger: logger)
        case let .failure(error):
            switch StoreKitErrorMapping.verdict(for: error) {
            case .cancelled: outcome = .cancelled
            case let .failure(failure): throw failure
            }
        }
        return try await takePurchase(outcome, of: id)
    }
}
