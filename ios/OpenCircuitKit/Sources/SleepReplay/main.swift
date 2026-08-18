// SleepReplay — replay a night's raw 0x4c records through the SHIPPING sleep pipeline and
// print the decision trace, so a "the night started hours too early" report can be located
// at a specific pass rather than argued about from a screenshot.
//
// WHY A SEPARATE TOOL. Every stage of the pipeline is already unit-tested against SYNTHETIC
// records; what no test can supply is a real wearer's night that the model got wrong. The
// JSON export carries `epochArchive[].recordsBase64` — the exact `[BulkRecord]` the app
// staged from — so this replays it byte-for-byte through the same public entry points
// (`ActivityPeriod.detectFromMotion` → `BulkSleep.latestNightRecords` → `SleepStaging.classify`)
// and reports WHERE the onset came from.
//
// It is READ-ONLY and offline: it opens one file, prints, and exits. It changes no behaviour.
//
//   swift run SleepReplay <export.json> [--tz Australia/Sydney] [--ring <id>]
//
// ⚠️ RETENTION: `EpochArchive.retention` is 30 h, so an export made more than ~30 h after the
// night carries no raw records for it. The tool says so rather than replaying a neighbouring
// night by accident.

import Foundation
import OpenCircuitKit

// MARK: - CLI

let rawArgs = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = rawArgs.firstIndex(of: name), i + 1 < rawArgs.count else { return nil }
    return rawArgs[i + 1]
}
guard let path = rawArgs.first(where: { !$0.hasPrefix("--") }) else {
    print("""
    usage: swift run SleepReplay <export.json> [--tz <IANA zone>] [--ring <ringID>]

      <export.json>  an OpenCircuit JSON export (Settings -> Export -> Format: JSON).
                     CSV will not work: the raw records are JSON-only.
      --tz           IANA zone to print wall-clock times in (default: this machine's).
      --ring         replay only this ringID (default: every ring in the file).
    """)
    exit(2)
}

let zone = flag("--tz").flatMap(TimeZone.init(identifier:)) ?? .current
let ringFilter = flag("--ring")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = zone

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm:ss"
    f.timeZone = zone
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func t(_ d: Date) -> String { clock.string(from: d) }
func t(_ d: Date?) -> String { d.map(t) ?? "—" }

func dur(_ s: TimeInterval) -> String {
    let m = Int((s / 60).rounded())
    return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(m)m"
}

func rule(_ title: String) {
    print("")
    print("── \(title) " + String(repeating: "─", count: max(0, 74 - title.count)))
}

func median(_ xs: [Int]) -> Int? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[s.count / 2]
}
func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[s.count / 2]
}

// MARK: - Load

guard let blob = FileManager.default.contents(atPath: path),
      let root = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any] else {
    print("error: could not read \(path) as JSON")
    exit(1)
}

print("SleepReplay — \(path)")
print("  schemaVersion \(root["schemaVersion"] as? Int ?? -1)   exportedAt \(root["exportedAt"] as? String ?? "?")")
print("  printing times in \(zone.identifier)")
if let meta = root["meta"] as? [String: Any] {
    let bits = ["appVersion", "build", "ringModel", "firmware", "deviceTimeZone"]
        .compactMap { k in (meta[k] as? String).map { "\(k)=\($0)" } }
    if !bits.isEmpty { print("  " + bits.joined(separator: "  ")) }
}

// Raw records, per ring. `epochArchive` is the archive staging actually ran on; the
// per-drain `historySyncEvidence` blobs are a LOSSY ring buffer and are used only as a
// fallback (and unioned in, since they can hold epochs the archive has since pruned).
struct RingRecords { let ringID: String; var records: [BulkRecord]; var archiveBacked: Bool }
var byRing: [String: RingRecords] = [:]

