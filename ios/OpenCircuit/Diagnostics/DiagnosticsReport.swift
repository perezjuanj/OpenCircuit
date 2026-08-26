import Foundation
import OpenCircuitKit

/// Assembles the shareable diagnostics bundle a tester sends us. It combines the highest-signal,
/// otherwise-unobtainable artifacts that diagnosed the 2026-06-24 overnight-drain bug from a live
/// device pull — so a tester we can't `devicectl` into can hand us the same conclusion:
///   • the EpochArchive gap report — which 0x4c epochs drained, and the HOLES where they didn't
///     (the key "why is my sleep blank" signal),
///   • the persisted nightly sleep summaries (the symptom the user sees),
///   • the sync cursors + activity log (when syncs ran and what each drained),
///   • optionally the raw-frame capture (protocol RE for a new ring generation).
/// Reachable from Device Info ▸ Diagnostics in Release builds (testers run TestFlight, not Debug),
/// with a privacy notice and MAC redaction on by default.
@MainActor
enum DiagnosticsReport {

    static func build(session: RingSession,
                      store: LocalStore?,
                      observability: ObservabilityStore = ObservabilityStore(),
                      defaults: UserDefaults = .standard,
                      redactMAC: Bool = true,
                      timeZone: TimeZone = .current,
                      now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        func t(_ d: Date?) -> String { d.map { fmt.string(from: $0) } ?? "—" }

        let fw = session.firmwareInfo
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let mac = fw.mac.map { redactMAC && $0.count >= 2 ? "··:··:··:··:··:" + String($0.suffix(2)) : $0 } ?? "(unread)"

        var s: [String] = []
        s.append("OpenCircuit — diagnostics bundle")
        s.append("Generated: \(t(now)) (\(timeZone.identifier))")
        s.append("App: \(short) (build \(build))")
        s.append("Firmware: \(fw.version.isEmpty ? "(unread)" : fw.version) · Generation: \(fw.generation.rawValue) · Model: \(fw.modelName.isEmpty ? "(unread)" : fw.modelName)")
        s.append("MAC: \(mac)")
        s.append("")
        s.append("# Privacy")
        s.append("This file contains your ring's overnight HR / HRV / SpO₂ history and sleep summaries.")
        s.append("It is personal health data — share it only with someone you trust to decode it.")
        s.append("")

        // 1) Epoch-archive gap report — the key sleep-loss signal.
        //
        // Decoded ONCE and reused by the `edges:` lines in section 2, which union it with the
        // persisted rows: `EpochArchiveStore.load()` re-reads and re-decodes a ~17 KB blob on every
        // call, and re-reading it per night would make a six-night section do seven decodes for one
        // ring's worth of data.
        let archive = session.archivedEpochs
        s.append(EpochArchiveDiagnostics.report(archive, timeZone: timeZone))
        s.append("")

        // 2) Nightly sleep summaries (the symptom) + the EDGE PROVENANCE behind each one.
        //
        // The `edges:` line is the part obtainable no other way. A truncated night looks perfectly
        // healthy in the summary above it — `R2_2026-08-17` reads 102 min in bed at efficiency
        // 1.0000, which is indistinguishable from a short good night — and the epoch-gap report in
        // section 1 is ring-wide, so it cannot say which hole belongs to which night's EDGE. This
        // line says whether the stream ran into the printed bedtime and continued past the printed
        // wake, so a bundle answers "was the night the tester complained about actually RECORDED?"
        // without a device pull.
        //
        // ⚠️ `reasons=` is the classifier's list, NOT a record of anything the tester saw. No
        // coverage caveat is shown in this build — the card is deliberately parked — so this line
        // is instrumentation collected AHEAD of the UI, which is the whole point: it is what will
        // let the eventual "does the caveat fire on nights people correct?" question be answered
        // from real phones instead of from 21 corpus nights.
        s.append("# Stored sleep summaries (latest first)")
        s.append("  edges: measured at the RECORDED window with heart-rate rows;"
                 + " material gap \(Int(WakeProvenance.materialGapSeconds / 60))m,"
                 + " continuous tolerance \(Int(WakeProvenance.continuousToleranceSeconds))s")
        // The `witness=` token on each line is the part that keeps this section honest about
        // ITSELF: the store rows alone are `SyncCursor.selectNew`'s forward-only output, so they
        // measure our cursor rather than the ring, and `store` on a night the ~30 h archive should
        // still cover is the tell that the archive was empty or out of reach.
        s.append("  witness=store means the epoch archive could not speak for that night;"
                 + " store+archive(n[,moved]) means n heart-rate-bearing epochs from the"
                 + " most-covering ring's archive sat inside the night ±"
                 + "\(Int(EpochArchive.retention / 3600))h, and `moved` that at least one of the"
                 + " three probe instants differs from the persisted-row answer — which may be an"
                 + " edge gap shrinking OR the retained-history floor reaching further back")
        let nights = (try? store?.recentSleepSummaries(limit: 6)) ?? []
        if nights.isEmpty {
            s.append("  (none stored)")
        } else {
            for n in nights {
                // An edited night's minutes describe the USER's window (`sleepEditCurrent*`), not
                // the recorded columns — printing the recorded window beside edited minutes reads
                // as an impossible night (asleep > span) and cost a real triage hours (2026-08-16).
                // Show the window the minutes belong to, and the recorded one for reference.
                let start = n.isManuallyEdited ? n.sleepEditCurrentInBedStart : n.inBedStart
                let end = n.isManuallyEdited ? n.sleepEditCurrentInBedEnd : n.inBedEnd
                let editedSuffix = n.isManuallyEdited
                    ? "  [edited; recorded \(t(n.inBedStart)) → \(t(n.inBedEnd))]" : ""
                s.append("  \(t(start)) → \(t(end))  asleep \(n.asleepMin)m"
                         + " (D\(n.deepMin)/R\(n.remMin)/L\(n.lightMin)/A\(n.awakeMin))  score \(n.sleepScore)"
                         + editedSuffix)
                s.append("      edges: \(edgeLine(n, store: store, archive: archive))")
            }
        }
        s.append("")

        // 3) Sync state — cursors + last success.
        s.append("# Sync state")
        s.append("  Last successful sync: \(t(observability.lastSuccessfulSync))")
        s.append("  Last background run:  \(t(observability.bgLastRun))")
        if let cursor = try? store?.loadCursor() {
            for kind in LocalStore.healthMirroredKinds + [.sleep] {
                if let last = cursor.last(kind) { s.append("  cursor \(kind.rawValue): \(t(last))") }
            }
        }
        s.append("")

        // 4) Sync activity log — when syncs ran and what they drained.
        let allRecs = observability.records().sorted { $0.date > $1.date }
        s.append("# Sync activity log (latest \(min(allRecs.count, 20)) of \(allRecs.count))")
        if allRecs.isEmpty { s.append("  (none)") }
        for r in allRecs.prefix(20) {
            s.append("  \(t(r.date))  \(r.kind.rawValue)  \(r.success ? "ok  " : "FAIL")  \(r.detail ?? "")")
        }
        s.append("")

        // 4b) Background scheduling diagnostics (#bg-observability) — the decisive triage for
        // "no background sync ever". Reads: whether register() was accepted (bgregister), whether
        // submit() succeeded or the named reason it failed (bgschedule), what iOS actually has queued
        // (bgpending), and whether iOS ever invoked the handler (bgtask "handler INVOKED"). If this
        // shows submits ok + pending requests but never a "handler INVOKED" line, iOS isn't granting;
        // a "SUBMIT FAILED — …" line names the cause (refresh disabled / id missing from Info.plist).
        s.append("# Background scheduling")
        s.append("  Last (re)scheduled: \(t(observability.bgLastScheduled))")
        // `hrv-pool` (#185 gate) and `sleep-sync` were being recorded but never surfaced — this
        // filter is the only thing that reaches a tester, and os_log does not. A permanently
        // suppressed HRV recovery, or a sleep drain that keeps skipping its re-stage, is otherwise
        // invisible in the one channel a TestFlight tester has. (Adversarial review.)
        // `focus` and `bgphase` join the whitelist: the Sleep Focus filter is OPT-IN (iOS never
        // invokes it until the user attaches it under Settings ▸ Focus ▸ Sleep ▸ Add Filter), and
        // without its breadcrumb "did Focus-off ever fire a sync?" is UNANSWERABLE from a tester
        // bundle — which is exactly the question the 2026-08-07 report turned on. Both are
        // low-volume (a couple of rows a day), so they cannot crowd out the scheduling lines.
        let bgSources: Set<String> = ["bgregister", "bgschedule", "bgpending", "bgtask",
                                      "bgphase", "focus", "hrv-pool", "sleep-sync"]
        let bgLog = observability.metricRecords()
            .filter { bgSources.contains($0.source) }
            .sorted { $0.date > $1.date }
        if bgLog.isEmpty { s.append("  (no scheduling events recorded)") }
        for r in bgLog.prefix(24) {
            s.append("  \(t(r.date))  \(r.source)  \(r.detail)")
        }
        s.append("")

        // 4c) Per-channel drain outcomes (#188 follow-up). These were being recorded and never
        // surfaced, so diagnosing the 2026-08-07 whole-night loss required decoding the raw-frame
        // capture by hand to find out what the morning drain actually did. `history-drain` carries
        // one line per channel (outcome / ack / page counts / records added) and `history-orphan`
        // records acked-but-unattributed pages — together they say whether a drain ran, what it
        // pulled, and whether anything arrived outside it.
        //
        // Kept in its OWN section with its own budget on purpose: these fire ~2-3× per drain and
        // ~20 drains a day, so folding them into the scheduling whitelist above would evict the
        // bgschedule/bgtask lines that answer a different question.
        let drainSources: Set<String> = ["history-drain", "history-orphan", "archive-repair"]
        let drainLog = observability.metricRecords()
            .filter { drainSources.contains($0.source) }
            .sorted { $0.date > $1.date }
        s.append("# History drains (latest \(min(drainLog.count, 40)) of \(drainLog.count))")
        if drainLog.isEmpty { s.append("  (no drain events recorded)") }
        for r in drainLog.prefix(40) {
            s.append("  \(t(r.date))  \(r.source)  \(r.detail)")
        }
        s.append("")

        // 5) Headache signals (#183) — the remote-debugging section for the overnight-signals
        // detector. It exists because the maintainer does not get headaches: TestFlight testers are
        // the ONLY source of ground truth for this feature, and a detector whose inputs are silently
        // ABSENT emits the same calm "nothing unusual for you" card as one that is working. The
        // per-feature presence table is the part obtainable no other way — from one export it says
        // whether overnight skin temp is ever captured on a tester's ring, and how often the all-day
        // channel starves.
        s.append(headacheSection(store: store, defaults: defaults, timeZone: timeZone, now: now))
        s.append("")

        // 6) Raw-frame capture — only present if the tester enabled it (protocol RE).
        if session.diagnosticsFrameCount > 0 {
            s.append("# Raw-frame capture")
            s.append(session.frameCaptureReport(redactMAC: redactMAC))
        }

        return s.joined(separator: "\n")
    }

