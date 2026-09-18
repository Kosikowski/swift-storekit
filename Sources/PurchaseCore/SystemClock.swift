//
//  SystemClock.swift
//  PurchaseCore
//
//  Layer: Application
//

public import Foundation

/// The real time.
///
/// Waits on the continuous clock, which keeps counting while the machine sleeps, so
/// a fortnight's wait is still a fortnight across a closed lid. It does not notice
/// the wall clock being *changed*; `PurchaseStore.refresh()` on becoming active
/// covers that, and a store reads `now` afresh every time it resolves.
public struct SystemClock: TimeProviding {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws(CancellationError) {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(remaining), clock: .continuous)
        } catch {
            throw CancellationError()
        }
    }
}
