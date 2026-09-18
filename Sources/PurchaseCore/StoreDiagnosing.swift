//
//  StoreDiagnosing.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Reports what this build actually receives from the store. For debug panels and
/// for a hosted test probing a real build; nothing in the package depends on it.
public protocol StoreDiagnosing: Sendable {
    func diagnose() async -> StoreDiagnosis
}
