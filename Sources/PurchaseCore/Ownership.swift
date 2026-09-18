//
//  Ownership.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  How the account came to hold a transaction.
//
//  It matters because a family-shared transaction carries the *purchaser's* dates.
//  For an unlock that is harmless. For a trial it is not: every member of the family
//  would be handed the organiser's trial — over already, as likely as not — and lose
//  their own, since a trial that is owned cannot be started.
//

/// How a transaction reached this account.
public enum Ownership: Hashable, Sendable {
    /// Bought by this account.
    case purchased
    /// Shared by a family member who bought it.
    case familyShared
    /// Assigned by an organisation that bought it in volume.
    case assigned
    /// Something the App Store has added since this was written. Counted like
    /// `familyShared`: good for an unlock, never for a trial.
    case unrecognised
}
