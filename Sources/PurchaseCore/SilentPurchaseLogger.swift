//
//  SilentPurchaseLogger.swift
//  PurchaseCore
//
//  Layer: Application
//

/// Logs nothing. The default.
public struct SilentPurchaseLogger: PurchaseLogging {
    public init() {}
    public func log(_ event: PurchaseEvent) {}
}
