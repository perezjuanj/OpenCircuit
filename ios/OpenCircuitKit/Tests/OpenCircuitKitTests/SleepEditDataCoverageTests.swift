import XCTest
@testable import OpenCircuitKit

/// #188 fallout — the sleep editor could not correct a badly truncated night.
///
/// THE REPORTED SYMPTOM (2026-08-04, real user): after the #188 loss staged an 8.6 h night as the
/// 07:30–08:55 tail, the edit sheet "won't let me select yesterday's date or any hour before 4 or
/// after 8". That is exactly `bounds` anchored on the recorded fragment:
///   earliest = 07:30 − 3 h = 04:30 · latest = 08:55 + 3 h = 11:55
///   "In bed" picker = earliest…onset = 04:30–07:30 → the real 00:15 bedtime was unreachable, and
///   so was the entire previous calendar day.
///
/// The fix lets the epochs we actually HOLD widen the bounds, capped at one plausible night.
final class SleepEditDataCoverageTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func d(_ day: Int, _ h: Int, _ m: Int) -> Date {
        DateComponents(calendar: cal, timeZone: TimeZone(identifier: "UTC"),
                       year: 2026, month: 8, day: day, hour: h, minute: m).date!
    }

    /// The user's night as the app recorded it after the loss.
    private var recordedOnset: Date { d(4, 7, 30) }
    private var recordedWake: Date { d(4, 8, 55) }

    // MARK: - the regression

    func testUnwidenedBoundsCannotReachTheRealBedtime() {
        // Documents the shipped behaviour that produced the report. The pinned edges moved on
        // 2026-08-22 when `strandedEditMargin` widened both sides from ±3 h to ±6 h (clipped by the
        // one-night caps) — but the POINT of this test is unchanged and still holds: with no
        // coverage at all, a 4 h 15 m front-edge loss is still out of reach, which is why the
        // coverage widening below is not redundant.
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        XCTAssertEqual(b.earliest, d(4, 1, 30), "onset − 6 h")
        XCTAssertEqual(b.latest, d(4, 14, 55), "wake + 6 h")
        XCTAssertGreaterThan(b.earliest, d(4, 0, 15),
                             "00:15 bedtime is still outside even the stranded margin")
    }

    func testArchiveCoverageWidensBoundsToReachTheRealBedtime() {
        // The archive still holds the evening before + the morning tail.
        let coverage = d(3, 19, 45)...d(4, 8, 53)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: coverage)
        XCTAssertLessThanOrEqual(b.earliest, d(4, 0, 15),
                                 "the real 00:15 bedtime must now be selectable")
        XCTAssertGreaterThanOrEqual(b.latest, d(4, 8, 53))
    }

    func testWideningNeverGoesTighterThanTheParityFloor() {
        // A night whose data coverage is NARROWER than the margin must still offer the full margin
        // — widening may only ever add. (Same edges as the no-coverage case above: coverage this
        // narrow contributes nothing, which is the assertion.)
        let narrow = d(4, 7, 45)...d(4, 8, 30)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: narrow)
        XCTAssertEqual(b.earliest, d(4, 1, 30))
        XCTAssertEqual(b.latest, d(4, 14, 55))
        XCTAssertEqual(b, SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake),
                       "narrow coverage must be indistinguishable from no coverage")
    }

    // MARK: - the recorder stops mid-night (Gen 2 Air, 2026-08-22)

    /// 🟢 THE SECOND REPORT, and the one `strandedEditMargin` exists for. Ring …59F91, FR04.009,
    /// Europe/Paris. The wearer slept 00:15 → 06:15. Her ring's last epoch of the night is
    /// **02:31:51** — it kept sending live skin-temperature descriptors unbroken at a ~42 s median
    /// through to 06:39, at 35.4–36.4 °C, so it was demonstrably worn and connected the whole time;
    /// it simply stopped writing history. Staging ended the night at 02:08:51.
    ///
    /// Under the ±3 h rule the wake picker stopped at 02:08:51 + 3 h = 05:08:51, and she wrote in to
    /// say so: "I can't write more than 5h15 AM". Coverage could not rescue it — the archive ENDS
    /// before the recorded wake, so there was nothing to widen with. The previous night was the same
    /// shape: last data 03:15, real wake 07:15, picker capped at 06:15.
    ///
    /// Times are UTC+2 wall clock expressed in the UTC helper, which is fine — the rule is
    /// arithmetic on instants and carries no calendar.
    func testTheWearerCanEnterHerRealWakeWhenTheRecorderStopped() throws {
        let onset = d(22, 0, 16)     // staged onset, ≈ her real bedtime
        let stagedWake = d(22, 2, 8) // where the data ran out, NOT where she woke
        let lastEpoch = d(22, 2, 31)
        let realWake = d(22, 6, 15)

        let coverage = d(21, 20, 36)...lastEpoch
        let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: stagedWake,
                                 dataCoverage: coverage)

        XCTAssertLessThan(stagedWake.addingTimeInterval(SleepEdit.editMargin), realWake,
                          "precondition: the ±3 h margin cannot reach her real wake")
        XCTAssertLessThan(coverage.upperBound, stagedWake.addingTimeInterval(SleepEdit.editMargin),
                          "precondition: coverage ends early, so it cannot widen anything either")

        XCTAssertGreaterThanOrEqual(b.latest, realWake, "her real 06:15 wake must be selectable")
        XCTAssertNil(SleepEdit.validate(.init(inBedStart: onset, sleepOnset: onset,
                                              sleepWake: realWake),
                                        recordedOnset: onset, recordedWake: stagedWake,
                                        dataCoverage: coverage),
                     "and the validator must accept what the picker offered")
    }

    /// 🟢 THE RACE, REMOVED. Adversarial review established that the 05:08 ceiling was not a
    /// permanent trap: her ring's post-hole resume block lands ~06:40, and on the two preceding
    /// nights coverage then widened the ceiling to 09:34 and 06:56, letting her save 06:45 and
    /// 06:43. On 2026-08-22 she simply opened the editor at 06:39, minutes too early. Sweeping the
    /// edit hour on master therefore walks the ceiling up with the clock — 07:00, 08:00, 09:00 —
    /// which means the answer to "can I enter the truth?" depended on WHEN she asked.
    ///
    /// What the stranded margin buys is REACHABILITY AT EVERY HOUR, not a constant ceiling. The
    /// ceiling itself still rises with the clock, because the coverage widening is still there and
    /// still earning its keep — it is what rescued her on 08-17 and 08-18. Asserting a single value
    /// would therefore be asserting the removal of a lever that works; the first draft of this test
    /// did exactly that and failed (4 distinct ceilings), which is the useful part.
    ///
    /// The property that matches what she experiences: at NO hour is her real wake out of reach, and
    /// the ceiling never moves DOWN as the archive grows.
    func testHerRealWakeIsReachableAtEveryHourSheMightEdit() {
        let onset = d(22, 0, 16), stagedWake = d(22, 2, 8), realWake = d(22, 6, 15)
        let firstEpoch = d(21, 20, 36), lastBeforeHole = d(22, 2, 31)
        let strandedFloor = stagedWake.addingTimeInterval(SleepEdit.strandedEditMargin)

        var previous: Date?
        for editHour in [6, 7, 8, 9, 11, 14, 20] {
            // The archive as it stands at `editHour`: the night, then the post-hole resume block
            // once it has drained. Before ~06:40 there is nothing past the hole.
            let upper = editHour <= 6 ? lastBeforeHole : d(22, editHour, 0)
            let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: stagedWake,
                                     dataCoverage: firstEpoch...upper)
            XCTAssertGreaterThanOrEqual(b.latest, realWake,
                                        "editing at \(editHour):00 must still reach her real wake")
            XCTAssertGreaterThanOrEqual(b.latest, strandedFloor,
                                        "the stranded margin is a floor the clock cannot erode")
            if let previous {
                XCTAssertGreaterThanOrEqual(b.latest, previous,
                                            "the ceiling must never move DOWN as the archive grows "
                                            + "— that is what makes a Save safe while the sheet is open")
            }
            previous = b.latest
        }

        // …and on master the 06:39 case was NOT reachable, which is the whole report.
        let atSixThirtyNine = SleepEdit.bounds(recordedOnset: onset, recordedWake: stagedWake,
                                               dataCoverage: firstEpoch...lastBeforeHole)
        XCTAssertLessThan(stagedWake.addingTimeInterval(SleepEdit.editMargin), realWake,
                          "precondition: the old ±3 h ceiling was below her real wake")
        XCTAssertGreaterThanOrEqual(atSixThirtyNine.latest, realWake)
    }

    /// The mirror: whatever the editor offers, `validate` must agree — otherwise the picker hands
    /// out times Save then rejects, which is how this class of bug reaches a user in the first place.
    func testValidatorAgreesWithEveryEdgeTheStrandedPickerOffers() {
        let onset = d(22, 0, 16), stagedWake = d(22, 2, 8)
        let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: stagedWake)
        for edge in [b.latest, b.latest.addingTimeInterval(-60), b.earliest.addingTimeInterval(3600)]
        where edge > onset {
            XCTAssertNil(SleepEdit.validate(.init(inBedStart: min(onset, b.earliest),
                                                  sleepOnset: min(onset, b.earliest),
                                                  sleepWake: edge),
                                            recordedOnset: onset, recordedWake: stagedWake),
                         "picker offered \(edge) but validate refused it")
        }
    }

    func testOnePlausibleNightSurvivesTwoNightCoverage() {
        // The EpochArchive retains ~30 h (two nights). Coverage reaching back that far must not let
        // an edit reach into the previous night. Each EDGE is capped one night-span past the
        // opposite floor edge; the paired WINDOW is capped by `validate`'s `.tooLong` — the edges
        // alone deliberately no longer pairwise-cap each other (that arithmetic was the 2026-08-16
        // seesaw, `testEveningCoverageMustNotEatTheHeldMorning` below).
        let twoNights = d(3, 2, 53)...d(4, 8, 53)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: twoNights)
        XCTAssertGreaterThan(b.earliest, d(3, 2, 53), "must not reach the neighbouring night")
        XCTAssertLessThanOrEqual(b.earliest, d(4, 0, 15), "…but still reaches this night's bedtime")
    }

    /// The `.tooLong` rule is the load-bearing replacement for the removed pairwise edge cap — it
    /// must not be deletable without a failure. Coverage widening BOTH sides makes the bounds span
    /// strictly exceed one night (earliest = floorLatest − 14 h = Aug 3 21:55; latest = min(13:00,
    /// floorEarliest + 14 h) = Aug 4 13:00 → 15 h 05 m), so the assertions below run unconditionally.
    func testWindowStretchedAcrossWidenedBoundsIsTooLong() {
        let coverage = d(3, 2, 53)...d(4, 13, 0)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: coverage)
        XCTAssertGreaterThan(b.latest.timeIntervalSince(b.earliest), SleepEdit.defaultMaxNightSpan,
                             "precondition: the widened bounds exceed one night")
        let stretched = SleepEdit.Times(inBedStart: b.earliest,
                                        sleepOnset: b.earliest.addingTimeInterval(900),
                                        sleepWake: b.latest)
        XCTAssertEqual(SleepEdit.validate(stretched, recordedOnset: recordedOnset,
                                          recordedWake: recordedWake, dataCoverage: coverage),
                       .tooLong(maxMinutes: Int(SleepEdit.defaultMaxNightSpan / 60)))
        // A window at exactly the limit passes — the rule caps, it doesn't creep.
        let atLimit = SleepEdit.Times(inBedStart: b.earliest,
                                      sleepOnset: b.earliest.addingTimeInterval(900),
                                      sleepWake: b.earliest.addingTimeInterval(SleepEdit.defaultMaxNightSpan))
        XCTAssertNil(SleepEdit.validate(atLimit, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake, dataCoverage: coverage))
    }

    /// `maxWindowDuration`'s two escape hatches, pinned: a long recorded night's full parity floor
    /// stays savable, and a previously saved longer edit stays re-savable.
    func testMaxWindowDurationFloorAndExistingEditEscapes() {
        // 13 h recorded night → floor span 19 h > maxNightSpan; the whole floor must validate.
        let longOnset = d(3, 19, 0), longWake = d(4, 8, 0)
        let floorTimes = SleepEdit.Times(inBedStart: longOnset.addingTimeInterval(-SleepEdit.editMargin),
                                         sleepOnset: longOnset,
                                         sleepWake: longWake.addingTimeInterval(SleepEdit.editMargin))
        XCTAssertNil(SleepEdit.validate(floorTimes, recordedOnset: longOnset, recordedWake: longWake))
        // A saved edit longer than one night-span must remain re-savable verbatim.
        let saved = d(3, 18, 0)...d(4, 9, 0)   // 15 h
        let savedTimes = SleepEdit.Times(inBedStart: saved.lowerBound,
                                         sleepOnset: saved.lowerBound.addingTimeInterval(900),
                                         sleepWake: saved.upperBound)
        XCTAssertNil(SleepEdit.validate(savedTimes, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake, existingEdit: saved))
    }

    func testNilCoverageIsExactlyTheOldBehaviour() {
        let old = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        let new = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                   dataCoverage: nil)
        XCTAssertEqual(old, new)
    }

    // MARK: - dataCoverage itself

    func testCoverageIsScopedToTheNightNotTheWholeArchive() {
        // Records spanning two nights; only those within one night-span of the recorded anchors count.
        let dates = [d(2, 23, 0), d(3, 3, 0), d(3, 22, 0), d(4, 2, 0), d(4, 8, 53)]
        let c = SleepEdit.dataCoverage(recordDates: dates,
                                       recordedOnset: recordedOnset, recordedWake: recordedWake)
        let cov = try! XCTUnwrap(c)
        XCTAssertGreaterThanOrEqual(cov.lowerBound, d(3, 18, 55),
                                    "records older than wake − maxNightSpan are excluded")
        XCTAssertEqual(cov.upperBound, d(4, 8, 53))
    }

    // MARK: - composition: dataCoverage → bounds (what production actually does)

    /// Every earlier `bounds` test hand-built a coverage range. Production always feeds
    /// `dataCoverage(recordDates:)` — over the WHOLE archive, which on a worn ring keeps growing
    /// through the day — straight into `bounds`. That composition is where the first draft failed.
    private func archiveDates(from start: Date, to end: Date) -> [Date] {
        var out: [Date] = []
        var t = start
        while t <= end { out.append(t); t = t.addingTimeInterval(150) }
        return out
    }

    /// THE REGRESSION. The first draft capped the early edge against the coverage-widened `latest`,
    /// which tracks wall-clock now — so the editable window trailed the clock and the fix expired a
    /// few hours after wake. Sweep the time-of-edit across the whole day; the early bound must not
    /// move, and the real 00:15 bedtime must stay reachable at every hour.
    func testBoundsDoNotMoveAsTheDayGoesOn() {
        let trueBedtime = d(4, 0, 15)
        var earliestSeen: Set<Date> = []
        for hour in [9, 11, 13, 15, 18, 21, 23] {
            let dates = archiveDates(from: d(3, 12, 0), to: d(4, hour, 0))
            let coverage = SleepEdit.dataCoverage(recordDates: dates,
                                                  recordedOnset: recordedOnset,
                                                  recordedWake: recordedWake)
            let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                     dataCoverage: coverage)
            earliestSeen.insert(b.earliest)
            XCTAssertLessThanOrEqual(b.earliest, trueBedtime,
                                     "editing at \(hour):00 must still reach the real bedtime")
        }
        XCTAssertEqual(earliestSeen.count, 1,
                       "bounds.earliest must be time-invariant, not a window trailing the clock")
    }

    /// The late edge must be capped too, or an evening edit could assert "I slept until 19:00" —
    /// `recompute` credits a user extension as core sleep. The cap anchors on the EARLY floor edge
    /// (onset − 3 h), never on the coverage-widened `earliest` (the 2026-08-16 seesaw).
    func testLateEdgeIsCappedAtOneNightSpan() {
        let dates = archiveDates(from: d(3, 12, 0), to: d(4, 21, 0))
        let coverage = SleepEdit.dataCoverage(recordDates: dates,
                                              recordedOnset: recordedOnset, recordedWake: recordedWake)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: coverage)
        XCTAssertLessThanOrEqual(b.latest, d(4, 4, 30).addingTimeInterval(SleepEdit.defaultMaxNightSpan),
                                 "late edge stops one night-span past the early floor edge")
        XCTAssertLessThan(b.latest, d(4, 19, 0), "must not let the user claim sleep into the evening")
    }

    // MARK: - the 2026-08-16 seesaw (🟢 device case, Gen 2 Air tester)

    /// THE SECOND REGRESSION. Recorded 03:44→06:04; the archive held the previous EVENING (which
    /// dragged `earliest` down to its cap) AND the morning through 10:51 — the tester's real ~10:15
    /// wake was inside held data. The shipped cap `earliest + maxNightSpan` collapsed the late edge
    /// to exactly 09:04 (the sheet's "Sat 7:04 PM to 9:04 AM"), spending the whole night-span budget
    /// on eight useless evening hours. Held morning data must stay reachable regardless of how far
    /// the evening side widened.
    func testEveningCoverageMustNotEatTheHeldMorning() {
        let onset = d(16, 3, 44), wake = d(16, 6, 4)
        let dates = archiveDates(from: d(15, 4, 53), to: d(15, 23, 43))
            + archiveDates(from: d(16, 3, 44), to: d(16, 10, 51))
        let coverage = try! XCTUnwrap(SleepEdit.dataCoverage(recordDates: dates,
                                                             recordedOnset: onset,
                                                             recordedWake: wake))
        XCTAssertGreaterThanOrEqual(coverage.upperBound, d(16, 10, 15),
                                    "the real wake IS inside held coverage — precondition")
        let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake, dataCoverage: coverage)
        XCTAssertGreaterThanOrEqual(b.latest, d(16, 10, 15),
                                    "the tester must be able to select the wake the ring recorded")
        // The evening side keeps its own cap: one night-span before the late floor edge.
        XCTAssertGreaterThanOrEqual(b.earliest, wake.addingTimeInterval(SleepEdit.editMargin)
                                        .addingTimeInterval(-SleepEdit.defaultMaxNightSpan))
        // And the corrected window itself validates end-to-end.
        let times = SleepEdit.Times(inBedStart: d(16, 3, 44), sleepOnset: d(16, 3, 45),
                                    sleepWake: d(16, 10, 15))
        XCTAssertNil(SleepEdit.validate(times, recordedOnset: onset, recordedWake: wake,
                                        minDuration: 30 * 60, dataCoverage: coverage))
    }

    /// The mirrored failure mode of the fix itself: morning coverage widening `latest` must not
    /// drag the EARLY cap along and cut off a held evening. Symmetric twin of the seesaw test.
    func testMorningCoverageMustNotEatTheHeldEvening() {
        let onset = d(16, 3, 44), wake = d(16, 6, 4)
        let dates = archiveDates(from: d(15, 21, 0), to: d(16, 10, 51))
        let coverage = try! XCTUnwrap(SleepEdit.dataCoverage(recordDates: dates,
                                                             recordedOnset: onset,
                                                             recordedWake: wake))
        let b = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake, dataCoverage: coverage)
        XCTAssertLessThanOrEqual(b.earliest, d(15, 21, 0),
                                 "held evening data stays reachable however far the morning widened")
    }

    // MARK: - rules that must not be deletable without a test failing

    /// Pins the parity FLOOR inside the cap. With a long recorded night the cap arithmetic would
    /// otherwise be free to push `earliest` later than onset − 3 h.
    ///
    /// ⚠️ RE-BASELINED 2026-08-24. The no-coverage expectations were `onset − 3 h` / `wake + 3 h`,
    /// which pinned the old rule that a long recorded night gets NO stranded margin because the
    /// opposite-floor caps cancelled it. That cancellation was the defect behind "won't allow me to
    /// edit wake time" — see `SleepEditInvariantTests`
    /// `testAFullNightIsWidenedByTheStrandedMarginToo` for the measured night and the reasoning.
    /// What this test is really for — the floor being a FLOOR that widening only ever adds to — is
    /// unchanged and is still asserted below.
    func testParityFloorSurvivesTheCapOnALongNight() {
        let onset = d(3, 22, 0), wake = d(4, 8, 0)          // a 10 h night
        let noCoverage = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake)
        XCTAssertEqual(noCoverage.earliest, d(3, 16, 0), "onset − 6 h (stranded margin, own anchor)")
        XCTAssertEqual(noCoverage.latest, d(4, 14, 0), "wake + 6 h (ditto)")
        XCTAssertLessThanOrEqual(noCoverage.earliest, d(3, 19, 0), "onset − 3 h is a FLOOR")
        XCTAssertGreaterThanOrEqual(noCoverage.latest, d(4, 11, 0), "wake + 3 h is a FLOOR")

        let wide = SleepEdit.bounds(recordedOnset: onset, recordedWake: wake,
                                    dataCoverage: d(2, 20, 0)...d(4, 20, 0))
        XCTAssertLessThanOrEqual(wide.earliest, d(3, 19, 0), "floor is a floor — widening only adds")
        XCTAssertGreaterThanOrEqual(wide.latest, d(4, 11, 0))
    }

    /// A saved edit must stay selectable even after retention prunes the coverage that allowed it.
    func testAnAlreadySavedEditIsAlwaysStillSelectable() {
        let saved = d(4, 0, 15)...d(4, 8, 53)
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: nil, existingEdit: saved)   // coverage fully pruned
        XCTAssertLessThanOrEqual(b.earliest, saved.lowerBound)
        XCTAssertGreaterThanOrEqual(b.latest, saved.upperBound)
        let times = SleepEdit.Times(inBedStart: saved.lowerBound,
                                    sleepOnset: saved.lowerBound.addingTimeInterval(900),
                                    sleepWake: saved.upperBound)
        XCTAssertNil(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake, existingEdit: saved),
                     "re-opening an edited night must not silently clamp the user's own times")
    }

    func testCoverageExcludesRecordsPastTheForwardWindow() {
        // Pins the `$0 <= hi` half of the night scoping — deleting it left every test green.
        let dates = [d(3, 22, 0), d(4, 2, 0), d(4, 23, 0)]   // last is > recordedOnset + 14 h
        let cov = try! XCTUnwrap(SleepEdit.dataCoverage(recordDates: dates,
                                                        recordedOnset: recordedOnset,
                                                        recordedWake: recordedWake))
        XCTAssertEqual(cov.lowerBound, d(3, 22, 0))
        XCTAssertEqual(cov.upperBound, d(4, 2, 0), "d(4,23,0) is beyond onset + 14 h and excluded")
    }

    func testCoverageIsNilWhenNoRecordsFallInTheWindow() {
        XCTAssertNil(SleepEdit.dataCoverage(recordDates: [d(1, 4, 0)],
                                            recordedOnset: recordedOnset, recordedWake: recordedWake))
        XCTAssertNil(SleepEdit.dataCoverage(recordDates: [],
                                            recordedOnset: recordedOnset, recordedWake: recordedWake))
    }

    // MARK: - the validator must agree with the picker

    func testValidatorAcceptsTheWidenedWindowThePickerNowOffers() {
        let coverage = d(3, 19, 45)...d(4, 8, 53)
        let times = SleepEdit.Times(inBedStart: d(4, 0, 15),
                                    sleepOnset: d(4, 0, 30),
                                    sleepWake: d(4, 8, 53))
        // Without coverage the server-side check rejects it — that mismatch is the bug class where
        // the picker offers a time Save then silently refuses.
        XCTAssertEqual(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                          recordedWake: recordedWake),
                       .startBeforeEarliest)
        XCTAssertNil(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                        recordedWake: recordedWake, dataCoverage: coverage))
    }

    func testWideningStillRejectsAnInventedNight() {
        // The guarantee that must survive: you cannot assert sleep in open space far from any data.
        let coverage = d(3, 19, 45)...d(4, 8, 53)
        let times = SleepEdit.Times(inBedStart: d(2, 21, 0),
                                    sleepOnset: d(2, 21, 30),
                                    sleepWake: d(3, 5, 0))
        XCTAssertNotNil(SleepEdit.validate(times, recordedOnset: recordedOnset,
                                           recordedWake: recordedWake, dataCoverage: coverage))
    }
}
