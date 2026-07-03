import SwiftUI
import UIKit
import OpenCircuitKit

// User-reachable observability screen (#44): freshness timestamps, whether iOS is actually
// running our background tasks, and a bounded log of recent sync outcomes — so a silent failure
// (a throttled BGTask, a stalled ring) becomes visible instead of invisible.

private enum LogPeriod: String, CaseIterable, Identifiable {
    case day       = "1d"
    case threeDays = "3d"
    case week      = "7d"
    case all       = "All"
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .day:       return 86_400
        case .threeDays: return 3 * 86_400
        case .week:      return 7 * 86_400
        case .all:       return nil
        }
    }
    func cutoff(from now: Date = Date()) -> Date? {
        seconds.map { now.addingTimeInterval(-$0) }
    }
}

struct ActivityLogView: View {
    var session: RingSession?
    private let store = ObservabilityStore()
    @State private var records: [TaskRecord] = []
    @State private var metricRecords: [MetricRecord] = []
    @State private var refreshStatus: UIBackgroundRefreshStatus = .available
    @State private var period: LogPeriod = .week
    @State private var shareItem: URL?
    @State private var showShare = false

    private var filteredRecords: [TaskRecord] {
        guard let cutoff = period.cutoff() else { return records }
        return records.filter { $0.date >= cutoff }
    }

    private var filteredMetricRecords: [MetricRecord] {
        guard let cutoff = period.cutoff() else { return metricRecords }
        return metricRecords.filter { $0.date >= cutoff }
    }

    /// Decode-sanity warnings worth surfacing here without opening Device Info: a firmware
    /// version different from the pinned/tested build, and any aggregate decode anomaly from
    /// the most recent drain (#decode-anomaly). Both are "this app might be reading the wrong
    /// bytes" signals, not "the ring/network is just being flaky" — distinct from the rest of
    /// this screen.
    private var decodeWarnings: [String] {
        var out: [String] = []
        if session?.firmwareInfo.hasFirmwareMismatch == true {
            out.append("Ring firmware (\(session?.firmwareInfo.version ?? "?")) differs from the "
                       + "tested build (\(FirmwareInfo.pinnedVersion)). Sensor byte offsets could differ.")
        }
        for anomaly in session?.lastSyncAnomalies ?? [] {
            switch anomaly {
            case .allZeroHRWhileWorn:
                out.append("Last sync had worn epochs but no valid heart rate decoded — possible format drift.")
            case .skinTempOutOfPhysicalRange:
                out.append("Recent skin-temperature readings were outside a plausible range for a sustained run.")
            }
        }
        return out
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(LogPeriod.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if !decodeWarnings.isEmpty {
                Section("Decode health") {
                    ForEach(decodeWarnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Freshness") {
                timeRow("Last successful sync", store.lastSuccessfulSync)
                timeRow("Last Health write", store.lastHealthWrite)
            }

            Section("Background tasks") {
                timeRow("Last background run", store.bgLastRun)
                timeRow("Last scheduled", store.bgLastScheduled)
                LabeledContent("Background App Refresh", value: refreshStatusText)
                if refreshStatus != .available {
                    Text("iOS is limiting background activity. Turn on Settings ▸ General ▸ "
                         + "Background App Refresh so the ring can sync while the app is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Background heart-rate runs at iOS's discretion (usually overnight while "
                     + "charging) and is best-effort — daytime background HR is not guaranteed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Sync activity (\(filteredRecords.count))") {
                if filteredRecords.isEmpty {
                    Text(period == .all ? "No background activity recorded yet."
                                       : "No activity in the last \(period.rawValue).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRecords.reversed()) { record in
                        recordRow(record)
                    }
                }
            }

            Section("Metric diagnostics (\(filteredMetricRecords.count))") {
                if filteredMetricRecords.isEmpty {
                    Text(period == .all ? "No metric-level capture diagnostics recorded yet."
                                       : "No metric events in the last \(period.rawValue).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredMetricRecords.reversed()) { record in
                        metricRecordRow(record)
                    }
                }
            }
        }
        .navigationTitle("Background activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { prepareShare() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = shareItem {
                ShareActivityView(url: url)
            }
        }
        .onAppear {
            records = store.records()
            metricRecords = store.metricRecords()
            refreshStatus = UIApplication.shared.backgroundRefreshStatus
        }
    }

    private func prepareShare() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = ["=== OpenCircuit activity log (\(period.rawValue)) ===",
                               "Exported: \(df.string(from: Date()))", ""]

        lines.append("--- Sync activity (\(filteredRecords.count)) ---")
        for r in filteredRecords.reversed() {
            let icon = r.success ? "✓" : "✗"
            let detail = r.detail.map { " — \($0)" } ?? ""
            lines.append("\(icon) [\(df.string(from: r.date))] \(kindLabel(r.kind))\(detail)")
        }

        lines.append("")
        lines.append("--- Metric diagnostics (\(filteredMetricRecords.count)) ---")
        for r in filteredMetricRecords.reversed() {
            lines.append("[\(df.string(from: r.date))] \(r.source): \(r.detail)")
        }

        let fileName = "opencircuit-log-\(period.rawValue)-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        shareItem = url
        showShare = true
    }

    private func timeRow(_ label: String, _ date: Date?) -> some View {
        LabeledContent(label) {
            if let date {
                Text(date, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            } else {
                Text("never").foregroundStyle(.tertiary)
            }
        }
    }

    private func recordRow(_ record: TaskRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.success ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(kindLabel(record.kind)).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(record.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let detail = record.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kindLabel(_ kind: TaskRecord.Kind) -> String {
        switch kind {
        case .appRefresh: return "App refresh"
        case .processing: return "Processing"
        case .foreground: return "Foreground sync"
        case .cbWake: return "Bluetooth wake"
        }
    }

    private func metricRecordRow(_ record: MetricRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.source).font(.subheadline.weight(.medium))
                Spacer()
                Text(record.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(record.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var refreshStatusText: String {
        switch refreshStatus {
        case .available: return "On"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}
