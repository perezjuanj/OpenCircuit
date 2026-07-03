import SwiftUI

struct HistoricalHealthCheckView: View {
    let report: HealthKitHistoryInspector.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found \(report.nightsFound) Apple Health sleep nights in the last \(report.lookbackDays) days.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(report.metrics.enumerated()), id: \.offset) { _, metric in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: metric.baselineReady ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                        .foregroundStyle(metric.baselineReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title)
                            .font(.subheadline.weight(.semibold))
                        if metric.supportsCurrentBaseline {
                            Text("\(metric.nightsWithData) nights available. \(metric.baselineReady ? "Enough to start the current baseline." : "Need at least \(metric.minimumBaselineNights) nights to start the current baseline.")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(metric.nightsWithData) nights available in Apple Health.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }

            ForEach(Array(report.missingCapabilities.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}
