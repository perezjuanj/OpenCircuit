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
// This file is the standing guard. It has three parts:
//   1. BEHAVIOUR — `SleepReplay.requireCorpus` throws `XCTSkip` when unset (XCTest then reports
//      "skipped", which is not a pass) and FAILS when the variable is set to a bad path.
//   2. SOURCE AUDIT — no test in this target may name a corpus environment variable except through
//      that gate, no helper may hand one back as an `Optional` (that Optional is the hole), and the
//      known entry points must keep EXACTLY the gate count they are pinned at.
//   3. PINNED GOLDEN — the corpus fingerprint and the baseline sha256 the campaign quotes live in
//      tracked source and tracked docs, so "the scoreboard did not move" is a checkable claim rather
//      than a number in a chat log.
//
// ── WHAT THIS FILE DOES **NOT** GUARANTEE ─────────────────────────────────────────────────────────
// It is a TRIPWIRE, not a proof. An earlier version of this header claimed "the pattern cannot come
// back"; that was an overclaim, and an adversarial review broke the audit three ways in one sitting:
// a comment supplying the missing unit of a `>=` count; a fresh `-> URL?` helper added to the one
// file the audit excluded; and the two-line `let env = …environment` / `env[<corpus name>]` form,
// which the single-line needle could not see. All three are closed below and each is re-broken on
// demand by scratchpad/gatebreak/break.py. What remains open, and is accepted:
//   • a variable name assembled at run time ("OC_SLEEP" + "_X" + "_CORPUS") is invisible to a text
//     audit;
//   • a `func` signature deliberately split so `-> URL?` and `private` never share a declaration
//     window would slip the shape rule;
//   • anything that bypasses the test target entirely.
// The audit stops the pattern that ACTUALLY OCCURRED and the near-misses that were actually tried.
// It does not stop a determined author, and no source-text audit can. If it is in your way: it
// exists because a green tick was once backed by zero assertions.
//
// All three parts run with no corpus present, on any machine, forever.

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

    // MARK: - 2. Source audit — the tripwire

    /// Every `.swift` in this test target, read from disk at run time and reduced to the text the
    /// compiler will actually run. **Nothing is excluded** — including `SleepReplay.swift`, which the
    /// first version of this audit skipped wholesale, and including this file, which has to discuss
    /// the banned patterns in prose.
    private func auditSources() throws -> [StrippedSource] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let all = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        let swift = all.filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(swift.count, 50,
                             "found only \(swift.count) sources under \(dir.path) — this audit reads "
                             + "the test target through #filePath; if the files moved, FIX THE AUDIT, "
                             + "do not let it pass vacuously")
        return try swift.map {
            StrippedSource(name: ($0 as NSString).lastPathComponent,
                           text: try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// THE REGRESSION GUARD. A corpus variable may appear in executable code in exactly one shape:
    /// as the first argument of `SleepReplay.requireCorpus`. Anything else — the raw lookup, a
    /// subscript into a captured environment dictionary, a name stashed in a `let` — is a route back
    /// to the silent pass.
    ///
    /// Two evasions the first version allowed, both closed here:
    ///   • the needle was the literal `environment` + `[`, so the idiomatic two-line form
    ///     `let env = ProcessInfo.processInfo.environment` then `env[<corpus name>]` walked past;
    ///   • matching was per line, so any statement split across lines walked past.
    /// The check now runs over the file FLATTENED (comments removed, lines joined), so line breaks
    /// buy nothing, and it bans the corpus name itself rather than one spelling of one reader.
    func testACorpusVariableIsOnlyEverNamedInsideTheLoudGate() throws {
        // Assembled from pieces so this file contains no text that its own rules would match.
        let rawLookup = "SleepReplay" + ".dir("
        let corpusToken = "OC_SLEEP" + "[A-Z0-9_]*" + "_CORPUS"
        let corpusLiteral = try NSRegularExpression(pattern: "\"" + corpusToken + "\"")
        let gatedLiteral = try NSRegularExpression(pattern: "requireCorpus\\(\\s*\"" + corpusToken + "\"")

        var violations: [String] = []
        let sources = try auditSources()

        for src in sources {
            // (a) the raw lookup, wherever it appears
            for (i, line) in src.lines.enumerated() where line.contains(rawLookup) {
                violations.append("\(src.name):\(i + 1) calls the raw variable lookup instead of the "
                                  + "loud gate. Open a corpus through `requireCorpus(_:purpose:)`, "
                                  + "which throws XCTSkip instead of returning nil.")
            }

            // (b) the corpus name in any position other than requireCorpus's first argument
            let flat = src.flat as NSString
            let whole = NSRange(location: 0, length: flat.length)
            var gated: [NSRange] = []
            gatedLiteral.enumerateMatches(in: src.flat, range: whole) { m, _, _ in
                if let m { gated.append(m.range) }
            }
            corpusLiteral.enumerateMatches(in: src.flat, range: whole) { m, _, _ in
                guard let m else { return }
                let covered = gated.contains { NSIntersectionRange($0, m.range).length == m.range.length }
                guard !covered else { return }
                violations.append(
                    "\(src.name):\(src.line(forUTF16Offset: m.range.location)) names a corpus "
                    + "variable (\(flat.substring(with: m.range))) somewhere other than the first "
                    + "argument of the loud gate. Every other route — a raw environment subscript, a "
                    + "name held in a constant — ends in an Optional whose nil becomes a silent early "
                    + "return, which XCTest reports as PASSED.")
            }
        }
        XCTAssertGreaterThan(sources.count, 50, "the audit scanned almost nothing")
        XCTAssertEqual(violations, [], "corpus gate bypassed:\n" + violations.joined(separator: "\n"))
    }

    /// THE SHAPE RULE, and the reason `SleepReplay.swift` is no longer excluded from the audit.
    ///
    /// The original hole was not the name `dir` — it was the RETURN TYPE. Any helper that hands a
    /// test a `URL?` invites `guard let … else { return }`, and XCTest scores that return as a pass.
    /// The first audit excluded the whole gate file, so a second `-> URL?` helper added right next to
    /// `requireCorpus` reopened the hole with all nine audit tests green (measured). So: in this test
    /// target, a function may return `URL?` only if it is `private`.
    func testNoCorpusHelperHandsBackAnOptionalURL() throws {
        var violations: [String] = []
        for src in try auditSources() {
            let flat = src.flat as NSString
            var searchFrom = 0
            while searchFrom < flat.length {
                let hit = flat.range(of: "func ", options: [],
                                     range: NSRange(location: searchFrom,
                                                    length: flat.length - searchFrom))
                guard hit.location != NSNotFound else { break }
                searchFrom = hit.location + hit.length

                // Declaration = `func` up to the opening brace (capped, so a missing brace cannot
                // swallow the file).
                let tailLen = min(400, flat.length - hit.location)
                let tail = flat.substring(with: NSRange(location: hit.location, length: tailLen))
                let decl = tail.components(separatedBy: "{").first ?? tail
                guard decl.replacingOccurrences(of: " ", with: "").contains("->URL?") else { continue }

                // Modifiers sit immediately before `func`.
                let backLen = min(60, hit.location)
                let modifiers = flat.substring(with: NSRange(location: hit.location - backLen,
                                                             length: backLen))
                if !modifiers.contains("private") {
                    violations.append(
                        "\(src.name):\(src.line(forUTF16Offset: hit.location)) declares a non-private "
                        + "function returning `URL?`. An Optional corpus directory is the hole this "
                        + "whole file exists to close — make it `private` and expose it through the "
                        + "loud gate, which throws XCTSkip instead of returning nil.")
                }
            }
        }
        XCTAssertEqual(violations, [], "optional-URL corpus helper:\n" + violations.joined(separator: "\n"))
    }

    /// `SleepReplay.dir` must STAY private. Without this, "fixing" the shape rule by deleting the
    /// keyword passes both of the rules above.
    func testTheRawLookupStaysPrivate() throws {
        let sources = Dictionary(uniqueKeysWithValues: try auditSources().map { ($0.name, $0) })
        let gate = try XCTUnwrap(sources["SleepReplay.swift"], "the gate file is gone — FIX THE AUDIT")
        XCTAssertTrue(gate.flat.contains("private static func dir("),
                      "the raw lookup is no longer `private static func dir(`. Making it visible "
                      + "again re-opens `guard let dir = … else { return }`, which XCTest reports "
                      + "as a pass.")
    }

    /// The inverse of the ban: the known entry points must still be gated, at an EXACT count, over
    /// executable text only.
    ///
    /// The first version counted the needle in the RAW file text against a `>=` threshold, so the
    /// file's own header comment (which names the gate in prose) supplied one unit of slack: an
    /// entry point could lose its real gate and still satisfy `>= 3`. Comments are now stripped and
    /// the counts are `==`. The file SET is pinned too, so a new gated test file is a deliberate
    /// one-line edit here rather than an unnoticed addition.
    func testEveryKnownCorpusEntryPointIsGatedExactly() throws {
        let expected: [String: Int] = [
            "CorpusGateLoudnessTests.swift": 5,   // this file's own five behaviour tests
            "SleepReplayTests.swift": 3,          // measure, fidelity, input-sensitivity
            "SleepBaselineTests.swift": 1,        // scoreboard emitter
            "SleepCoverageMeasureTests.swift": 1, // acquisition-coverage scoreboard
        ]
        let gateCall = "SleepReplay" + ".requireCorpus("
        var found: [String: Int] = [:]
        for src in try auditSources() {
            let n = src.flat.components(separatedBy: gateCall).count - 1
            if n > 0 { found[src.name] = n }
        }
        XCTAssertEqual(
            Set(found.keys), Set(expected.keys),
            "the set of files that open a corpus changed.\n  found:    \(found.keys.sorted())\n"
            + "  expected: \(expected.keys.sorted())\nIf you added a corpus-gated test file, add it "
            + "to `expected` with its exact gate count. If a file DISAPPEARED from this list it lost "
            + "its gate and can now run — and report success — on no corpus at all.")
        for (file, count) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(found[file], count,
                           "\(file) has \(found[file].map(String.init) ?? "0") corpus gate(s) in "
                           + "executable code, pinned at \(count).")
        }
    }

    /// The fidelity proof's own tripwire. `asserted` counts the fields the manifest declared as
    /// fidelity targets; a corpus that declares none would otherwise walk every night, print a
    /// table, assert nothing and pass. The gate above stops a MISSING corpus; this stops an EMPTY
    /// one. Both are "success with zero assertions". Checked against executable text, so deleting
    /// the assertion and leaving a comment behind does not satisfy it.
    func testFidelityProofKeepsItsZeroAssertionTripwire() throws {
        let sources = Dictionary(uniqueKeysWithValues: try auditSources().map { ($0.name, $0) })
        let text = try XCTUnwrap(sources["SleepReplayTests.swift"]).flat
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
        let sources = Dictionary(uniqueKeysWithValues: try auditSources().map { ($0.name, $0) })
        let text = try XCTUnwrap(sources["SleepBaselineTests.swift"]).flat
        XCTAssertTrue(text.contains("XCTAssertGreaterThan(replayed, 0"),
                      "SleepBaselineTests lost its 'nothing was replayed at all' check — it would "
                      + "write a header-only TSV, hash it, and that hash would be quoted as a "
                      + "byte-identity proof.")
        XCTAssertTrue(text.contains("XCTAssertTrue(failures.isEmpty"),
                      "SleepBaselineTests lost its load-failure check — the scoreboard could silently "
                      + "omit the nights that failed to load.")
    }

    // MARK: - 3. The pinned golden

    /// `git grep ef5dc087` used to return NOTHING. The whole "no staged sleep number moved" story
    /// rested on a sha256 that no committed artifact recorded — so a future reader could not tell a
    /// re-derivation from a re-typing, and a change that DID move the scoreboard would have been
    /// caught only by whoever remembered the old value. The value now lives in tracked source
    /// (`SleepBaselineGolden`), is asserted by the emitter against the corpus it was measured on,
    /// and is quoted in tracked docs. This test keeps those copies in agreement.
    func testGoldenBaselineHashIsPinnedInTrackedSourceAndDocs() throws {
        let hex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        for (label, value) in [("baselineSHA256", SleepBaselineGolden.baselineSHA256),
                               ("corpusManifestSHA256", SleepBaselineGolden.corpusManifestSHA256)] {
            XCTAssertNotNil(hex.firstMatch(in: value,
                                           range: NSRange(location: 0, length: value.utf16.count)),
                            "SleepBaselineGolden.\(label) is not a lowercase 64-char sha256: '\(value)'")
        }

        // …/ios/OpenCircuitKit/Tests/OpenCircuitKitTests/<this file>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenCircuitKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // OpenCircuitKit
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
        let doc = repoRoot.appendingPathComponent("docs/SLEEP_REPLAY_HARNESS.md")
        guard let text = try? String(contentsOf: doc, encoding: .utf8) else {
            XCTFail("could not read \(doc.path) — this audit locates the docs through #filePath; if "
                    + "the layout moved, FIX THE AUDIT rather than letting the pin go unchecked")
            return
        }
        XCTAssertTrue(text.contains(SleepBaselineGolden.baselineSHA256),
                      "docs/SLEEP_REPLAY_HARNESS.md no longer quotes the pinned baseline sha256 "
                      + "\(SleepBaselineGolden.baselineSHA256). Source and docs must agree, or "
                      + "`git grep <hash>` stops answering 'which corpus produced this number?'.")
        XCTAssertTrue(text.contains(SleepBaselineGolden.corpusManifestSHA256),
                      "docs/SLEEP_REPLAY_HARNESS.md no longer quotes the pinned corpus manifest "
                      + "fingerprint. Without it the baseline hash names no corpus and cannot be "
                      + "reproduced.")
    }
}

