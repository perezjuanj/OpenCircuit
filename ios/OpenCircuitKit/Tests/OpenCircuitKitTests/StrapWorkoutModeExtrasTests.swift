import XCTest
@testable import OpenCircuitKit

// What the strap's workout mode adds to a strap workout (#359, decision 89e, 89h): the metadata keys
// and values, reading them back (missing = phone-side), the journal carrying them through a kill, and
// the below-Zone-1 note narrowed to workouts that ran without the mode. Every value is synthetic.
final class StrapWorkoutModeExtrasTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let zones = HeartRateZones(percentOfMax: 180)   // Zone 1 starts at 90 bpm

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func readings(_ to: TimeInterval, bpm: Int) -> [HRSample] {
        stride(from: 1, through: to, by: 1).map { HRSample(bpm: bpm, start: at($0 - 1), end: at($0)) }
    }

    // MARK: Metadata (89e, 89h)

    func testTheKeysAreNamedOnce() {
        XCTAssertEqual(StrapWorkoutMetadata.swingCountKey, "OCStrapSwingCount")
        XCTAssertEqual(StrapWorkoutMetadata.activeEnergyKey, "OCStrapActiveEnergyKcal")
        XCTAssertEqual(StrapWorkoutMetadata.workoutModeKey, "OCStrapWorkoutMode")
    }

    func testARacketSportStoresTheFlagTheSwingsAndTheStrapsKcal() {
        let extras = StrapWorkoutModeExtras(ranWithWorkoutMode: true, swings: 420, strapKilocalories: 310)
        XCTAssertEqual(StrapWorkoutMetadata.metadata(extras),
                       ["OCStrapWorkoutMode": 1, "OCStrapSwingCount": 420, "OCStrapActiveEnergyKcal": 310])
        XCTAssertEqual(StrapWorkoutMetadata.extras(from: StrapWorkoutMetadata.metadata(extras)), extras)
    }

    func testANonRacketSportStoresNoSwings() {
        let extras = StrapWorkoutModeExtras(ranWithWorkoutMode: true, swings: nil, strapKilocalories: 200)
        XCTAssertEqual(StrapWorkoutMetadata.metadata(extras), ["OCStrapWorkoutMode": 1, "OCStrapActiveEnergyKcal": 200])
    }

    func testAPhoneSideWorkoutStoresOnlyTheFlag() {
        XCTAssertEqual(StrapWorkoutMetadata.metadata(StrapWorkoutModeExtras()), ["OCStrapWorkoutMode": 0])
    }

    func testAMissingFlagReadsAsPhoneSide() {
        XCTAssertFalse(StrapWorkoutMetadata.extras(from: nil).ranWithWorkoutMode)
        XCTAssertFalse(StrapWorkoutMetadata.extras(from: ["HKOther": 1]).ranWithWorkoutMode)
        XCTAssertFalse(StrapWorkoutMetadata.extras(from: ["OCStrapWorkoutMode": 0]).ranWithWorkoutMode)
        XCTAssertFalse(StrapWorkoutMetadata.extras(from: ["OCStrapWorkoutMode": "1"]).ranWithWorkoutMode, "unreadable = phone-side")
        let stored = StrapWorkoutMetadata.extras(from: ["OCStrapWorkoutMode": NSNumber(value: 1),
                                                        "OCStrapSwingCount": NSNumber(value: 12.0)])
        XCTAssertTrue(stored.ranWithWorkoutMode)
        XCTAssertEqual(stored.swings, 12)
        XCTAssertNil(StrapWorkoutMetadata.extras(from: ["OCStrapSwingCount": -3]).swings)
    }

    // MARK: Journal (a kill keeps them)

    func testTheJournalCarriesTheExtrasIntoARecoveredWorkout() throws {
        let extras = StrapWorkoutModeExtras(ranWithWorkoutMode: true, swings: 80, strapKilocalories: 40)
        let journal = StrapWorkoutJournal(sport: .tennis, ledger: WorkoutActivityLedger(start: t0), lastAliveAt: at(600),
                                          timelineRaw: "zeppos:STRAP", workoutMode: extras)
        let decoded = try XCTUnwrap(StrapWorkoutJournal.decoded(from: journal.encoded()))
        XCTAssertEqual(decoded.workoutMode, extras)
        guard case .offer(let recovered) = StrapWorkoutRecovery.decide(journal: decoded, samples: readings(600, bpm: 120),
                                                                      now: at(700)) else { return XCTFail() }
        XCTAssertEqual(recovered.workoutMode, extras)
        XCTAssertEqual(recovered.sport, .tennis)
    }

    func testAJournalFromBeforeTheModeDecodesWithoutIt() throws {
        let old = #"{"sport":"other","ledger":{"start":0,"pauses":[],"gaps":[]},"lastAliveAt":600,"timelineRaw":"zeppos:STRAP"}"#
        let journal = try XCTUnwrap(StrapWorkoutJournal.decoded(from: Data(old.utf8)))
        XCTAssertNil(journal.workoutMode)
    }

    // MARK: The below-Zone-1 note (89h)

    func testTheNoteIsOnlyForAWorkoutThatRanWithoutTheMode() {
        let low = readings(1800, bpm: 80)
        XCTAssertTrue(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, ranWithWorkoutMode: false, sport: .tennis,
                                                           activeSeconds: 1800, activeReadings: low, zones: zones))
        XCTAssertFalse(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, ranWithWorkoutMode: true, sport: .tennis,
                                                            activeSeconds: 1800, activeReadings: low, zones: zones))
        var ledger = WorkoutActivityLedger(start: t0)
        ledger.pause(at: at(1800))
        XCTAssertFalse(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, ranWithWorkoutMode: true, sport: .other,
                                                            ledger: ledger, samples: low, end: at(1900), zones: zones))
        XCTAssertTrue(StrapWorkoutLowHeartRateNote.applies(isStrapWorkout: true, sport: .other,
                                                           ledger: ledger, samples: low, end: at(1900), zones: zones),
                      "no flag given = phone-side")
    }
}
