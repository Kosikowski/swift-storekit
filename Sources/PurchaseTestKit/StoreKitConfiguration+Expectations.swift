//
//  StoreKitConfiguration+Expectations.swift
//  PurchaseTestKit
//
//  The file-against-catalogue check, said the way a test says things: one failure
//  per problem, each a sentence, each at the line that asked.
//
//  `#expect(file.problems(against: catalogue) == [])` works, and fails with an array
//  of enum cases printed on one line — four problems in one paragraph, none of them
//  saying what to do. This records each as an issue of its own, in the words that
//  say what to fix.
//
//  It is also why an app cannot link this module. Swift Testing is on the search
//  path of a test target and of nothing else, so a module that calls into it does
//  not link into an app: Xcode stops the build — Debug and Release alike — with
//  "Undefined symbols … referenced from PurchaseTestKit.o", whether or not the app
//  uses anything in it. **[ran]** (docs/10-decisions.md, D34.) A use, and not a
//  trick: a test kit whose checks report through the test framework. And it turns
//  "no app links the test kit" from a rule somebody has to remember into a build
//  that fails.
//

public import PurchaseCore
public import Testing

extension StoreKitConfiguration {
    /// Records an issue for each way this file disagrees with `catalogue`, at the
    /// caller's line, and nothing when they agree.
    ///
    ///     let file = try StoreKitConfiguration(contentsOf: url)
    ///     file.expectNoProblems(against: Shop.catalogue)
    ///
    /// The default location is Swift Testing's own, as on `Issue.record`, so that a
    /// helper of your own can pass on where *it* was called.
    ///
    /// `offers` are the promotional and win-back offers the app names in its own code, by
    /// the product they are for.
    public func expectNoProblems(
        against catalogue: Catalogue,
        offers: [ProductID: Set<OfferID>] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for problem in problems(against: catalogue, offers: offers) {
            Issue.record(Comment(rawValue: problem.description), sourceLocation: sourceLocation)
        }
    }
}
