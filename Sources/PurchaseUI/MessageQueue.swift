//
//  MessageQueue.swift
//  PurchaseUI
//
//  Apple's messages, held back while the app says so and shown in the order they came.
//

/// Messages waiting to be shown, oldest first.
package struct MessageQueue<Message> {
    package private(set) var waiting: [Message] = []

    package init() {}

    /// Shows `message` after any still waiting, unless the app is deferring them: then it waits too.
    package mutating func receive(_ message: Message, deferred: Bool, display: (Message) throws -> Void) {
        waiting.append(message)
        if !deferred { release(display: display) }
    }

    /// Shows every message waiting, oldest first. One that cannot be shown — no scene to show
    /// it in — waits for the next release, with every one after it: once iterated, StoreKit
    /// will not show it itself.
    package mutating func release(display: (Message) throws -> Void) {
        var shown = 0
        for message in waiting {
            do { try display(message) } catch { break }
            shown += 1
        }
        waiting.removeFirst(shown)
    }
}