for a in (root["epochArchive"] as? [[String: Any]] ?? []) {
    guard let ringID = a["ringID"] as? String,
          let b64 = a["recordsBase64"] as? String,
          let data = Data(base64Encoded: b64) else { continue }
    byRing[ringID] = RingRecords(ringID: ringID, records: EpochArchive.decode(data), archiveBacked: true)
}
for e in (root["historySyncEvidence"] as? [[String: Any]] ?? []) {
    guard let ringID = e["ringID"] as? String,
          let b64 = e["rawRecordBlobBase64"] as? String,
          let data = Data(base64Encoded: b64) else { continue }
    let recs = EpochArchive.decode(data)
    guard !recs.isEmpty else { continue }
    if var existing = byRing[ringID] {
        // Union, dedup by counter — merge() also prunes to retention, which is what the app did.
        existing.records = EpochArchive.merge(existing: existing.records, incoming: recs)
        byRing[ringID] = existing
    } else {
        byRing[ringID] = RingRecords(ringID: ringID, records: recs, archiveBacked: false)
    }
}

// Skin temperature drives the #41 wear gate on both the coarse and staged paths, so feed it
// exactly as the app does. It is not ring-scoped in the export, so every ring gets all of it.
let temperatures: [TemperatureSample] = {
    let iso = ISO8601DateFormatter()
    return (root["samples"] as? [[String: Any]] ?? []).compactMap { s in
        guard s["kind"] as? String == MetricKind.temperature.rawValue,
              let start = (s["start"] as? String).flatMap({ iso.date(from: $0) }),
              let v = s["value"] as? Double else { return nil }
        return TemperatureSample(time: start, celsius: v)
    }
}()

// What the app actually SHIPPED for these nights — the thing the user saw in Apple Health.
rule("what the app shipped (sleepSessions)")
let sessions = root["sleepSessions"] as? [[String: Any]] ?? []
if sessions.isEmpty {
    print("  (no sleepSessions in this export)")
}
for s in sessions {
    let night = s["night"] as? String ?? "?"
    let offsetISO = ISO8601DateFormatter()
    offsetISO.formatOptions = [.withInternetDateTime]
    func d(_ k: String) -> Date? { (s[k] as? String).flatMap { offsetISO.date(from: $0) } }
    let inBed = d("inBedStart"), onset = d("sleepOnset"), wake = d("sleepWake"), inBedEnd = d("inBedEnd")
    let edited = (s["isManuallyEdited"] as? Bool ?? false) ? "  [manually edited]" : ""
    print("  \(night)  inBed \(t(inBed)) → \(t(inBedEnd))   onset \(t(onset))   wake \(t(wake))\(edited)")
    if let onset, let wake {
        print("           onset→wake \(dur(wake.timeIntervalSince(onset)))"
              + (inBed.map { "   inBed→onset \(dur(onset.timeIntervalSince($0)))" } ?? ""))
    }
    if let hyp = s["hypnogram"] as? [[String: Any]], !hyp.isEmpty {
        var totals: [String: TimeInterval] = [:]
        for seg in hyp {
            let stage = seg["stage"] as? String ?? "?"
            totals[stage, default: 0] += (seg["durationSec"] as? Double ?? 0)
        }
        let line = totals.sorted { $0.key < $1.key }.map { "\($0.key) \(dur($0.value))" }.joined(separator: "  ")
        print("           hypnogram: \(hyp.count) segments — \(line)")
    }
}

// MARK: - Per-ring replay

let epoch = Command.syncEpoch

