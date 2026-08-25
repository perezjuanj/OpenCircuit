// THE GATE AND THE EXACT SENTENCE for the edited-night notice.
//
// Two things are pinned here and nothing else: WHEN the line appears, and WHAT IT SAYS to the
// character. The copy is pinned verbatim because it is the one place the app tells a wearer which
// part of her night is her own account rather than a measurement.
//
// ⚠️ RE-BASELINED 2026-08-24 — THE HEALTH SENTENCE ONLY. The maintainer reversed build 47's
// withholding: asserted sleep now REACHES Apple Health, tagged `HKMetadataKeyWasUserEntered`. The
// old copy ("Only the measured part reaches Apple Health, so your sleep there reads shorter" /
// "No sleep reaches Apple Health for this night") described a subtraction the app no longer makes,
// so keeping it would have been the same defect pointing the other way. Every other assertion in
// this file — the silence gates, the sentinels, the grammar, the tone, the arithmetic — is
// unchanged, and the two halves of the sentence still quote the same two measured spans.

import XCTest
@testable import OpenCircuitKit

final class SleepEditedNightNoticeTests: XCTestCase {

    private func line(measured: Double, asserted: Double, health: Bool = true) -> String? {
        SleepEditedNightNotice.line(measuredAsleep: measured * 60,
                                    assertedAsleep: asserted * 60,
                                    mirrorsSleepToHealth: health)
    }

    // MARK: - Silence

    func testSilentWhenNothingIsAsserted() {
        XCTAssertNil(line(measured: 403, asserted: 0),
                     "a fully measured night must read exactly as it does today")
    }

    func testSilentBelowOneWholeAssertedMinute() {
        XCTAssertNil(line(measured: 400, asserted: 0.9),
                     "a sub-minute rounding artifact is not worth a caption")
        XCTAssertNotNil(line(measured: 400, asserted: 1.0), "one whole minute is the floor, inclusive")
    }

    func testSilentWhenOnlyAWAKETimeIsAsserted() {
        // 🟢 The real corpus night this pins is `R1_2026-08-16`: 0.0 asserted asleep, 120.3 asserted
        // awake. Those awake segments are published like everything else (tagged user-entered), so
        // Health and the card agree on Time in Bed, Time Asleep AND awake. Declared scope limit, not
        // an oversight: see the type's doc comment.
        XCTAssertNil(line(measured: 237, asserted: 0),
                     "asserted-awake-only leaves the asleep headline in agreement with Health")
    }

    func testSilentOnTheStoreNotComputedSentinel() {
        // `StoredSleepSummary` writes -1 for "not computed" — a legacy row, or one written before
        // the provenance columns existed. "We did not compute it" is not "the ring measured nothing"
        // and must never be rendered as if it were.
        XCTAssertNil(line(measured: -1, asserted: 241), "measured -1 is the not-computed sentinel")
        XCTAssertNil(line(measured: 162, asserted: -1), "asserted -1 is the not-computed sentinel")
    }

    // MARK: - The sentence

    func testQuotesBothHalvesAndTheHealthConsequence() {
        XCTAssertEqual(
            line(measured: 162, asserted: 241),
            "We kept the times you set. The ring recorded 2h 42m of the sleep above; for the other "
            + "4h 1m we have your account, not a measurement. Both reach Apple Health; your part is "
            + "marked there as entered by you.")
    }

    func testDropsTheHealthSentenceWhenSleepIsNotBeingWrittenThere() {
        // Not reworded — DROPPED. Telling a wearer whose sleep permission is off what Apple Health
        // "gets" is an unearned claim about a surface we are not writing to.
        let text = line(measured: 162, asserted: 241, health: false)
        XCTAssertEqual(
            text,
            "We kept the times you set. The ring recorded 2h 42m of the sleep above; for the other "
            + "4h 1m we have your account, not a measurement.")
        XCTAssertFalse(text?.contains("Apple Health") ?? true)
    }

    func testNothingMeasuredGetsItsOwnSentenceRatherThanZeroMinutes() {
        XCTAssertEqual(
            line(measured: 0, asserted: 246),
            "We kept the times you set. The ring wasn’t recording for any of this night, so all "
            + "4h 6m of the sleep above is your account, not a measurement. It all reaches Apple "
            + "Health, marked there as entered by you.")
        XCTAssertEqual(
            line(measured: 0, asserted: 246, health: false),
            "We kept the times you set. The ring wasn’t recording for any of this night, so all "
            + "4h 6m of the sleep above is your account, not a measurement.")
    }

