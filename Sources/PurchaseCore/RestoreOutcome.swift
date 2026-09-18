//
//  RestoreOutcome.swift
//  PurchaseCore
//
//  Layer: Domain
//

/// How a restore ended. Whether it *found* anything is in the standing, which has
/// been read again by the time this is returned.
public enum RestoreOutcome: Hashable, Sendable {
    case completed
    /// The person dismissed the store's sign-in prompt. Say nothing.
    case cancelled
}
