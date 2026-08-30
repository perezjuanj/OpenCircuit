import XCTest

/// THE APP MAY HAVE EXACTLY ONE HEALTHKIT AUTHORIZATION REQUEST FOR THE TYPES IT SHARES.
///
/// THE INCIDENT (build 50, shipped to every tester). `WorkoutHistoryReader` gained a second,
/// scoped request — `requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])` — so the
/// Activity tab could read workouts back, while `HealthKitWriter.requestAuthorization()` kept naming
/// that same workout type in `toShare` only. The two requests disagreed about one type's `toShare`
/// membership, and on device the user could never reach a settled state: fresh launch prompts for
/// Workouts + Workout Routes WRITE → Allow → Health ▸ Data Access shows both granted → open the
/// Activity tab → the read prompt appears → the write grant is gone → next fresh launch prompts for
/// write again, forever. Reported first-hand off a build-50 device.
///
/// Why HealthKit clears the grant is NOT documented by Apple and is NOT asserted anywhere in this
/// suite — see `HealthKitWriter.authorizationReadTypes` for exactly what is and is not established.
/// This audit pins the SHAPE that made the mechanism reachable, which is the part we control: one
/// request, one read set, no second opinion about any type.
///
/// WHY A SOURCE AUDIT. `HKHealthStore` is not mockable and the simulator reports every type
/// `.notDetermined`, so no runtime test can observe an authorization request at all (see the
/// validation-and-qa skill, "What CANNOT be auto-tested"). The property at stake is not a value, it
/// is "how many places ask" — a fact about the source. So the source is what gets read. This lives
/// in the Kit rather than the app target on purpose: the Kit suite is the release gate, the
/// app-target suite is not.
///
/// This test is BRITTLE BY DESIGN. Adding, moving, or reshaping an authorization call site fails it.
/// That is the point: the failure message is the rule, and it is meant to be read before the pin is
/// updated — not updated to make the build green.
final class HealthKitAuthorizationSurfaceTests: XCTestCase {

    /// Every `.swift` under `ios/OpenCircuit/`, reduced to the text the compiler actually runs.
    /// Comment-stripping is load-bearing: the call sites this audit counts are *quoted verbatim* in
    /// the doc comments that explain the defect (in `HealthKitWriter`, in `WorkoutHistoryView`, and
    /// in this file's own header), so a raw text scan would count the explanation as a violation and
    /// the true count would be unreadable.
    private func appSources() throws -> [StrippedSource] {
        // …/ios/OpenCircuitKit/Tests/OpenCircuitKitTests/<this file>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenCircuitKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // OpenCircuitKit
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
        let appDir = repoRoot.appendingPathComponent("ios/OpenCircuit")
        guard let all = try? FileManager.default.subpathsOfDirectory(atPath: appDir.path) else {
            XCTFail("could not read \(appDir.path) — this audit locates the app target through "
                    + "#filePath; if the layout moved, FIX THE AUDIT rather than letting the "
                    + "one-request rule go unchecked")
            return []
        }
        let swift = all.filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(swift.count, 40,
                             "found only \(swift.count) sources under \(appDir.path) — too few for "
                             + "this to be the app target. FIX THE AUDIT; do not let it pass vacuously.")
        return try swift.map {
            StrippedSource(name: ($0 as NSString).lastPathComponent,
                           text: try String(contentsOf: appDir.appendingPathComponent($0),
                                            encoding: .utf8))
        }
    }

