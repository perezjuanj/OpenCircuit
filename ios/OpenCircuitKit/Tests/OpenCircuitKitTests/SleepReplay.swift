// SLEEP REPLAY HARNESS — stage any night from raw bytes on the command line.
//
// WHY THIS EXISTS. Every sleep-accuracy claim in this project has to be MEASURED on real
// records, not argued about. This file is the measuring instrument: it takes a corpus of nights
// (base64 0x4c records + a manifest row) and runs the SAME staging pipeline the shipped app
// runs, then reports the detected window, the stage minutes, and — where the night carries a
// stored summary or a ground-truth label — the signed error against it.
//
// ============================================================================================
// PRODUCTION PARITY — the whole value of this harness rests on this section being true.
// ============================================================================================
// `stage(_:)` below is a line-for-line transcription of the app's own path. Read them side by
// side; the comments name the exact call sites this was checked against (master @ f042639).
//
//   ios/OpenCircuit/BLE/RingSession.swift  commitDrainedRecords (:3607-3697)
//     :3618  let temps        = wearTemperatureSamples()            -> nightTemperatureLog (:1350-1352)
//     :3619  let union        = epochArchiveStore.merge(bulkRecords)
//                              -> EpochArchive.merge(existing:incoming:) : dedup by counter,
//                                 sort ascending, prune to the 30 h retention window
//     :3620  let nightRecords = BulkSleep.latestNightRecords(from: union, temperatures: temps)
//     :3674  stagedSegments   = overnightStagedSegments(from: nightRecords, archive: union)
//
//   ios/OpenCircuit/BLE/RingSession.swift  overnightStagedSegments (:1563-1615)
//     :1580  let segs = SleepStaging.classify(from: records,
//     :1581                                   temperatures: wearTemperatureSamples(),
//     :1582                                   baseline: personalSleepBaseline(from: records))
//     :1588  let inBeds = segs.filter { $0.stage == .inBed }
//     :1589  guard let lo = inBeds.map(\.start).min(), let hi = inBeds.map(\.end).max() else { return segs }
//     :1592  if SleepWindow.isOvernightBlock(start: lo, end: hi) { return segs }
//     :1611  let onsetIsUnobserved = BulkSleep.onsetIsUnobserved(DateInterval(start: lo, end: max(hi, lo)),
//     :1612                                                      in: archive)     // <- the UNION, not the slice
//     :1613  return SleepWindow.isOvernightBlock(start: lo, end: hi,
//     :1614                                      onsetIsUnobserved: onsetIsUnobserved) ? segs : []
//
//   ios/OpenCircuit/BLE/RingSession.swift  persistSleepAndSteps (:1855-1927) — what gets STORED
//     :1876  let summary = SleepStaging.summary(stagedSegments)
//     :1887  let start   = stagedSegments.map(\.start).min()        -> StoredSleepSummary.inBedStart
//     :1888  let end     = stagedSegments.map(\.end).max()          -> StoredSleepSummary.inBedEnd
//     :1892  let sleep   = SleepStaging.sleepWindow(stagedSegments) -> sleepOnset / sleepWake
//
//   ios/OpenCircuitKit/Sources/OpenCircuitKit/BulkSleep.swift
//     :966-969  latestNightRecords derives `heartRateSamples:` and `sleepVitalTimes:` from the SAME
//               records it is given and passes both into `detectFromMotion`, so the harness needs
//               no extra input for the physiological gate. (Everything the HR gate and the
//               sleep-vitals rescue see is already in the .b64.)
//
// THE FOUR INPUTS PRODUCTION HAS THAT A .b64 FILE DOES NOT. All four are manifest fields and all
// four are swept by `SleepReplayInputSensitivityTests`, because an unmeasured input difference is
// how a harness quietly starts lying:
//
//   1. LOCAL TIME ZONE. `SleepWindow.isOvernightBlock` (:123) defaults to `Calendar.current`, and
//      `BulkSleep.latestNightRecords` gives no way to inject a calendar — so the 21:00/09:00
//      midpoint cliff that decides whether a block is a NIGHT is resolved from the PROCESS zone.
//      `withTimeZone` sets `NSTimeZone.default` and then ASSERTS the switch actually took, because
//      a silently wrong zone would corrupt every number this file prints.
//   2. `wearTemperatureSamples()` = `nightTemperatureLog`: in-memory, SESSION-scoped, night-window
//      only, stamped with frame ARRIVAL time (RingSession :4404). It cannot be reconstructed
//      exactly — a session replaced at 04:00 starts it empty. `[]` is the honest default and is
//      literally what a post-relaunch re-stage sees.
//   3. `personalSleepBaseline` (RingSession :1631-1643): median hrDeep of up to 7 PRIOR stored
//      nights, nil below 3. Manifest `deepHRBaselineBPM`; nil where the artifact has no hrDeep.
//   4. THE ARCHIVE SNAPSHOT. Production staged from the archive as it stood at that instant. A
//      corpus night rebuilt from a later export can be richer or poorer. Every manifest row states
//      its `inputProvenance` and `inputCaveat`; rows whose input provably differs from what staging
//      saw carry an empty `fidelity` list and are measured, never asserted.
//
// Deliberately NOT reproduced, because none of it feeds the stored window or the stage minutes:
// `BulkSleep.sleepSegments` (the coarse card timeline, RingSession :3673), `computeSleepExtras`,
// `SleepScore`, naps, the HealthKit mirror, and `SleepEdit.recompute` (the post-edit overlay — a
// night the user edited has stored MINUTES that are not a staging output at all).