// MARK: - Comment-stripped source

/// A source file reduced to what the compiler runs: `//` line comments and `/* */` blocks removed,
/// string literals (including `"""` and `#"…"#`) preserved verbatim, and one output line per input
/// line so violations still report a usable line number.
///
/// Comments are where the banned patterns are *discussed* — in this file, in `SleepReplay.swift`'s
/// doc block, in every runbook header. The first audit counted them, and that alone was enough to
/// satisfy a `>=` threshold with a real gate deleted.
struct StrippedSource {
    let name: String
    let lines: [String]
    let flat: String
    private let lineStarts: [Int]   // UTF-16 offset into `flat` where each line begins

    init(name: String, text: String) {
        self.name = name
        self.lines = StrippedSource.strip(text)
        var flat = ""
        var starts: [Int] = []
        var cursor = 0
        for line in lines {
            starts.append(cursor)
            let piece = line + " "
            flat += piece
            cursor += (piece as NSString).length
        }
        self.flat = flat
        self.lineStarts = starts
    }

    /// 1-based line number containing the given UTF-16 offset into `flat`.
    func line(forUTF16Offset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best + 1
    }

    private enum State { case code, lineComment, block(Int), string, rawString, multiline }

    private static func strip(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var state = State.code
        let c = Array(text)
        var i = 0
        func at(_ k: Int) -> Character? { i + k < c.count ? c[i + k] : nil }
        func endLine() { out.append(current); current = "" }

        while i < c.count {
            let ch = c[i]
            switch state {
            case .code:
                if ch == "/", at(1) == "/" { state = .lineComment; i += 2; continue }
                if ch == "/", at(1) == "*" { state = .block(1); i += 2; continue }
                if ch == "#", at(1) == "\"" { state = .rawString; current += "#\""; i += 2; continue }
                if ch == "\"", at(1) == "\"", at(2) == "\"" {
                    state = .multiline; current += "\"\"\""; i += 3; continue
                }
                if ch == "\"" { state = .string; current.append(ch); i += 1; continue }
                if ch == "\n" { endLine(); i += 1; continue }
                current.append(ch); i += 1
            case .lineComment:
                if ch == "\n" { endLine(); state = .code }
                i += 1
            case .block(let depth):
                if ch == "/", at(1) == "*" { state = .block(depth + 1); i += 2; continue }
                if ch == "*", at(1) == "/" { state = depth == 1 ? .code : .block(depth - 1); i += 2; continue }
                if ch == "\n" { endLine() }
                i += 1
            case .string:
                if ch == "\\" { current.append(ch); if let n = at(1) { current.append(n) }; i += 2; continue }
                if ch == "\n" { endLine(); state = .code; i += 1; continue }  // unterminated: recover
                current.append(ch)
                if ch == "\"" { state = .code }
                i += 1
            case .rawString:
                if ch == "\"", at(1) == "#" { current += "\"#"; state = .code; i += 2; continue }
                if ch == "\n" { endLine(); i += 1; continue }
                current.append(ch); i += 1
            case .multiline:
                if ch == "\"", at(1) == "\"", at(2) == "\"" {
                    current += "\"\"\""; state = .code; i += 3; continue
                }
                if ch == "\n" { endLine(); i += 1; continue }
                current.append(ch); i += 1
            }
        }
        out.append(current)
        return out
    }
}
