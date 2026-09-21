//
//  PurchaseStore.swift
//  PurchaseCore
//
//  Layer: Application
//
//  The one stateful thing in the package.
//
//  Everything that is a *rule* has been moved out of here into something pure —
//  `StandingResolver`, `Standing`, `UnlistedPurchases` — so that what is left is
//  only what has to be stateful: the order things happen in.
//
//  On the main actor, because everything that reads it is a view, and a holder that
//  views read synchronously cannot also be a step behind them. Code that is not a
//  view can watch it with `Observations { store.standing }`.
//

import Foundation
public import Observation

/// Where the account stands, and the commands that change it.
@MainActor
@Observable
public final class PurchaseStore: PurchaseStateProviding, PurchaseCommanding {
    public let catalogue: Catalogue
    public private(set) var standing: Standing
    public private(set) var products: [StoreProduct] = []
    public private(set) var productLoad: ProductLoadState = .notLoaded
    public private(set) var pendingApprovals: Set<ProductID> = []
    public private(set) var activity: PurchaseActivity = .idle
    public private(set) var requestedPurchases: [RequestedPurchase] = []
    /// Apple's word on each group's introductory offer, read with the prices.
    private var saysEligible: [SubscriptionGroupID: Bool] = [:]
    /// Groups in which this store has seen an introductory offer used. Apple's answer keeps
    /// its first value for the life of the process (measured), so what was seen is kept too.
    private var usedIntroductoryOffer: Set<SubscriptionGroupID> = []
    /// The groups whose statuses the last read could say. Where one could not, "never
    /// subscribed" is only the listing's word, and refuses nobody a promotional offer.
    @ObservationIgnored private var statusesRead: Set<SubscriptionGroupID> = []
    /// How many purchases each non-renewing subscription waiting for approval had when it
    /// began waiting. It is owned from its first purchase, so only a later one settles it.
    @ObservationIgnored private var purchasesWhenPending: [ProductID: Int] = [:]
    /// Non-renewing purchases the updates stream announced: new, whatever was counted since.
    @ObservationIgnored private var announcedNonRenewing: Set<OwnedProduct> = []

    @ObservationIgnored private let catalogueLoader: any ProductCatalogueLoading
    @ObservationIgnored private let ownership: any OwnershipReading
    @ObservationIgnored private let purchaser: any ProductPurchasing
    @ObservationIgnored private let restorer: any PurchaseRestoring
    @ObservationIgnored private let observer: any TransactionObserving
    @ObservationIgnored private let subscriptionStatuses: (any SubscriptionStatusReading)?
    @ObservationIgnored private let eligibility: (any IntroductoryEligibilityReading)?
    @ObservationIgnored private let offerSigner: (any OfferSigning)?
    /// The clock this store decides by. For whoever asks it a question that takes a date
    /// — `standing.access(to:at:)` — and should be asking by the same clock: an app that
    /// kept one of its own beside this had two, and only a test could tell them apart.
    @ObservationIgnored public let clock: any TimeProviding
    @ObservationIgnored private let diagnoser: (any StoreDiagnosing)?
    @ObservationIgnored package let logger: any PurchaseLogging
    @ObservationIgnored private let listingGrace: Duration
    @ObservationIgnored private let renewalGrace: Duration
    @ObservationIgnored private let resolver = StandingResolver()

    @ObservationIgnored private var unlisted = UnlistedPurchases()
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// When to look again at a lapse that was not believed yet, if one was not.
    @ObservationIgnored private var recheck: Date?
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var passRequested = false
    @ObservationIgnored private var load: Task<Void, Never>?

