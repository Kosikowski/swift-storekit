//
//  TimeProviding.swift
//  PurchaseCore
//
//  Layer: Port
//

public import Foundation

/// The time, and a way to wait for a later one.
///
/// A port because a trial's end is the one thing here that happens by itself, and
/// code that waits for it cannot be tested against a clock it does not control. The
/// deadline is absolute rather than a duration so that a manual clock has nothing to
/// race: advance-then-sleep and sleep-then-advance come to the same thing.
public protocol TimeProviding: Sendable {
    var now: Date { get }
    /// Returns at or after `deadline`. May return early; callers look at `now` again.
    func sleep(until deadline: Date) async throws(CancellationError)
}