    /// One night's acquisition verdict, as a single greppable line:
    /// `bed=resumedAfterGap(241m) wake=stoppedThenResumed(244m) reasons=noRecordingAfterWake`.
    ///
    /// Measured over the RECORDED window (`inBedStart`/`inBedEnd`), matching the data export's
    /// `sleepSessions[].edgeProvenance` — an edit changes what the app shows, not what was recorded,
    /// and a corrected wake landing inside a hole would otherwise shrink the evidence for the
    /// correction. On an unedited night that IS the window printed on the line above.
    ///
    /// `reasons=` is what `SleepConfidence.assess` CONCLUDED, not what any screen showed: nothing
    /// in this build renders a coverage caveat. `(none)` is a real and common answer — 12 of 21
    /// corpus nights.
    ///
    /// Three `fetchLimit = 1` reads per night, six nights: 18 indexed single-row fetches for the
    /// whole section. Never a scan, so this cannot become the reason a big archive times out the
    /// export. Every read is `try?`, like every other read in this file: a bundle must not be lost
    /// because one night could not be probed.
    ///
    /// ⚠️ THOSE ROWS ALONE MEASURE OUR CURSOR, NOT THE RING, so `archive` (this ring's ~30 h epoch
    /// archive, decoded once by `build`) is unioned in — the same union the export's
    /// `coverageFraction` already uses, extended to the two edge probes. The persisted rows are what
    /// survived `SyncCursor.selectNew`, which is strictly forward-only, so one late-stamped live
    /// sample strands every earlier epoch the ring delivers afterwards. 🟢 On the tester's night of
    /// 2026-08-25 (Gen 2 Air FR04.009, build 47) the export's copy of this probe — the SAME three
    /// store reads over the SAME recorded window — published `bedtimeVerdict=resumedAfterGap`,
    /// `bedtimeGapSeconds=6641` across 111 minutes that sit inside an unbroken run of 162
    /// consecutive 150 s epochs (20:36:37 → 03:19:07) with nothing missing, so this line
    /// would have read `bed=resumedAfterGap(111m)`: a triager's first row saying the ring stopped
    /// when it had not. `ExportCoverageWitness.edges` carries the derivation, the widening
    /// (`EpochArchive.retention`, not a number chosen here) and the proof that the union can only
    /// SHRINK a gap.
    ///
    /// The trailing `witness=` token names what actually answered, because the degeneration is
    /// otherwise invisible: an empty or out-of-reach archive silently returns the old store-only
    /// verdict and nothing else on the line changes.
    ///
    /// One archive, not all of them: this bundle is scoped to the ring that is CONNECTED (`session`),
    /// which is the ring a tester is complaining about. The export's copy of this probe passes every
    /// known ring's archive and lets `edges` pick the most-covering one; on the single-ring install
    /// that is every install in the field the two are the same array.
    private static func edgeLine(_ n: StoredSleepSummary,
                                 store: LocalStore?,
                                 archive: [BulkRecord]) -> String {
        guard let store, n.inBedEnd > n.inBedStart, n.inBedStart > .distantPast else {
            return "(no recorded window to measure)"
        }
        let start = n.inBedStart, end = n.inBedEnd
        let edges = ExportCoverageWitness.edges(
            archives: archive.isEmpty ? [] : [archive],
            storedLastBeforeStart: (try? store.latestSample(kind: .heartRate, before: start))?.start,
            storedFirstAfterEnd: (try? store.earliestSample(kind: .heartRate, after: end))?.start,
            storedEarliestRetained: (try? store.earliestSample(kind: .heartRate))?.start,
            inBedStart: start, inBedEnd: end)
        let assessment = SleepConfidence.assess(
            asleep: n.asSummary.totalAsleep, inBed: n.asSummary.inBed,
            coverage: edges.coverage)
        func gap(_ seconds: TimeInterval?) -> String {
            guard let seconds else { return "" }
            return "(\(Int((seconds / 60).rounded()))m)"
        }
        let reasons = assessment.reasons.map(SleepConfidence.exportName)
        return "bed=\(SleepConfidence.exportName(assessment.bedtime))"
            + gap(SleepConfidence.gapSeconds(assessment.bedtime))
            + "  wake=\(SleepConfidence.exportName(assessment.wake))"
            + gap(SleepConfidence.gapSeconds(assessment.wake))
            + "  witness=\(edges.witnessDescription)"
            + "  reasons=" + (reasons.isEmpty ? "(none)" : reasons.joined(separator: ","))
    }