    /// Takes the store one role at a time. Construction touches nothing: a store
    /// built for a preview or a test has not spoken to anything until `start()`.
    ///
    /// - Parameters:
    ///   - subscriptionStatuses: what says each subscription group's statuses. Without
    ///     it, the listing stands in for every group, and nothing is known of renewals.
    ///   - introductoryEligibility: what says whether this person may have each group's
    ///     introductory offer. Without it every introductory offer is `unknown`.
    ///   - offerSigner: the app's server, signing promotional offers and the introductory
    ///     override. Without it a purchase with either fails with `offerNotSigned`.
    ///   - listingGrace: how long a grant is believed before the store's own listing has
    ///     it. The listing was measured to catch up within a second; the default is
    ///     generous because lapsing early re-locks something just bought.
    ///   - renewalGrace: how long after a renewing subscription's period ends a lapse is
    ///     doubted. Measured, StoreKit says a subscription has expired for up to 0.7 s at
    ///     every renewal; the default is generous for the same reason as `listingGrace`.
    public init(
        catalogue: Catalogue,
        catalogueLoader: any ProductCatalogueLoading,
        ownership: any OwnershipReading,
        purchaser: any ProductPurchasing,
        restorer: any PurchaseRestoring,
        observer: any TransactionObserving,
        subscriptionStatuses: (any SubscriptionStatusReading)? = nil,
        introductoryEligibility: (any IntroductoryEligibilityReading)? = nil,
        offerSigner: (any OfferSigning)? = nil,
        clock: any TimeProviding = SystemClock(),
        logger: any PurchaseLogging = SilentPurchaseLogger(),
        listingGrace: Duration = .seconds(30),
        renewalGrace: Duration = .seconds(30)
    ) {
        self.catalogue = catalogue
        self.standing = .unknown(catalogue: catalogue)
        self.catalogueLoader = catalogueLoader
        self.ownership = ownership
        self.purchaser = purchaser
        self.restorer = restorer
        self.observer = observer
        self.subscriptionStatuses = subscriptionStatuses
        self.eligibility = introductoryEligibility
        self.offerSigner = offerSigner
        self.clock = clock
        self.logger = logger
        self.listingGrace = listingGrace
        self.renewalGrace = renewalGrace
        // Whichever of the roles can say what this build receives. Usually they are all
        // one object; asked in the order somebody debugging would think of them.
        self.diagnoser = [catalogueLoader, ownership, purchaser, restorer, observer]
            .lazy.compactMap { $0 as? any StoreDiagnosing }.first
    }

    /// The usual case: one object plays every role — subscription statuses and
    /// introductory eligibility too, if it can say them. The signer is the app's own.
    public convenience init(
        catalogue: Catalogue,
        front: some StoreFront,
        offerSigner: (any OfferSigning)? = nil,
        clock: any TimeProviding = SystemClock(),
        logger: any PurchaseLogging = SilentPurchaseLogger(),
        listingGrace: Duration = .seconds(30),
        renewalGrace: Duration = .seconds(30)
    ) {
        self.init(
            catalogue: catalogue, catalogueLoader: front, ownership: front, purchaser: front,
            restorer: front, observer: front, subscriptionStatuses: front as? any SubscriptionStatusReading,
            introductoryEligibility: front as? any IntroductoryEligibilityReading, offerSigner: offerSigner,
            clock: clock, logger: logger, listingGrace: listingGrace, renewalGrace: renewalGrace)
    }

    /// Isolated, so that the tasks can be reached at all: a plain `deinit` is
    /// nonisolated and may not touch main-actor state. Without this the listener
    /// stays parked on the stream until the next transaction happens to arrive.
    isolated deinit {
        listener?.cancel()
        expiry?.cancel()
    }

    // MARK: - Reading

    public func knownStanding() async -> Standing {
        // Cannot hang: every pass ends with a known standing, and the pass is not
        // something a cancelled caller can cut short.
        if !standing.isKnown { await start() }
        return standing
    }

    /// What this build receives from the store, if the store behind this can say: the
    /// App Store and the simulated one both can. Nil otherwise. Here so that an app which
    /// made its store in one line does not have to keep the front as well, for the one
    /// afternoon it needs to ask why Buy does nothing.
    public func diagnose() async -> StoreDiagnosis? {
        await diagnoser?.diagnose()
    }

    // MARK: - Commands

    public func start() async {
        listen()
        if !standing.isKnown { await resolve() }
    }

    public func refresh() async {
        listen()
        await resolve()
    }

