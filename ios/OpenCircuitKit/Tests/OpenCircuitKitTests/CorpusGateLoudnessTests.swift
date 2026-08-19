// THE GATE ON THE GATE.
//
// The sleep replay harness is becoming the house regression gate for every staging change: a PR
// claims "byte-identical, hash unchanged" and the corpus-gated tests are what back that claim. So
// the failure mode that matters most is not a wrong number — it is a run that measured NOTHING and
// said "passed".
//
// That is exactly what shipped. Every corpus-gated entry point opened with
//
//     guard let dir = SleepReplay.dir("OC_SLEEP_…") else { print("unset — skipping"); return }
//
// XCTest scores that early `return` as a PASS. Reproduced on this branch before the fix, with the
// env var unset and the command straight out of docs/SLEEP_REPLAY_HARNESS.md §1:
//
//     Test Case '-[…SleepReplayFidelityTests testReproducesStoredWindowAndMinutes]' passed (0.001 s)
//     Executed 1 test, with 0 failures (0 unexpected)
//     [replay] OC_SLEEP_FIDELITY_CORPUS unset — skipping the fidelity proof.
//
// Note where the "skipping" line lands: AFTER the green summary, in a different stream, four lines
// below the word `passed`. Nobody reads that. All four entry points behaved this way, not just the
// fidelity proof.
//
// This file is the standing guard. It has two halves:
//   1. BEHAVIOUR — `SleepReplay.requireCorpus` throws `XCTSkip` when unset (XCTest then reports
//      "skipped", which is not a pass) and FAILS when the variable is set to a bad path.
//   2. SOURCE AUDIT — no test in this target may read a corpus environment variable except through
//      that gate, and the fidelity proof must keep its own zero-assertion tripwire. This half is
//      what stops the pattern coming back in a test that does not exist yet.
//
// Both halves run with no corpus present, on any machine, forever.

import XCTest
@testable import OpenCircuitKit

final class CorpusGateLoudnessTests: XCTestCase {

    // MARK: - 1. Behaviour of the gate itself

    /// The defect, inverted: an unset corpus variable must produce an `XCTSkip`, never a value and
    /// never a silent fallthrough.
    func testUnsetCorpusVariableThrowsXCTSkip() {
        do {
            _ = try SleepReplay.requireCorpus("OC_SLEEP_GATE_SELFTEST",
                                              purpose: "the gate self-test",
                                              environment: [:])
            XCTFail("requireCorpus returned for an UNSET variable — a corpus-gated test would now "
                    + "run on nothing and XCTest would report it as passed. This is the exact "
                    + "defect this file exists to prevent.")
        } catch let skip as XCTSkip {
            // XCTSkip is what makes the run report "skipped" instead of "passed".
            let reason = skip.message ?? ""
            XCTAssertTrue(reason.contains("OC_SLEEP_GATE_SELFTEST"),
                          "the skip reason must name the variable that was unset; got: \(reason)")
            XCTAssertTrue(reason.contains("NOTHING WAS MEASURED"),
                          "the skip reason must say plainly that nothing was measured; got: \(reason)")
        } catch {
            XCTFail("expected XCTSkip, got \(error)")
        }
    }

    /// An exported-but-empty variable (`OC_SLEEP_CORPUS= swift test`) is the same as unset.
    func testEmptyCorpusVariableThrowsXCTSkip() {
        do {
            _ = try SleepReplay.requireCorpus("OC_SLEEP_GATE_SELFTEST",
                                              purpose: "the gate self-test",
                                              environment: ["OC_SLEEP_GATE_SELFTEST": ""])
            XCTFail("an empty corpus variable must skip, not resolve to a directory")
        } catch is XCTSkip {
        } catch {
            XCTFail("expected XCTSkip, got \(error)")
        }
    }