    private func matchCount(_ pattern: String, in source: StrippedSource) throws -> Int {
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: (source.flat as NSString).length)
        return re.numberOfMatches(in: source.flat, range: range)
    }

    /// THE PIN. The set of files that ask HealthKit for authorization, and how many times each asks.
    ///
    /// `HealthKitWriter.swift` = 2: the request, plus its retry with `.bodyTemperature` dropped from
    /// `toShare` (one non-shareable type must degrade to "temp not shared", not disable every
    /// metric). Both send the SAME read set, so they are one request surface, not two.
    ///
    /// `CalibrationSupport.swift` = 3 (SpO₂, Apple Watch HR, Apple Watch ECG). These are read-only
    /// requests inside the cuff/PPG calibration dev tool, reachable ONLY from the `#if DEBUG` block
    /// in `ContentView` (`showCalibration = true` at ContentView.swift is inside `#if DEBUG` …
    /// `#endif`; verified on this branch), so a Release/TestFlight build never runs them.
    ///
    /// ⚠️ THEY ARE NOT ENDORSED — TWO OF THEM ARE THE SAME SHAPE AS THE DEFECT. `read: [spo2Type]`
    /// and `read: [hrType]` name types that `HealthKitWriter.allTypes` carries in `toShare`, i.e.
    /// the exact disagreement that broke the workout grant, and heart rate is the very type
    /// `isShareAuthorized` probes — so if that shape does what the build-50 device showed, running
    /// the DEBUG calibration flow could switch the whole Health writeback off. They are allowlisted
    /// here only because they cannot reach a shipping user, and they are recorded here so the next
    /// person does not have to rediscover them. The ECG request is the one non-divergent member:
    /// `HKObjectType.electrocardiogramType()` appears in no other request. If you make the
    /// calibration tool reachable in Release, fix these first.
    func testExactlyOneAuthorizationRequestSurfaceInTheShippingApp() throws {
        let sources = try appSources()
        guard !sources.isEmpty else { return }
        let needle = #"requestAuthorization\s*\(\s*toShare\s*:"#

        var found: [String: Int] = [:]
        for source in sources {
            let n = try matchCount(needle, in: source)
            if n > 0 { found[source.name] = n }
        }

        let expected = ["HealthKitWriter.swift": 2, "CalibrationSupport.swift": 3]
        XCTAssertEqual(found, expected, """
            The HealthKit authorization surface moved. Found \(found), expected \(expected).

            THE RULE: the app makes ONE authorization request for the types it shares —
            HealthKitWriter.requestAuthorization(), over allTypes + authorizationReadTypes. A second
            request that names an already-shared type with a different `toShare` membership is the
            build-50 defect: it left testers in a permission loop with no settled state, and the
            grant it destroyed was one the user had already given.

            If you need to READ a new type, add it to HealthKitWriter.authorizationReadTypes.
            If you need to WRITE one, add it to HealthKitWriter.allTypes (mind N10 — no
            HKCorrelationType, no Apple-computed type: that raises an uncatchable Obj-C exception).
            Only then update this pin, and say in the commit why the new call site cannot diverge.
            """)
    }

    /// The #129 upgrade re-prompt — the ONLY path that can heal a device already stuck in the loop,
    /// and the only path that carries a newly-added read type to an existing install — is built on
    /// `statusForAuthorizationRequest`. Apple documents that probe as reporting whether the user
    /// would be prompted "if the same collections of types are passed to
    /// requestAuthorizationToShareTypes:readTypes:" (HKHealthStore.h), so it answers for the request
    /// it was handed, not for the one the app actually sends. Build 50's probe passed
    /// `read: [sleepAnalysis]` while the request sent a far larger read set — which is why a type
    /// added to the request's read half was invisible to the heal.
    ///
    /// Both call sites must therefore take the read set from the ONE property. An inline literal is
    /// how they drift apart, so an inline literal is what this bans.
    func testAuthorizationRequestAndItsStatusProbeShareOneReadSet() throws {
        let sources = try appSources()
        guard let writer = sources.first(where: { $0.name == "HealthKitWriter.swift" }) else {
            return XCTFail("HealthKitWriter.swift not found under ios/OpenCircuit — FIX THE AUDIT")
        }

        // Both the request and its status probe must be present, or this test is checking nothing.
        XCTAssertEqual(try matchCount(#"requestAuthorization\s*\(\s*toShare\s*:"#, in: writer), 2)
        XCTAssertEqual(try matchCount(#"statusForAuthorizationRequest\s*\(\s*toShare\s*:"#, in: writer), 1)

        let inlineReadSet = try NSRegularExpression(pattern: #"read\s*:\s*\["#)
        let ns = writer.flat as NSString
        let matches = inlineReadSet.matches(in: writer.flat, range: NSRange(location: 0, length: ns.length))
        let lines = matches.map { writer.line(forUTF16Offset: $0.range.location) }
        XCTAssertTrue(matches.isEmpty, """
            HealthKitWriter.swift passes an inline `read: [...]` set at line(s) \(lines).

            The authorization request and `authorizationPromptAvailable()`'s status probe must both
            read from `authorizationReadTypes`. When they disagree, `statusForAuthorizationRequest`
            silently answers for a request the app never makes, and the #129 upgrade re-prompt stops
            carrying new read types — the failure that stranded the workout read grant in build 50.
            """)
    }
}
