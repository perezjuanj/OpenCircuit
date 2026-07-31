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
        s.append(EpochArchiveDiagnostics.report(session.archivedEpochs, timeZone: timeZone))
        s.append("")

        // 2) Nightly sleep summaries (the symptom).
        s.append("# Stored sleep summaries (latest first)")
        let nights = (try? store?.recentSleepSummaries(limit: 6)) ?? []
        if nights.isEmpty {
            s.append("  (none stored)")
        } else {
            for n in nights {
                s.append("  \(t(n.inBedStart)) → \(t(n.inBedEnd))  asleep \(n.asleepMin)m"
                         + " (D\(n.deepMin)/R\(n.remMin)/L\(n.lightMin)/A\(n.awakeMin))  score \(n.sleepScore)")
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
        let bgSources: Set<String> = ["bgregister", "bgschedule", "bgpending", "bgtask"]
        let bgLog = observability.metricRecords()
            .filter { bgSources.contains($0.source) }
            .sorted { $0.date > $1.date }
        if bgLog.isEmpty { s.append("  (no scheduling events recorded)") }
        for r in bgLog.prefix(24) {
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
