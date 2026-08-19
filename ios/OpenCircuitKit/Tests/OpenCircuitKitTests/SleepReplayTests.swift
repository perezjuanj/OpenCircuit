// COMMAND-LINE ENTRY POINTS for the sleep replay harness (see SleepReplay.swift for the
// production-parity contract this rests on).
//
//   # measure every night in the corpus and print the table
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_CORPUS=<corpus-dir> swift test --filter SleepReplayMeasureTests 2>&1 | sed -n '/SLEEP REPLAY/,$p'
//
//   # the fidelity proof: assert the harness reproduces what the app actually stored
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_FIDELITY_CORPUS=<fidelity-dir> swift test --filter SleepReplayFidelityTests
//
//   # how much do the two inputs a .b64 cannot carry actually matter?
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_FIDELITY_CORPUS=<fidelity-dir> swift test --filter SleepReplayInputSensitivityTests
//
// With neither variable set every test SKIPS with a printed reason, so `swift test` stays green on
// a machine that holds no tester health data. Nothing here reads or writes the repo.

import XCTest
@testable import OpenCircuitKit

// MARK: - Measure

final class SleepReplayMeasureTests: XCTestCase {

    func testMeasureCorpus() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_CORPUS") else {
            print("[replay] OC_SLEEP_CORPUS unset — skipping. Point it at a corpus directory.")
            return
        }
        let nights = try SleepReplay.loadManifest(at: dir)
        var results: [ReplayResult] = []
        var failures: [String] = []
        var summaryOnly = 0
        for n in nights {
            do { results.append(try SleepReplay.measure(n, in: dir)) }
            catch SleepReplay.ReplayError.noRecords { summaryOnly += 1 }
            catch { failures.append("\(n.id): \(error)") }
        }

        print("\n=== SLEEP REPLAY — \(dir.path)")
        print("=== \(nights.count) manifest rows: \(results.count) replayable, "
              + "\(summaryOnly) summary-only (no records), \(failures.count) failed to load\n")
        print(SleepReplay.header())
        for r in results.sorted(by: { $0.id < $1.id }) { print(SleepReplay.row(r)) }
        print("\n" + SleepReplay.legend())

        // Aggregates over the labelled subset only, stated as what they are.
        let onsetErrs = results.compactMap(\.labelOnsetErrorMin)
        let wakeErrs = results.compactMap(\.labelWakeErrorMin)
        func stats(_ v: [Int], _ name: String) -> String {
            guard !v.isEmpty else { return "\(name): no labelled nights" }
            let abs = v.map { Swift.abs($0) }.sorted()
            let mae = Double(abs.reduce(0, +)) / Double(abs.count)
            return String(format: "%@: n=%d  median|err|=%d min  MAE=%.1f min  worst=%d min  bias=%+.1f min",
                          name, v.count, abs[abs.count / 2], mae, abs.last ?? 0,
                          Double(v.reduce(0, +)) / Double(v.count))
        }
        print("\n" + stats(onsetErrs, "onset vs label"))
        print(stats(wakeErrs, "wake  vs label"))
        print("⚠️  Labelled nights are the nights someone thought were WRONG. These are "
              + "\"how wrong when wrong\", never overall accuracy.")

        let staged = results.filter { $0.inBedStart != nil }
        print("\nstaged a night: \(staged.count)/\(results.count)   "
              + "returned nothing: \(results.count - staged.count)")
        if !failures.isEmpty {
            print("\nLOAD FAILURES (\(failures.count)):")
            for f in failures { print("  " + f) }
        }
        // A corpus that stages nothing at all means the harness is broken, not the data.
        XCTAssertFalse(results.isEmpty, "the corpus produced no measurable nights at all")
    }
}

// MARK: - Fidelity

/// THE PROOF. A harness that does not reproduce production is the most dangerous artifact in this
/// campaign, so this asserts — per night, per field — that replaying the stored bytes returns what
/// the app actually persisted.
///
/// Only fields the manifest explicitly lists in `stored.fidelity` are asserted. A row whose input
/// provably differs from what staging saw (a later archive snapshot, a hole the app did not have)
/// declares an EMPTY list and is reported, never asserted — see each row's `inputCaveat`.
final class SleepReplayFidelityTests: XCTestCase {

