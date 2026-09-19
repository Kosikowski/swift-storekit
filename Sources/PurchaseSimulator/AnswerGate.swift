//
//  AnswerGate.swift
//  PurchaseSimulator
//
//  Holds an answer back until a test lets it through.
//
//  The most useful test in a purchasing suite is the one about the moment *before*
//  the store has answered: nothing must be locked, nothing must be offered, and
//  nobody who has paid must see a paywall. That moment is over in milliseconds
//  unless something holds it open. This does.
//
//  DEBUG only, like the store whose answers it holds. This module is inside every app
//  that uses PurchaseLaunch or PurchaseDebugUI — an app never imports it, but it links
//  it — so whatever is in it and not behind the guard is in every app that ships.
//  Nothing is.
//

#if DEBUG

import Synchronization

/// A gate on an answer. Open by default.
public final class AnswerGate: Sendable {
    private struct State {
        var isOpen = true
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    public init(closed: Bool = false) {
        if closed { close() }
    }

    /// Anyone who asks after this waits until `open()`.
    public func close() {
        state.withLock { $0.isOpen = false }
    }

    public func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    public var isOpen: Bool { state.withLock { $0.isOpen } }

    /// How many are waiting. For a test that needs to know the store has *asked*
    /// before it asserts what happens while it has no answer.
    public var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Returns at once if open; otherwise when next opened. Deliberately ignores
    /// cancellation: a held answer stays held, which is the point of the gate.
    public func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state -> Bool in
                if state.isOpen { return false }
                state.nextID += 1
                state.waiters[state.nextID] = continuation
                return true
            }
            if !waits { continuation.resume() }
        }
    }

    deinit {
        // A gate dropped while closed would otherwise leak whoever was waiting.
        let waiting = state.withLock { Array($0.waiters.values) }
        for continuation in waiting { continuation.resume() }
    }
}

#endif
