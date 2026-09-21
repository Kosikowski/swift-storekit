import PurchaseUI
import Testing

@Suite("Apple's messages, held back and shown in order")
struct MessageQueueTests {
    private struct NoScene: Error {}

    @Test("while deferred, each waits; released, they are shown oldest first, and none is left")
    func deferred() {
        var queue = MessageQueue<Int>()
        var shown: [Int] = []
        queue.receive(1, deferred: true) { shown.append($0) }
        queue.receive(2, deferred: true) { shown.append($0) }
        #expect(shown.isEmpty)
        queue.release { shown.append($0) }
        #expect(shown == [1, 2])
        #expect(queue.waiting.isEmpty)
    }

    @Test("not deferred, a message is shown at once")
    func atOnce() {
        var queue = MessageQueue<Int>()
        var shown: [Int] = []
        queue.receive(1, deferred: false) { shown.append($0) }
        #expect(shown == [1])
        #expect(queue.waiting.isEmpty)
    }

    @Test("one that cannot be shown waits, with every one after it, and is shown first at the next release")
    func cannotShow() {
        var queue = MessageQueue<Int>()
        var shown: [Int] = []
        queue.receive(1, deferred: true) { shown.append($0) }
        queue.receive(2, deferred: true) { shown.append($0) }
        queue.release { _ in throw NoScene() }
        #expect(queue.waiting == [1, 2])
        queue.receive(3, deferred: false) { shown.append($0) }
        #expect(shown == [1, 2, 3])
        #expect(queue.waiting.isEmpty)
    }

    @Test("a failure part-way keeps the rest in order")
    func failsPartWay() {
        var queue = MessageQueue<Int>()
        for message in 1 ... 3 { queue.receive(message, deferred: true) { _ in } }
        var shown: [Int] = []
        queue.release { message in
            if message == 2 { throw NoScene() }
            shown.append(message)
        }
        #expect(shown == [1])
        #expect(queue.waiting == [2, 3])
    }
}