    /// **Single-flight, in a task nobody cancels**, for the reasons `resolve()` is.
    ///
    /// Single-flight, because two loads finish in whichever order the network likes and
    /// the last to finish wins: a first load timing out after a retry had succeeded
    /// left "could not load" over prices that were there. A caller arriving while one
    /// is under way joins it — prices asked for a moment ago are the prices — where a
    /// read of what is owned is run again, because what is owned may just have changed.
    ///
    /// In a task nobody cancels, because SwiftUI cancels `.task` whenever a view goes
    /// away and a cancelled request comes back as a failure. This state is shared, so
    /// one paywall closing at the wrong moment told every view the store was broken.
    public func loadProducts() async {
        if let load {
            await load.value
            return
        }
        let task = Task {
            await loadProductsOnce()
            // No suspension between the load's last line and this, so nobody can ask
            // in the gap and be left waiting on a load that has finished.
            load = nil
        }
        load = task
        await task.value
    }

    /// Prices, unless they are here already. What a paywall calls when it opens, and a
    /// second scene when it appears: `loadProducts()` goes to the network every time it
    /// is asked, which is right for a Retry button and wrong for everything else. A load
    /// that failed is needed again; one under way is joined.
    public func loadProductsIfNeeded() async {
        if productLoad == .loaded { return }
        await loadProducts()
    }

    private func loadProductsOnce() async {
        productLoad = .loading
        do throws(PurchaseError) {
            let loaded = try await catalogueLoader.products()
            let order = Dictionary(
                uniqueKeysWithValues: catalogue.entries.enumerated().map { ($1.id, $0) })
            products = loaded
                .filter { order[$0.id] != nil }
                .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            productLoad = .loaded
            let identifiers = Set(products.map(\.id))
            logger.log(
                identifiers.isEmpty
                    ? .catalogueLoadedEmpty(requested: catalogue.identifiers)
                    : .catalogueLoaded(identifiers))
        } catch {
            // The last good answer stays. A price that was right a minute ago is a
            // better thing to show than an empty paywall — and none of this goes
            // anywhere near the standing.
            productLoad = .failed(error)
            logger.log(.catalogueLoadFailed(error))
        }
        // Beside the prices, and like them never waited for by anything that decides access:
        // an introductory offer is terms on a paywall.
        await readIntroductoryEligibility()
    }

    private func readIntroductoryEligibility() async {
        let groups = catalogue.subscriptionGroups
        guard !groups.isEmpty, let eligibility else { return }
        let said = await eligibility.introductoryEligibility(in: Set(groups))
        if said.contains(where: { saysEligible[$0.key] != $0.value }) { saysEligible.merge(said) { $1 } }
    }

    // MARK: - Offers

    public func introductoryOffer(for id: ProductID) -> IntroductoryEligibility {
        guard let group = catalogue.entry(for: id)?.subscriptionTerms?.group else { return .noOffer }
        guard let product = products.first(where: { $0.id == id }) else { return .unknown }
        guard let terms = product.subscription?.introductoryOffer else { return .noOffer }
        // One per group per account. Used, as far as this store has seen — bought here, or
        // on a status in the group — it is used, whatever Apple's first answer was.
        if usedIntroductoryOffer.contains(group)
            || standing.subscription(in: group).all.contains(where: { $0.offer?.kind == .introductory && $0.ownership == .purchased })
        {
            return .ineligible
        }
        switch saysEligible[group] {
        case true?: return .eligible(terms)
        case false?: return .ineligible
        case nil: return .unknown
        }
    }

    public func winBackOffers(in group: SubscriptionGroupID) -> [WinBackOffer] {
        let subscription = standing.subscription(in: group)
        guard subscription.isActive == false else { return [] }
        // The account's own status: a win-back offer is for the plan this person lapsed
        // from, and access through Family Sharing does not count towards one [Apple].
        guard let own = subscription.all.first(where: { $0.ownership == .purchased }), let renewal = own.renewal,
            let offers = products.first(where: { $0.id == own.product })?.subscription?.winBackOffers
        else { return [] }
        return renewal.winBackOffers.compactMap { id in
            offers.first { $0.id == id }.map { WinBackOffer(product: own.product, id: id, terms: $0) }
        }
    }

