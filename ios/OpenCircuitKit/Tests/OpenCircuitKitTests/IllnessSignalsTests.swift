import XCTest
@testable import OpenCircuitKit

/// `IllnessSignals`: the two-of-four overnight check that sits below the fever flag.
///
/// The REAL-NIGHT fixture is per-night aggregates (no raw readings: the repo never commits raw health
/// data) from a Helio Strap export, worn on the wrist, Europe/Madrid, covering a confirmed cold:
///
///     night        in-bed window (local)   HR mean   RMSSD mean   resp. rate   skin temp
///     A 19→20      00:00–07:45 (partial)     65.6       62.4        15.17      –
///     B 20→21      23:20–08:05               65.4       71.8        13.29      34.04 °C
///     C 21→22      00:42–08:01   (cold)      73.3       50.9        13.80      35.15 °C
///
/// On night C the shipped checks raised only the skin-temperature alert: the fever flag needs
/// +8 bpm on the lowest-5-minute resting HR (62.2 vs 56.2 the day before, +6.0).
final class IllnessSignalsTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func night(_ i: Int) -> Date { t0.addingTimeInterval(Double(i) * day) }

    private func vitals(_ i: Int, hr: Double?, hrv: Double?, rr: Double?) -> IllnessSignals.NightVitals {
        IllnessSignals.NightVitals(night: night(i), restingHR: hr, hrv: hrv, respiratoryRate: rr)
    }

    // MARK: Real night

    private var realPrior: [IllnessSignals.NightVitals] {
        [vitals(0, hr: 65.6, hrv: 62.4, rr: 15.17), vitals(1, hr: 65.4, hrv: 71.8, rr: 13.29)]
    }
    private var realCold: IllnessSignals.NightVitals { vitals(2, hr: 73.3, hrv: 50.9, rr: 13.80) }

    /// The export holds only two prior nights, so this test lowers the floor to 2. The app has more
    /// strap history than one export's window; the threshold logic under test is the same.
    func testRealColdNightIsFlaggedOnTempHeartRateAndHRV() {
        var config = IllnessSignals.Config()
        config.minPriorNights = 2
        let a = IllnessSignals.assess(tonight: realCold, prior: realPrior, skinTempOffsetC: 35.15 - 34.04,
                                      config: config)
        XCTAssertTrue(a.isSuspected)
        XCTAssertEqual(a.signals, [.skinTempRise, .restingHRRise, .hrvDrop])
        let hr = try? XCTUnwrap(a.readings.first { $0.signal == .restingHRRise })
        XCTAssertEqual(hr?.delta ?? 0, 7.8, accuracy: 0.01)          // 73.3 − median(65.6, 65.4)
        let hrv = try? XCTUnwrap(a.readings.first { $0.signal == .hrvDrop })
        XCTAssertEqual(hrv?.delta ?? 0, -16.2, accuracy: 0.01)        // 50.9 − median(62.4, 71.8)
        XCTAssertFalse(a.readings.first { $0.signal == .respiratoryRateRise }?.isElevated ?? true)
    }

    /// The same cold night is caught even WITHOUT skin temperature (a ring night the app did not
    /// stay connected through has none): heart rate and HRV alone are two signals.
    func testRealColdNightIsFlaggedWithoutTemperature() {
        var config = IllnessSignals.Config()
        config.minPriorNights = 2
        let a = IllnessSignals.assess(tonight: realCold, prior: realPrior, skinTempOffsetC: nil, config: config)
        XCTAssertTrue(a.isSuspected)
        XCTAssertEqual(a.signals, [.restingHRRise, .hrvDrop])
    }

    /// The wearer's ordinary night B, judged against night A, moves nothing.
    func testRealOrdinaryNightIsQuiet() {
        var config = IllnessSignals.Config()
        config.minPriorNights = 1
        let a = IllnessSignals.assess(tonight: realPrior[1], prior: [realPrior[0]], skinTempOffsetC: nil,
                                      config: config)
        XCTAssertFalse(a.isSuspected)
        XCTAssertEqual(a.signals, [])
    }

    // MARK: Rules

    private var steadyPrior: [IllnessSignals.NightVitals] {
        (0..<5).map { vitals($0, hr: 58, hrv: 60, rr: 14) }
    }

    func testOneSignalAloneIsNotEnough() {
        let hot = IllnessSignals.assess(tonight: vitals(9, hr: 58, hrv: 60, rr: 14), prior: steadyPrior,
                                        skinTempOffsetC: 1.4)
        XCTAssertEqual(hot.signals, [.skinTempRise])
        XCTAssertFalse(hot.isSuspected)

        let fast = IllnessSignals.assess(tonight: vitals(9, hr: 70, hrv: 60, rr: 14), prior: steadyPrior,
                                         skinTempOffsetC: 0.1)
        XCTAssertEqual(fast.signals, [.restingHRRise])
        XCTAssertFalse(fast.isSuspected)
    }

    func testThresholdsAreInclusive() {
        let a = IllnessSignals.assess(tonight: vitals(9, hr: 63, hrv: 48, rr: 15), prior: steadyPrior,
                                      skinTempOffsetC: 0.5)
        XCTAssertEqual(a.signals, [.skinTempRise, .restingHRRise, .hrvDrop, .respiratoryRateRise])
        let below = IllnessSignals.assess(tonight: vitals(9, hr: 62.9, hrv: 48.1, rr: 14.9), prior: steadyPrior,
                                          skinTempOffsetC: 0.49)
        XCTAssertEqual(below.signals, [])
    }

    /// A low-HRV person: 20 % of 30 ms is 6 ms, below the 8 ms floor, so a 7 ms dip is noise.
    func testHRVDropNeedsTheAbsoluteFloorToo() {
        let prior = (0..<5).map { vitals($0, hr: 60, hrv: 30, rr: 14) }
        let small = IllnessSignals.assess(tonight: vitals(9, hr: 60, hrv: 23, rr: 14), prior: prior,
                                          skinTempOffsetC: nil)
        XCTAssertFalse(small.readings.first { $0.signal == .hrvDrop }?.isElevated ?? true)
        let big = IllnessSignals.assess(tonight: vitals(9, hr: 60, hrv: 22, rr: 14), prior: prior,
                                        skinTempOffsetC: nil)
        XCTAssertTrue(big.readings.first { $0.signal == .hrvDrop }?.isElevated ?? false)
    }

    /// Below the 3-night floor a vital has no baseline and contributes nothing, so a brand-new
    /// device can't alert off one or two nights of history.
    func testTooLittleHistoryGivesNoBaseline() {
        let a = IllnessSignals.assess(tonight: realCold, prior: realPrior, skinTempOffsetC: nil)
        XCTAssertTrue(a.readings.isEmpty)
        XCTAssertFalse(a.isSuspected)
    }

    /// The baseline is a median, so one earlier rough night doesn't become "your usual".
    func testMedianBaselineIgnoresOneEarlierOutlier() {
        var prior = steadyPrior
        prior[2] = vitals(2, hr: 80, hrv: 25, rr: 18)
        let a = IllnessSignals.assess(tonight: vitals(9, hr: 64, hrv: 46, rr: 14), prior: prior,
                                      skinTempOffsetC: nil)
        XCTAssertEqual(a.readings.first { $0.signal == .restingHRRise }?.baseline, 58)
        XCTAssertEqual(a.signals, [.restingHRRise, .hrvDrop])
    }

    /// Tonight (or anything after it) passed in `prior` by mistake is ignored, not averaged in.
    func testPriorNightsAtOrAfterTonightAreIgnored() {
        var prior = steadyPrior
        prior.append(vitals(9, hr: 90, hrv: 10, rr: 25))
        prior.append(vitals(10, hr: 90, hrv: 10, rr: 25))
        let a = IllnessSignals.assess(tonight: vitals(9, hr: 64, hrv: 46, rr: 14), prior: prior,
                                      skinTempOffsetC: nil)
        XCTAssertEqual(a.readings.first { $0.signal == .restingHRRise }?.baseline, 58)
    }

    /// Only the trailing `maxPriorNights` count.
    func testBaselineUsesTrailingWindow() {
        var config = IllnessSignals.Config()
        config.maxPriorNights = 3
        let prior = (0..<3).map { vitals($0, hr: 80, hrv: 60, rr: 14) }
            + (3..<6).map { vitals($0, hr: 58, hrv: 60, rr: 14) }
        let a = IllnessSignals.assess(tonight: vitals(9, hr: 64, hrv: 60, rr: 14), prior: prior,
                                      skinTempOffsetC: nil, config: config)
        XCTAssertEqual(a.readings.first { $0.signal == .restingHRRise }?.baseline, 58)
    }

    // MARK: Nightly vitals

    func testNightlyVitalsBucketsByWindowAndNeedsThreeReadings() {
        let w1 = IllnessSignals.NightWindow(night: night(0), start: night(0), end: night(0).addingTimeInterval(3600))
        let w2 = IllnessSignals.NightWindow(night: night(1), start: night(1), end: night(1).addingTimeInterval(3600))
        func s(_ kind: MetricKind, _ w: IllnessSignals.NightWindow, _ minute: Int, _ v: Double) -> QuantitySample {
            QuantitySample(kind: kind, start: w.start.addingTimeInterval(Double(minute) * 60), value: v)
        }
        let samples = [
            s(.heartRate, w1, 1, 60), s(.heartRate, w1, 2, 62), s(.heartRate, w1, 3, 64),
            s(.heartRate, w1, 4, 4),                                 // implausible: dropped
            s(.heartRate, w1, 90, 120),                              // after the window: ignored
            s(.hrvSDNN, w1, 1, 50), s(.hrvSDNN, w1, 2, 70),          // only two: no mean
            s(.respiratoryRate, w2, 1, 14), s(.respiratoryRate, w2, 2, 15), s(.respiratoryRate, w2, 3, 16),
            s(.temperature, w2, 1, 35), s(.temperature, w2, 2, 35), s(.temperature, w2, 3, 35),
        ]
        let out = IllnessSignals.nightlyVitals(samples: samples.reversed(), windows: [w2, w1])
        XCTAssertEqual(out.map(\.night), [night(0), night(1)])
        XCTAssertEqual(out[0].restingHR, 62)
        XCTAssertNil(out[0].hrv)
        XCTAssertNil(out[0].respiratoryRate)
        XCTAssertNil(out[1].restingHR)
        XCTAssertEqual(out[1].respiratoryRate, 15)
    }

    // MARK: Copy

    func testCopyNamesWhatMovedAndNeverDiagnoses() {
        var config = IllnessSignals.Config()
        config.minPriorNights = 2
        let a = IllnessSignals.assess(tonight: realCold, prior: realPrior, skinTempOffsetC: 1.11, config: config)
        let copy = IllnessSignals.copy(for: a)
        XCTAssertEqual(copy.title, "Possible illness signs")
        XCTAssertTrue(copy.body.contains("skin temperature was 1.1 °C higher, sleeping heart rate was 8 bpm "
                                         + "higher and HRV was 24% lower"), copy.body)
        XCTAssertTrue(copy.body.contains("alcohol"))
        for banned in ["COVID", "flu", "diagnos", "you have", "you are sick"] {
            XCTAssertFalse(copy.body.localizedCaseInsensitiveContains(banned), banned)
        }
    }

    func testCopyWithTwoSignals() {
        let a = IllnessSignals.assess(tonight: vitals(9, hr: 64, hrv: 60, rr: 15.5), prior: steadyPrior,
                                      skinTempOffsetC: nil)
        XCTAssertTrue(IllnessSignals.copy(for: a).body.hasPrefix(
            "Last night your sleeping heart rate was 6 bpm higher and breathing rate was 1.5 breaths/min higher"))
    }

    // MARK: Routing (TempFeverNotifications)

    private func flags(rise: Bool = false, fluctRise: Bool = false, drop: Bool = false) -> SkinTempBaseline.AnomalyFlags {
        var f = SkinTempBaseline.AnomalyFlags()
        f.abnormalRise = rise; f.fluctuationRise = fluctRise; f.abnormalDrop = drop
        return f
    }

    private func suspected(withTemp: Bool) -> IllnessSignals.Assessment {
        IllnessSignals.assess(tonight: vitals(9, hr: 66, hrv: 40, rr: 14), prior: steadyPrior,
                              skinTempOffsetC: withTemp ? 1.1 : 0.2)
    }

    func testIllnessReplacesTheTempRiseAlertsItAlreadyNames() {
        let out = TempFeverNotifications.notifications(flags: flags(rise: true, fluctRise: true),
                                                       feverSuspected: false,
                                                       illness: suspected(withTemp: true))
        XCTAssertEqual(out, [.illnessSigns])
    }

    func testIllnessKeepsATempAlertItDoesNotName() {
        let out = TempFeverNotifications.notifications(flags: flags(fluctRise: true), feverSuspected: false,
                                                       illness: suspected(withTemp: false))
        XCTAssertEqual(out, [.skinTempFluctuationRise, .illnessSigns])
    }

    func testFeverWinsOverIllness() {
        let out = TempFeverNotifications.notifications(flags: flags(rise: true), feverSuspected: true,
                                                       illness: suspected(withTemp: true))
        XCTAssertEqual(out, [.skinTempRise, .fever])
    }

    func testNoIllnessArgumentIsTheShippedRouting() {
        XCTAssertEqual(TempFeverNotifications.notifications(flags: flags(rise: true, fluctRise: true),
                                                            feverSuspected: false),
                       [.skinTempRise, .skinTempFluctuationRise])
    }

    func testIllnessIsAPerNightTempFamilyAlert() {
        XCTAssertTrue(TempFeverNotifications.notificationSet.contains(.illnessSigns))
        XCTAssertFalse(HeadacheSignsNotifications.notificationSet.contains(.illnessSigns))
        XCTAssertFalse(LiveHealthAlerts.notificationSet.contains(.illnessSigns))
    }
}
