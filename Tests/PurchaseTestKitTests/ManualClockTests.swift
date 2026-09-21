import Foundation
import PurchaseCore
import PurchaseTestKit
import Testing

@Suite("Manual clock", .timeLimit(.minutes(1)))
struct ManualClockTests {
    @Test("time stands still until it is moved")
    func standsStill() {
        let clock = ManualClock()
        let start = clock.now
        clock.advance(by: .seconds(90))
        #expect(clock.now == start.addingTimeInterval(90))
    }

    @Test("a deadline already past does not park at all")
    func pastDeadline() async throws {
        let clock = ManualClock()
        try await clock.sleep(until: clock.now)
        try await clock.sleep(until: clock.now.addingTimeInterval(-5))
        #expect(clock.sleeperCount == 0)
    }

    @Test("a sleeper wakes when time reaches its deadline, and not before")
    func wakesAtDeadline() async {
        let clock = ManualClock()
        let deadline = clock.now.addingTimeInterval(300)
        let sleeper = Task { try? await clock.sleep(until: deadline); return clock.now }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(299))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        #expect(await sleeper.value == deadline)
    }

    @Test("advancing BEFORE the sleeper arrives loses nothing, because deadlines are absolute")
    func advanceFirst() async throws {
        let clock = ManualClock()
        let deadline = clock.now.addingTimeInterval(60)
        clock.advance(by: .seconds(60))
        try await clock.sleep(until: deadline)
        #expect(clock.sleeperCount == 0)
    }

    @Test("a cancelled sleeper throws, whether it was parked or had not got that far")
    func cancellation() async {
        let clock = ManualClock()
        let parked = Task { () -> Bool in
            do { try await clock.sleep(until: .distantFuture); return false } catch { return true }
        }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        parked.cancel()
        #expect(await parked.value)
        #expect(clock.sleeperCount == 0)

        let early = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await clock.sleep(until: .distantFuture); return false } catch { return true }
        }
        #expect(await early.value)
        #expect(clock.sleeperCount == 0)
    }

    @Test("waking sleepers early moves no time")
    func wakeEarly() async {
        let clock = ManualClock()
        let start = clock.now
        let sleeper = Task { try? await clock.sleep(until: .distantFuture) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.wakeSleepers()
        await sleeper.value
        #expect(clock.now == start)
    }

    @Test("a hundred sleepers and a hundred advances, in any order, leave nobody behind")
    func stress() async {
        let clock = ManualClock()
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for step in 1 ... 100 {
                group.addTask { try? await clock.sleep(until: start.addingTimeInterval(Double(step))) }
                group.addTask { clock.advance(to: start.addingTimeInterval(Double(step))) }
            }
        }
        #expect(clock.sleeperCount == 0)
    }
}