    @discardableResult
    public func purchase(
        _ id: ProductID, options: PurchaseOptions, confirmation: PurchaseConfirmation
    ) async throws(PurchaseError) -> PurchaseCompletion {
        guard catalogue.contains(id) else { throw .productUnavailable }
        guard activity == .idle else { throw .alreadyInProgress }
        listen()
        activity = .purchasing(id)
        defer { activity = .idle }
        logger.log(.purchaseStarted(id))

        // Asked for outside the app and now bought here, however it ends: the request is dealt with.
        requestedPurchases.removeAll { $0.product == id }
        if !standing.isKnown { await resolve() }
        let before = standing
        let outcome: PurchaseOutcome
        do throws(PurchaseError) {
            let signed = try await signed(options, for: id)
            outcome = try await purchaser.purchase(id, options: signed, confirmation: confirmation)
        } catch {
            // Thrown on to the button that asked. The standing is not read, not
            // written and not doubted: a purchase failing says nothing about what
            // was already owned.
            logger.log(.purchaseFailed(id, error))
            throw error
        }
        try await refuseIfHandedBack(outcome, asked: id, before: before)
        return await settle(outcome, asked: id, offer: options.offer)
    }

    /// Bought again, StoreKit can hand back a purchase already made and buy nothing: a
    /// subscription's transaction already over (spike/README.md, row 10; D51), or a
    /// non-renewing purchase already counted (n03; D52). Neither is a purchase, and trying
    /// again is fair.
    ///
    /// - Parameter before: the standing from before the purchase. One read since may
    ///   already count the purchase just made.
    private func refuseIfHandedBack(
        _ outcome: PurchaseOutcome, asked id: ProductID, before: Standing, announced: Set<OwnedProduct> = []
    ) async throws(PurchaseError) {
        guard case let .purchased(owned) = outcome, let entry = catalogue.entry(for: owned.id) else { return }
        let handedBack =
            if entry.subscriptionTerms != nil {
                owned.expirationDate.map { $0 <= clock.now } ?? false
            } else if entry.nonRenewingTerms != nil {
                before.purchases(ofNonRenewing: owned.id).contains(owned.purchaseDate) && !announced.contains(owned)
            } else {
                false
            }
        guard handedBack else { return }
        logger.log(.purchaseFailed(id, .system))
        await resolve()
        throw .system
    }

    /// `options` with the signature its offer needs, from the app's signer. **Nothing is
    /// bought without one**, and a promotional offer for someone who has never subscribed in
    /// the group is refused before the signer is asked: Apple gives them only to current
    /// and former subscribers [Apple].
    private func signed(_ options: PurchaseOptions, for id: ProductID) async throws(PurchaseError) -> PurchaseOptions {
        var signed = options
        signed.signature = nil
        let kind: OfferSignatureRequest.Kind
        switch options.offer {
        case nil, .winBack?:
            return signed
        case let .promotional(offer)?:
            guard let group = catalogue.entry(for: id)?.subscriptionTerms?.group else { throw .offerRefused(.unknownOffer) }
            if statusesRead.contains(group), standing.subscription(in: group) == .none { throw .offerRefused(.notEligible) }
            kind = .promotional(offer)
        case .introductoryOverride?:
            guard catalogue.entry(for: id)?.subscriptionTerms != nil else { throw .offerRefused(.unknownOffer) }
            kind = .introductoryOverride
        }
        guard let offerSigner else { throw .offerNotSigned }
        // The account's own latest transaction in the group, which Apple's signature creators
        // take — and which the override's requires [Apple].
        let statuses = (catalogue.entry(for: id)?.subscriptionTerms.map { standing.subscription(in: $0.group).all } ?? [])
            .filter { $0.transactionID != nil }
        let transaction = (statuses.first { $0.ownership == .purchased } ?? statuses.first)?.transactionID
        do {
            let request = OfferSignatureRequest(
                product: id, kind: kind, appAccountToken: options.appAccountToken, transactionID: transaction.map(String.init))
            signed.signature = try await offerSigner.signature(for: request)
        } catch {
            logger.log(.offerSignerFailed(id, typeName: String(reflecting: type(of: error))))
            throw .offerNotSigned
        }
        return signed
    }

