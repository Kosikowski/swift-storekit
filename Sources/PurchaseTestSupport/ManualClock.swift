//
//  ManualClock.swift
//  PurchaseTestSupport
//
//  A clock that moves only when it is told to.
//
//  For testing anything that waits for a trial to end without waiting for it: set up
//  a trial that ends in five minutes, `advance(by: .seconds(300))`, and the store's
//  scheduled re-read fires now.
//
//  **Why this does not race.** Deadlines are absolute, so advancing before the
//  sleeper arrives and after it come to the same thing: a sleeper whose deadline has
//  already passed never parks. Whether to park is decided under the same lock that
//  `advance` takes, so there is no moment at which a sleeper has looked at the time
//  and not yet been added to the list. Sleepers are resumed outside the lock, in
//  deadline order and then arrival order, so nothing a resumed task does can find
//  the clock held.
//

public import Foundation
public import PurchaseCore
import Synchronization

/// A clock for tests. Not `#if DEBUG`: it grants nothing, and an app's tests need it
/// in whatever configuration they are built.
public final class ManualClock: TimeProviding {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Date
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// Sleepers cancelled before they had parked. Found on arrival.
        var cancelledEarly: Set<Int> = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }

    /// How many tasks are parked waiting for a later time. For a test that needs to
    /// know the store has got as far as scheduling its re-read before it moves time.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Date) async throws(CancellationError) {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { state -> Bool in
                    if state.cancelledEarly.remove(id) != nil { return false }
                    if deadline <= state.now { return false }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                if !parked { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    // Not parked yet. Leave a note for when it tries to.
                    state.cancelledEarly.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume()
        }
        state.withLock { _ = $0.cancelledEarly.remove(id) }
        if Task.isCancelled { throw CancellationError() }
    }

    /// Moves time forward and wakes everyone whose deadline has come.
    public func advance(by duration: Duration) {
        advance(to: now.addingTimeInterval(duration.timeInterval))
    }

    public func advance(to date: Date) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = max(state.now, date)
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due.sorted(by: { ($0.deadline, $0.id) < ($1.deadline, $1.id) }) {
            sleeper.continuation.resume()
        }
    }

    /// Wakes every sleeper **without moving time** — a timer that fires a moment
    /// early, which a real one may. Whatever was waiting should look at the time,
    /// find it is not yet, and wait again.
    public func wakeSleepers() {
        let all = state.withLock { state -> [Sleeper] in
            defer { state.sleepers = [] }
            return state.sleepers
        }
        for sleeper in all.sorted(by: { $0.id < $1.id }) { sleeper.continuation.resume() }
    }
}
