// Decision 73 (#278): a later sleep the strap marks only in its per-minute activity data (kind `0x78`)
// joins its night. Every minute and session here is synthetic: spans on the hour or half hour.

import XCTest
import OpenCircuitKit
@testable import ZeppKit

/// 2026-09-30T00:00:00Z: minute 1440 of every span below is this midnight (UTC).
private let reference: TimeInterval = 1_790_726_400

/// Minute `m` counted from the midnight before `reference`: 1380 is 23:00 the evening before, 1440 is
/// midnight and 1800 is 06:00.
private func at(_ m: Int) -> Date { date(reference - 86_400 + TimeInterval(m) * 60) }

private func span(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

private let utcZone = TimeZone(secondsFromGMT: 0)!

/// One activity minute of `kind` at minute `m`.
private func minute(_ m: Int, _ kind: UInt8) -> ZeppActivityMinute {
    ZeppActivityMinute(time: at(m), kind: kind, intensity: 8, steps: 0, rawHeartRate: 55, unknown4: 0,
                       sleep: 0, deepSleep: 0, rem: 0)
}

/// Kind-sleep minutes `from ..< to`.
private func asleep(_ from: Int, _ to: Int) -> [ZeppActivityMinute] {
    (from..<to).map { minute($0, ZeppActivityMinute.kindSleep) }
}

/// Minutes `from ..< to` of an ordinary (non-sleep) kind.
private func up(_ from: Int, _ to: Int) -> [ZeppActivityMinute] { (from..<to).map { minute($0, 0x01) } }

/// A session's night as `night(from:now:)` builds it: one `.inBed` over `from ..< to`, asleep all of it,
/// the strap's score 80, recorded in UTC.
private func session(_ from: Int, _ to: Int, score: UInt8 = 80) -> HelioSleepSelection.Night {
    HelioSleepSelection.Night(segments: [SleepSegment(start: at(from), end: at(to), stage: .inBed),
                                         SleepSegment(start: at(from), end: at(to), stage: .asleepCore)],
                              window: span(from, to), strapScore: score, recordedTimeZone: utcZone)
}

final class HelioActivitySleepTests: XCTestCase {
    private typealias Selection = HelioSleepSelection

    /// 10:00 the morning after.
    private let morning = at(1440 + 600)
    /// Sleep A, 23:00–02:00.
    private let sleepA = session(1380, 1560)

    private func blocks(_ minutes: [ZeppActivityMinute], sessions: [Selection.Night] = [],
                        now: Date? = nil) -> [Selection.Night] {
        Selection.activityBlocks(from: minutes, sessions: sessions, now: now ?? morning)
    }

    private func inBeds(_ night: Selection.Night) -> [DateInterval] {
        night.segments.filter { $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    private func stages(_ night: Selection.Night) -> [DateInterval] {
        night.segments.filter { $0.stage != .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
    }

    // MARK: 73a/73b: blocks

    /// One clean run, 05:30–07:00, then up: one block, one `.inBed` over it, its minutes merged into one
    /// generic-asleep stage, no strap score, and the zone of the session beside it.
    func testOneCleanRunOfSleepMinutesIsOneBlock() throws {
        let found = blocks(asleep(1770, 1860) + up(1860, 1900), sessions: [sleepA])
        XCTAssertEqual(found.count, 1)
        let block = try XCTUnwrap(found.first)
        XCTAssertEqual(block.window, span(1770, 1860))
        XCTAssertEqual(inBeds(block), [span(1770, 1860)])
        XCTAssertEqual(stages(block), [span(1770, 1860)])
        XCTAssertEqual(block.segments.filter { $0.stage != .inBed }.map(\.stage), [Selection.stage(for: .other(0))])
        XCTAssertNil(block.strapScore)
        XCTAssertEqual(block.recordedTimeZone, utcZone)
    }

    /// Five non-sleep minutes inside a run are an awake gap of the block (no segment for them); six end it.
    func testRunsJoinAcrossAFiveMinuteGapAndSplitAtASixMinuteOne() throws {
        let five = blocks(asleep(1740, 1770) + up(1770, 1775) + asleep(1775, 1805) + up(1805, 1840))
        XCTAssertEqual(five.map(\.window), [span(1740, 1805)])
        XCTAssertEqual(five.first.map(stages), [span(1740, 1770), span(1775, 1805)], "the gap stays a gap")
        XCTAssertEqual(five.first.map(inBeds), [span(1740, 1805)])

        let six = blocks(asleep(1740, 1770) + up(1770, 1776) + asleep(1776, 1806) + up(1806, 1840))
        XCTAssertEqual(six.map(\.window), [span(1740, 1770), span(1776, 1806)])

        let missing = blocks(asleep(1740, 1770) + asleep(1776, 1806) + up(1806, 1840))
        XCTAssertEqual(missing.map(\.window), [span(1740, 1770), span(1776, 1806)], "missing minutes count as non-sleep")
    }

    /// A run under 20 minutes (first sleep minute to last + 1) is no block; 20 minutes is.
    func testARunUnderTwentyMinutesIsNoBlock() {
        XCTAssertEqual(blocks(asleep(1740, 1759) + up(1759, 1800)), [])
        XCTAssertEqual(blocks(asleep(1740, 1760) + up(1760, 1800)).map(\.window), [span(1740, 1760)])
    }

    /// Sleep minutes inside a staged session's in-bed span are the session's: only the ones outside it
    /// make a block, and a run never crosses a session.
    func testSleepMinutesInsideASessionsInBedSpanAreNoBlock() {
        XCTAssertEqual(blocks(asleep(1380, 1560) + up(1560, 1620), sessions: [sleepA]), [], "all inside")
        XCTAssertEqual(blocks(asleep(1440, 1620) + up(1620, 1680), sessions: [sleepA]).map(\.window), [span(1560, 1620)],
                       "only the part after the session")
        let short = session(1600, 1603)
        XCTAssertEqual(blocks(asleep(1560, 1660) + up(1660, 1700), sessions: [short]).map(\.window),
                       [span(1560, 1600), span(1603, 1660)], "split at the session it would cross")
    }

    /// Decision 73d: a block whose last sleep minute is less than 20 minutes before the newest minute of
    /// the sync may still be going on; it is judged again by the next sync.
    func testABlockStillInProgressIsHeldUntilTwentyMinutesHavePassed() {
        XCTAssertEqual(blocks(asleep(1770, 1860), sessions: [sleepA]), [], "asleep to the newest minute")
        XCTAssertEqual(blocks(asleep(1770, 1860) + up(1860, 1879), sessions: [sleepA]), [], "19 minutes on")
        XCTAssertEqual(blocks(asleep(1770, 1860) + up(1860, 1880), sessions: [sleepA]).map(\.window), [span(1770, 1860)],
                       "20 minutes on: settled")
    }

    /// No activity minutes (the activity round failed or ran out of time): the nights are the sessions'
    /// own stitch, exactly.
    func testWithoutActivityMinutesTheNightsAreTheSessionsStitchUnchanged() {
        let cases: [[Selection.Night]] = [[], [sleepA], [sleepA, session(1770, 1860)], [session(1200, 1290), sleepA],
                                          [sleepA, session(2100, 2160)]]
        for sessions in cases {
            let found = blocks([], sessions: sessions)
            XCTAssertEqual(found, [])
            let join = Selection.nights(sessions: sessions, activityBlocks: found)
            XCTAssertEqual(join.nights, Selection.stitch(sessions))
            XCTAssertEqual(join.joinedBlocks, 0)
            XCTAssertEqual(join.aloneBlocks, 0)
        }
    }

    // MARK: 73c: joining

    /// #278's shape: the session 23:00–02:00, the strap's sleep minutes 05:30–07:00 (3.5 h later, an
    /// overnight sleep of the same night key, 71b). One night over both, one `.inBed` each, the gap a gap,
    /// the session's score.
    func testABlockHoursAfterTheSessionJoinsItsNight() throws {
        let found = blocks(asleep(1770, 1860) + up(1860, 1900), sessions: [sleepA])
        let join = Selection.nights(sessions: [sleepA], activityBlocks: found)
        XCTAssertEqual(join.nights.count, 1)
        let night = try XCTUnwrap(join.nights.first)
        XCTAssertEqual(night.window, span(1380, 1860))
        XCTAssertEqual(night.inBedSpans, [span(1380, 1560), span(1770, 1860)])
        XCTAssertFalse(night.segments.contains { $0.start < at(1770) && at(1560) < $0.end }, "the gap stays a gap")
        XCTAssertEqual(night.strapScore, 80)
        XCTAssertEqual(night.recordedTimeZone, utcZone)
        XCTAssertEqual(join.joinedBlocks, 1)
        XCTAssertEqual(join.aloneBlocks, 0)
    }

    /// A block longer than the session it joins doesn't take the night's score away: the night keeps
    /// the session's.
    func testAJoinedNightKeepsTheSessionsScoreWhenTheBlockIsLonger() throws {
        let short = session(1380, 1470)
        let join = Selection.nights(sessions: [short], activityBlocks: blocks(asleep(1560, 1800) + up(1800, 1840), sessions: [short]))
        XCTAssertEqual(join.nights.map(\.window), [span(1380, 1800)])
        XCTAssertEqual(join.nights.first?.strapScore, 80)
    }

    /// 28f: a block 30 minutes after the session joins it, whatever it is.
    func testABlockHalfAnHourAfterTheSessionJoinsIt() {
        let join = Selection.nights(sessions: [sleepA], activityBlocks: blocks(asleep(1590, 1650) + up(1650, 1700), sessions: [sleepA]))
        XCTAssertEqual(join.nights.map(\.window), [span(1380, 1650)])
        XCTAssertEqual(join.nights.first?.inBedSpans, [span(1380, 1560), span(1590, 1650)])
        XCTAssertEqual(join.joinedBlocks, 1)
    }

    /// A daytime block (13:00–14:00 after a 23:00–07:00 session) stands alone: dropped, counted.
    func testAStandaloneDaytimeBlockIsDropped() {
        let night = session(1380, 1860)
        let join = Selection.nights(sessions: [night], activityBlocks: blocks(asleep(2220, 2280) + up(2280, 2320),
                                                                                     sessions: [night], now: at(2400)))
        XCTAssertEqual(join.nights, [night])
        XCTAssertEqual(join.joinedBlocks, 0)
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// An evening doze block (20:00–21:00, two hours before a 23:00–07:00 session) is no overnight sleep
    /// and too far to stitch: dropped, counted.
    func testAnEveningDozeBlockIsDropped() {
        let night = session(1380, 1860)
        let join = Selection.nights(sessions: [night], activityBlocks: blocks(asleep(1200, 1260) + up(1260, 1300), sessions: [night]))
        XCTAssertEqual(join.nights, [night])
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// A night with no session record: its blocks are no night in v1, together or apart.
    func testBlocksOnANightWithNoSessionRecordAreDropped() {
        let minutes = asleep(1380, 1560) + up(1560, 1600) + asleep(1600, 1800) + up(1800, 1840)
        let alone = Selection.nights(sessions: [], activityBlocks: blocks(minutes))
        XCTAssertEqual(alone.nights, [])
        XCTAssertEqual(alone.aloneBlocks, 2)

        let lastNight = session(1380 - 1440, 1860 - 1440)
        let found = blocks(minutes, sessions: [lastNight])
        let join = Selection.nights(sessions: [lastNight], activityBlocks: found)
        XCTAssertEqual(join.nights, [lastNight], "a session of another night is no anchor")
        XCTAssertEqual(join.aloneBlocks, 2)
    }

    // MARK: 73f: no lead-in; 73g: a block never costs a night

    /// A block in place, as `activityBlocks` builds it: one `.inBed`, asleep all of it, no score, UTC.
    private func block(_ from: Int, _ to: Int) -> Selection.Night {
        Selection.Night(segments: [SleepSegment(start: at(from), end: at(to), stage: .inBed),
                                   SleepSegment(start: at(from), end: at(to), stage: Selection.activityBlockStage)],
                        window: span(from, to), strapScore: nil, recordedTimeZone: utcZone)
    }

    /// Decision 73f: a doze 22:00–22:40, 20 minutes before the record (23:00–02:00), would join by 28f,
    /// but it lies before the session's in-bed start: never joined, counted alone. Once the night is
    /// written, later syncs no longer fetch it, so a lead-in would be deleted by the next extension.
    func testALeadInBlockBeforeTheSessionIsNeverJoined() {
        let minutes = asleep(1320, 1360) + up(1360, 1380) + asleep(1380, 1560) + up(1560, 1600)
        let found = blocks(minutes, sessions: [sleepA])
        XCTAssertEqual(found.map(\.window), [span(1320, 1360)], "it is a block")
        let join = Selection.nights(sessions: [sleepA], activityBlocks: found)
        XCTAssertEqual(join.nights, [sleepA])
        XCTAssertEqual(join.joinedBlocks, 0)
        XCTAssertEqual(join.aloneBlocks, 1)

        let later = Selection.nights(sessions: [sleepA], activityBlocks: found + [block(1770, 1860)])
        XCTAssertEqual(later.nights.map(\.window), [span(1380, 1860)], "a later block still joins; the lead-in doesn't")
        XCTAssertEqual(later.joinedBlocks, 1)
        XCTAssertEqual(later.aloneBlocks, 1)
    }

    /// Decision 73g, the review's lie-in: record 23:00–07:00, sleep minutes 07:30–12:10. Joined by 28f, the
    /// night would end after noon and be no overnight sleep, so nothing would be stored. The record's own
    /// night is kept and the block is counted alone.
    func testALateMorningBlockPastTheWakeWindowNeverCostsTheNight() {
        let night = session(1380, 1860)
        let found = blocks(asleep(1380, 1860) + up(1860, 1890) + asleep(1890, 2170) + up(2170, 2220),
                           sessions: [night], now: at(2220))
        XCTAssertEqual(found.map(\.window), [span(1890, 2170)])
        XCTAssertFalse(Selection.isOvernightSleep(Selection.stitch([night] + found).first!), "joined, it is no overnight sleep")
        let join = Selection.nights(sessions: [night], activityBlocks: found)
        XCTAssertEqual(join.nights, [night])
        XCTAssertEqual(join.joinedBlocks, 0)
        XCTAssertEqual(join.aloneBlocks, 1)
    }

    /// Decisions 73h/73i: a separate evening session (20:00–21:00), a block 21:30–22:30, the night
    /// 23:00–07:00. Stitched, all three would be one night, with the block between two of its sessions,
    /// before the last one's in-bed end, so 73i leaves it alone. The evening session and the night then
    /// stitch exactly as without the block (more than 60 min apart, and the evening session is no
    /// overnight sleep). Without the evening session the same block is a lead-in and is alone too.
    func testABlockBetweenAnEveningSessionAndTheNightIsAlone() {
        let evening = session(1200, 1260), night = session(1380, 1860), doze = block(1290, 1350)
        let between = Selection.nights(sessions: [evening, night], activityBlocks: [doze])
        XCTAssertEqual(between.nights, Selection.stitch([evening, night]))
        XCTAssertEqual(between.nights.map(\.window), [span(1200, 1260), span(1380, 1860)])
        XCTAssertEqual(between.joinedBlocks, 0)
        XCTAssertEqual(between.aloneBlocks, 1)

        let leadIn = Selection.nights(sessions: [night], activityBlocks: [doze])
        XCTAssertEqual(leadIn.nights, [night])
        XCTAssertEqual(leadIn.aloneBlocks, 1)
    }

    /// Decision 73i: a block between two fragments of one night (A1 23:00–01:00, block 01:15–02:15, A2
    /// 02:30–05:00) is alone, and the two records join by 71b exactly as without it; a block after A2
    /// joins.
    func testABlockBetweenTwoFragmentsOfOneNightIsAloneAndOneAfterTheLastJoins() {
        let a1 = session(1380, 1500), a2 = session(1590, 1740)
        let between = Selection.nights(sessions: [a1, a2], activityBlocks: [block(1515, 1575)])
        XCTAssertEqual(between.nights, Selection.stitch([a1, a2]))
        XCTAssertEqual(between.nights.map(\.window), [span(1380, 1740)])
        XCTAssertEqual(between.aloneBlocks, 1)

        let after = Selection.nights(sessions: [a1, a2], activityBlocks: [block(1515, 1575), block(1770, 1860)])
        XCTAssertEqual(after.nights.map(\.window), [span(1380, 1860)])
        XCTAssertEqual(after.nights.first?.inBedSpans, [span(1380, 1500), span(1590, 1740), span(1770, 1860)])
        XCTAssertEqual(after.joinedBlocks, 1)
        XCTAssertEqual(after.aloneBlocks, 1)
    }

    /// Decisions 73f/73g/73i as a property, over a grid of session and block placements around one night:
    /// every overnight sleep kept without blocks is covered by one kept with them, at least as wide; every
    /// block is counted once; and every joined block starts at or after the in-bed end of the LAST
    /// session of its night (73i).
    func testBlocksNeverCostOrNarrowANightOverAGridOfPlacements() {
        let sessionSpots = [(1200, 1260), (1380, 1560), (1380, 1860), (1740, 1860), (1500, 1620), (2220, 2280), (1080, 1140)]
        let blockSpots = [(1100, 1160), (1290, 1350), (1320, 1370), (1590, 1650), (1620, 1720), (1870, 1900),
                          (1890, 2170), (2300, 2360), (1260, 1290), (1880, 2000)]
        func overlap(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 < b.1 && b.0 < a.1 }
        func subsets(_ spots: [(Int, Int)]) -> [[(Int, Int)]] {
            var out: [[(Int, Int)]] = [[]]
            for i in spots.indices {
                out.append([spots[i]])
                for j in spots.indices where j > i && !overlap(spots[i], spots[j]) { out.append([spots[i], spots[j]]) }
            }
            return out
        }
        func holds(_ night: Selection.Night, _ sleep: Selection.Night) -> Bool {
            let start = sleep.segments.filter { $0.stage != .inBed }.map(\.start).min() ?? sleep.window.start
            return night.window.start <= start && start < night.window.end
        }
        var checked = 0
        for sessionSet in subsets(sessionSpots) {
            for blockSet in subsets(blockSpots) where !blockSet.contains(where: { b in sessionSet.contains { overlap($0, b) } }) {
                let sessions = sessionSet.map { session($0.0, $0.1) }, blocks = blockSet.map { block($0.0, $0.1) }
                let label = "sessions \(sessionSet) blocks \(blockSet)"
                let without = Selection.stitch(sessions).filter(Selection.isOvernightSleep)
                let join = Selection.nights(sessions: sessions, activityBlocks: blocks)
                let with = join.nights.filter(Selection.isOvernightSleep)
                for night in without {
                    XCTAssertTrue(with.contains { $0.window.start <= night.window.start && night.window.end <= $0.window.end },
                                  "\(label): \(night.window) is covered")
                }
                XCTAssertEqual(join.joinedBlocks + join.aloneBlocks, blocks.count, label)
                for night in join.nights {
                    for block in blocks where night.segments.contains(block.segments[1]) {
                        let lastEnd = sessions.filter { holds(night, $0) }.map(\.window.end).max()
                        XCTAssertTrue(lastEnd.map { $0 <= block.window.start } ?? false,
                                      "\(label): \(block.window) is after the last session of its night")
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 500)
    }
}

// MARK: - Decision 76a: the blocks that stood alone are handed back

extension HelioActivitySleepTests {
    /// A block in place, as `activityBlocks` builds it.
    private func placed(_ from: Int, _ to: Int) -> HelioSleepSelection.Night {
        HelioSleepSelection.Night(segments: [SleepSegment(start: at(from), end: at(to), stage: .inBed),
                                             SleepSegment(start: at(from), end: at(to), stage: HelioSleepSelection.activityBlockStage)],
                                  window: span(from, to), strapScore: nil, recordedTimeZone: utcZone)
    }

    /// Every shape 73c/73f/73g/73i leaves alone comes back in `aloneNights`, exactly as built and oldest
    /// first; a joined block never does, and the counts keep their meaning.
    func testTheBlocksThatStandAloneAreHandedBackAndTheJoinedOnesAreNot() {
        let night = session(1380, 1860)
        let cases: [(String, [HelioSleepSelection.Night], [HelioSleepSelection.Night], [Int])] = [
            ("a daytime block", [night], [placed(2220, 2280)], [0]),
            ("an evening doze", [night], [placed(1200, 1260)], [0]),
            ("no session record", [], [placed(1380, 1560), placed(1600, 1800)], [0, 1]),
            ("a lead-in, then a later block that joins", [sleepA], [placed(1320, 1360), placed(1770, 1860)], [0]),
            ("a lie-in that would cost the night", [night], [placed(1890, 2170)], [0]),
            ("between two fragments, then one after", [session(1380, 1500), session(1590, 1740)],
             [placed(1515, 1575), placed(1770, 1860)], [0]),
            ("one that joins", [sleepA], [placed(1770, 1860)], []),
        ]
        for (label, sessions, blocks, aloneIndices) in cases {
            let join = HelioSleepSelection.nights(sessions: sessions, activityBlocks: blocks)
            XCTAssertEqual(join.aloneNights, aloneIndices.map { blocks[$0] }, label)
            XCTAssertEqual(join.aloneBlocks, join.aloneNights.count, label)
            XCTAssertEqual(join.joinedBlocks + join.aloneBlocks, blocks.count, label)
        }
        XCTAssertEqual(HelioSleepSelection.nights(sessions: [night], activityBlocks: []).aloneNights, [], "no blocks, none handed back")
    }

    /// Over the same grid of placements as the 73f/73g property: the handed-back blocks are exactly the
    /// ones no night holds, and no handed-back block is part of any night.
    func testTheHandedBackBlocksAreExactlyTheOnesNoNightHoldsOverAGridOfPlacements() {
        let sessionSpots = [(1200, 1260), (1380, 1560), (1380, 1860), (1740, 1860), (1500, 1620), (2220, 2280), (1080, 1140)]
        let blockSpots = [(1100, 1160), (1290, 1350), (1320, 1370), (1590, 1650), (1620, 1720), (1870, 1900),
                          (1890, 2170), (2300, 2360), (1260, 1290), (1880, 2000)]
        func overlap(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 < b.1 && b.0 < a.1 }
        var checked = 0
        for s in sessionSpots.indices {
            for (i, a) in blockSpots.enumerated() {
                for b in blockSpots[i...] where !overlap(a, b) || a == b {
                    let spots = a == b ? [a] : [a, b]
                    guard !spots.contains(where: { overlap($0, sessionSpots[s]) }) else { continue }
                    let blocks = spots.map { placed($0.0, $0.1) }
                    let join = HelioSleepSelection.nights(sessions: [session(sessionSpots[s].0, sessionSpots[s].1)], activityBlocks: blocks)
                    let held = blocks.filter { block in join.nights.contains { $0.segments.contains(block.segments[1]) } }
                    XCTAssertEqual(join.aloneNights, blocks.filter { !held.contains($0) }, "\(sessionSpots[s]) \(spots)")
                    XCTAssertEqual(join.aloneBlocks, join.aloneNights.count)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }
}

// MARK: - Decision 76h: a nap waits while sleep follows it within the hour

extension HelioActivitySleepTests {
    /// A kind-sleep minute from the nap's end up to 60 min after it holds the nap; one 61 min after,
    /// a non-sleep minute, or a sleep minute inside or before the nap doesn't.
    func testOnlyASleepMinuteWithinTheHourAfterTheNapHoldsIt() {
        let nap = span(780, 840)
        XCTAssertTrue(HelioSleepSelection.sleepFollowsWithinNapGap(nap, in: asleep(840, 841)), "right at the end")
        XCTAssertTrue(HelioSleepSelection.sleepFollowsWithinNapGap(nap, in: up(840, 900) + asleep(900, 901)), "60 min after")
        XCTAssertFalse(HelioSleepSelection.sleepFollowsWithinNapGap(nap, in: up(840, 901) + asleep(901, 960)), "61 min after")
        XCTAssertFalse(HelioSleepSelection.sleepFollowsWithinNapGap(nap, in: asleep(700, 840) + up(840, 960)), "inside or before")
        XCTAssertFalse(HelioSleepSelection.sleepFollowsWithinNapGap(nap, in: []))
    }
}