    /// A purchase this store did not make, **taken as though it had**: held until the
    /// listing and the status have it, and read again at once.
    ///
    /// For purchases made by Apple's own views — `SubscriptionStoreView`, `ProductView`,
    /// `StoreView` — whose transactions this store is not reliably told of. Measured in the
    /// iOS simulator: an unlock bought in `ProductView` is announced **nowhere**, and a
    /// subscription bought in `SubscriptionStoreView` only on the status updates
    /// (spike/README.md, q12). Someone who has just paid would go on seeing the paywall
    /// until the store next reads.
    ///
    /// `PurchaseStoreKit` has the form an app calls, which takes the view's own result.
    /// This one is for a store front of an app's own, and for tests. Nothing waits on
    /// `activity`: the purchase is over.
    ///
    /// A purchase handed back that was not made fails with `system`, as it does from
    /// `purchase(_:options:confirmation:)`.
    ///
    /// - Parameter id: the product the person chose. A subscription that comes back as
    ///   another plan of the same group is a change waiting for the renewal.
    @discardableResult
    public func takePurchase(_ outcome: PurchaseOutcome, of id: ProductID) async throws(PurchaseError) -> PurchaseCompletion {
        listen()
        // Made before this was called, so perhaps counted already: on the Mac, Apple's views
        // announce what they sell (spike/README.md, q12).
        try await refuseIfHandedBack(outcome, asked: id, before: standing, announced: announcedNonRenewing)
        return await settle(outcome, asked: id)
    }

    /// - Parameter offer: the offer the purchase asked for, if any. One the transaction does
    ///   not carry, and the renewal is not waiting to apply, was not applied, and is said so.
    private func settle(
        _ outcome: PurchaseOutcome, asked id: ProductID, offer: PurchaseOptions.Offer? = nil
    ) async -> PurchaseCompletion {
        switch outcome {
        case .cancelled:
            logger.log(.purchaseCancelled(id))
            return .cancelled
        case .pending:
            if catalogue.entry(for: id)?.nonRenewingTerms != nil {
                purchasesWhenPending[id] = standing.purchases(ofNonRenewing: id).count
            }
            pendingApprovals.insert(id)
            logger.log(.purchasePending(id))
            return .pending
        case let .purchased(owned):
            // The same rule as the listing, so a purchase that grants this account
            // nothing is never held as though it had.
            guard resolver.counts(owned, in: catalogue) else {
                logger.log(.purchaseNotCounted(id))
                await resolve()
                return .notCounted(owned)
            }
            noteIntroductoryOffer(on: owned)
            hold(owned)
            await resolve()
            logger.log(.purchased(id))
            let completion = completion(for: owned, asked: id)
            if let offer, case let .subscribed(held) = completion, !Self.carries(held, offer) {
                return .offerNotApplied(held)
            }
            return completion
        }
    }

    /// Whether `held` carries `offer`: on its transaction, or waiting for the renewal.
    private static func carries(_ held: HeldSubscription, _ offer: PurchaseOptions.Offer) -> Bool {
        [held.offer, held.renewal?.offer].contains { applied in
            guard let applied else { return false }
            switch offer {
            case let .winBack(id): return applied.kind == .winBack && applied.id == id
            case let .promotional(id): return applied.kind == .promotional && applied.id == id
            case .introductoryOverride: return applied.kind == .introductory
            }
        }
    }

    /// A transaction bought with the introductory offer uses up the group's: Apple's own
    /// answer was measured to go on saying "eligible" for the rest of the process.
    private func noteIntroductoryOffer(on owned: OwnedProduct) {
        guard owned.offer?.kind == .introductory, owned.ownership == .purchased, let group = catalogue.entry(for: owned.id)?.subscriptionTerms?.group
        else { return }
        usedIntroductoryOffer.insert(group)
    }