    /// Trailing window for the headache section. Two weeks is long enough to expose a channel that
    /// is starving every night and short enough to keep the export readable; the frozen table itself
    /// is kept forever (docs/HEADACHE_SIGNALS.md §4.2) and its full size is printed alongside.
    private static let headacheWindowDays = 14

    /// The `# Headache signals` section (#183, Phase 2).
    ///
    /// Split out of `build` because it is the one section with real logic rather than a straight
    /// dump. Every read is `try?`/optional-chained exactly like the sections above: a user with the
    /// feature switched off — the default — has no flags, no frozen rows and no log, and must still
    /// get a complete, non-throwing export.
    ///
    /// The emitted `index` is a RELATIVE position on that one user's own scale, never a probability
    /// or a risk; it is comparable only against the same user's other rows.
    private static func headacheSection(store: LocalStore?,
                                        defaults: UserDefaults,
                                        timeZone: TimeZone,
                                        now: Date) -> String {
        var lines = ["# Headache signals"]

        var cal = Calendar.current
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let windowEnd = cal.date(byAdding: .day, value: 1, to: today) ?? now
        let windowStart = cal.date(byAdding: .day, value: -(headacheWindowDays - 1), to: today) ?? today

        let dayFmt = DateFormatter()
        dayFmt.timeZone = timeZone
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"

        // Feature flags. `promotedOnDayKey` is written by the Phase-3 unlock gate, which is not built
        // yet, so its stored type (an Int `yyyymmdd` like `TempFeverNotifications.dayKey`, or a
        // String) is not pinned — read it as an object and describe it rather than guessing a type
        // and printing "—" for a value that is actually there.
        let promoted = defaults.object(forKey: HeadacheDefaults.promotedOnDayKey)
            .map { String(describing: $0) } ?? "—"
        lines.append("  enabled: \(defaults.bool(forKey: HeadacheDefaults.enabled))"
                     + " · alerts unlocked: \(defaults.bool(forKey: HeadacheDefaults.unlocked))"
                     + " · promotedOnDayKey: \(promoted)"
                     + " · lookCount: \(defaults.integer(forKey: HeadacheDefaults.lookCount))")
        lines.append("  Window: \(dayFmt.string(from: windowStart)) → \(dayFmt.string(from: today))"
                     + " (\(headacheWindowDays) days, \(timeZone.identifier))")
        lines.append("")

        // Frozen rows, decoded ONCE — both the per-row lines and the presence table read this.
        let rows = ((try? store?.riskDays(from: windowStart, to: windowEnd)) ?? [])
            .sorted { $0.day > $1.day }
        let decoded = rows.map(DecodedRiskRow.init)
        let totalRows = ((try? store?.riskDays(from: .distantPast, to: windowEnd)) ?? []).count
        let ringFeatureTotal = HeadacheSignals.Feature.allCases.filter(\.isRingDerived).count

        lines.append("Frozen daily rows (latest \(rows.count) of \(totalRows) — written once, never recomputed)")
        if decoded.isEmpty { lines.append("  (none — nothing frozen yet)") }
        for d in decoded {
            let r = d.row
            let flags = [r.sleepRestaged ? "restaged" : nil,
                         r.alerted ? "alerted" : nil,
                         r.postUnlock ? "postUnlock" : nil].compactMap { $0 }
            lines.append("  \(dayFmt.string(from: r.day))  index \(String(format: "%g", r.index))"
                         + "  \(bandName(r.bandRaw))"
                         + "  ring \(r.ringFeatureCount)/\(ringFeatureTotal)"
                         + "  coverage \(String(format: "%.2f", r.coverageFraction))"
                         + (flags.isEmpty ? "" : "  [\(flags.joined(separator: " "))]"))
            // The frozen numbers behind the index, per feature: ramp position `c`, the robust `z`
            // that produced it and the weight `w` actually used. Printed because §12 retires
            // `onsetZ`/`zClamp` from 🔴 PROVISIONAL off the observed z DISTRIBUTION, and the raw
            // inputs are gone — `StoredSample` prunes at 30 days, so a row exported today is the
            // only surviving evidence of the z it was scored on.
            let present = HeadacheSignals.Feature.allCases.compactMap { f -> String? in
                guard let rec = d.contributions[f], let c = rec.c else { return nil }
                let z = rec.z.map { String(format: "%+.2f", $0) } ?? "—"
                return "\(f.rawValue)=\(String(format: "%.2f", c)) (z \(z), w \(String(format: "%.2f", rec.w)))"
            }
            lines.append("      present: "
                         + (present.isEmpty ? "(none)" : present.joined(separator: ", ")))
            // A feature is PRESENT when the row froze a numeric contribution for it. Everything else
            // is absent, and the reason is the whole point of the line — "(no reason recorded)" is
            // itself a finding, because the engine is supposed to record one for every absence.
            let missing = HeadacheSignals.Feature.allCases.compactMap { f -> String? in
                guard !d.isPresent(f) else { return nil }
                return "\(f.rawValue)=\(d.absentReason(f))"
            }
            lines.append("      absent: "
                         + (missing.isEmpty ? "(none — every feature present)" : missing.joined(separator: ", ")))
        }
        lines.append("")

        // Per-feature presence rate — the table that separates "this tester's nights are typical"
        // from "this input has never once been measured on this tester's ring".
        let nameWidth = (HeadacheSignals.Feature.allCases.map(\.rawValue.count).max() ?? 0) + 2
        lines.append("Per-feature presence over those \(rows.count) row(s):")
        if decoded.isEmpty { lines.append("  (nothing to measure presence over)") }
        for f in HeadacheSignals.Feature.allCases where !decoded.isEmpty {
            var present = 0
            var reasons: [String: Int] = [:]
            for d in decoded {
                if d.isPresent(f) {
                    present += 1
                } else {
                    reasons[d.absentReason(f), default: 0] += 1
                }
            }
            let ranked = reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let name = f.rawValue + String(repeating: " ", count: max(0, nameWidth - f.rawValue.count))
            lines.append("  \(name)present \(present)/\(rows.count)"
                         + (ranked.isEmpty ? "" : " · absent: " + ranked.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                         + (f.isRingDerived ? "" : "   (cycle phase — not ring-derived)"))
        }
        // Drift canary. It fires ONLY when a column holds keys this build could not turn into a
        // single contribution record — not merely when a row froze nothing, which is a legitimate
        // thin day. The first version tested `contributions.isEmpty && ringFeatureCount > 0` while
        // the reader itself was mis-shaped, so it fired on 100 % of scored rows: a warning that is
        // always on carries no information and teaches its reader to skip it. If this line appears
        // now, the writer and this reader have genuinely diverged.
        let unreadable = decoded.filter(\.contributionsUnreadable).count
        if unreadable > 0 {
            lines.append("  WARNING: \(unreadable) row(s) have a contributionsJSON this build cannot"
                         + " decode (shape drift) — presence above understates those rows")
        }
        lines.append("")

        // Skin temp is LIVE-only (0x10/0x87) and is NOT in the drainable 0x4c history, so a window
        // that missed it can never be back-filled (project memory: skin-temp-capture). A 0 here means
        // `skinTempDeviation` can never contribute for this tester, whatever the presence table says.
        let nights = (try? store?.sleepSummaries(from: windowStart, to: windowEnd)) ?? []
        let withTemp = nights.filter { $0.skinTempC > 0 }.count
        lines.append("Nights with skinTempC > 0: \(withTemp)/\(headacheWindowDays)"
                     + " (\(nights.count) night(s) stored in the window)")

        // PRIVACY — COUNTS ONLY, and it must stay that way. This file is one a TESTER EMAILS TO A
        // STRANGER to get their sync debugged. A headache diary is sensitive personal health
        // information: NEVER emit the notes, the symptom tags, the trigger tags, the per-entry
        // severities or the onset timestamps here, however useful they look. The counts below are
        // all it takes to tell "the label series is empty" from "the detector isn't scoring", which
        // is the only question this export has to answer about the log.
        let entries = (try? store?.allHeadacheEntries()) ?? []
        let inWindow = entries.filter { $0.onset >= windowStart && $0.onset < windowEnd }.count
        let pending = ((try? store?.pendingHeadacheEntries()) ?? []).count
        let consumed = (defaults.array(forKey: HeadacheDefaults.consumedImportUUIDs) as? [String])?.count ?? 0
        lines.append("Headache log: \(entries.count) entries · \(inWindow) in the window"
                     + " · \(pending) awaiting the Apple Health mirror")
        lines.append("  by source: "
                     + HeadacheSource.allCases
                        .map { src in "\(src.rawValue) \(entries.filter { $0.source == src }.count)" }
                        .joined(separator: " · ")
                     + " · consumed import UUIDs \(consumed)")

        return lines.joined(separator: "\n")
    }

    /// One frozen row, read back through `HeadacheRiskCoding` — the ENGINE'S OWN codec, and
    /// deliberately not a second reading of the JSON here.
    ///
    /// This section originally re-derived the shape as `[Feature.rawValue: Double]` (what
    /// docs/HEADACHE_SIGNALS.md §4.2 first specified) while the engine writes a
    /// `HeadacheContributionRecord` — `{z, c, w}` — per feature. Every `as? Double` cast therefore
    /// failed, so on a perfectly healthy install every feature printed absent, every presence rate
    /// printed 0/N, and the export read as a ring that has never once measured skin temperature.
    /// `decodeContributions` had no caller anywhere, which is exactly why the drift went unseen;
    /// routing through it means the compiler, not a tester's export, absorbs the next shape change.
    /// `@MainActor` because it reads a `@Model` row's properties: nested types do not inherit the
    /// enclosing enum's isolation, and this one is built inside `headacheSection` on the main actor
    /// alongside every other store read here.
    @MainActor
    private struct DecodedRiskRow {
        let row: StoredHeadacheRisk
        let contributions: [HeadacheSignals.Feature: HeadacheContributionRecord]
        let absent: [HeadacheSignals.Feature: HeadacheSignals.AbsentReason]
        /// Verbatim `absentJSON` pairs. `decodeAbsent` drops a reason raw value this build does not
        /// know — a row written by a NEWER build — and that would print as "(no reason recorded)",
        /// i.e. as an engine bug that isn't one. Falling back to the raw string keeps the drift
        /// visible instead.
        let rawAbsent: [String: String]
        /// Key count of `contributionsJSON` read as plain JSON, `nil` when it is not a JSON object
        /// at all. The only way to tell "this day froze nothing" from "this column no longer
        /// decodes", which is the sole question the drift canary below is allowed to answer.
        let rawContributionKeys: Int?

        init(_ row: StoredHeadacheRisk) {
            self.row = row
            self.contributions = HeadacheRiskCoding.decodeContributions(row.contributionsJSON)
            self.absent = HeadacheRiskCoding.decodeAbsent(row.absentJSON)
            self.rawAbsent = (DiagnosticsReport.jsonObject(row.absentJSON) ?? [:])
                .compactMapValues { $0 as? String }
            self.rawContributionKeys = DiagnosticsReport.jsonObject(row.contributionsJSON)?.count
        }

        /// PRESENT means the row froze a numeric contribution. `c == nil` is ABSENT — and absent is
        /// never 0, because 0 means "measured, and ordinary" (`HeadacheContributionRecord`).
        func isPresent(_ f: HeadacheSignals.Feature) -> Bool { contributions[f]?.c != nil }

        func absentReason(_ f: HeadacheSignals.Feature) -> String {
            absent[f]?.rawValue ?? rawAbsent[f.rawValue] ?? "(no reason recorded)"
        }

        /// The contributions column carries data this build could not decode. `{}` and a row that
        /// legitimately froze nothing are SILENT — see the canary comment above.
        var contributionsUnreadable: Bool {
            guard contributions.isEmpty else { return false }
            guard let keys = rawContributionKeys else { return true }  // not even a JSON object
            return keys > 0                                            // keys present, none readable
        }
    }

    /// Raw JSON-object read of one of `StoredHeadacheRisk`'s two columns, used only where the typed
    /// codec cannot answer the question: how many keys a column actually holds (so an undecodable
    /// column can be told from an empty one) and the verbatim absence strings. `nil` means the text
    /// is not a JSON object at all — itself a finding, never a reason to fail the export: a single
    /// malformed row must not cost a tester the whole bundle.
    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// `StoredHeadacheRisk.bandRaw` → its name. A raw value the Kit no longer knows is printed as-is
    /// rather than dropped — an unmappable band is exactly the kind of drift this export is for.
    private static func bandName(_ raw: Int) -> String {
        guard let band = HeadacheSignals.Band(rawValue: raw) else { return "band?(\(raw))" }
        switch band {
        case .typical:  return "typical"
        case .elevated: return "elevated"
        case .flagged:  return "flagged"
        }
    }
}
