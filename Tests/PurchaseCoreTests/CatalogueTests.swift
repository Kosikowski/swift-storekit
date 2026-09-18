import PurchaseCore
import Testing

@Suite("Catalogue")
struct CatalogueTests {
    @Test("a sound catalogue has no problems and knows its identifiers")
    func sound() {
        #expect(Catalogue.problems(in: Shop.catalogue.entries).isEmpty)
        #expect(Shop.catalogue.identifiers == [Shop.pro, Shop.trial])
        #expect(Shop.catalogue.trials(of: Shop.pro).map(\.id) == [Shop.trial])
    }

    @Test("the same identifier twice is a problem")
    func duplicate() {
        let problems = Catalogue.problems(in: [.unlock("a"), .unlock("a")])
        #expect(problems == [.duplicateIdentifier("a")])
    }

    @Test("a trial of something the catalogue does not sell is a problem")
    func missingTarget() {
        let problems = Catalogue.problems(in: [.trial("t", of: ["nowhere"], lasting: .seconds(1))])
        #expect(problems == [.trialTargetMissing(trial: "t", target: "nowhere")])
    }

    @Test("a trial of a trial is a problem, and so is a trial of nothing")
    func trialOfTrial() {
        let problems = Catalogue.problems(in: [
            .unlock("a"),
            .trial("t1", of: ["a"], lasting: .seconds(1)),
            .trial("t2", of: ["t1"], lasting: .seconds(1)),
            .trial("t3", of: [], lasting: .seconds(1)),
        ])
        #expect(problems == [
            .trialTargetIsNotAnUnlock(trial: "t2", target: "t1"),
            .trialWithoutTargets("t3"),
        ])
    }
}
