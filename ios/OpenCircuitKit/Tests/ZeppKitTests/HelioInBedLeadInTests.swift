// Decision 77 (#328): a strap night's in-bed lead-in, reached back from its first in-bed start over the
// strap's own stored minutes (worn, no walking, heart rate near the sleeping level). Every minute, night,
// heart rate and step count here is synthetic: spans on round minutes, round beats per minute.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// 2026-09-30T00:00:00Z: minute 1440 of every span below is this midnight (UTC).
private let reference: TimeInterval = 1_790_726_400

/// Minute `m` counted from the midnight before `reference`: 1380 is 23:00 the evening before.
private func at(_ m: Int) -> Date { date(reference - 86_400 + TimeInterval(m) * 60) }

private func span(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

/// The night's sleeping level in these fixtures, and a heart rate well above it.
private let sleeping: Double = 60
private let walking: Double = 95

/// One heart-rate sample a minute over `from ..< to` at `bpm`.
private func beats(_ from: Int, _ to: Int, _ bpm: Double = sleeping) -> [HelioInBedLeadIn.HeartRateMinute] {
    (from..<to).map { HelioInBedLeadIn.HeartRateMinute(time: at($0), bpm: bpm) }
}

/// One step row over minute `m`.
private func stepsAt(_ m: Int, _ count: Int) -> HelioInBedLeadIn.StepMinute {
    HelioInBedLeadIn.StepMinute(start: at(m), end: at(m + 1), steps: count)
}

final class HelioInBedLeadInTests: XCTestCase {
    private typealias LeadIn = HelioInBedLeadIn
    private typealias Selection = HelioSleepSelection

    /// The first in-bed start and first sleep minute: 23:00.
    private let bed = 1380

    /// The night's own heart rate after its first sleep minute, at the sleeping level.
    private var night: [LeadIn.HeartRateMinute] { beats(bed, bed + 60) }

    private func leadIn(_ before: [LeadIn.HeartRateMinute], steps: [LeadIn.StepMinute] = [],
                        earliest: Date = .distantPast) -> Int? {
        LeadIn.start(inBedStart: at(bed), firstSleep: at(bed), heartRate: before + night, steps: steps, earliest: earliest)
            .map { Int((at(bed).timeIntervalSince($0) / 60).rounded()) }
    }

    // MARK: The walk back (77a)

    func testWornStillAndAtTheSleepingLevelIsLeadIn() {
        XCTAssertEqual(leadIn(beats(bed - 40, bed)), 40)
    }

    func testAStepBurstEndsTheWalk() {
        XCTAssertEqual(leadIn(beats(bed - 40, bed), steps: [stepsAt(bed - 26, 30)]), 25)
    }

    func testAFewStepsInBedDoNotEndTheWalk() {
        XCTAssertEqual(leadIn(beats(bed - 40, bed), steps: [stepsAt(bed - 26, LeadIn.stepsThatEndIt - 1)]), 40)
        XCTAssertEqual(leadIn(beats(bed - 40, bed), steps: [stepsAt(bed - 26, LeadIn.stepsThatEndIt)]), 25)
    }

    func testAHeartRateWellAboveTheSleepingLevelEndsTheWalk() {
        XCTAssertEqual(leadIn(beats(bed - 40, bed - 25, walking) + beats(bed - 25, bed)), 25)
    }

    func testAHeartRateUpToTheMarginJoinsAndAboveItEndsTheWalk() {
        let atMargin = sleeping + LeadIn.heartRateMarginBPM
        XCTAssertEqual(leadIn(beats(bed - 40, bed, atMargin)), 40)
        XCTAssertEqual(leadIn(beats(bed - 40, bed - 25, atMargin + 1) + beats(bed - 25, bed)), 25)
    }

    func testTheSleepingLevelIsTheMedianOfTheNightsFirstHour() {
        // The first hour: 40 minutes at 60 and 20 at 90, so the median is 60 and 80 is above the margin.
        let night = beats(bed, bed + 40) + beats(bed + 40, bed + 60, 90)
        let start = LeadIn.start(inBedStart: at(bed), firstSleep: at(bed), heartRate: beats(bed - 40, bed, 80) + night,
                                 steps: [], earliest: .distantPast)
        XCTAssertNil(start)
        XCTAssertEqual(LeadIn.median([60, 90, 60]), 60)
        XCTAssertEqual(LeadIn.median([60, 70]), 65)
        XCTAssertNil(LeadIn.median([]))
    }

    func testAShortHeartRateHoleIsBridgedAndALongerOneEndsTheWalk() {
        let hole = LeadIn.maxHoleMinutes
        XCTAssertEqual(leadIn(beats(bed - 40, bed - 20 - hole) + beats(bed - 20, bed)), 40, "a hole at the limit is bridged")
        XCTAssertEqual(leadIn(beats(bed - 40, bed - 21 - hole) + beats(bed - 20, bed)), 20, "one minute more ends it")
    }

    func testUnwornThereIsNoLeadIn() {
        XCTAssertNil(leadIn([]))
        XCTAssertNil(leadIn(beats(bed - 90, bed - 30)), "worn earlier, then off for half an hour before bed")
    }

    func testWithoutTheNightsOwnHeartRateNothingIsJudged() {
        XCTAssertNil(LeadIn.start(inBedStart: at(bed), firstSleep: at(bed), heartRate: beats(bed - 40, bed),
                                  steps: [], earliest: .distantPast))
    }

    func testALeadInShorterThanTheMinimumIsNotAdded() {
        let minimum = Int(LeadIn.minLength / 60)
        XCTAssertNil(leadIn(beats(bed - minimum + 1, bed)))
        XCTAssertEqual(leadIn(beats(bed - minimum, bed)), minimum)
    }

    func testALeadInIsCappedAtTheLongest() {
        let longest = Int(LeadIn.maxLength / 60)
        XCTAssertEqual(leadIn(beats(bed - longest - 60, bed)), longest)
    }

    func testItNeverStartsBeforeTheEarliestAllowedStart() {
        XCTAssertEqual(leadIn(beats(bed - 90, bed), earliest: at(bed - 20)), 20, "the previous sleep ended 20 min before")
        XCTAssertNil(leadIn(beats(bed - 90, bed), earliest: at(bed - 3)), "too little room left: nothing")
        XCTAssertNil(leadIn(beats(bed - 90, bed), earliest: at(bed)), "a sleep ending at the in-bed start: nothing")
    }

    func testTheSleepingLevelIsJudgedFromTheFirstSleepMinuteNotTheInBedStart() {
        // The record's in-bed span starts 5 min before the first stage; those minutes are no sleep.
        let start = LeadIn.start(inBedStart: at(bed - 5), firstSleep: at(bed), heartRate: beats(bed - 45, bed - 5) + night,
                                 steps: [], earliest: .distantPast)
        XCTAssertEqual(start, at(bed - 45))
    }

    // MARK: The lead-in in a night's segments (77a, 77d)

    /// One fragment 23:00–07:00 as `night(from:now:)` builds it: its `.inBed`, then its stages.
    private let fragment: [SleepSegment] = [
        SleepSegment(start: at(1380), end: at(1860), stage: .inBed),
        SleepSegment(start: at(1380), end: at(1500), stage: .asleepCore),
        SleepSegment(start: at(1500), end: at(1530), stage: .awake),
        SleepSegment(start: at(1530), end: at(1860), stage: .asleepDeep),
    ]

    private func spans(_ segments: [SleepSegment], _ stage: SleepStage) -> [DateInterval] {
        segments.filter { $0.stage == stage }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    func testTheLeadInIsAnAwakeInBedSpanBeforeTheFirstFragmentAndMovesTheWindowStartOnly() {
        let night = Selection.Night(segments: fragment, window: span(1380, 1860), strapScore: 80).withLeadIn(from: at(1340))
        XCTAssertEqual(night.window, span(1340, 1860))
        XCTAssertEqual(night.leadIn, span(1340, 1380))
        XCTAssertEqual(night.windowWithoutLeadIn, span(1380, 1860))
        XCTAssertEqual(Array(night.segments.prefix(2)), [SleepSegment(start: at(1340), end: at(1380), stage: .inBed),
                                                         SleepSegment(start: at(1340), end: at(1380), stage: .awake)])
        XCTAssertEqual(Array(night.segments.dropFirst(2)), fragment, "the stages are untouched")
        XCTAssertEqual(night.strapScore, 80)
        XCTAssertTrue(night.segments.allSatisfy { $0.provenance == .measured }, "measured rows, never asserted time")
        XCTAssertEqual(night.withoutLeadIn, Selection.Night(segments: fragment, window: span(1380, 1860), strapScore: 80))
    }

    func testTimeInBedAndAwakeGrowAsleepIsUnchanged() {
        let before = SleepStaging.summary(fragment)
        let after = SleepStaging.summary(Selection.withLeadIn(fragment, window: span(1380, 1860), from: at(1340)))
        XCTAssertEqual(after.inBed, before.inBed + 40 * 60)
        XCTAssertEqual(after.awake, before.awake + 40 * 60)
        XCTAssertEqual(after.totalAsleep, before.totalAsleep)
        XCTAssertLessThan(after.totalAsleep / after.inBed, before.totalAsleep / before.inBed, "efficiency drops")
        XCTAssertNotNil(SleepStaging.sleepWindow(fragment))
        XCTAssertEqual(SleepStaging.sleepWindow(Selection.withLeadIn(fragment, window: span(1380, 1860), from: at(1340)))?.onset,
                       SleepStaging.sleepWindow(fragment)?.onset, "sleep onset is unchanged")
    }

    func testTheSleepReadersNeverSeeTheLeadIn() {
        let night = Selection.Night(segments: fragment, window: span(1380, 1860), strapScore: nil).withLeadIn(from: at(1340))
        XCTAssertEqual(night.sleepSpans, [span(1380, 1860)], "71i/74c readers judge the fragment only")
        XCTAssertEqual(Selection.Night(segments: fragment, window: span(1380, 1860), strapScore: nil).sleepSpans, night.sleepSpans)
    }

    /// A stitched night: the fragment above to 02:00, the gap 02:00–05:30 filled awake (decision 74), and
    /// a later fragment 05:30–07:00.
    private var stitchedAndFilled: [SleepSegment] {
        let joined = [
            SleepSegment(start: at(1380), end: at(1560), stage: .inBed),
            SleepSegment(start: at(1380), end: at(1560), stage: .asleepCore),
            SleepSegment(start: at(1770), end: at(1860), stage: .inBed),
            SleepSegment(start: at(1770), end: at(1860), stage: .asleepCore),
        ]
        return Selection.awakeFilled(joined, window: span(1380, 1860), heartRateMinutes: (1560..<1770).map(at))
    }

    func testAStitchedNightGetsTheLeadInBeforeItsFirstFragmentOnlyAndKeepsItsFill() {
        let filled = stitchedAndFilled
        let out = Selection.withLeadIn(filled, window: span(1380, 1860), from: at(1340))
        XCTAssertEqual(Selection.leadIn(in: out), span(1340, 1380))
        XCTAssertEqual(Selection.awakeFillRuns(in: out), [span(1340, 1380), span(1560, 1770)])
        XCTAssertEqual(Selection.withoutLeadIn(out), filled, "the 74 fill is unchanged")
        XCTAssertEqual(Selection.sleepSpans(of: out, window: span(1340, 1860)), [span(1380, 1560), span(1770, 1860)])
        XCTAssertEqual(Selection.leadIn(in: filled), nil, "a gap fill is never a lead-in")
    }

    func testANightWithoutALeadInReadsAsBefore() {
        XCTAssertNil(Selection.leadIn(in: fragment))
        XCTAssertEqual(Selection.withoutLeadIn(fragment), fragment)
        XCTAssertEqual(Selection.windowWithoutLeadIn(fragment, window: span(1380, 1860)), span(1380, 1860))
        XCTAssertEqual(Selection.withLeadIn(fragment, window: span(1380, 1860), from: at(1380)), fragment, "no room: none")
        // The ring's shape (one `.inBed` over everything, a pre-sleep `.awake` inside it) is no lead-in.
        let ring = [SleepSegment(start: at(1340), end: at(1860), stage: .inBed),
                    SleepSegment(start: at(1340), end: at(1380), stage: .awake),
                    SleepSegment(start: at(1380), end: at(1860), stage: .asleepCore)]
        XCTAssertNil(Selection.leadIn(in: ring))
        XCTAssertEqual(Selection.windowWithoutLeadIn(ring, window: span(1340, 1860)), span(1340, 1860))
    }

    func testAddingALeadInAgainReplacesTheOldOne() {
        let once = Selection.withLeadIn(fragment, window: span(1380, 1860), from: at(1340))
        let again = Selection.withLeadIn(once, window: span(1340, 1860), from: at(1360))
        XCTAssertEqual(Selection.leadIn(in: again), span(1360, 1380))
        XCTAssertEqual(Selection.withoutLeadIn(again), fragment)
    }

    func testALeadInCrossingMidnightKeepsTheNightKey() {
        // Asleep 00:10–07:00; the lead-in reaches back to 23:30 the evening before.
        let afterMidnight = [SleepSegment(start: at(1450), end: at(1860), stage: .inBed),
                             SleepSegment(start: at(1450), end: at(1860), stage: .asleepCore)]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let night = Selection.Night(segments: afterMidnight, window: span(1450, 1860), strapScore: nil,
                                    recordedTimeZone: TimeZone(identifier: "UTC")).withLeadIn(from: at(1410))
        XCTAssertEqual(night.window, span(1410, 1860))
        XCTAssertNotEqual(utc.startOfDay(for: night.window.start), utc.startOfDay(for: night.windowWithoutLeadIn.start))
        XCTAssertEqual(SleepNightKey.night(inBedStart: night.window.start, inBedEnd: night.window.end, calendar: utc),
                       SleepNightKey.night(inBedStart: at(1450), inBedEnd: at(1860), calendar: utc))
        XCTAssertEqual(Selection.nightKey(of: night), Selection.nightKey(of: night.withoutLeadIn))
    }
}
