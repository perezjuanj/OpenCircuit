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

        // 5) Raw-frame capture — only present if the tester enabled it (protocol RE).
        if session.diagnosticsFrameCount > 0 {
            s.append("# Raw-frame capture")
            s.append(session.frameCaptureReport(redactMAC: redactMAC))
        }

        return s.joined(separator: "\n")
    }
}
