// The gate is DEBUG only, like the store whose answers it holds.
#if DEBUG

import Foundation
import PurchaseTestKit
import PurchaseTestSupport
import Testing

@Suite("Answer gate", .timeLimit(.minutes(1)))
struct AnswerGateTests {
    @Test("an open gate lets everyone straight through")
    func open() async {
        let gate = AnswerGate()
        await gate.pass()
        #expect(gate.waiterCount == 0)
    }

    @Test("a closed gate holds whoever asks until it is opened")
    func closed() async {
        let gate = AnswerGate(closed: true)
        let waiting = Task { await gate.pass(); return true }
        await waitUntil { gate.waiterCount == 1 }
        #expect(gate.waiterCount == 1)
        gate.open()
        #expect(await waiting.value)
        #expect(gate.waiterCount == 0)
    }

    @Test("a held answer stays held through cancellation")
    func ignoresCancellation() async {
        let gate = AnswerGate(closed: true)
        let waiting = Task { await gate.pass() }
        await waitUntil { gate.waiterCount == 1 }
        waiting.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(gate.waiterCount == 1)
        gate.open()
        await waiting.value
    }
}

#endif