    @discardableResult
    public func restorePurchases() async throws(PurchaseError) -> RestoreOutcome {
        guard activity == .idle else { throw .alreadyInProgress }
        listen()
        activity = .restoring
        defer { activity = .idle }
        do throws(PurchaseError) {
            let outcome = try await restorer.restorePurchases()
            await resolve()
            logger.log(outcome == .completed ? .restoreCompleted : .restoreCancelled)
            return outcome
        } catch {
            // Read again regardless, and never downgrade: the store could not be
            // reached, which is no evidence that anything stopped being owned.
            await resolve()
            logger.log(.restoreFailed(error))
            throw error
        }
    }

    // MARK: - Resolving

    /// Reads what is owned and republishes the standing. **Single-flight, with a
    /// re-run, in a task nobody cancels.**
    ///
    /// Single-flight with a re-run: a caller arriving while a pass is under way is
    /// given a pass that *started after it asked*, so a `purchase()` that returns
    /// has a standing that already includes it.
    ///
    /// In a task nobody cancels, because the real store answers a **cancelled** task
    /// with nothing at all — measured: 0 of 1 entitlements — and nothing at all reads
    /// as "owns nothing". SwiftUI cancels `.task` whenever a view goes away. Were the
    /// read made in the caller's task, a paying customer closing a sheet at the wrong
    /// moment would be locked out. So the read happens in a task of its own, and a
    /// cancelled caller simply waits for it like anyone else.
    private func resolve() async {
        passRequested = true
        if let pass {
            await pass.value
            return
        }
        let task = Task {
            while passRequested {
                passRequested = false
                await resolveOnce()
            }
            // No suspension between the loop's last look at the flag and this, so
            // nobody can ask in the gap and be left waiting on a finished pass.
            pass = nil
        }
        pass = task
        await task.value
    }

    private func resolveOnce() async {
        let listed = await ownership.ownedProducts()
        let groups = catalogue.subscriptionGroups
        // Beside the listing, in the same task nobody cancels: a status read from a
        // cancelled task answers "never subscribed" (measured, spike/README.md).
        var statuses: [SubscriptionGroupID: [HeldSubscription]] = [:]
        if !groups.isEmpty, let subscriptionStatuses {
            statuses = await subscriptionStatuses.subscriptionStatuses(in: Set(groups))
        }
        statusesRead = Set(statuses.keys)
        let introductoryUsed = Set(
            statuses.values.joined().filter { $0.offer?.kind == .introductory && $0.ownership == .purchased }.map(\.group))
        if !introductoryUsed.isSubset(of: usedIntroductoryOffer) { usedIntroductoryOffer.formUnion(introductoryUsed) }
        // The only place the clock is read for a decision.
        let now = clock.now
        // Settled against what the listing has *and counts*. A listing that has the
        // product and does not count it — a family member's copy of something this
        // account has just bought for itself — has not taken over from the hold, and
        // letting go on the identifier alone left the purchase vouched for by nobody.
        //
        // A subscription's hold is settled by its status, not by the listing: the two catch
        // up a moment apart, in either order (measured), and a listing that let go first left
        // an empty status saying "never subscribed" to someone who had just paid. Only for a
        // group whose status could not be read does the listing stand in, as it does there.
        let settledByListing = listed.filter { owned in
            guard resolver.counts(owned, in: catalogue) else { return false }
            guard let group = catalogue.entry(for: owned.id)?.subscriptionTerms?.group else { return true }
            return statuses[group] == nil
        }
        unlisted.settle(listedIn: settledByListing + caughtUp(with: statuses), at: now)
        let held = unlisted.held
        var subscriptions: [SubscriptionGroupID: SubscriptionStanding] = [:]
        recheck = nil
        for group in groups {
            // A purchase or a renewal the status has not caught up with is believed beside
            // it, as a grant is believed before the listing has it.
            let holds = held.compactMap { subscription(from: $0, in: group) }
            let reading = resolver.subscription(
                in: group, statuses: statuses[group].map { $0 + holds },
                listed: listed.compactMap { subscription(from: $0, in: group) } + holds, catalogue: catalogue)
            let before = standing.subscription(in: group)
            let believed = reading.believed(over: before, at: now, renewalGrace: renewalGrace.timeInterval)
            if believed != reading, let ends = before.current?.periodEnds {
                // Doubted: look again in a moment, and no later than the doubt allows.
                let soon = min(now.addingTimeInterval(2), ends.addingTimeInterval(renewalGrace.timeInterval))
                recheck = min(recheck ?? soon, soon)
            }
            if case let .active(current, _) = believed, current.accessEnds <= now {
                // Still said to be subscribed after its end: the renewal not synced yet, or
                // the listing standing in for a status. Look again in a minute; activation
                // reads again too.
                let later = now.addingTimeInterval(60)
                recheck = min(recheck ?? later, later)
            }
            subscriptions[group] = believed
        }
        // Published only when it says something new. An app reads again whenever it
        // becomes active, and nearly every one of those reads finds what the last found;
        // assigned regardless, each redrew every view that watches this, for nothing.
        let resolved = resolver.standing(owned: listed + held, catalogue: catalogue, asOf: now, subscriptions: subscriptions)
        if !resolved.saysTheSame(as: standing) { standing = resolved }
        let subscribed = groups.compactMap { group -> ProductID? in
            guard case let .active(current, _) = standing.subscription(in: group) else { return nil }
            return current.product
        }
        // An approved change of plan waits for the renewal, handed back as the plan already
        // held (measured): the plan asked for is not active until then, only named as next.
        let scheduled = groups.compactMap { group -> ProductID? in
            guard case let .active(current, _) = standing.subscription(in: group) else { return nil }
            return current.renewal?.nextProduct
        }
        let bought = standing.ownedProducts.map(\.id).filter { id in
            purchasesWhenPending[id].map { standing.purchases(ofNonRenewing: id).count > $0 } ?? true
        }
        let settled = pendingApprovals.intersection(bought + subscribed + scheduled)
        if !settled.isEmpty { pendingApprovals.subtract(settled) }
        logger.log(.standingResolved(owned: Set(standing.ownedProducts.map(\.id) + subscribed)))
        scheduleNextLook()
    }

