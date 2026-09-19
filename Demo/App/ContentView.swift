//
//  ContentView.swift
//  Demo
//
//  A paywall of the plainest kind, to show where the app's half of the work goes.
//
//  Everything here that is *wording* or *policy* is the app's and not the package's:
//  what "Pro" means, what to say when a purchase is pending or does not verify, and
//  how to write the end of a trial — with its time, because a trial ends at an
//  instant and "until the 30th" is wrong by evening for someone who began in the
//  evening.
//

import PurchaseCore
import PurchaseDebugUI
import PurchaseLaunch
import PurchaseStoreKit
import PurchaseUI
import StoreKit
import SwiftUI

struct ContentView: View {
    @Environment(\.purchaseState) private var purchases
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var showsDebugPanel = false
    #endif

    /// The launch this view belongs to: whether it is on a simulated store, and what the
    /// debug panel needs. Nil in a preview, which has neither.
    var launch: StoreLaunch?

    /// The result of *this view's* buttons, kept here. Published somewhere shared, it
    /// would be announced by every view watching.
    @State private var notice: String?
    @State private var showsAppleStore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Said out loud, and the first thing a UI test looks for: in a build that
            // cannot honour a scenario the app runs on the real store and nothing fails,
            // so a test that did not check would photograph the wrong thing. Never true in
            // a release build, so this needs no `#if`.
            if launch?.isSimulated == true {
                Text("Simulated store").font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("simulated-store")
            }
            // Asked afresh every second, so the view changes when a trial runs out. The
            // standing is not resolved again for this: its questions take the date.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                status(at: timeline.date).accessibilityIdentifier("pro-status")
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            HStack {
                PurchaseButton(Shop.pro) { notice = Self.words(for: $0) } label: {
                    Text("Buy Pro\(price(of: Shop.pro))")
                }
                trialButton
                RestorePurchasesButton("Restore Purchases") { result in
                    if case let .failure(error) = result { notice = Self.words(for: error) }
                }
            }
            Divider()
            membership
            // Apple's own views sell from the App Store whatever the store below is, so they
            // are offered only when that is the App Store too.
            if launch?.isSimulated == false {
                Button("Apple's store…") { showsAppleStore = true }
                    .accessibilityIdentifier("apple-store")
                    .sheet(isPresented: $showsAppleStore) { appleStore }
            }
            debugPanelButton
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 520, alignment: .leading)
        #endif
    }

    /// A window of its own on the Mac; a sheet on iOS, which has no `Window` scenes. Not
    /// there at all in a release build, where there is no panel to open — asked of the
    /// panel, not of the preprocessor.
    @ViewBuilder
    private var debugPanelButton: some View {
        if PurchaseDebugPanel.isAvailable, let launch {
            #if os(macOS)
            Button("Purchase debug panel…") { openWindow(id: "purchase-debug") }
            #else
            Button("Purchase debug panel…") { showsDebugPanel = true }
                .sheet(isPresented: $showsDebugPanel) { PurchaseDebugPanel(launch) }
            #endif
        }
    }

    @ViewBuilder
    private func status(at date: Date) -> some View {
        switch purchases?.standing.access(to: Shop.pro, at: date) {
        case nil, .unknown?:
            // Not "free": the store has not answered, and nothing is judged yet.
            ProgressView()
        case .owned?:
            Label("Pro", systemImage: "checkmark.seal.fill").font(.title2)
        case let .onTrial(period, _)?:
            Label("Trial until \(Self.moment(period.endsAt))", systemImage: "hourglass").font(.title2)
        case .subscribed?:
            Label("Pro", systemImage: "checkmark.seal.fill").font(.title2)
        case .none?:
            Label("Free", systemImage: "lock").font(.title2)
        }
    }

    // MARK: - Membership, a subscription

    /// Where the membership stands, in the app's own words: the package says the state
    /// and the dates, and what they are called is the app's. A grace period is still a
    /// member — Apple's rule, and a promise the developer makes — and billing retry is not,
    /// said so that the person knows why and what to do.
    @ViewBuilder
    private var membership: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(membershipStatus).accessibilityIdentifier("membership-status")
            HStack {
                ForEach([Shop.monthly, Shop.yearly, Shop.plus], id: \.self) { plan in
                    PurchaseButton(plan) { notice = Self.words(for: $0) } label: {
                        Text("\(Self.name(of: plan))\(price(of: plan))")
                    }
                }
                ManageSubscriptionsButton("Manage", group: Shop.membership)
            }
            if let introductory = introductoryOffer {
                Text(introductory).font(.caption).accessibilityIdentifier("introductory-offer")
            }
            // Only what Apple says this person may have: someone lapsed long enough.
            ForEach(purchases?.winBackOffers(in: Shop.membership) ?? [], id: \.id) { offer in
                PurchaseButton(offer.product, options: PurchaseOptions(offer: .winBack(offer.id))) {
                    notice = Self.words(for: $0)
                } label: {
                    Text("Come back: \(Self.terms(offer.terms))")
                }
            }
        }
    }

    /// The introductory offer, for someone who may have it, **with its terms from the store**.
    /// Nothing while it is unknown: the regular price on the button is the right thing to
    /// show then, and the payment sheet applies the offer if it is due.
    private var introductoryOffer: String? {
        guard case let .eligible(terms)? = purchases?.introductoryOffer(for: Shop.monthly) else { return nil }
        let then = purchases?.products.first { $0.id == Shop.monthly }?.displayPrice
        return "New members: \(Self.terms(terms))\(then.map { ", then \($0) a month" } ?? "")"
    }

    /// An offer's terms in the Demo's words. The numbers are the store's; the sentence is ours.
    private static func terms(_ terms: OfferTerms) -> String {
        let unit =
            switch terms.period.unit {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            case .unrecognised: "period"
            }
        let length = terms.period.value * terms.periodCount
        let span = "\(length) \(unit)\(length == 1 ? "" : "s")"
        return switch terms.paymentMode {
        case .freeTrial: "\(span) free"
        case .payUpFront: "\(terms.displayPrice) for \(span)"
        default: "\(terms.displayPrice) a \(unit) for \(span)"
        }
    }

    /// Apple's own views, for an app that would rather not draw its own. The store is not
    /// always told of what is bought in them: in the iOS simulator an unlock bought in
    /// `ProductView` is announced nowhere at all (spike/README.md, q12). So their completion
    /// hands each purchase over, and without that line "Free" stays on screen until the
    /// app next reads.
    private var appleStore: some View {
        VStack {
            ProductView(id: Shop.pro.rawValue)
            SubscriptionStoreView(groupID: Shop.membership.rawValue)
        }
        .onInAppPurchaseCompletion { product, result in
            guard let store = launch?.store else { return }
            do throws(PurchaseError) {
                let completion = try await store.takePurchase(result, of: product)
                notice = Self.words(for: .success(completion))
                if completion != .cancelled { showsAppleStore = false }
            } catch {
                notice = Self.words(for: error)
            }
        }
    }

    private var membershipStatus: String {
        switch purchases?.standing.subscription(in: Shop.membership) {
        case nil, .unknown?:
            return "Membership: …"
        case .none?:
            return "Not a member"
        case let .active(held, _)?:
            let plan = Self.name(of: held.product)
            if case let .inGracePeriod(until) = held.state {
                return "\(plan) — your payment didn't go through. Update it by \(Self.moment(until)) to stay a member."
            }
            guard let renewal = held.renewal else { return "\(plan) member" }
            if !renewal.willRenew { return "\(plan) member until \(Self.moment(held.periodEnds)), then it ends" }
            if let next = renewal.nextProduct, next != held.product {
                return "\(plan) member; \(Self.name(of: next)) from \(Self.moment(held.periodEnds))"
            }
            return "\(plan) member; renews \(Self.moment(held.periodEnds))"
        case let .inactive(held, _)?:
            if held.state == .inBillingRetry { return "Membership paused: the App Store couldn't take payment" }
            return "Membership ended \(Self.moment(held.periodEnds))"
        }
    }

    private static func name(of plan: ProductID) -> String {
        switch plan {
        case Shop.monthly: "Monthly"
        case Shop.yearly: "Yearly"
        case Shop.plus: "Plus"
        default: plan.rawValue
        }
    }

    /// Three states, not two: once used, the button stays, disabled, saying when the
    /// trial ended. Hidden, people wonder where it went.
    @ViewBuilder
    private var trialButton: some View {
        switch purchases?.standing.trial(Shop.trial) {
        case .available?:
            PurchaseButton("Start 14-day Trial", buying: Shop.trial) { notice = Self.words(for: $0) }
        case let .used(period)?:
            Button("Trial ended \(Self.moment(period.endsAt))") {}.disabled(true)
        default:
            EmptyView()
        }
    }

    private func price(of id: ProductID) -> String {
        purchases?.products.first { $0.id == id }.map { " for \($0.displayPrice)" } ?? ""
    }

    private static func moment(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func words(for result: Result<PurchaseCompletion, PurchaseError>) -> String? {
        switch result {
        case .success(.owned), .success(.trialRunning), .success(.subscribed), .success(.cancelled): nil
        case .success(.offerNotApplied):
            "You're a member — but the offer couldn't be applied, so this was at the regular price. Contact support if that's not what you expected."
        case let .success(.planChangeScheduled(_, at)):
            "Your plan changes at your next renewal\(at.map { ", on \(moment($0))" } ?? "")."

        case .success(.pending): "Waiting for approval. Pro unlocks as soon as it is given."
        case let .success(.trialUsed(period)): "Your trial ended on \(moment(period.endsAt))."
        case .success(.notCounted): "That purchase was completed, but it does not unlock anything for this account."
        case let .failure(error): words(for: error)
        }
    }

    private static func words(for error: PurchaseError) -> String {
        switch error {
        case .unverified:
            "The App Store could not verify this purchase, so nothing has been unlocked. Try Restore Purchases, and contact support if you were charged."
        case .productUnavailable, .notAvailableInStorefront:
            "This is not available from the App Store at the moment."
        case .purchaseNotAllowed: "Purchases are switched off on this device."
        case .network: "The App Store could not be reached. Try again in a moment."
        case .alreadyInProgress: "A purchase is already under way."
        // Not "nothing has been charged": for this one, that is not known.
        case .revoked: "The App Store completed this purchase and then took it back, so nothing has been unlocked. Contact support if you were charged."
        case .offerRefused(.notEligible): "That offer isn't available to you. Nothing has been charged."
        case .offerRefused: "That offer couldn't be used just now. Nothing has been charged."
        case .offerNotSigned: "That offer couldn't be prepared. Nothing has been charged — try again in a moment."
        default: "Something went wrong, and nothing has been unlocked. Try again in a moment."
        }
    }
}