for ringID in byRing.keys.sorted() {
    guard ringFilter == nil || ringFilter == ringID else { continue }
    let ring = byRing[ringID]!
    let records = ring.records.sorted { $0.counter < $1.counter }

    print("")
    print(String(repeating: "═", count: 80))
    print("RING \(ringID)   \(records.count) records"
          + (ring.archiveBacked ? "" : "   ⚠️ evidence blobs only (no epochArchive) — LOSSY"))
    print(String(repeating: "═", count: 80))

    guard records.count >= 2 else { print("  too few records to replay"); continue }
    let first = records.first!.date(epoch: epoch), last = records.last!.date(epoch: epoch)
    print("  span \(t(first)) → \(t(last))   (\(dur(last.timeIntervalSince(first))))")

    // The three timelines every pass is built from — identical construction to BulkSleep.mainSleep.
    let motion = BulkSleep.motionTimeline(from: records, epoch: epoch)
    let hr = BulkSleep.heartRateTimeline(from: records, epoch: epoch)
    let vitals = BulkSleep.sleepVitalTimeline(from: records, epoch: epoch)
    let quiet = BulkSleep.activityQuietTimeline(from: records, epoch: epoch)
    let tempsInSpan = temperatures.filter { $0.time >= first.addingTimeInterval(-3600)
                                         && $0.time <= last.addingTimeInterval(3600) }
    print("  motion samples \(motion.count)   HR readings \(hr.count)"
          + "   sleep-vitals epochs \(vitals.count)   temp samples in span \(tempsInSpan.count)")

    // ── 1. Data holes ────────────────────────────────────────────────────────────────────
    // A hole > gravityMaxGap splits the detector's runs AND splits `contiguousFragments`,
    // which is what makes each side stage independently (its own HR floor, its own bands).
    rule("1. data holes (> \(Int(ActivityPeriod.gravityMaxGap / 60)) min — these split fragments)")
    var holes = 0
    for i in 1 ..< records.count {
        let gap = TimeInterval(Int(records[i].counter) - Int(records[i - 1].counter))
        guard gap > ActivityPeriod.gravityMaxGap else { continue }
        holes += 1
        print("  \(t(records[i - 1].date(epoch: epoch))) → \(t(records[i].date(epoch: epoch)))   \(dur(gap))")
    }
    if holes == 0 { print("  none — one contiguous run") }

    // ── 2. Coarse detection, ungated vs gated ────────────────────────────────────────────
    // `detectFromMotion(_:)` is motion only; the four-argument form applies the wear gate
    // (#41) then the HR gate then the sleep-vitals tail rescue. Diffing them names the gate.
    rule("2. coarse detection — which sleep blocks the gates removed")
    let ungated = ActivityPeriod.detectFromMotion(motion)
    let gated = ActivityPeriod.detectFromMotion(motion,
                                                temperatureSamples: tempsInSpan,
                                                heartRateSamples: hr,
                                                sleepVitalTimes: vitals,
                                                activityQuiet: quiet)
    let floor = ActivityPeriod.sleepHRFloor(hr)
    let threshold = floor.map { $0 + ActivityPeriod.awakeHRMarginBPM }
    print("  HR floor (p10 of DISTINCT levels across the whole timeline): "
          + (floor.map { "\($0) bpm" } ?? "n/a")
          + "   → HR-gate threshold \(threshold.map { "\($0) bpm" } ?? "n/a")")
    print("  (a still block is kept as sleep while its MEDIAN HR is at or below that threshold)")
    print("")
    print("  sleep blocks ≥ 15 min, after gating:")
    var anyBlock = false
    for p in gated where p.activity == .sleep && p.duration >= 15 * 60 {
        anyBlock = true
        let inside = hr.filter { $0.time >= p.start && $0.time <= p.end }.map(\.bpm)
        let temp = tempsInSpan.filter { $0.time >= p.start && $0.time <= p.end }.map(\.celsius)
        let med = median(inside).map { "\($0)" } ?? "—"
        let headroom = (median(inside).flatMap { m in threshold.map { $0 - m } })
            .map { $0 >= 0 ? "\($0) bpm under" : "\(-$0) bpm over" } ?? "—"
        print("    \(t(p.start)) → \(t(p.end))  \(dur(p.duration).padded(7))"
              + "  medianHR \(med.padded(4)) (\(headroom) threshold)"
              + "  n=\(inside.count)"
              + (median(temp).map { String(format: "  medianTemp %.1f°C", $0) } ?? ""))
    }
    if !anyBlock { print("    (none)") }

    let killed = ungated.filter { u in
        u.activity == .sleep && u.duration >= 15 * 60
            && !gated.contains { $0.activity == .sleep && $0.start == u.start && $0.end == u.end }
    }
    print("")
    if killed.isEmpty {
        print("  gates removed NOTHING — every still block above survived into the night candidates.")
    } else {
        print("  gates REMOVED these still blocks (good — this is the machinery working):")
        for p in killed {
            let inside = hr.filter { $0.time >= p.start && $0.time <= p.end }.map(\.bpm)
            print("    \(t(p.start)) → \(t(p.end))  \(dur(p.duration).padded(7))"
                  + "  medianHR \(median(inside).map { "\($0)" } ?? "—")")
        }
    }

    // ── 3. Clustering into one "main sleep block" ────────────────────────────────────────
    // `mainSleepBlock` chains sleep periods separated by < maxSleepPause. A bridge listed
    // here is an awake stretch that was absorbed into the night wholesale.
    rule("3. clustering — gaps bridged by maxSleepPause (\(Int(ActivityPeriod.maxSleepPause / 60)) min)")
    let sleeps = gated.filter { $0.activity == .sleep }.sorted { $0.start < $1.start }
    var bridged = 0
    for (a, b) in zip(sleeps, sleeps.dropFirst()) {
        let gap = b.start.timeIntervalSince(a.end)
        guard gap > 0, gap < ActivityPeriod.maxSleepPause else { continue }
        bridged += 1
        print("  bridged \(t(a.end)) → \(t(b.start))   \(dur(gap))   (awake, counted inside the night)")
    }
    if bridged == 0 { print("  no gaps bridged") }
    if let block = ActivityPeriod.mainSleepBlock(gated) {
        print("  → main block  \(t(block.start)) → \(t(block.end))   \(dur(block.duration))")
    } else {
        print("  → no main block")
    }

    // ── 4. Night scoping ─────────────────────────────────────────────────────────────────
    // `latestNightRecords` picks the anchor night, chains earlier fragments within
    // maxIntraNightGap, then FLOORS the start at anchor.end − maxNightSpan. Hitting that
    // floor exactly is the signature of a window that wanted to be even wider.
    rule("4. night scoping (latestNightRecords)")
    let night = BulkSleep.latestNightRecords(from: records, temperatures: tempsInSpan, epoch: epoch)
    if night.isEmpty || night.count == records.count {
        print("  scoping returned \(night.count == records.count ? "EVERYTHING (no overnight block found)" : "nothing")")
    }
    if let ns = night.first?.date(epoch: epoch), let ne = night.last?.date(epoch: epoch) {
        let span = ne.timeIntervalSince(ns)
        print("  window \(t(ns)) → \(t(ne))   \(dur(span))   (\(night.count) records)")
        // The window carries a ±30 min margin, so compare against maxNightSpan + both margins.
        let cap = BulkSleep.maxNightSpan + 3600
        if span >= cap - 300 {
            print("  ⚠️ AT THE maxNightSpan CAP (\(dur(BulkSleep.maxNightSpan)) + margins) — the")
            print("     detected cluster wanted to be WIDER and was clipped. The true head of the")
            print("     over-wide block is EARLIER than the window start above.")
        }
    }

    // ── 5. Fragments ─────────────────────────────────────────────────────────────────────
    // `SleepStaging.classify` stages each fragment INDEPENDENTLY — its own HR floor, its own
    // percentile bands. An evening fragment therefore gets a full Deep/Core/REM mini-night.
    rule("5. fragments inside the night window (each staged INDEPENDENTLY)")
    let frags = BulkSleep.contiguousFragments(night)
    for (i, f) in frags.enumerated() {
        guard let fs = f.first?.date(epoch: epoch), let fe = f.last?.date(epoch: epoch) else { continue }
        let fhr = f.compactMap(\.heartRate)
        print("  #\(i + 1)  \(t(fs)) → \(t(fe))  \(dur(fe.timeIntervalSince(fs)).padded(7))"
              + "  \(f.count) epochs"
              + "  HR min/med/max \(fhr.min().map(String.init) ?? "—")/"
              + "\(median(fhr).map(String.init) ?? "—")/\(fhr.max().map(String.init) ?? "—")")
    }
    if frags.count > 1 {
        print("  ⚠️ \(frags.count) fragments — each computes its OWN sleeping floor and stage bands,")
        print("     so an evening fragment can be staged as a self-contained night.")
    }

    // ── 6. Staging ───────────────────────────────────────────────────────────────────────
    rule("6. staging (SleepStaging.classify) — the hypnogram that reaches Apple Health")
    let staged = SleepStaging.classify(from: night, temperatures: tempsInSpan, epoch: epoch)
    if let w = SleepStaging.sleepWindow(staged) {
        print("  onset \(t(w.onset))   wake \(t(w.wake))   asleep-span \(dur(w.wake.timeIntervalSince(w.onset)))")
    } else {
        print("  no asleep segments")
    }
    if let bed = staged.filter({ $0.stage == .inBed }).map(\.start).min(),
       let bedEnd = staged.filter({ $0.stage == .inBed }).map(\.end).max() {
        print("  inBed \(t(bed)) → \(t(bedEnd))   \(dur(bedEnd.timeIntervalSince(bed)))")
    }
    let totals = SleepStaging.stageTotals(staged)
    print("  totals: " + SleepStage.allCases
        .compactMap { s in totals[s].map { "\(s.rawValue) \(dur($0))" } }
        .joined(separator: "   "))
    print("  total asleep \(dur(SleepStaging.totalAsleep(staged)))")

    // ── 7. Why onset landed where it did ─────────────────────────────────────────────────
    // Both onset-correction passes (`markDescentOnsetAwake`, `markLeadInWakeOnset`) search
    // only the first `onsetSearchEpochs` of a fragment. If real onset sits beyond that
    // horizon they CANNOT reach it, and onset falls to the first sustained quiet run instead.
    rule("7. onset-search horizon — can the onset passes even REACH the real onset?")
    let d = SleepStaging.Tuning.default
    let horizon = TimeInterval(d.onsetSearchEpochs * BulkRecord.epochSeconds)
    print("  default onsetSearchEpochs = \(d.onsetSearchEpochs) epochs × \(BulkRecord.epochSeconds)s = \(dur(horizon)) from each fragment's start")
    for (i, f) in frags.enumerated() {
        guard let fs = f.first?.date(epoch: epoch) else { continue }
        print("    fragment #\(i + 1) horizon ends \(t(fs.addingTimeInterval(horizon)))")
    }
    print("  → any real onset LATER than its fragment's horizon is unreachable by both onset passes.")
    print("")
    print("  sweep (everything else held at defaults):")
    print("    onsetSearchEpochs   onset            wake             asleep")
    for k in [d.onsetSearchEpochs, 96, 192, 288, 384] {
        let tuned = SleepStaging.Tuning(onsetSearchEpochs: k)
        let s = SleepStaging.classify(from: night, temperatures: tempsInSpan, epoch: epoch, tuning: tuned)
        let w = SleepStaging.sleepWindow(s)
        let tag = k == d.onsetSearchEpochs ? " (default)" : ""
        print("    \(String(k).padded(6))\(tag.padded(12))\(t(w?.onset).padded(17))\(t(w?.wake).padded(17))\(dur(SleepStaging.totalAsleep(s)))")
    }

    // ── 8. HR-gate margin sweep ──────────────────────────────────────────────────────────
    // The coarse gate's margin decides whether a sedentary evening survives as "sleep" at
    // all. If tightening it collapses the block start onto the real bedtime, the gate — not
    // staging — is where the night is being lost.
    rule("8. coarse HR-gate margin sweep (default \(ActivityPeriod.awakeHRMarginBPM) bpm)")
    print("    margin   main block start   end                span")
    for m in [ActivityPeriod.awakeHRMarginBPM, 20, 15, 12, 10, 8] {
        let g = ActivityPeriod.detectFromMotion(motion,
                                                temperatureSamples: tempsInSpan,
                                                heartRateSamples: hr,
                                                sleepVitalTimes: vitals,
                                                activityQuiet: quiet,
                                                awakeHRMargin: m)
        let b = ActivityPeriod.mainSleepBlock(g)
        let tag = m == ActivityPeriod.awakeHRMarginBPM ? "*" : " "
        print("    \(String(m).padded(3))\(tag.padded(6))\(t(b?.start).padded(19))\(t(b?.end).padded(19))"
              + (b.map { dur($0.duration) } ?? "—"))
    }
    print("    (* = shipping default)")

    // ── 9b. Staging wake-margin sweep ────────────────────────────────────────────────────
    // `wakeHRMarginBPM` decides, per epoch, whether smoothed HR sits far enough above the
    // fragment's sleeping floor to be WAKE. It is the one knob that separates quiet
    // wakefulness from sleep, and it is a fixed bpm — so it fails for a wearer whose sitting
    // HR and sleeping HR differ by less than the margin. `earliestAsleep` is the tell: if it
    // jumps hours later as the margin tightens, the leading "sleep" was HR-indistinguishable.
    rule("9b. staging wake margin sweep (default \(Int(d.wakeHRMarginBPM)) bpm above the fragment floor)")
    print("    margin   onset            wake             asleep    of which Deep")
    for m in [d.wakeHRMarginBPM, 15, 12, 10, 9, 8, 6] {
        let tuned = SleepStaging.Tuning(wakeHRMarginBPM: m)
        let sg = SleepStaging.classify(from: night, temperatures: tempsInSpan, epoch: epoch, tuning: tuned)
        let w = SleepStaging.sleepWindow(sg)
        let deep = SleepStaging.stageTotals(sg)[.asleepDeep] ?? 0
        let tag = m == d.wakeHRMarginBPM ? "*" : " "
        print("    \(String(Int(m)).padded(3))\(tag.padded(6))\(t(w?.onset).padded(17))"
              + "\(t(w?.wake).padded(17))\(dur(SleepStaging.totalAsleep(sg)).padded(10))\(dur(deep))")
    }
    print("    (* = shipping default)")

    // ── 8b. Desk-activity gate (#204) ────────────────────────────────────────────────────
    rule("8b. desk-activity gate — zero-share threshold sweep (default \(ActivityPeriod.deskWakeZeroShareThreshold))")
    // Only the COARSE half is swept here: `latestNightRecords` reads the module constant, so a
    // staged-onset column would be computed on the shipping window at every row and read as if the
    // knob had not moved. Section 6 above is the staged result at the shipping default.
    print("    thresh   main block start   end                span")
    for th in [0.0, 0.20, 0.30, ActivityPeriod.deskWakeZeroShareThreshold, 0.45, 0.60] {
        let g = ActivityPeriod.detectFromMotion(motion, temperatureSamples: tempsInSpan,
                                                heartRateSamples: hr, sleepVitalTimes: vitals,
                                                activityQuiet: quiet, threshold: th)
        let b = ActivityPeriod.mainSleepBlock(g)
        let tag = th == ActivityPeriod.deskWakeZeroShareThreshold ? "*" : (th == 0 ? "off" : "")
        print("    \(String(format: "%.2f", th).padded(6))\(tag.padded(4))\(t(b?.start).padded(19))"
              + "\(t(b?.end).padded(19))\(b.map { dur($0.duration) } ?? "—")")
    }
    print("    (* = shipping default;  off = gate disabled, pre-#204 behaviour)")

    // ── 9. Naps ──────────────────────────────────────────────────────────────────────────
    // A SEPARATE path to Apple Health. `NapDetection.naps` writes every accepted daytime
    // still-block as sleep (`HealthKitWriter.flushNaps`), with its own staged Deep/Light/REM
    // hypnogram — so an evening block that never entered the night above can still land in
    // Health and be folded into "the night" by any app that aggregates sleep samples.
    //
    // ⚠️ THE HR GATE IS NOT APPLIED ON THIS PATH. `NapDetection.naps` calls
    // `detectFromMotion(timeline, temperatureSamples:)` with NO heartRateSamples, so the
    // awake-but-still defence that section 2 measured is inert here. The only physiological
    // gate a nap must clear is `minNapSleepVitalsShare`.
    rule("9. naps — the OTHER path into Apple Health (HR gate NOT applied here)")
    let mainBlock = ActivityPeriod.mainSleepBlock(gated)
    let naps = NapDetection.naps(from: records, mainSleep: mainBlock,
                                 temperatures: tempsInSpan, epoch: epoch)
    if naps.isEmpty {
        print("  no naps detected")
    }
    for n in naps {
        let stages = SleepStaging.stageTotals(n.segments)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) \(dur($0.value))" }
            .joined(separator: " ")
        print("  \(t(n.start)) → \(t(n.end))  \(dur(n.duration).padded(7))"
              + "  asleep \(dur(n.asleep).padded(7))\(n.isLongNap ? "  [isLongNap]" : "")")
        print("        → written to Apple Health as: \(stages)")
    }

    // Every candidate the nap path considered, with the reason it was kept or dropped —
    // `sleepVitalsShare` is private, so it is recomputed here from the public `layout`
    // (same rule: worn epochs whose layout is .sleepVitals, over all worn epochs).
    print("")
    print("  candidates (still blocks ≥ \(Int(NapDetection.minNapDuration / 60)) min, motion+wear gates only):")
    let napPeriods = ActivityPeriod.detectFromMotion(motion, temperatureSamples: tempsInSpan)
    for p in napPeriods where p.activity == .sleep && p.duration >= NapDetection.minNapDuration {
        let worn = records.filter {
            let x = $0.date(epoch: epoch)
            return x >= p.start && x <= p.end && $0.layout != .idle
        }
        let share = worn.isEmpty ? 0
            : Double(worn.filter { $0.layout == .sleepVitals }.count) / Double(worn.count)
        let overlapsNight = mainBlock.map { p.start < $0.end && p.end > $0.start } ?? false
        let overnight = SleepWindow.isOvernightBlock(start: p.start, end: p.end, calendar: calendar)
        let inside = hr.filter { $0.time >= p.start && $0.time <= p.end }.map(\.bpm)
        let verdict: String
        if overlapsNight { verdict = "dropped — overlaps the main night" }
        else if overnight { verdict = "dropped — overnight midpoint (not a nap)" }
        else if share < NapDetection.minNapSleepVitalsShare {
            verdict = String(format: "dropped — sleep-vitals share %.2f < %.2f", share, NapDetection.minNapSleepVitalsShare)
        } else {
            verdict = String(format: "KEPT as a nap — sleep-vitals share %.2f", share)
        }
        // What the HR gate WOULD have said, had this path applied it.
        let wouldGate: String = {
            guard let th = threshold, let m = median(inside), inside.count >= 3 else { return "" }
            return m > th ? "   [HR gate WOULD have rejected: median \(m) > \(th)]" : ""
        }()
        print("    \(t(p.start)) → \(t(p.end))  \(dur(p.duration).padded(7))"
              + "  medianHR \((median(inside).map { "\($0)" } ?? "—").padded(4))  \(verdict)\(wouldGate)")
    }
}

print("")

// MARK: - Small helpers

extension String {
    /// Left-justify to `n` columns so the tables above line up without a formatter dependency.
    func padded(_ n: Int) -> String {
        count >= n ? self + " " : self + String(repeating: " ", count: n - count)
    }
}