import Foundation
import OpenCircuitKit

// MARK: - Corpus model
//
// Two manifest dialects are accepted, because the campaign has two corpora:
//   * "harness" — scratchpad/corpus-harness-v1: small, hand-justified, carries `temperatures`
//     and `deepHRBaselineBPM`, and is the only one that declares FIDELITY ASSERTIONS.
//   * "shared"  — scratchpad/corpus: the big multi-ring corpus. Measured and reported; its stored
//     windows appear as delta columns, never as assertions (its rows do not carry the two
//     production inputs above, and its record window is a fixed 24 h slice, not the app's archive).

struct ReplayNight {
    /// A night the user EDITED stores minutes that are a `SleepEdit.recompute` output, not a
    /// staging output. Where the edit's own anchors are known the harness can still check those
    /// minutes end-to-end: base segments -> SleepEdit -> stored minutes.
    struct Edit {
        var inBedStart: Date
        var sleepOnset: Date
        var sleepWake: Date
        var onsetProvenance: String?
        var asleepMin: Int?
        var awakeMin: Int?
        var deepMin: Int?
        var remMin: Int?
        var lightMin: Int?
        var fidelity: [String]
    }

    struct Stored {
        var isManuallyEdited: Bool?
        var inBedStart: Date?
        var inBedEnd: Date?
        var sleepOnset: Date?
        var sleepWake: Date?
        var asleepMin: Int?
        var awakeMin: Int?
        var deepMin: Int?
        var remMin: Int?
        var lightMin: Int?
        var windowPrecisionSec: Int
        /// Field names this row is willing to be ASSERTED on. Empty ⇒ measured only.
        var fidelity: [String]
        var minutesNote: String?
        var edit: Edit?
    }

    /// Ground truth. Kept separate from `stored` on purpose: sleep EDITS are a biased sample
    /// (people edit nights that look wrong — `SleepEditLabel.swift` says so), so these measure
    /// "how wrong are we when wrong", never overall accuracy.
    struct Label {
        var onset: Date?
        var wake: Date?
        var source: String?
    }

    var id: String
    var timeZone: TimeZone
    var recordsFile: String
    var dialect: String
    var appBuild: String?
    var ring: String?
    var source: String?
    var inputProvenance: String?
    var inputCaveat: String?
    var codeParity: String?
    /// Replay only records at or before this instant. Production staged from the archive AS IT
    /// STOOD at that moment; a corpus file rebuilt later can hold records staging never saw, and a
    /// row frozen by `.keptManualEdit` never absorbs them. Absent ⇒ replay everything.
    var inputTruncateAfter: Date?
    var inputTruncateReason: String?
    var deepHRBaselineBPM: Double?
    var temperatures: [(t: Date, c: Double)]
    var stored: Stored
    var label: Label?
}

// MARK: - Measurement

/// Everything one replayed night produces. A nil date means staging emitted nothing there.
struct ReplayResult {
    let night: ReplayNight
    let recordsLoaded: Int
    let recordsAfterRetention: Int
    let nightScopedRecords: Int
    let segments: [SleepSegment]

    let inBedStart: Date?
    let inBedEnd: Date?
    let onset: Date?
    let wake: Date?

