import XCTest
@testable import OpenCircuitKit

// The Today brief: the facts the on-device model phrases for the Today line, and its vet. Synthetic.
// The vet rules each come from a live run against the on-device model (see TodayBrief.swift).

final class TodayBriefTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ readiness: TodaySynthesis.Readiness = .scored(score: 82, tier: .good, factorCount: 3),
                       hrv: BaselineTrend.Direction? = .above, rhr: BaselineTrend.Direction? = .within,
                       temp: BaselineTrend.Direction? = nil, fever: Bool = false,
                       last: Int? = 400, usual: Double? = 440, ageHours: Double = 2) -> TodaySynthesis.Input {
        TodaySynthesis.Input(readiness: readiness, hrv: hrv, restingHR: rhr, skinTemp: temp,
                             feverSuspected: fever, lastNightSleepMinutes: last, usualSleepMinutes: usual,
                             newestDataAt: now.addingTimeInterval(-ageHours * 3600), now: now)
    }

    private func facts(_ i: TodaySynthesis.Input) throws -> SleepRecap.Facts {
        try XCTUnwrap(TodaySynthesis.briefFacts(i))
    }

    func testFactsSplitIntoMustAndMay() throws {
        let f = try facts(input())
        XCTAssertEqual(f.lines, ["Readiness today is good, at 82 out of 100."])
        XCTAssertEqual(f.required, [["82"]])
        XCTAssertTrue(f.optionalLines.contains("Last night you slept 6 h 40 m, 40 m less than your recent average of 7 h 20 m."))
        XCTAssertTrue(f.optionalLines.contains("HRV is above your usual."))
        XCTAssertTrue(f.optionalLines.contains("Resting heart rate is within your usual range."))
        XCTAssertTrue(f.prompt.hasPrefix("Facts about today:\nMust mention:\n- Readiness today is good"))
        XCTAssertTrue(f.prompt.contains("\nMay mention:\n"))
        XCTAssertTrue(f.allowedNumbers.isSuperset(of: [82, 100, 6, 40, 7, 20]))
    }

    func testTierWordingIsGrammatical() throws {
        let f = try facts(input(.scored(score: 52, tier: .needsImprovement, factorCount: 3)))
        XCTAssertEqual(f.lines.first, "Readiness today needs improvement, at 52 out of 100.")
    }

    func testMissingDataStatesKeepTheTemplate() {
        XCTAssertNil(TodaySynthesis.briefFacts(input(.pending)))
        XCTAssertNil(TodaySynthesis.briefFacts(input(ageHours: 40)), "stale data: the template says sync")
        var none = input(); none.newestDataAt = nil
        XCTAssertNil(TodaySynthesis.briefFacts(none))
    }

    func testFeverPairAndSuggestionsAreMustMention() throws {
        let fever = try facts(input(fever: true))
        XCTAssertTrue(fever.lines.contains("Skin temperature and resting heart rate are both above your usual."))
        XCTAssertTrue(fever.lines.contains("Taking today gently may help."))
        XCTAssertTrue(fever.required.contains(["skin temperature"]))
        XCTAssertFalse((fever.lines + fever.optionalLines).joined().lowercased().contains("fever"))
        let low = try facts(input(.scored(score: 52, tier: .needsImprovement, factorCount: 3)))
        XCTAssertTrue(low.lines.contains("An easier day may help."))
        XCTAssertFalse(try facts(input()).lines.contains { $0.hasSuffix("may help.") })
    }

    func testShortNightAndFirstConcernAreMustMention() throws {
        let short = try facts(input(.scored(score: 70, tier: .good, factorCount: 1), last: 330))
        XCTAssertTrue(short.lines.contains("Last night's sleep was short."))
        XCTAssertTrue(short.optionalLines.contains("Readiness is based on last night's sleep alone."))
        let concern = try facts(input(hrv: .below, rhr: .above, last: 430))
        XCTAssertTrue(concern.lines.contains("HRV is below your usual."))
        XCTAssertTrue(concern.optionalLines.contains("Resting heart rate is above your usual."))
    }

    /// No score, no brief: the live model invented a resting heart rate to fill the gap.
    func testNoNightOrNoScoreKeepsTheTemplate() {
        XCTAssertNil(TodaySynthesis.briefFacts(input(.noNight, last: nil)))
        XCTAssertNil(TodaySynthesis.briefFacts(input(.noScore)))
    }

    // MARK: vet

    func testVetAcceptsAFaithfulBrief() throws {
        let reply = "Your readiness today is 82 out of 100, and your HRV is above your usual."
        XCTAssertEqual(TodaySynthesis.vetBrief(reply, facts: try facts(input())), .success(reply))
    }

    func testVetRejectsAMissingMustMention() throws {
        XCTAssertEqual(TodaySynthesis.vetBrief("Your readiness is 82 out of 100. Taking today gently may help.",
                                               facts: try facts(input(fever: true))),
                       .failure(.missing("skin temperature")))
    }

    func testVetRejectsAdviceTheFactsDidNotGive() throws {
        let f = try facts(input())
        XCTAssertEqual(TodaySynthesis.vetBrief("Your readiness is 82, but consider an early night.", facts: f),
                       .failure(.unrequestedAdvice("consider")))
        XCTAssertEqual(TodaySynthesis.vetBrief("Your readiness is 82, so take it slow.", facts: f),
                       .failure(.unrequestedAdvice("take it")))
    }

    func testVetAllowsTheSuggestionTheFactsCarry() throws {
        let reply = "Your readiness is 52 out of 100, so an easier day may help."
        XCTAssertEqual(TodaySynthesis.vetBrief(reply, facts: try facts(input(.scored(score: 52, tier: .needsImprovement, factorCount: 3)))),
                       .success(reply))
    }

    func testVetRejectsListsGreetingsAndFeelings() throws {
        let f = try facts(input())
        XCTAssertEqual(TodaySynthesis.vetBrief("Readiness: 82 out of 100.", facts: f), .failure(.listLike))
        XCTAssertEqual(TodaySynthesis.vetBrief("Hello, your readiness is 82 today.", facts: f), .failure(.greeting))
        XCTAssertEqual(TodaySynthesis.vetBrief("Your readiness is 82, so you are well rested.", facts: f),
                       .failure(.claimsFeeling("rested")))
        XCTAssertEqual(TodaySynthesis.vetBrief("You are doing well, with readiness at 82.", facts: f),
                       .failure(.claimsFeeling("doing well")))
    }

    func testVetKeepsTheRecapRules() throws {
        let f = try facts(input())
        XCTAssertEqual(TodaySynthesis.vetBrief("Your readiness is 82 and your resting heart rate is 62.", facts: f),
                       .failure(.inventedNumber("62")))
        XCTAssertEqual(TodaySynthesis.vetBrief("Your readiness is 82; no sign of illness.", facts: f),
                       .failure(.medicalWording("illness")))
        XCTAssertEqual(TodaySynthesis.vetBrief(String(repeating: "Readiness is good. ", count: 13), facts: f),
                       .failure(.tooLong))
    }

    func testInstructionsMatchTheVet() {
        let i = TodaySynthesis.briefInstructions
        XCTAssertTrue(i.contains("Copy every number exactly"))
        XCTAssertTrue(i.contains("Otherwise give no advice"))
        XCTAssertTrue(i.contains("Do not greet the person"))
        XCTAssertTrue(i.contains("do not use colons"))
        XCTAssertTrue(i.contains("do not diagnose"))
    }
}