    /// The stored window is compared at the manifest row's own precision: a diagnostics `.txt`
    /// prints HH:mm, so a 60 s row can only ever be asserted to the minute.
    func testReproducesStoredWindowAndMinutes() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_FIDELITY_CORPUS") else {
            print("[replay] OC_SLEEP_FIDELITY_CORPUS unset — skipping the fidelity proof.")
            return
        }
        let nights = try SleepReplay.loadManifest(at: dir)
        var asserted = 0
        print("\n=== SLEEP REPLAY FIDELITY — \(dir.path)\n")

        for n in nights {
            let r = try SleepReplay.measure(n, in: dir)
            let tz = n.timeZone
            let tol = Double(n.stored.windowPrecisionSec)
            print("--- \(n.id)   build \(n.appBuild ?? "?")  \(n.ring ?? "")  "
                  + "\(n.inputProvenance ?? "?")  records \(r.recordsLoaded)"
                  + " → after 30 h retention \(r.recordsAfterRetention) → night-scoped \(r.nightScopedRecords)")
            print("    parity: \(n.codeParity ?? "unstated")")
            if n.stored.fidelity.isEmpty {
                print("    NOT A FIDELITY TARGET — \(n.inputCaveat ?? "no reason recorded")")
            }
            func line(_ name: String, _ got: String, _ want: String, _ ok: Bool?) {
                let mark = ok == nil ? "   " : (ok! ? " ✓ " : " ✗ ")
                print("   \(mark)\(name.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                      + "harness \(got.padding(toLength: 20, withPad: " ", startingAt: 0)) stored \(want)")
            }

            // --- window
            for (field, got, want) in [("inBedStart", r.inBedStart, n.stored.inBedStart),
                                       ("inBedEnd", r.inBedEnd, n.stored.inBedEnd)] {
                guard let want else { continue }
                let assertThis = n.stored.fidelity.contains(field)
                let ok = got.map { abs($0.timeIntervalSince(want)) <= tol }
                line(field, SleepReplay.clock(got, tz), SleepReplay.clock(want, tz),
                     assertThis ? (ok ?? false) : nil)
                guard assertThis else { continue }
                asserted += 1
                let g = try XCTUnwrap(got, "\(n.id): staging returned NO \(field) at all")
                XCTAssertEqual(g.timeIntervalSince1970, want.timeIntervalSince1970, accuracy: tol,
                               "\(n.id).\(field): harness \(SleepReplay.clock(g, tz)) "
                               + "vs stored \(SleepReplay.clock(want, tz)) "
                               + "(Δ \(Int((g.timeIntervalSince(want) / 60).rounded())) min). "
                               + "The harness does NOT reproduce production for this night — "
                               + "no measurement taken with it can be trusted until this is explained.")
            }

            // --- minutes
            for (field, got, want) in [("asleepMin", r.asleepMin, n.stored.asleepMin),
                                       ("awakeMin", r.awakeMin, n.stored.awakeMin),
                                       ("deepMin", r.deepMin, n.stored.deepMin),
                                       ("remMin", r.remMin, n.stored.remMin),
                                       ("lightMin", r.lightMin, n.stored.lightMin)] {
                guard let want else { continue }
                let assertThis = n.stored.fidelity.contains(field)
                line(field, String(got), String(want), assertThis ? (got == want) : nil)
                guard assertThis else { continue }
                asserted += 1
                XCTAssertEqual(got, want,
                               "\(n.id).\(field): harness \(got) vs stored \(want) "
                               + "(Δ \(got - want) min)")
            }
            if let note = n.stored.minutesNote, n.stored.asleepMin == nil {
                print("        (minutes: \(note))")
            }

            // --- the EDIT overlay. A night the user edited stores minutes that came out of
            // SleepEdit.recompute, not out of staging. Where the edit's anchors are known, the
            // harness must still reproduce them END TO END: base segments -> SleepEdit -> stored.
            if let e = n.stored.edit {
                let times = SleepEdit.Times(inBedStart: e.inBedStart, sleepOnset: e.sleepOnset,
                                            sleepWake: e.sleepWake)
                let edited = SleepEdit.recompute(baseSegments: r.segments, times: times)
                let m = SleepStaging.summary(edited).minutes
                print("    edit overlay: SleepEdit.recompute(bed \(SleepReplay.clock(e.inBedStart, tz)), "
                      + "onset \(SleepReplay.clock(e.sleepOnset, tz)), "
                      + "wake \(SleepReplay.clock(e.sleepWake, tz)))")
                print("       onset provenance: \(e.onsetProvenance ?? "unstated")")
                for (field, got, want) in [("asleepMin", m.asleep, e.asleepMin),
                                           ("awakeMin", m.awake, e.awakeMin),
                                           ("deepMin", m.deep, e.deepMin),
                                           ("remMin", m.rem, e.remMin),
                                           ("lightMin", m.light, e.lightMin)] {
                    guard let want else { continue }
                    let assertThis = e.fidelity.contains(field)
                    line("edit." + field, String(got), String(want), assertThis ? (got == want) : nil)
                    guard assertThis else { continue }
                    asserted += 1
                    XCTAssertEqual(got, want,
                                   "\(n.id).edit.\(field): harness \(got) vs stored \(want) "
                                   + "(Δ \(got - want) min)")
                }
            }
            print("")
        }
        XCTAssertGreaterThan(asserted, 0,
                             "no manifest row declared any fidelity target — the proof is vacuous")
        print("=== asserted \(asserted) field(s) across \(nights.count) corpus night(s)")
    }
}