    /// Two things change by themselves, with no transaction to announce them: a trial
    /// reaches its end, and a held grant runs out of time. Without a look scheduled
    /// for the sooner of the two, nothing locks until something unrelated redraws, or
    /// the app is relaunched.
    ///
    /// A wake that lands a moment early needs no special case: nothing has changed at
    /// `now`, so the same deadline comes back and is waited for again.
    private func scheduleNextLook() {
        expiry?.cancel()
        expiry = nil
        // Never a moment already gone. A standing that did not change is not republished,
        // so its `nextExpiry` can be one that has passed — a lapse still being doubted —
        // and a look scheduled for it would wake at once, and again, for ever.
        let now = clock.now
        guard let deadline = [standing.nextExpiry(after: now), unlisted.nextLapse, recheck].compactMap(\.self).filter({ $0 > now }).min()
        else { return }
        expiry = Task { [weak self, clock] in
            do throws(CancellationError) {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.resolve()
        }
    }

    // MARK: - Listening

    /// Started by the first command rather than by `init`, so that building a store
    /// — in a preview, in a test — reaches for nothing. Once, for the store's life.
    private func listen() {
        guard listener == nil else { return }
        // Subscribed here, synchronously, before anything else can happen.
        let updates = observer.transactionUpdates()
        listener = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                await self.transactionArrived(update)
            }
        }
    }

    private func transactionArrived(_ update: TransactionUpdate) async {
        logger.log(.transactionUpdated(update.productID))
        switch update {
        case let .granted(owned):
            // It arrives before the store lists it, so it is believed for a moment,
            // exactly as a purchase made here is — and by the same rule, so a grant
            // that gives this account nothing is never held.
            if resolver.counts(owned, in: catalogue) { hold(owned) }
            if catalogue.entry(for: owned.id)?.nonRenewingTerms != nil { announcedNonRenewing.insert(owned) }
            noteIntroductoryOffer(on: owned)
            pendingApprovals.remove(owned.id)
        case let .withdrawn(id):
            // Stop vouching for it at once. A refund that overtakes the listing is
            // otherwise ignored until the next launch.
            unlisted.drop(id)
        case .subscriptionChanged:
            // Read again: the status is asked for with the listing, and decides.
            break
        case let .purchaseRequested(request):
            // A request, not a purchase: nothing to read. Kept once, for the app to act on.
            if !requestedPurchases.contains(request) { requestedPurchases.append(request) }
            return
        }
        await resolve()
    }

    public func dismissRequestedPurchase(_ request: RequestedPurchase) {
        requestedPurchases.removeAll { $0 == request }
    }

    /// Believed for `listingGrace` — and a subscription never beyond the end of the period
    /// it bought, so one whose period has ended lapses at the next read without being
    /// believed at all: renewals missed while nothing ran arrive at the next launch, newest
    /// first and the oldest last (measured).
    private func hold(_ owned: OwnedProduct) {
        let until = clock.now.addingTimeInterval(listingGrace.timeInterval)
        unlisted.hold(
            owned, until: min(until, owned.expirationDate ?? .distantFuture),
            alongside: catalogue.entry(for: owned.id)?.nonRenewingTerms != nil)
    }

    // MARK: - Subscriptions

    /// A subscription transaction — held, or listed — as a status would say it: subscribed
    /// until its period ends. What the store stands in with when no status is to be had.
    private func subscription(from owned: OwnedProduct, in group: SubscriptionGroupID) -> HeldSubscription? {
        guard let terms = catalogue.entry(for: owned.id)?.subscriptionTerms, terms.group == group else { return nil }
        return HeldSubscription(
            product: owned.id, group: group, ownership: owned.ownership, state: .subscribed,
            firstSubscribed: owned.originalPurchaseDate, periodStarted: owned.purchaseDate,
            periodEnds: owned.expirationDate ?? .distantFuture, offer: owned.offer)
    }

    /// The held subscriptions a status has caught up with: one for the same product, for a
    /// period that began no earlier. In the iOS simulator a renewal in billing retry arrives
    /// as a transaction of its own (measured); held regardless, it would grant what the
    /// status says is not entitled.
    private func caughtUp(with statuses: [SubscriptionGroupID: [HeldSubscription]]) -> [OwnedProduct] {
        unlisted.held.filter { owned in
            guard let group = catalogue.entry(for: owned.id)?.subscriptionTerms?.group, let said = statuses[group] else { return false }
            return said.contains { $0.product == owned.id && $0.periodStarted >= owned.purchaseDate }
        }
    }

    // MARK: - Completions

    /// - Parameter asked: the product the purchase was for. A subscription purchase that
    ///   comes back with another product of the same group is a change of plan waiting for
    ///   the renewal: StoreKit returns the subscription already held (measured).
    private func completion(for owned: OwnedProduct, asked: ProductID) -> PurchaseCompletion {
        if let terms = catalogue.entry(for: owned.id)?.subscriptionTerms {
            if owned.id != asked, catalogue.entry(for: asked)?.subscriptionTerms?.group == terms.group {
                return .planChangeScheduled(to: asked, at: owned.expirationDate)
            }
            if case let .active(current, _) = standing.subscription(in: terms.group), current.product == owned.id {
                return .subscribed(current)
            }
            return subscription(from: owned, in: terms.group).map(PurchaseCompletion.subscribed) ?? .owned(owned)
        }
        // At its own date, if that is still to come by this device's clock: the store's is not this one.
        if catalogue.entry(for: owned.id)?.nonRenewingTerms != nil,
            case let .active(period) = standing.nonRenewing(owned.id, at: max(clock.now, owned.purchaseDate))
        {
            return .nonRenewing(period)
        }
        guard let terms = catalogue.entry(for: owned.id)?.trialTerms else { return .owned(owned) }
        let period = terms.period(startingAt: owned.originalPurchaseDate)
        return period.isRunning(at: clock.now) ? .trialRunning(period) : .trialUsed(period)
    }
}