    let inBedMin: Int
    let asleepMin: Int
    let awakeMin: Int
    let deepMin: Int
    let remMin: Int
    let lightMin: Int
    let efficiency: Double

    var id: String { night.id }
    var timeZone: TimeZone { night.timeZone }

    /// Signed minutes, detected − reference. Positive = we placed it LATE.
    static func delta(_ detected: Date?, _ reference: Date?) -> Int? {
        guard let detected, let reference else { return nil }
        return Int((detected.timeIntervalSince(reference) / 60).rounded())
    }

    var storedStartDeltaMin: Int? { Self.delta(inBedStart, night.stored.inBedStart) }
    var storedEndDeltaMin: Int? { Self.delta(inBedEnd, night.stored.inBedEnd) }
    var labelOnsetErrorMin: Int? { Self.delta(onset, night.label?.onset) }
    var labelWakeErrorMin: Int? { Self.delta(wake, night.label?.wake) }
}

enum SleepReplay {

    enum ReplayError: Error, CustomStringConvertible {
        case noManifest(String)
        case noRecords(String)
        case badBase64(String)
        case noTimeZone(String)
        case timeZoneDidNotTake(String, String)
        case badDate(String)

        var description: String {
            switch self {
            case let .noManifest(p): "no manifest.json under \(p)"
            case let .noRecords(id): "corpus night \(id): summary-only row, no records file — nothing to replay"
            case let .badBase64(id): "corpus night \(id): records file is not valid base64"
            case let .noTimeZone(id):
                "corpus night \(id): no timeZone/timeZoneIdentifier/timeZoneOffsetSeconds — "
                + "the 21:00/09:00 overnight cliff cannot be evaluated without one, so this row is refused"
            case let .timeZoneDidNotTake(want, got):
                "process time zone would not switch to '\(want)' (Calendar.current resolved to '\(got)') "
                + "— every number this harness produces would be wrong, so it refuses to continue"
            case let .badDate(s): "unparseable ISO-8601 timestamp '\(s)'"
            }
        }
    }