// MARK: - Input sensitivity

/// The harness cannot reconstruct two of production's inputs exactly (`nightTemperatureLog` and
/// the `PersonalBaseline` deep HR). Rather than assume they are inert, measure it: if a sweep moves
/// a number, that number carries an error bar and every later claim must say so.
final class SleepReplayInputSensitivityTests: XCTestCase {

    func testTemperatureAndBaselineSensitivity() throws {
        guard let dir = SleepReplay.dir("OC_SLEEP_FIDELITY_CORPUS") else {
            print("[replay] OC_SLEEP_FIDELITY_CORPUS unset — skipping the sensitivity sweep.")
            return
        }
        let nights = try SleepReplay.loadManifest(at: dir)
        print("\n=== INPUT SENSITIVITY — the two inputs a .b64 file cannot carry\n")

        for n in nights {
            let manifestTemps = n.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) }
            let withTemps = try SleepReplay.measure(n, in: dir, temperaturesOverride: manifestTemps)
            let noTemps = try SleepReplay.measure(n, in: dir, temperaturesOverride: [])
            print("--- \(n.id)  (\(manifestTemps.count) reconstructed temperature samples)")
            print("    wearTemperatureSamples()=manifest : " + SleepReplay.row(withTemps))
            print("    wearTemperatureSamples()=[]       : " + SleepReplay.row(noTemps))
            print("    temperature-inert: "
                  + String(same(withTemps, noTemps)))

            var lines: [String] = []
            for b in [nil, 45.0, 50.0, 55.0, 60.0, 65.0, 70.0] as [Double?] {
                let r = try SleepReplay.measure(n, in: dir, deepHRBaselineOverride: .some(b))
                lines.append("    deepHRBaseline=\(b.map { String(format: "%.0f", $0) } ?? "nil")".padding(
                    toLength: 28, withPad: " ", startingAt: 0) + ": " + SleepReplay.row(r))
            }
            for l in lines { print(l) }
            print("")
        }
    }

    private func same(_ a: ReplayResult, _ b: ReplayResult) -> Bool {
        a.inBedStart == b.inBedStart && a.inBedEnd == b.inBedEnd
            && a.onset == b.onset && a.wake == b.wake
            && a.asleepMin == b.asleepMin && a.awakeMin == b.awakeMin
            && a.deepMin == b.deepMin && a.remMin == b.remMin && a.lightMin == b.lightMin
    }
}
