import XCTest
@testable import OpenCircuitKit

// On-device sleep recap: the facts the model is handed, and the vet its reply must pass. Every fixture
// is synthetic.

final class SleepRecapTests: XCTestCase {

    private func night(asleep: Int, deep: Int = 60, rem: Int = 90, score: Int = 80,
                       edited: Bool = false) -> SleepRecap.Night {
        SleepRecap.Night(asleepMin: asleep, inBedMin: asleep + 25, deepMin: deep,
                         lightMin: max(0, asleep - deep - rem), remMin: rem, awakeMin: 25,
                         efficiency: Double(asleep) / Double(asleep + 25), score: score,
                         isManuallyEdited: edited)
    }

    func testFactsCarryEveryNumberPrecomputed() throws {
        let tonight = night(asleep: 400, deep: 50, rem: 80, score: 72)
        let prior = (0..<7).map { _ in night(asleep: 430, deep: 70, rem: 95, score: 81) }
        let facts = try XCTUnwrap(SleepRecap.facts(for: tonight, prior: prior))
        let text = facts.lines.joined(separator: "\n")

        XCTAssertTrue(text.contains("Time asleep: 6 h 40 m."))
        XCTAssertTrue(text.contains("Time in bed: 7 h 5 m."))
        XCTAssertTrue(text.contains("Sleep efficiency: 94%."))
        XCTAssertTrue(text.contains("Sleep score: 72 out of 100."))
        // Differences are worked out here, never by the model.
        XCTAssertTrue(text.contains("Time asleep was 30 m less than your average of 7 h 10 m over the previous 7 nights."))
        XCTAssertTrue(text.contains("Deep sleep was 20 m less than your average of 1 h 10 m"))
        XCTAssertTrue(text.contains("REM sleep was 15 m less than"))
        XCTAssertTrue(text.contains("The score was 9 points lower than your average score of 81"))
        XCTAssertTrue(facts.allowedNumbers.isSuperset(of: [6, 40, 30, 7, 10, 72, 81, 9, 100]))
        XCTAssertTrue(facts.prompt.hasPrefix("Facts about last night:\n- Time asleep"))
    }

    func testFactsNeverCarryClockTimes() throws {
        // The card shows bedtime and wake already, and the live model rewrote "11:26 PM" as "23:26".
        let facts = try XCTUnwrap(SleepRecap.facts(for: night(asleep: 400),
                                                   prior: (0..<3).map { _ in night(asleep: 430) }))
        XCTAssertFalse(facts.prompt.contains("AM") || facts.prompt.contains("PM"), "no clock time may reach the model")
        XCTAssertFalse(facts.prompt.contains("asleep at"))
    }

    func testSmallDifferencesReadAsAboutTheSame() throws {
        let facts = try XCTUnwrap(SleepRecap.facts(for: night(asleep: 425, score: 80),
                                                   prior: (0..<5).map { _ in night(asleep: 430, score: 82) }))
        let text = facts.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Time asleep was about the same as your average of 7 h 10 m over the previous 5 nights."))
        XCTAssertTrue(text.contains("The score was about the same as your average score of 82"))
    }

    /// No history, no recap: given a night with nothing to compare, the live model invented a comparison.
    func testNoRecapWithoutEnoughEarlierNights() {
        let prior = [night(asleep: 430), night(asleep: 0), night(asleep: 440)]
        XCTAssertNil(SleepRecap.facts(for: night(asleep: 400), prior: prior))
        XCTAssertNil(SleepRecap.facts(for: night(asleep: 400), prior: []))
        XCTAssertNotNil(SleepRecap.facts(for: night(asleep: 400), prior: prior + [night(asleep: 410)]))
        XCTAssertNil(SleepRecap.facts(for: night(asleep: 0), prior: (0..<7).map { _ in night(asleep: 430) }))
    }

    func testBaselineUsesAtMostSevenNights() throws {
        let prior = (0..<7).map { _ in night(asleep: 420) } + (0..<10).map { _ in night(asleep: 60) }
        let text = try XCTUnwrap(SleepRecap.facts(for: night(asleep: 420), prior: prior)).lines.joined()
        XCTAssertTrue(text.contains("about the same as your average of 7 h over the previous 7 nights"))
    }