    // MARK: Dates

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) throws -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = isoFrac.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        throw ReplayError.badDate(s)
    }

    // MARK: Loading

    /// Directory for the measured corpus (`OC_SLEEP_CORPUS`), and for the asserted fidelity corpus
    /// (`OC_SLEEP_FIDELITY_CORPUS`). Both nil ⇒ the tests skip rather than fail, so `swift test`
    /// stays green on a machine that has no private health data on it.
    static func dir(_ variable: String) -> URL? {
        guard let p = ProcessInfo.processInfo.environment[variable], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func loadManifest(at dir: URL) throws -> [ReplayNight] {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw ReplayError.noManifest(dir.path) }
        let root = try JSONSerialization.jsonObject(with: data)
        guard let obj = root as? [String: Any],
              let rows = obj["nights"] as? [[String: Any]] else { throw ReplayError.noManifest(url.path) }
        return try rows.map(parse)
    }

    private static func parse(_ r: [String: Any]) throws -> ReplayNight {
        let isShared = r["ringId"] != nil

        let id = (r["id"] as? String)
            ?? [r["ringId"] as? String, r["night"] as? String].compactMap { $0 }.joined(separator: "_")

        // Time zone: named zone first (DST-correct), fixed offset only as the corpus's own fallback.
        let tz: TimeZone
        if let name = (r["timeZone"] as? String) ?? (r["timeZoneIdentifier"] as? String),
           let z = TimeZone(identifier: name) {
            tz = z
        } else if let off = r["timeZoneOffsetSeconds"] as? Int, let z = TimeZone(secondsFromGMT: off) {
            tz = z
        } else {
            throw ReplayError.noTimeZone(id)
        }

        var stored = ReplayNight.Stored(
            isManuallyEdited: nil, inBedStart: nil, inBedEnd: nil, sleepOnset: nil, sleepWake: nil,
            asleepMin: nil, awakeMin: nil, deepMin: nil, remMin: nil, lightMin: nil,
            windowPrecisionSec: 1, fidelity: [], minutesNote: nil)
        var label: ReplayNight.Label?
        var recordsFile = ""
        var appBuild: String?
        var deepHR: Double?
        var temps: [(t: Date, c: Double)] = []

        if isShared {
            recordsFile = r["recordsFile"] as? String ?? ""
            appBuild = (r["appBuilds"] as? [String])?.joined(separator: "/")
            stored.isManuallyEdited = r["isManuallyEdited"] as? Bool
            stored.inBedStart = try date(r["recordedInBedStart"] as? String)
            stored.inBedEnd = try date(r["recordedInBedEnd"] as? String)
            stored.sleepOnset = try date(r["recordedOnset"] as? String)
            stored.sleepWake = try date(r["recordedWake"] as? String)
            stored.asleepMin = r["asleepMin"] as? Int
            stored.awakeMin = r["awakeMin"] as? Int
            stored.deepMin = r["deepMin"] as? Int
            stored.remMin = r["remMin"] as? Int
            stored.lightMin = r["lightMin"] as? Int
            stored.windowPrecisionSec = (r["edgePrecision"] as? String) == "minutes" ? 60 : 1
            // Shared-corpus rows are MEASURED, never asserted: they carry neither the temperature
            // log nor the personal baseline, and their record window is a fixed 24 h slice rather
            // than the app's own archive. Asserting on them would be asserting on a different input.
            stored.fidelity = []
            stored.minutesNote = "shared corpus — measured only, see the parity block at the top of this file"
            if r["isLabelled"] as? Bool == true {
                label = ReplayNight.Label(onset: try date(r["editedOnset"] as? String),
                                          wake: try date(r["editedWake"] as? String),
                                          source: "user sleep edit (>= 3 min correction)")
            }
        } else {
            recordsFile = r["records"] as? String ?? ""
            appBuild = (r["appBuild"] as? Int).map(String.init)
            deepHR = r["deepHRBaselineBPM"] as? Double
            if let s = r["stored"] as? [String: Any] {
                stored.isManuallyEdited = s["isManuallyEdited"] as? Bool
                stored.inBedStart = try date(s["inBedStart"] as? String)
                stored.inBedEnd = try date(s["inBedEnd"] as? String)
                stored.sleepOnset = try date(s["sleepOnset"] as? String)
                stored.sleepWake = try date(s["sleepWake"] as? String)
                stored.asleepMin = s["asleepMin"] as? Int
                stored.awakeMin = s["awakeMin"] as? Int
                stored.deepMin = s["deepMin"] as? Int
                stored.remMin = s["remMin"] as? Int
                stored.lightMin = s["lightMin"] as? Int
                stored.windowPrecisionSec = s["windowPrecisionSec"] as? Int ?? 1
                stored.fidelity = s["fidelity"] as? [String] ?? []
                stored.minutesNote = s["minutesNote"] as? String
                if let e = s["edit"] as? [String: Any],
                   let b = try date(e["inBedStart"] as? String),
                   let o = try date(e["sleepOnset"] as? String),
                   let w = try date(e["sleepWake"] as? String) {
                    stored.edit = ReplayNight.Edit(
                        inBedStart: b, sleepOnset: o, sleepWake: w,
                        onsetProvenance: e["onsetProvenance"] as? String,
                        asleepMin: e["asleepMin"] as? Int, awakeMin: e["awakeMin"] as? Int,
                        deepMin: e["deepMin"] as? Int, remMin: e["remMin"] as? Int,
                        lightMin: e["lightMin"] as? Int,
                        fidelity: e["fidelity"] as? [String] ?? [])
                }
            }
            if let l = r["label"] as? [String: Any] {
                label = ReplayNight.Label(onset: try date(l["onset"] as? String),
                                          wake: try date(l["wake"] as? String),
                                          source: l["source"] as? String)
            }
            for t in (r["temperatures"] as? [[String: Any]] ?? []) {
                if let d = try date(t["t"] as? String), let c = t["c"] as? Double {
                    temps.append((d, c))
                }
            }
        }

        let ring = (r["ring"] as? [String: Any]).map {
            [$0["generation"] as? String, $0["firmware"] as? String].compactMap { $0 }.joined(separator: " ")
        } ?? [r["ringGeneration"] as? String, r["firmware"] as? String].compactMap { $0 }.joined(separator: " ")

        return ReplayNight(id: id, timeZone: tz, recordsFile: recordsFile,
                           dialect: isShared ? "shared" : "harness",
                           appBuild: appBuild, ring: ring.isEmpty ? nil : ring,
                           source: r["source"] as? String,
                           inputProvenance: r["inputProvenance"] as? String,
                           inputCaveat: r["inputCaveat"] as? String,
                           codeParity: r["codeParity"] as? String,
                           inputTruncateAfter: try date(r["inputTruncateAfter"] as? String),
                           inputTruncateReason: r["inputTruncateReason"] as? String,
                           deepHRBaselineBPM: deepHR, temperatures: temps,
                           stored: stored, label: label)
    }

    /// The .b64 file -> `[BulkRecord]`, through the SAME decoder the app uses for an archive blob
    /// (`EpochArchive.decode` -> `BulkSleep.records(fromStream:)`); a trailing partial chunk is
    /// dropped by the decoder, exactly as on device. Honours `inputTruncateAfter`.
    static func loadRecords(_ night: ReplayNight, in dir: URL) throws -> [BulkRecord] {
        guard !night.recordsFile.isEmpty else { throw ReplayError.noRecords(night.id) }
        let raw = try String(contentsOf: dir.appendingPathComponent(night.recordsFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) else {
            throw ReplayError.badBase64(night.id)
        }
        let all = EpochArchive.decode(data)
        guard let cut = night.inputTruncateAfter else { return all }
        return all.filter { $0.date() <= cut }
    }

    // MARK: The pipeline

    /// Run `body` with the process time zone set to `tz`, then restore.
    static func withTimeZone<T>(_ tz: TimeZone, at instant: Date, _ body: () throws -> T) throws -> T {
        let saved = NSTimeZone.default
        NSTimeZone.default = tz
        defer { NSTimeZone.default = saved }
        // Self-check BEFORE any measurement: `Calendar.current` is what the staging code reads.
        let got = Calendar.current.timeZone
        guard got.secondsFromGMT(for: instant) == tz.secondsFromGMT(for: instant) else {
            throw ReplayError.timeZoneDidNotTake(tz.identifier, got.identifier)
        }
        return try body()
    }

    /// Stage one night exactly as `RingSession` does. See the parity block at the top of this file.
    /// `observedGapCoverageCut` is the candidate-1 kill switch (`BulkSleep.observedGapAbsorbCoverageCut`,
    /// default 0 = master). Threaded here so a candidate can be A/B'd against master in one process,
    /// on the same bytes, with nothing else different.
    static func stage(records: [BulkRecord],
                      temperatures: [TemperatureSample] = [],
                      deepHRBaseline: Double? = nil,
                      tuning: SleepStaging.Tuning = .default,
                      observedGapCoverageCut: Double = BulkSleep.observedGapAbsorbCoverageCut)
        -> (segments: [SleepSegment], union: [BulkRecord], nightRecords: [BulkRecord]) {

        // RingSession :3619 — epochArchiveStore.merge() IS EpochArchive.merge(existing:incoming:).
        // `existing: []` + `incoming: records` reproduces its sort and its 30 h retention prune, and
        // is literally what the first drain after a cold launch does.
        let union = EpochArchive.merge(existing: [], incoming: records)

        // RingSession :3620
        let nightRecords = BulkSleep.latestNightRecords(from: union, temperatures: temperatures,
                                                        observedGapCoverageCut: observedGapCoverageCut)

        // RingSession :1580-1582
        let baseline = deepHRBaseline.map { SleepStaging.PersonalBaseline(deepSleepHR: $0) }
        let segs = SleepStaging.classify(from: nightRecords,
                                         temperatures: temperatures,
                                         tuning: tuning,
                                         baseline: baseline)

        // RingSession :1588-1614 — the overnight envelope gate.
        let inBeds = segs.filter { $0.stage == .inBed }
        guard let lo = inBeds.map(\.start).min(), let hi = inBeds.map(\.end).max() else {
            return (segs, union, nightRecords)                                       // :1589
        }
        if SleepWindow.isOvernightBlock(start: lo, end: hi) {
            return (segs, union, nightRecords)                                       // :1592
        }
        let onsetIsUnobserved = BulkSleep.onsetIsUnobserved(                          // :1611-1612
            DateInterval(start: lo, end: max(hi, lo)), in: union)
        let accepted = SleepWindow.isOvernightBlock(start: lo, end: hi,
                                                    onsetIsUnobserved: onsetIsUnobserved)
        return (accepted ? segs : [], union, nightRecords)                            // :1613-1614
    }

    /// Stage one manifest night and roll it up the way `persistSleepAndSteps` does.
    ///
    /// `temperaturesOverride` / `deepHRBaselineOverride` exist for the input-sensitivity sweep;
    /// leave them nil to use exactly what the manifest declares.
    static func measure(_ night: ReplayNight,
                        in dir: URL,
                        temperaturesOverride: [TemperatureSample]? = nil,
                        deepHRBaselineOverride: Double?? = nil,
                        tuning: SleepStaging.Tuning = .default,
                        observedGapCoverageCut: Double = BulkSleep.observedGapAbsorbCoverageCut)
        throws -> ReplayResult {
        let records = try loadRecords(night, in: dir)
        let temps = temperaturesOverride
            ?? night.temperatures.map { TemperatureSample(time: $0.t, celsius: $0.c) }
        let baseline: Double? = deepHRBaselineOverride ?? night.deepHRBaselineBPM
        let anchor = records.first?.date() ?? Date()

        return try withTimeZone(night.timeZone, at: anchor) {
            let staged = stage(records: records, temperatures: temps,
                               deepHRBaseline: baseline, tuning: tuning,
                               observedGapCoverageCut: observedGapCoverageCut)
            let segs = staged.segments
            let summary = SleepStaging.summary(segs)              // RingSession :1876
            let sleep = SleepStaging.sleepWindow(segs)            // RingSession :1892
            let m = summary.minutes
            return ReplayResult(
                night: night,
                recordsLoaded: records.count,
                recordsAfterRetention: staged.union.count,
                nightScopedRecords: staged.nightRecords.count,
                segments: segs,
                inBedStart: segs.map(\.start).min(),              // RingSession :1887
                inBedEnd: segs.map(\.end).max(),                  // RingSession :1888
                onset: sleep?.onset, wake: sleep?.wake,
                inBedMin: m.inBed, asleepMin: m.asleep, awakeMin: m.awake,
                deepMin: m.deep, remMin: m.rem, lightMin: m.light,
                efficiency: summary.efficiency)
        }
    }

    // MARK: Reporting

    static func clock(_ d: Date?, _ tz: TimeZone) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private static let columns: [(String, Int)] = [
        ("night", 22), ("inBedStart", 14), ("inBedEnd", 14), ("onset", 14), ("wake", 14),
        ("inBed", 5), ("aslp", 5), ("awk", 4), ("deep", 4), ("rem", 4), ("light", 5), ("eff", 5),
        ("dStart", 7), ("dEnd", 6), ("dOnset", 7), ("dWake", 6),
    ]

    static func header() -> String {
        let line = columns.map { $0.0.padding(toLength: $0.1, withPad: " ", startingAt: 0) }
            .joined(separator: " ")
        return line + "\n" + String(repeating: "-", count: line.count)
    }

    static func row(_ r: ReplayResult) -> String {
        func right(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
        }
        func left(_ s: String, _ n: Int) -> String {
            s.count >= n ? String(s.prefix(n)) : s.padding(toLength: n, withPad: " ", startingAt: 0)
        }
        func signed(_ v: Int?) -> String { v.map { ($0 > 0 ? "+" : "") + String($0) } ?? "·" }
        let tz = r.timeZone
        let cells = [left(r.id, 22),
                     left(clock(r.inBedStart, tz), 14), left(clock(r.inBedEnd, tz), 14),
                     left(clock(r.onset, tz), 14), left(clock(r.wake, tz), 14),
                     right(String(r.inBedMin), 5), right(String(r.asleepMin), 5),
                     right(String(r.awakeMin), 4), right(String(r.deepMin), 4),
                     right(String(r.remMin), 4), right(String(r.lightMin), 5),
                     right(String(format: "%.3f", r.efficiency), 5),
                     right(signed(r.storedStartDeltaMin), 7), right(signed(r.storedEndDeltaMin), 6),
                     right(signed(r.labelOnsetErrorMin), 7), right(signed(r.labelWakeErrorMin), 6)]
        return cells.joined(separator: " ")
    }

    static func legend() -> String {
        """
        dStart/dEnd  = detected in-bed edge MINUS the app's stored RECORDED edge, signed minutes \
        (+ = later than the app placed it). '·' = the corpus row carries no stored window.
        dOnset/dWake = detected sleep onset/wake MINUS the GROUND-TRUTH label, signed minutes \
        (+ = we placed it late). Labels are a biased sample — see SleepEditLabel.swift.
        inBed/aslp/awk/deep/rem/light are whole minutes from SleepStaging.Summary.minutes; \
        eff = SleepStaging.Summary.efficiency.
        """
    }
}
