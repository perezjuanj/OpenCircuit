import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// SYNTHETIC-ONLY sweep for decision 96 (#404) through the production path: `runRestingHRFlush` (the
/// body of `flushRestingHR`) with an in-memory Health store, flushed every 30 min across two whole
/// local days, the night reaching Health at different times (or never) and device records arriving
/// at different times, in a plain calendar and across both DST changes. After EVERY flush:
/// - at most one live sample from this app per day;
/// - no sample for a day without a mirrored night before its cutoff, and no watermark on a day
///   before its cutoff;
/// - a mirrored day with a covered value has a live sample of that whole bpm before its cutoff;
/// - at its finalizing flush a day's live sample is the covered value then (whole bpm), and it never
///   changes afterwards.
@MainActor
final class RestingHREarlyWriteSweepTests: XCTestCase {

    private static let finalizationDelay: TimeInterval = 12 * 3600

    private struct Record { let stamped: Date; let bpm: Int; let arrives: Date }

    private final class FakeHealth {
        var live: [UUID: (day: Date, bpm: Double)] = [:]
        var saves = 0
        func save(_ bpm: Double, _ day: Date) -> UUID {
            let id = UUID()
            live[id] = (day, bpm)
            saves += 1
            return id
        }
        func delete(_ id: UUID) { live[id] = nil }
        func samples(on day: Date) -> [(id: UUID, bpm: Double)] {
            live.filter { $0.value.day == day }.map { ($0.key, $0.value.bpm) }
        }
    }

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func local(_ cal: Calendar, _ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Runs one sweep over `first` and the day after it. `mirrorAt` is the local time each day's night
    /// reaches Health (nil: never); `records` builds each day's device records.
    private func sweep(_ zone: String, first: DateComponents, mirrorAt: (hour: Int, minute: Int)?,
                       records: (Calendar, Date) -> [Record],
                       file: StaticString = #filePath, line: UInt = #line) async {
        let cal = calendar(zone)
        let d1 = cal.date(from: first)!
        let days = [d1, cal.date(byAdding: .day, value: 1, to: d1)!]
        let end = cal.date(byAdding: .day, value: 2, to: d1)!
        let label = "\(zone) \(first.month!)-\(first.day!) mirror \(mirrorAt.map { "\($0.hour):\($0.minute)" } ?? "never")"

        // Each night: asleep 23:00 → 07:00, readings every 5 min drifting down (so the sleep mean
        // keeps moving by whole bpm as the night fills in); awake 72 bpm 07:00 → 23:00.
        var hr: [HRSample] = []
        var nights: [(key: Date, segment: SleepSegment)] = []
        for (n, day) in days.enumerated() {
            let bed = local(cal, cal.date(byAdding: .day, value: -1, to: day)!, 23)
            let wake = local(cal, day, 7)
            nights.append((day, SleepSegment(start: bed, end: wake, stage: .asleepCore)))
            var t = bed, i = 0
            while t < wake { hr.append(HRSample(bpm: 60 + 2 * n - i / 8, start: t)); t += 300; i += 1 }
            let bedNext = local(cal, day, 23)
            while t < bedNext { hr.append(HRSample(bpm: 72, start: t)); t += 300 }
        }
        let allRecords = days.flatMap { records(cal, $0) }
        let mirrorTimes = Dictionary(uniqueKeysWithValues: days.map { d in
            (d, mirrorAt.map { local(cal, d, $0.hour, $0.minute) })
        })

        let health = FakeHealth()
        var state = HealthKitWriter.RestingHRWriteState(watermark: cal.date(byAdding: .day, value: -1, to: d1)!)
        var finalValue: [Date: UUID] = [:]
        var now = cal.startOfDay(for: d1)
        var flushes = 0, earlyWrites = 0
        while now < end {
            let mirrored = Set(days.filter { d in mirrorTimes[d]!.map { $0 <= now } ?? false })
            // The staged night grows until wake; it is passed once it's mirrored.
            let sleep = nights.filter { mirrored.contains($0.key) }.map {
                SleepSegment(start: $0.segment.start, end: min($0.segment.end, now), stage: .asleepCore)
            }.filter { $0.end > $0.start }
            let hrNow = hr.filter { $0.start <= now }
            let reported = allRecords.filter { $0.arrives <= now }.map { HRSample(bpm: $0.bpm, start: $0.stamped) }
            let before = state
            let covered = Dictionary(
                HealthKitWriter.restingHRWritePlan(hr: hrNow, reported: reported, sleepSegments: sleep,
                                                   lastWritten: .distantPast, now: now.addingTimeInterval(Self.finalizationDelay),
                                                   calendar: cal).map { ($0.day, $0.bpm) },
                uniquingKeysWith: { a, _ in a })
            let outcome = await HealthKitWriter.runRestingHRFlush(
                hr: hrNow, reported: reported, sleepSegments: sleep, state: state, now: now, calendar: cal,
                mirroredNights: mirrored,
                save: { health.save($0, $1) }, delete: { health.delete($0) }, persist: { _ in })
            XCTAssertFalse(outcome.failed, "\(label) at \(now)", file: file, line: line)
            state = outcome.state
            flushes += 1

            let cutoff = now.addingTimeInterval(-Self.finalizationDelay)
            XCTAssertLessThanOrEqual(state.watermark, max(before.watermark, cutoff),
                                     "\(label): the watermark only moves onto a finalized day (\(now))", file: file, line: line)
            for day in days {
                let samples = health.samples(on: day)
                XCTAssertLessThanOrEqual(samples.count, 1, "\(label): one sample for \(day) at \(now)", file: file, line: line)
                let finalized = day <= cutoff
                if !finalized {
                    if !mirrored.contains(day) {
                        XCTAssertTrue(samples.isEmpty, "\(label): nothing before the cutoff without a night (\(day), \(now))",
                                      file: file, line: line)
                    } else if day == cal.startOfDay(for: now), let bpm = covered[day] ?? nil {
                        XCTAssertEqual(samples.map { HealthKitWriter.wholeBpm($0.bpm) }, [HealthKitWriter.wholeBpm(bpm)],
                                       "\(label): the provisional sample tracks the day (\(day), \(now))", file: file, line: line)
                        earlyWrites += 1
                    }
                } else if let id = finalValue[day] {
                    XCTAssertEqual(samples.map(\.id), [id], "\(label): a final day never changes (\(day), \(now))",
                                   file: file, line: line)
                } else if before.watermark < day {
                    // This flush finalized the day.
                    if let bpm = covered[day] ?? nil {
                        XCTAssertEqual(samples.map { HealthKitWriter.wholeBpm($0.bpm) }, [HealthKitWriter.wholeBpm(bpm)],
                                       "\(label): the final sample is the day's value (\(day), \(now))", file: file, line: line)
                        XCTAssertEqual(state.watermark, day, "\(label): finalized onto \(day)", file: file, line: line)
                    }
                    XCTAssertNotEqual(state.provisional?.day, day, "\(label): the record is cleared", file: file, line: line)
                    if let id = samples.first?.id { finalValue[day] = id }
                }
            }
            now += 1800
        }
        XCTAssertGreaterThanOrEqual(flushes, 92, label, file: file, line: line)
        XCTAssertEqual(Set(finalValue.keys), Set(days), "\(label): both days end final in Health", file: file, line: line)
        XCTAssertNil(state.provisional, label, file: file, line: line)
        if mirrorAt == nil || mirrorAt!.hour >= 12 {
            XCTAssertEqual(earlyWrites, 0, label, file: file, line: line)
        } else {
            XCTAssertGreaterThan(earlyWrites, 0, "\(label): the early write happened", file: file, line: line)
        }
    }

    private static let mirrorTimes: [(hour: Int, minute: Int)?] = [(3, 0), (6, 30), (11, 30), nil]

    /// No device records: the derivation (sleep mean once the night is in, else lowest sustained).
    private func derivedOnly(_ cal: Calendar, _ day: Date) -> [Record] { [] }

    /// Device records: one stamped the evening before (files to this day), two revisions overnight
    /// synced in the morning, and one revision synced after the cutoff (never rewrites a final day).
    private func strapRecords(_ cal: Calendar, _ day: Date) -> [Record] {
        let eve = cal.date(byAdding: .day, value: -1, to: day)!
        return [
            Record(stamped: local(cal, eve, 22), bpm: 61, arrives: local(cal, eve, 22, 30)),
            Record(stamped: local(cal, day, 4), bpm: 58, arrives: local(cal, day, 7, 30)),
            Record(stamped: local(cal, day, 6), bpm: 56, arrives: local(cal, day, 9)),
            Record(stamped: local(cal, day, 10), bpm: 53, arrives: local(cal, day, 13)),
        ]
    }

    private func runAll(_ zone: String, _ first: DateComponents) async {
        for mirror in Self.mirrorTimes {
            await sweep(zone, first: first, mirrorAt: mirror, records: derivedOnly)
            await sweep(zone, first: first, mirrorAt: mirror, records: strapRecords)
        }
    }

    func testEveryHalfHourAcrossTwoOrdinaryDays() async {
        await runAll("America/New_York", DateComponents(year: 2026, month: 9, day: 29))
        await runAll("UTC", DateComponents(year: 2026, month: 9, day: 29))
    }

    func testEveryHalfHourAcrossTheSpringForwardChange() async {
        await runAll("America/New_York", DateComponents(year: 2026, month: 3, day: 8))
    }

    func testEveryHalfHourAcrossTheFallBackChange() async {
        await runAll("America/New_York", DateComponents(year: 2026, month: 11, day: 1))
    }
}