    func testEditedNightIsSaid() throws {
        let text = try XCTUnwrap(SleepRecap.facts(for: night(asleep: 400, edited: true),
                                                  prior: (0..<3).map { _ in night(asleep: 430) })).lines.joined()
        XCTAssertTrue(text.contains("edited this night's times by hand"))
    }

    // MARK: vet

    private var facts: SleepRecap.Facts {
        SleepRecap.facts(for: night(asleep: 400, deep: 50, rem: 80, score: 72),
                         prior: (0..<7).map { _ in night(asleep: 430, deep: 70, rem: 95, score: 81) })!
    }

    func testVetAcceptsAReplyThatOnlyCopiesNumbers() {
        let reply = "  You slept 6 h 40 m, 30 m less than your 7-night average. Deep sleep ran a bit short, and your score of 72 sits 9 points under usual.  "
        XCTAssertEqual(SleepRecap.vet(reply, facts: facts),
                       .success("You slept 6 h 40 m, 30 m less than your 7-night average. Deep sleep ran a bit short, and your score of 72 sits 9 points under usual."))
    }

    func testVetRejectsAnInventedNumber() {
        XCTAssertEqual(SleepRecap.vet("Your resting heart rate was 54 bpm.", facts: facts),
                       .failure(.inventedNumber("54")))
        // Rounded or recomputed numbers are invented too.
        XCTAssertEqual(SleepRecap.vet("You slept about 6.2 hours.", facts: facts),
                       .failure(.inventedNumber("2")))
    }

    func testVetRejectsSpelledOutNumbersNotInTheFacts() {
        XCTAssertEqual(SleepRecap.vet("You woke up three times.", facts: facts),
                       .failure(.inventedNumber("three")))
        // The live run's catch: a 6 h 40 m night told as "six hours, nineteen minutes".
        XCTAssertEqual(SleepRecap.vet("You slept six hours, nineteen minutes.", facts: facts),
                       .failure(.inventedNumber("nineteen")))
        // A spelled-out number the facts DO contain is fine.
        XCTAssertEqual(SleepRecap.vet("Compared with the last seven nights, it was shorter.", facts: facts),
                       .success("Compared with the last seven nights, it was shorter."))
    }

    func testVetRejectsMedicalWording() {
        XCTAssertEqual(SleepRecap.vet("This could be a sign of sleep apnea.", facts: facts),
                       .failure(.medicalWording("apnea")))
        XCTAssertEqual(SleepRecap.vet("Consider seeing a doctor.", facts: facts),
                       .failure(.medicalWording("doctor")))
        XCTAssertEqual(SleepRecap.vet("No sign of insomnia here.", facts: facts),
                       .failure(.medicalWording("insomnia")))
        XCTAssertEqual(SleepRecap.vet("You may be getting sick.", facts: facts),
                       .failure(.medicalWording("sick")))
    }

    func testVetDoesNotTripOnOrdinarySleepWords() {
        let reply = "You were homesick for your pillow, but the night was steady."
        XCTAssertEqual(SleepRecap.vet(reply, facts: facts), .success(reply))
    }

    func testVetRejectsEmptyAndLongReplies() {
        XCTAssertEqual(SleepRecap.vet("   \n ", facts: facts), .failure(.empty))
        XCTAssertEqual(SleepRecap.vet(String(repeating: "Good night. ", count: 40), facts: facts),
                       .failure(.tooLong))
    }

    func testInstructionsForbidWhatTheVetEnforces() {
        let i = SleepRecap.instructions
        XCTAssertTrue(i.contains("Copy every number exactly"))
        XCTAssertTrue(i.contains("do not write numbers as words"))
        XCTAssertTrue(i.contains("do not diagnose"))
        XCTAssertTrue(i.contains("Use only the facts"))
        XCTAssertTrue(i.contains("start with that comparison"))
    }
}
