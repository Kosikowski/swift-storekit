//
//  PurchaseLogging.swift
//  PurchaseCore
//
//  Layer: Port
//

/// Receives what happened. Events carry nothing unsafe to write down, so a conformer
/// may log them as they are. The package ships only a silent one; five lines over
/// `os.Logger` are in the documentation.
public protocol PurchaseLogging: Sendable {
    func log(_ event: PurchaseEvent)
}
