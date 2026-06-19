import SwiftUI
import SwiftData
import OpenCircuitKit

/// Local data export screen (#80). Lets the user pick a date range and format
/// (CSV or JSON), then shares the exported file via the system share sheet.
///
/// All exported data comes from the local SwiftData store — no network calls.
/// The export is entirely opt-in and is triggered only by an explicit user tap.
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var startDate: Date = Calendar.current.date(
        byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var format: ExportFormat = .csv
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isExporting = false
    @State private var errorMessage: String?

    enum ExportFormat: String, CaseIterable {
        case csv  = "CSV"
        case json = "JSON"
    }

    var body: some View {
        Form {
            Section("Date range") {
                DatePicker("Start", selection: $startDate,
                           in: ...endDate, displayedComponents: .date)
                DatePicker("End", selection: $endDate,
                           in: startDate..., displayedComponents: .date)
            }

            Section("Format") {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    Task { await runExport() }
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Preparing export…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Text("Exports all stored samples (HR, SpO₂, temperature, HRV, RR), "
                     + "nightly sleep summaries, and daily step rollups for the selected range. "
                     + "Data stays on your device and is only shared when YOU tap Export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data Export")
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareActivityView(url: url)
            }
        }
    }

    // MARK: - Export

    @MainActor
    private func runExport() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        let store = LocalStore(modelContext)
        let rangeStart = Calendar.current.startOfDay(for: startDate)
        let rangeEnd   = Calendar.current.date(byAdding: .day, value: 1,
                                               to: Calendar.current.startOfDay(for: endDate)) ?? endDate

        // Collect samples for all mirrored kinds
        var sampleRows: [ExportEngine.SampleRow] = []
        for kind in LocalStore.healthMirroredKinds {
            let samples = (try? store.samples(kind: kind, from: rangeStart, to: rangeEnd)) ?? []
            sampleRows += samples.map {
                ExportEngine.SampleRow(kind: $0.kind.rawValue,
                                       start: $0.start, end: $0.end, value: $0.value)
            }
        }
        sampleRows.sort { $0.start < $1.start }

        // Collect sleep summaries
        let nights = (try? store.recentSleepSummaries(limit: 1_000)) ?? []
        let sleepRows = nights
            .filter { $0.night >= rangeStart && $0.night < rangeEnd }
            .map {
                ExportEngine.SleepRow(
                    night: $0.night, asleepMin: $0.asleepMin,
                    deepMin: $0.deepMin, lightMin: $0.lightMin,
                    remMin: $0.remMin, awakeMin: $0.awakeMin,
                    efficiency: $0.efficiency, skinTempC: $0.skinTempC,
                    sleepScore: $0.sleepScore, stressScore: $0.stressScore)
            }

        // Collect daily rollups
        let dailies = (try? store.recentDailies(limit: 1_000)) ?? []
        let dailyRows = dailies
            .filter { $0.day >= rangeStart && $0.day < rangeEnd }
            .map { ExportEngine.DailyRow(day: $0.day, steps: $0.steps) }

        // Serialise
        let content: String
        let ext: String
        switch format {
        case .csv:
            content = [
                ExportEngine.samplesCSV(sampleRows),
                "",
                ExportEngine.sleepCSV(sleepRows),
                "",
                ExportEngine.dailyCSV(dailyRows)
            ].joined(separator: "\n")
            ext = "csv"
        case .json:
            guard let json = ExportEngine.toJSON(samples: sampleRows, sleep: sleepRows,
                                                  daily: dailyRows) else {
                errorMessage = "Failed to serialise JSON — please try again."
                return
            }
            content = json
            ext = "json"
        }

        // Write to a temp file
        let fileName = "opencircuit-export-\(isoDate(Date())).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to write export file: \(error.localizedDescription)"
            return
        }

        exportURL = url
        showShareSheet = true
    }

    private func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}

// MARK: - UIActivityViewController bridge

/// Wraps `UIActivityViewController` for the system share sheet (iOS 17 compatible).
private struct ShareActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
