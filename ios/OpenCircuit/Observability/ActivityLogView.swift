import SwiftUI
import UIKit

// User-reachable observability screen (#44): freshness timestamps, whether iOS is actually
// running our background tasks, and a bounded log of recent sync outcomes — so a silent failure
// (a throttled BGTask, a stalled ring) becomes visible instead of invisible.

struct ActivityLogView: View {
    private let store = ObservabilityStore()
    @State private var records: [TaskRecord] = []
    @State private var refreshStatus: UIBackgroundRefreshStatus = .available

    var body: some View {
        List {
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

            Section("Recent activity") {
                if records.isEmpty {
                    Text("No background activity recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records.reversed()) { record in
                        recordRow(record)
                    }
                }
            }
        }
        .navigationTitle("Background activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            records = store.records()
            refreshStatus = UIApplication.shared.backgroundRefreshStatus
        }
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