    func testASubMinuteMeasurementIsQUOTED_notCalledNothing() {
        // 40 measured seconds is not "nothing". `duration` floors at a minute, so the ordinary
        // sentence is honest here and the stronger "wasn't recording for any of this night" — which
        // would be an overstatement — is reserved for a true zero.
        XCTAssertEqual(
            SleepEditedNightNotice.line(measuredAsleep: 40, assertedAsleep: 246 * 60,
                                        mirrorsSleepToHealth: false),
            "We kept the times you set. The ring recorded 1 minute of the sleep above; for the "
            + "other 4h 6m we have your account, not a measurement.")
    }

    func testTheSentenceIsGrammaticalForASUBHOURPluralSpan() {
        // The obvious phrasing — "the other 2 minutes IS your account" — is ungrammatical, and it is
        // reachable: any modest edit into a small hole produces a sub-hour plural. Pin both the
        // plural and the singular so a future reword cannot quietly reintroduce it.
        XCTAssertEqual(
            line(measured: 400, asserted: 2, health: false),
            "We kept the times you set. The ring recorded 6h 40m of the sleep above; for the other "
            + "2 minutes we have your account, not a measurement.")
        XCTAssertEqual(
            line(measured: 400, asserted: 1, health: false),
            "We kept the times you set. The ring recorded 6h 40m of the sleep above; for the other "
            + "1 minute we have your account, not a measurement.")
    }

    func testItCreditsTheCorrectionAndNeverScolds() {
        // The wearer told us something true the ring could not see. Guard the tone against a future
        // reword that turns an acknowledgement into an accusation.
        for text in [line(measured: 162, asserted: 241)!, line(measured: 0, asserted: 246)!] {
            XCTAssertTrue(text.hasPrefix("We kept the times you set."), text)
            XCTAssertTrue(text.contains("your account, not a measurement"), text)
            for banned in ["estimate", "guess", "unverified", "invalid", "incorrect", "cannot be trusted"] {
                XCTAssertFalse(text.lowercased().contains(banned), "‘\(banned)’ in: \(text)")
            }
        }
    }

    // MARK: - Duration rendering

    func testDurationRendersAtEpochPrecisionNeverSeconds() {
        XCTAssertEqual(SleepEditedNightNotice.duration(30), "1 minute")     // never "0 minutes"
        XCTAssertEqual(SleepEditedNightNotice.duration(174), "3 minutes")   // 2.9 min -> 3
        XCTAssertEqual(SleepEditedNightNotice.duration(59 * 60), "59 minutes")
        XCTAssertEqual(SleepEditedNightNotice.duration(60 * 60), "1 hour")
        XCTAssertEqual(SleepEditedNightNotice.duration(120 * 60), "2 hours")
        XCTAssertEqual(SleepEditedNightNotice.duration(241 * 60), "4h 1m")
        XCTAssertEqual(SleepEditedNightNotice.duration(162 * 60), "2h 42m")
    }

    // MARK: - Arithmetic a wearer can check against the headline

    /// The card prints ONE headline; this line prints its two parts, each rounded to the minute
    /// independently. A wearer who adds them must land on the headline — or at worst one minute off,
    /// which is unavoidable at 150 s epoch granularity and is inside the precision the copy claims.
    /// Pinned so that bound is KNOWN rather than accidental: if a reword ever quotes seconds, or
    /// truncates instead of rounding, this drifts past a minute and fails.
    func testTheQuotedSpansReconcileWithTheHeadlineToWithinOneMinute() {
        var worst = 0
        for measured in stride(from: 0.0, through: 8 * 3600, by: 37.0) {
            for asserted in [61.0, 149.0, 150.0, 375.0, 3_600.0, 14_484.0, 14_586.0] {
                let m = Int((measured / 60).rounded())
                let a = Int((asserted / 60).rounded())
                let headline = Int(((measured + asserted) / 60).rounded())
                worst = max(worst, abs(m + a - headline))
            }
        }
        XCTAssertLessThanOrEqual(worst, 1, "the two printed spans drifted from the headline")

        // On both device nights it reconciles EXACTLY, which is what the tester would check.
        // (162 / 241 and 3 / 243 are `SleepProvenanceCardProbe`'s measured split for those nights.)
        XCTAssertEqual(162 + 241, 403, "R2_2026-08-18 headline")
        XCTAssertEqual(3 + 243, 246, "R2_2026-08-17 headline")
    }
}
