import Foundation
import PurchaseCore
import Testing

/// One conversion, shared by the store's grace, a trial's end, the simulated store's
/// ages and the manual clock, so that all four agree about the same fortnight.
@Suite("Duration as seconds")
struct DurationTests {
    @Test("whole and fractional seconds both survive", arguments: [
        (Duration.zero, 0.0),
        (.seconds(14 * 86_400), 1_209_600.0),
        (.milliseconds(1_500), 1.5),
        (.seconds(-300), -300.0),
    ])
    func seconds(duration: Duration, expected: TimeInterval) {
        #expect(duration.timeInterval == expected)
    }

    @Test("a trial's end is its start moved by exactly its duration")
    func trialEnd() {
        let terms = TrialTerms(duration: .milliseconds(333), targets: [Shop.pro])
        #expect(terms.period(startingAt: Shop.epoch).endsAt == Shop.epoch.addingTimeInterval(0.333))
    }
}
