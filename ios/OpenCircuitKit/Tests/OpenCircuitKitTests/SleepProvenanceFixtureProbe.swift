// SCAFFOLD — prints the geometry needed to hand-write the committed fixture. Not a test of
// anything; it exists so the fixture's numbers are extracted from real bytes rather than typed
// from memory. Delete-safe.

import XCTest
@testable import OpenCircuitKit

final class SleepProvenanceFixtureProbe: XCTestCase {

    func testPrintGeometry() throws {
        let dir = try SleepReplay.requireCorpus(
            "OC_SLEEP_PROVENANCE_CORPUS",
            purpose: "the scaffold that re-derives the committed provenance fixture's geometry from real bytes",
            consequence: "The fixture cannot be regenerated on this run; the committed numbers stand.")
        let nights = try SleepReplay.loadManifest(at: dir)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        for id in ["R2_2026-08-18", "R2_2026-08-17"] {
            guard let n = nights.first(where: { $0.id == id }) else { continue }
            iso.timeZone = n.timeZone
            let records = try SleepReplay.loadRecords(n, in: dir)
            let cov = MeasuredCoverage(records: records)
            print("\n### \(id)  tz=\(n.timeZone.identifier)  records=\(records.count)")
            print("merged coverage intervals (\(cov.intervals.count)):")
            for iv in cov.intervals {
                print("   \(iso.string(from: iv.lowerBound)) -> \(iso.string(from: iv.upperBound))"
                      + "  (\(Int(iv.upperBound.timeIntervalSince(iv.lowerBound))) s)"
                      + "  epoch1970 \(Int(iv.lowerBound.timeIntervalSince1970)) .. "
                      + "\(Int(iv.upperBound.timeIntervalSince1970))")
            }
            try SleepReplay.withTimeZone(n.timeZone, at: records.first?.date() ?? Date()) {
                let base = SleepReplay.stage(
                    records: records,
                    temperatures: n.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) },
                    deepHRBaseline: n.deepHRBaselineBPM).segments
                print("staged base segments: \(base.count)")
                let sleep = SleepStaging.sleepWindow(base)
                print("   staged sleep window: \(sleep.map { iso.string(from: $0.onset) } ?? "nil")"
                      + " -> \(sleep.map { iso.string(from: $0.wake) } ?? "nil")")
                let m = SleepStaging.summary(base).minutes
                print("   staged minutes inBed=\(m.inBed) asleep=\(m.asleep) awake=\(m.awake) "
                      + "deep=\(m.deep) rem=\(m.rem) light=\(m.light)")
                for s in base where s.stage != .inBed {
                    print("   SEG \(iso.string(from: s.start)) -> \(iso.string(from: s.end)) \(s.stage) "
                          + "| epoch1970 \(Int(s.start.timeIntervalSince1970)) "
                          + "\(Int(s.end.timeIntervalSince1970))")
                }
            }
        }
    }
}
