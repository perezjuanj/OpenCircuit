import XCTest
@testable import OpenCircuitKit

/// The wire names `sleepSessions[].edgeProvenance` and the diagnostics bundle emit.
///
/// These are the only part of the parked coverage-card work that ships now, and they are the part a
/// future analysis keys on, so they are pinned by value rather than round-tripped: a round-trip test
/// stays green through a rename and every bundle already collected does not.
final class SleepConfidenceExportNamesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_787_013_422)   // 2026-08-18 02:37:02 +02:00

    /// A rename here silently invalidates every tester bundle already collected — the reader is a
    /// script, so nothing fails to compile on the other side.
    func testExportNamesArePinned() {
        XCTAssertEqual(SleepConfidence.exportName(SleepConfidence.Reason.durationLikelyHigh),
                       "durationLikelyHigh")
        XCTAssertEqual(SleepConfidence.exportName(
            SleepConfidence.Reason.noRecordingAfterWake(from: t0, silentFor: 1)),
                       "noRecordingAfterWake")
        XCTAssertEqual(SleepConfidence.exportName(
            SleepConfidence.Reason.noRecordingBeforeBedtime(until: t0, silentFor: 1)),
                       "noRecordingBeforeBedtime")
        XCTAssertEqual(SleepConfidence.exportName(BedtimeProvenance.Verdict.witnessed), "witnessed")
        XCTAssertEqual(SleepConfidence.exportName(BedtimeProvenance.Verdict.resumedAfterGap(1)),
                       "resumedAfterGap")
        XCTAssertEqual(SleepConfidence.exportName(BedtimeProvenance.Verdict.noPriorMeasurement),
                       "noPriorMeasurement")
        XCTAssertEqual(SleepConfidence.exportName(BedtimeProvenance.Verdict.unknown), "unknown")
        XCTAssertEqual(SleepConfidence.exportName(WakeProvenance.Verdict.witnessed), "witnessed")
        XCTAssertEqual(SleepConfidence.exportName(WakeProvenance.Verdict.stoppedThenResumed(1)),
                       "stoppedThenResumed")
        XCTAssertEqual(SleepConfidence.exportName(WakeProvenance.Verdict.unknown), "unknown")
    }

    /// A verdict that measured NO silence must report nil, not 0 — 0 would claim a continuous
    /// stream, which is precisely what `.unknown` cannot claim.
    func testGapSecondsIsNilRatherThanZeroWhenNothingWasMeasured() {
        XCTAssertNil(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.witnessed))
        XCTAssertNil(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.unknown))
        XCTAssertNil(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.noPriorMeasurement))
        XCTAssertNil(SleepConfidence.gapSeconds(WakeProvenance.Verdict.witnessed))
        XCTAssertNil(SleepConfidence.gapSeconds(WakeProvenance.Verdict.unknown))
        XCTAssertEqual(SleepConfidence.gapSeconds(WakeProvenance.Verdict.stoppedThenResumed(42)), 42)
        XCTAssertEqual(SleepConfidence.gapSeconds(BedtimeProvenance.Verdict.resumedAfterGap(42)), 42)
    }
}
