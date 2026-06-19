import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for vitals baseline + acute anomaly detection + fever (#72).
/// Controlled inputs with a known baseline/severity — never real health values.
final class VitalsBaselineTests: XCTestCase {

    // MARK: Baseline window

    func testBaselineNeedsMinimumHistory() {
        // 6 days < default minBaselineDays (7) → no baseline.
        XCTAssertNil(VitalsBaseline.stats(Array(repeating: 60.0, count: 6)))
        let s = VitalsBaseline.stats(Array(repeating: 60.0, count: 7))
        XCTAssertNotNil(s)
        XCTAssertEqual(s!.mean, 60, accuracy: 1e-9)
        XCTAssertEqual(s!.sd, 0, accuracy: 1e-9)
        XCTAssertEqual(s!.n, 7)
    }

    func testBaselineTrailingWindowCaps() {
        // 40 prior values but a 30-day max → only the most-recent 30 count.
        let prior = (1...40).map { Double($0) }          // 1…40 oldest→newest
        let s = VitalsBaseline.stats(prior)              // last 30 = 11…40, mean 25.5
        XCTAssertEqual(s!.n, 30)
        XCTAssertEqual(s!.mean, 25.5, accuracy: 1e-9)
    }

    // MARK: Severity thresholds

    func testRestingHRSignificantRise() {
        // baseline mean 60, sd 2 → +10 bpm is 5 sd and past the 5-bpm floor → significant.
        let prior = [58.0, 60, 62, 58, 60, 62, 60]       // mean 60, sd≈1.6
        let c = VitalsBaseline.classify(today: 75, prior: prior, vital: .restingHR)
        XCTAssertEqual(c.severity, .significant)
        XCTAssertEqual(c.direction, .rise)
    }

    func testRestingHRMinorRise() {
        // Wider baseline so a moderate rise lands in the minor (1.5–2.5 sd) band.
        let prior = [50.0, 55, 60, 65, 70, 55, 60]       // mean 59.3, sd≈6.3
        let c = VitalsBaseline.classify(today: 71, prior: prior, vital: .restingHR)
        XCTAssertEqual(c.severity, .minor)
    }

    func testRestingHRLowIsNotConcerning() {
        // A LOWER resting HR is healthy — never flagged (concern is .high only).
        let prior = [58.0, 60, 62, 58, 60, 62, 60]
        let c = VitalsBaseline.classify(today: 45, prior: prior, vital: .restingHR)
        XCTAssertEqual(c.severity, .normal)
        XCTAssertEqual(c.direction, .drop)
    }

    func testAbsoluteFloorSuppressesTinyDeviation() {
        // Very tight baseline (sd≈0): a 2-bpm change is huge in z but below the 5-bpm floor → normal.
        let prior = Array(repeating: 60.0, count: 7)
        let c = VitalsBaseline.classify(today: 62, prior: prior, vital: .restingHR)
        XCTAssertEqual(c.severity, .normal)
        // But a change past the floor with zero sd is treated as significant.
        let big = VitalsBaseline.classify(today: 70, prior: prior, vital: .restingHR)
        XCTAssertEqual(big.severity, .significant)
    }

    func testSpO2DropConcerning() {
        let prior = [98.0, 97, 98, 99, 97, 98, 98]       // mean ≈97.9, sd≈0.6
        let c = VitalsBaseline.classify(today: 92, prior: prior, vital: .overnightSpO2)
        XCTAssertEqual(c.severity, .significant)
        XCTAssertEqual(c.direction, .drop)
        // A higher SpO2 is never an anomaly.
        XCTAssertEqual(VitalsBaseline.classify(today: 100, prior: prior, vital: .overnightSpO2).severity, .normal)
    }

    func testHRVDropConcerning() {
        let prior = [60.0, 65, 55, 60, 62, 58, 60]       // mean 60, sd≈3
        let c = VitalsBaseline.classify(today: 40, prior: prior, vital: .overnightHRV)
        XCTAssertEqual(c.severity, .significant)
        XCTAssertEqual(c.direction, .drop)
        XCTAssertEqual(VitalsBaseline.classify(today: 90, prior: prior, vital: .overnightHRV).severity, .normal)
    }

    func testTempSeverityBands() {
        XCTAssertEqual(VitalsBaseline.tempSeverity(offsetC: 0.3), .normal)
        XCTAssertEqual(VitalsBaseline.tempSeverity(offsetC: 0.7), .minor)
        XCTAssertEqual(VitalsBaseline.tempSeverity(offsetC: 1.4), .significant)
        XCTAssertEqual(VitalsBaseline.tempSeverity(offsetC: -1.4), .significant, "a sharp drop is also significant")
    }

    // MARK: Fever (HR + temp cross-reference)

    func testFeverNeedsBothSignals() {
        let hrPrior = Array(repeating: 60.0, count: 7)
        // Temp up but HR normal → no fever.
        XCTAssertFalse(VitalsBaseline.suspectedFever(restingHRToday: 60, restingHRPrior: hrPrior, skinTempOffsetC: 1.2))
        // HR up but temp normal → no fever.
        XCTAssertFalse(VitalsBaseline.suspectedFever(restingHRToday: 75, restingHRPrior: hrPrior, skinTempOffsetC: 0.3))
        // BOTH up → fever.
        XCTAssertTrue(VitalsBaseline.suspectedFever(restingHRToday: 75, restingHRPrior: hrPrior, skinTempOffsetC: 1.2))
    }

    func testFeverRequiresInputs() {
        XCTAssertFalse(VitalsBaseline.suspectedFever(restingHRToday: nil, restingHRPrior: [], skinTempOffsetC: 1.2))
        XCTAssertFalse(VitalsBaseline.suspectedFever(restingHRToday: 80, restingHRPrior: [], skinTempOffsetC: nil))
        // Too little HR history → can't establish a personal baseline → no false fever.
        XCTAssertFalse(VitalsBaseline.suspectedFever(restingHRToday: 90,
                                                     restingHRPrior: [60, 60, 60],
                                                     skinTempOffsetC: 1.5))
    }

    // MARK: Vitals Status report

    func testStatusNormal() {
        let inputs = [
            VitalsBaseline.VitalInput(vital: .restingHR, today: 60, prior: Array(repeating: 60.0, count: 7)),
            VitalsBaseline.VitalInput(vital: .overnightSpO2, today: 98, prior: Array(repeating: 98.0, count: 7)),
        ]
        let r = VitalsBaseline.report(inputs, skinTempOffsetC: 0.2)
        XCTAssertEqual(r.status, .normal)
        XCTAssertTrue(r.signals.isEmpty)
        XCTAssertFalse(r.feverSuspected)
    }

    func testStatusWatchOnMinor() {
        let prior = [50.0, 55, 60, 65, 70, 55, 60]
        let inputs = [VitalsBaseline.VitalInput(vital: .restingHR, today: 71, prior: prior)]
        let r = VitalsBaseline.report(inputs)
        XCTAssertEqual(r.status, .watch)
        XCTAssertEqual(r.signals.count, 1)
        XCTAssertEqual(r.signals.first?.severity, .minor)
    }

    func testStatusAnomalyOnFever() {
        // HR + temp both elevated → fever → anomaly, even though HR alone might only be minor.
        let inputs = [VitalsBaseline.VitalInput(vital: .restingHR, today: 75,
                                                prior: Array(repeating: 60.0, count: 7))]
        let r = VitalsBaseline.report(inputs, skinTempOffsetC: 1.3)
        XCTAssertEqual(r.status, .anomaly)
        XCTAssertTrue(r.feverSuspected)
    }

    func testStatusAnomalyOnSignificant() {
        let inputs = [VitalsBaseline.VitalInput(vital: .overnightSpO2, today: 91,
                                                prior: [98, 97, 98, 99, 97, 98, 98])]
        let r = VitalsBaseline.report(inputs)
        XCTAssertEqual(r.status, .anomaly)
    }
}
