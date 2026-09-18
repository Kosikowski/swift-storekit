//
//  RecordingPurchaseLogger.swift
//  PurchaseTestKit
//

public import PurchaseCore
import Synchronization

/// Keeps every event, in order, for a test to look at afterwards.
public final class RecordingPurchaseLogger: PurchaseLogging {
    private let recorded = Mutex<[PurchaseEvent]>([])

    public init() {}

    public var events: [PurchaseEvent] { recorded.withLock { $0 } }

    public func log(_ event: PurchaseEvent) {
        recorded.withLock { $0.append(event) }
    }
}
