import StoreKit
import SwiftUI

@main
struct HostApp: App {
    /// q12: launched with `-probe-storeview` or `-probe-storeview-completion`, the host shows
    /// Apple's `SubscriptionStoreView`, and with `-probe-productview` a `ProductView` for a
    /// one-time unlock, and says what reached the app when a person bought through it.
    /// Otherwise it is only a host for the probes in HostTests.
    private let probe: StoreViewProbe? = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-probe-storeview-completion") { return StoreViewProbe(completion: true) }
        if arguments.contains("-probe-storeview") { return StoreViewProbe(completion: false) }
        if arguments.contains("-probe-productview") { return StoreViewProbe(completion: false, unlock: true) }
        return nil
    }()

    /// Phase 3: launched with `-probe-intents`, the host listens for purchase intents from
    /// launch and shows every one it receives.
    private let intents: IntentProbe? =
        ProcessInfo.processInfo.arguments.contains("-probe-intents") ? IntentProbe() : nil

    #if os(iOS)
    /// Phase 3: launched with `-probe-messages`, the host keeps every StoreKit message it is
    /// sent, displaying none, and shows their reasons.
    private let messages: MessageProbe? =
        ProcessInfo.processInfo.arguments.contains("-probe-messages") ? MessageProbe() : nil
    #endif

    var body: some Scene {
        WindowGroup {
            if let probe {
                StoreViewProbeView(probe: probe)
            } else if let intents {
                Text("intents: " + intents.heard.joined(separator: " ")).accessibilityIdentifier("intents")
            } else if let messages = messageProbe {
                Text("messages: " + messages).accessibilityIdentifier("messages")
            } else {
                Text("StoreKit subscriptions spike host")
            }
        }
    }
}

extension HostApp {
    private var messageProbe: String? {
        #if os(iOS)
        messages.map { $0.heard.joined(separator: " ") }
        #else
        nil
        #endif
    }
}

#if os(iOS)
@MainActor
@Observable
final class MessageProbe {
    private let start = Date()
    var heard: [String] = []

    init() {
        Task {
            // Something to ask a price rise of: the monthly plan, bought at launch.
            if let product = try? await Product.products(for: ["probe.monthly"]).first,
                case let .success(.verified(transaction))? = try? await product.purchase()
            {
                await transaction.finish()
                heard.append("bought")
            }
        }
        Task {
            for await message in Message.messages {
                heard.append("reason \(message.reason.rawValue)@\(String(format: "%.2f", Date().timeIntervalSince(start)))")
            }
        }
    }
}
#endif

@MainActor
@Observable
final class IntentProbe {
    private let start = Date()
    var heard: [String] = []

    init() {
        Task {
            for await intent in PurchaseIntent.intents {
                var text = "\(intent.product.id)@\(String(format: "%.2f", Date().timeIntervalSince(start)))"
                if let offer = intent.offer { text += "+offer:\(offer.type.rawValue)/\(offer.id ?? "-")" }
                heard.append(text)
            }
        }
    }
}

/// What reached the app, and when, in seconds from launch. Listening starts as the app
/// does, before any view, so nothing announced can fall before it.
@MainActor
@Observable
final class StoreViewProbe {
    let completion: Bool
    /// A `ProductView` for a one-time unlock, in place of the subscription store.
    let unlock: Bool
    private let start = Date()
    var updates: [String] = []
    var statuses: [String] = []
    var completions: [String] = []
    var listed: [String] = []
    var firstListed: String?
    var unfinished: [String] = []

    init(completion: Bool, unlock: Bool = false) {
        self.completion = completion
        self.unlock = unlock
        Task { await self.listen() }
        Task { await self.listenToStatuses() }
        Task { await self.poll() }
    }

    private func listenToStatuses() async {
        for await status in Product.SubscriptionInfo.Status.updates {
            statuses.append("\(status.transaction.unsafePayloadValue.productID) \(status.state.localizedDescription)@\(now)")
        }
    }

    private var now: String { String(format: "%.2f", Date().timeIntervalSince(start)) }

    private func listen() async {
        for await result in Transaction.updates {
            let transaction = result.unsafePayloadValue
            updates.append("\(transaction.productID)#\(transaction.id)@\(now)")
            // Finished only so that the next run starts clean: the question is whether it came.
            await transaction.finish()
        }
    }

    private func poll() async {
        while true {
            var listing: [String] = []
            for await result in Transaction.currentEntitlements { listing.append(result.unsafePayloadValue.productID) }
            if listing != listed { listed = listing }
            if firstListed == nil, !listing.isEmpty { firstListed = now }
            var open: [String] = []
            for await result in Transaction.unfinished { open.append(result.unsafePayloadValue.productID) }
            if open != unfinished { unfinished = open }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func completed(_ product: Product, _ result: Result<Product.PurchaseResult, any Error>) {
        let said: String =
            switch result {
            case let .success(.success(verification)): "success #\(verification.unsafePayloadValue.id)"
            case .success(.pending): "pending"
            case .success(.userCancelled): "cancelled"
            case .success: "other"
            case let .failure(error): "error \(error)"
            }
        completions.append("\(product.id) \(said)@\(now)")
    }
}

struct StoreViewProbeView: View {
    let probe: StoreViewProbe

    var body: some View {
        VStack(spacing: 4) {
            store
            Group {
                Text("updates: " + probe.updates.joined(separator: " ")).accessibilityIdentifier("updates")
                Text("statuses: " + probe.statuses.joined(separator: " ")).accessibilityIdentifier("statuses")
                Text("first listed: " + (probe.firstListed ?? "-")).accessibilityIdentifier("first-listed")
                Text("completions: " + probe.completions.joined(separator: " ")).accessibilityIdentifier("completions")
                Text("listed: " + probe.listed.joined(separator: " ")).accessibilityIdentifier("listed")
                Text("unfinished: " + probe.unfinished.joined(separator: " ")).accessibilityIdentifier("unfinished")
            }
            .font(.caption2)
        }
    }

    @ViewBuilder private var store: some View {
        if probe.unlock {
            ProductView(id: "probe.unlock")
        } else if probe.completion {
            SubscriptionStoreView(groupID: "5B1F2A02")
                .onInAppPurchaseCompletion { product, result in probe.completed(product, result) }
        } else {
            SubscriptionStoreView(groupID: "5B1F2A02")
        }
    }
}