    /// Set to a real directory ⇒ the gate gets out of the way. Without this the "fix" could be
    /// "always skip", which would disable the harness rather than harden it.
    func testSetVariableResolvesToTheDirectory() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("oc-corpus-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let got = try SleepReplay.requireCorpus("OC_SLEEP_GATE_SELFTEST",
                                                purpose: "the gate self-test",
                                                environment: ["OC_SLEEP_GATE_SELFTEST": tmp.path])
        XCTAssertEqual(got.standardizedFileURL.path, tmp.standardizedFileURL.path)
    }

    /// A typo'd path must FAIL, not skip. The variable being set means someone intended to measure
    /// something; skipping there would hand them a green run for a corpus that was never opened.
    func testSetButMissingDirectoryFailsRatherThanSkipping() {
        let missing = NSTemporaryDirectory() + "/oc-corpus-gate-does-not-exist-\(UUID().uuidString)"
        do {
            _ = try SleepReplay.requireCorpus("OC_SLEEP_GATE_SELFTEST",
                                              purpose: "the gate self-test",
                                              environment: ["OC_SLEEP_GATE_SELFTEST": missing])
            XCTFail("a corpus variable pointing at a nonexistent path must fail the test")
        } catch is XCTSkip {
            XCTFail("a SET-but-wrong path was treated as 'no corpus present' and skipped — a typo in "
                    + "the path would then read as a clean run")
        } catch let e as SleepReplay.ReplayError {
            XCTAssertTrue("\(e)".contains("OC_SLEEP_GATE_SELFTEST"), "\(e)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// A file is not a corpus.
    func testCorpusVariablePointingAtAFileFails() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("oc-corpus-gate-\(UUID().uuidString).txt")
        try Data("not a corpus".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }

        XCTAssertThrowsError(try SleepReplay.requireCorpus("OC_SLEEP_GATE_SELFTEST",
                                                           purpose: "the gate self-test",
                                                           environment: ["OC_SLEEP_GATE_SELFTEST": f.path])) {
            XCTAssertFalse($0 is XCTSkip, "pointing the corpus variable at a FILE must fail, not skip")
        }
    }

    // MARK: - 2. Source audit — the pattern cannot come back

    /// Every `.swift` in this test target, read from disk at run time.
    private func loadTestTargetSources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let all = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        let swift = all.filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(swift.count, 50,
                             "found only \(swift.count) sources under \(dir.path) — this audit reads "
                             + "the test target through #filePath; if the files moved, FIX THE AUDIT, "
                             + "do not let it pass vacuously")
        return try swift.map { (($0 as NSString).lastPathComponent,
                                try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// THE REGRESSION GUARD. A new corpus-gated test written the old way — reading `OC_SLEEP_*_CORPUS`
    /// out of the environment itself, or calling the raw lookup — can report success having asserted
    /// nothing. Fail the build instead.
    func testNoTestReadsACorpusVariableOutsideTheLoudGate() throws {
        // The gate's own implementation is the one legal reader.
        let gateFile = "SleepReplay.swift"
        // Assembled at run time so that THIS file — which has to talk about the banned pattern in
        // prose and in failure messages — is still audited like every other file instead of being
        // excluded from its own rule.
        let rawLookup = "SleepReplay" + ".dir("
        let envRead = "environment" + "["
        let corpusVar = try NSRegularExpression(pattern: #"OC_SLEEP[A-Z0-9_]*_CORPUS"#)
        var violations: [String] = []
        var filesScanned = 0

        for (name, text) in try loadTestTargetSources() where name != gateFile {
            filesScanned += 1
            for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                // Full-line comments may quote the pattern; executable lines may not.
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let ns = line as NSString
                let namesACorpusVar = corpusVar.firstMatch(
                    in: line, range: NSRange(location: 0, length: ns.length)) != nil

                if line.contains(rawLookup) {
                    violations.append("\(name):\(i + 1) calls the raw variable lookup instead of the "
                                      + "gate. Use `try SleepReplay.requireCorpus(_:purpose:)`.")
                }
                if namesACorpusVar && line.contains(envRead) {
                    violations.append("\(name):\(i + 1) reads a corpus variable straight out of the "
                                      + "environment. A nil there becomes a silent early return, "
                                      + "which XCTest reports as PASSED. Use "
                                      + "`try SleepReplay.requireCorpus(_:purpose:)`.")
                }
            }
        }
        XCTAssertGreaterThan(filesScanned, 50, "the audit scanned almost nothing")
        XCTAssertEqual(violations, [], "corpus gate bypassed:\n" + violations.joined(separator: "\n"))
    }

    /// The inverse of the rule above: the four known entry points must still be gated. Without this,
    /// "fixing" the audit by deleting the gate would pass.
    func testEveryKnownCorpusEntryPointIsGated() throws {
        let expected = ["SleepReplayTests.swift": 3,    // measure, fidelity, input-sensitivity
                        "SleepBaselineTests.swift": 1]  // scoreboard emitter
        let sources = Dictionary(uniqueKeysWithValues: try loadTestTargetSources().map { ($0.name, $0.text) })
        for (file, count) in expected {
            let text = try XCTUnwrap(sources[file], "\(file) is gone — was an entry point renamed?")
            let got = text.components(separatedBy: "SleepReplay.requireCorpus").count - 1
            XCTAssertGreaterThanOrEqual(
                got, count,
                "\(file) has \(got) corpus gate(s), expected at least \(count). An entry point lost "
                + "its gate, so it can now run — and report success — on no corpus at all.")
        }
    }

    /// The fidelity proof's own tripwire. `asserted` counts the fields the manifest declared as
    /// fidelity targets; a corpus that declares none would otherwise walk every night, print a
    /// table, assert nothing and pass. The gate above stops a MISSING corpus; this stops an EMPTY
    /// one. Both are "success with zero assertions".
    func testFidelityProofKeepsItsZeroAssertionTripwire() throws {
        let sources = Dictionary(uniqueKeysWithValues: try loadTestTargetSources().map { ($0.name, $0.text) })
        let text = try XCTUnwrap(sources["SleepReplayTests.swift"])
        XCTAssertTrue(text.contains("XCTAssertGreaterThan(asserted, 0"),
                      "SleepReplayFidelityTests lost the `XCTAssertGreaterThan(asserted, 0)` check. "
                      + "Without it a corpus whose rows declare no fidelity targets produces a green "
                      + "parity claim backed by zero assertions.")
        XCTAssertTrue(text.contains("XCTAssertFalse(results.isEmpty"),
                      "SleepReplayMeasureTests lost its 'the corpus produced no measurable nights' "
                      + "check — an empty corpus directory would print a table of nothing and pass.")
    }

    /// The baseline emitter is the hash the whole campaign quotes. It must refuse to declare success
    /// without having replayed something.
    func testBaselineEmitterKeepsItsNonEmptyChecks() throws {
        let sources = Dictionary(uniqueKeysWithValues: try loadTestTargetSources().map { ($0.name, $0.text) })
        let text = try XCTUnwrap(sources["SleepBaselineTests.swift"])
        XCTAssertTrue(text.contains("XCTAssertGreaterThan(replayed, 0"),
                      "SleepBaselineTests lost its 'nothing was replayed at all' check — it would "
                      + "write a header-only TSV, hash it, and that hash would be quoted as a "
                      + "byte-identity proof.")
        XCTAssertTrue(text.contains("XCTAssertTrue(failures.isEmpty"),
                      "SleepBaselineTests lost its load-failure check — the scoreboard could silently "
                      + "omit the nights that failed to load.")
    }
}
