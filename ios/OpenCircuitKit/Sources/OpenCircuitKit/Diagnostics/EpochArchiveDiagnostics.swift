// Pure diagnostics over the drained 0x4c epoch archive.
//
// This is the single most useful artifact for triaging "why is my sleep / HRV / Respiratory blank":
// it shows exactly which epochs the app actually drained and, crucially, the GAPS between them. A
// hole here = history the app NEVER pulled off the ring (e.g. an overnight backlog the resume pointer
// was walked past, discussion #111 / the 2026-06-24 overnight-drain bug) — which is invisible in a
// raw-frame capture but obvious here. Mirrors the by-hand `EpochArchive` analysis that diagnosed that
// bug, so a tester can hand us the same conclusion without a live device pull.
//
// Pure (Foundation only) so it unit-tests on the CLI; the app layer wraps it with the persisted
// archive bytes + the store summaries (see DiagnosticsReport).

import Foundation

public enum EpochArchiveDiagnostics {

    /// Minimum gap between consecutive epoch counters to flag as a hole. Epochs step 150 s, so a few
    /// multiples is normal cadence; past `defaultGapThreshold` it's a genuinely missing stretch.
    public static let defaultGapThreshold: TimeInterval = 6 * 60

    /// A shareable text section: span, layout/vitals coverage, and the gap report. `timeZone` formats
    /// the timestamps (the app passes `.current` so a tester reads local time; tests pin it to UTC).
    public static func report(_ records: [BulkRecord],
                              gapThreshold: TimeInterval = defaultGapThreshold,
                              timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
                              epoch: Int = Command.syncEpoch) -> String {
        var lines = ["# Epoch archive (drained 0x4c sleep/activity history)"]
        let sorted = records.sorted { $0.counter < $1.counter }
        guard let first = sorted.first, let last = sorted.last else {
            lines.append("(empty — nothing drained for the retained window, or archive cleared)")
            return lines.joined(separator: "\n")
        }

        let fmt = DateFormatter()
        fmt.timeZone = timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MM-dd HH:mm"
        func t(_ d: Date) -> String { fmt.string(from: d) }
        let offH = timeZone.secondsFromGMT() / 3600
        let offLabel = "UTC\(offH >= 0 ? "+" : "")\(offH)"

        var idle = 0, sleepV = 0, activity = 0, hr = 0, hrv = 0, spo2 = 0
        for r in sorted {
            switch r.layout {
            case .idle: idle += 1
            case .sleepVitals: sleepV += 1
            case .activity: activity += 1
            }
            if r.heartRate != nil { hr += 1 }
            if r.hrvRMSSD != nil { hrv += 1 }
            if r.spo2Percent != nil { spo2 += 1 }
        }

        lines.append("Epochs: \(sorted.count)   span: \(t(first.date(epoch: epoch))) → \(t(last.date(epoch: epoch))) (\(offLabel))")
        lines.append("Layout: sleepV \(sleepV) · activity \(activity) · idle \(idle)")
        lines.append("Vitals coverage: HR \(hr) · HRV \(hrv) · SpO2 \(spo2)")
        lines.append("")
        lines.append("Gaps > \(Int(gapThreshold / 60)) min (a hole = history NEVER drained — the key sleep-loss signal):")
        var anyGap = false
        for i in 1 ..< sorted.count {
            let gap = TimeInterval(Int(sorted[i].counter) - Int(sorted[i - 1].counter))
            if gap > gapThreshold {
                anyGap = true
                lines.append("  \(t(sorted[i - 1].date(epoch: epoch))) ──\(String(format: "%.1f", gap / 3600))h──> \(t(sorted[i].date(epoch: epoch)))")
            }
        }
        if !anyGap { lines.append("  (none — contiguous coverage)") }
        return lines.joined(separator: "\n")
    }
}
