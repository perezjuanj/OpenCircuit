import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import OpenCircuitKit

/// Local data export screen (#80). Lets the user choose WHAT to export (a date range, one recorded
/// night, or only the nights they haven't exported yet), pick CSV or JSON, and either save straight
/// into a folder they chose once or share the file through the system sheet.
///
/// All exported data comes from the local SwiftData store — no network calls, no BLE, no HealthKit.
/// The export is entirely opt-in and is triggered only by an explicit user tap.
///
/// The row collection itself lives in `ExportBuilder`, shared with `ExportRingDataIntent`, so the
/// file a Shortcut produces is byte-for-byte the file this screen produces.
struct ExportView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var mode: ModeChoice = .dateRange
    @State private var startDate: Date = Calendar.current.date(
        byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var format: ExportBuilder.Format = .csv
    @State private var selectedNight: Date?
    @State private var nights: [NightOption] = []
    @State private var lastExported: Date?
    @State private var newSessionCount = 0

    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    /// Held between building the file and the share sheet CLOSING, so the export watermark advances
    /// only once the user has actually sent the file somewhere — a cancelled share must not consume
    /// the nights it contained.
    @State private var pendingSharePayload: ExportBuilder.Payload?

    @State private var showFolderImporter = false
    @State private var folderName: String? = ExportDestination.chosenFolderName

    enum ModeChoice: String, CaseIterable, Identifiable {
        case dateRange
        case singleSession
        case newSessions

        var id: String { rawValue }
        var label: String {
            switch self {
            case .dateRange:     return "Date range"
            case .singleSession: return "One night"
            case .newSessions:   return "New only"
            }
        }
    }

    /// One selectable recorded night.
    struct NightOption: Identifiable, Equatable {
        let night: Date
        let asleepMin: Int
        var id: Date { night }

        var label: String {
            let day = night.formatted(date: .abbreviated, time: .omitted)
            guard asleepMin > 0 else { return day }
            return "\(day) — \(asleepMin / 60)h \(asleepMin % 60)m"
        }
    }

    var body: some View {
        Form {
            Section("What to export") {
                Picker("Mode", selection: $mode) {
                    ForEach(ModeChoice.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .dateRange:
                    DatePicker("Start", selection: $startDate,
                               in: ...endDate, displayedComponents: .date)
                    DatePicker("End", selection: $endDate,
                               in: startDate..., displayedComponents: .date)
                    Text("Up to \(ExportBuilder.maxExportDays) days per file. A longer range is "
                         + "exported one year at a time, ending on the End date.")
                        .font(.caption).foregroundStyle(.secondary)

                case .singleSession:
                    if nights.isEmpty {
                        Text("No recorded nights yet — sync the ring first.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Night", selection: $selectedNight) {
                            ForEach(nights) { option in
                                Text(option.label).tag(Optional(option.night))
                            }
                        }
                    }

                case .newSessions:
                    LabeledContent("Last exported",
                                   value: lastExported.map {
                                       $0.formatted(date: .abbreviated, time: .omitted)
                                   } ?? "Never")
                    Text(newSessionsSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Format") {
                Picker("Format", selection: $format) {
                    ForEach(ExportBuilder.Format.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Destination") {
                LabeledContent("Save to", value: folderName ?? "Share sheet")
                Button("Choose folder…") { showFolderImporter = true }
                if folderName != nil {
                    Button("Use share sheet instead", role: .destructive) {
                        ExportDestination.forget()
                        folderName = nil
                        statusMessage = nil
                    }
                }
                Text(folderName == nil
                     ? "Exports open the share sheet so you can file them wherever you like. Pick a "
                       + "folder to save straight there every time."
                     : "Exports are written into this folder. If it ever becomes unavailable, "
                       + "OpenCircuit falls back to the share sheet instead of failing.")
                    .font(.caption).foregroundStyle(.secondary)
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

                if let status = statusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                // "how much of this night the app holds" — NOT "how much the ring delivered". The
                // file's own coverage note says the export cannot tell an unworn ring, an undrained
                // backlog and lost epochs apart, so the screen must not attribute a shortfall to the
                // ring either.
                Text("Each export carries the raw timestamped measurements the ring delivered — heart "
                     + "rate, HRV, SpO₂, respiratory rate, skin temperature, step deltas — plus one "
                     + "row per sleep session: bedtime and wake times, the per-epoch sleep stages, the "
                     + "overnight SpO₂ (apnea) figures, and a coverage measurement showing how much of "
                     + "the night this app currently holds. Every section is labelled measured, "
                     + "derived or diagnostic, and the file records the app build, ring model and "
                     + "firmware, and which timezone its timestamps are in.")
                    .font(.caption).foregroundStyle(.secondary)
                // The honest half. These caveats are also written into the file's own `notes` — in
                // BOTH formats, CSV included — but a reader who never opens the file should still
                // meet them before they act on a number.
                Text("Sleep stages are an ON-DEVICE ESTIMATE — the ring transmits no hypnogram, so "
                     + "stage totals approximate the RingConn app's but the placement of individual "
                     + "cycles is not validated. The overnight lowest SpO₂, time below 90 % and ODI "
                     + "are EXPERIMENTAL estimates; only the average SpO₂ is validated (±1 %) against "
                     + "the RingConn app. Nothing leaves this device unless you share or save the file "
                     + "yourself, and the ring's MAC address and your device's name are never included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data Export")
        .task { refreshSessions() }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            chooseFolder(result)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareActivityView(url: url) { completed in
                    shareFinished(completed)
                }
            }
        }
    }

    /// Wording for the "New only" mode. Split out because "nothing new SINCE THEN" is a lie on an
    /// install that has never exported anything — there is no "then" yet.
    private var newSessionsSummary: String {
        if newSessionCount > 0 {
            return "\(newSessionCount) session\(newSessionCount == 1 ? "" : "s") ready to export."
        }
        return lastExported == nil
            ? "No sleep sessions recorded yet — sync the ring first."
            : "No sleep sessions recorded since then."
    }

    // MARK: - Loading

    /// Refresh the night list and the watermark state.
    ///
    /// The 120-night limit is arbitrary and display-only — it has no bearing on what an export
    /// contains, it just keeps a long-lived install from scanning its whole sleep table to fill a
    /// picker. `.newSessions` still asks the STORE what is unexported, not this list.
    private func refreshSessions() {
        let store = LocalStore(modelContext)
        let rows = (try? store.recentSleepSummaries(limit: 120)) ?? []
        nights = rows.map { NightOption(night: $0.night, asleepMin: $0.asleepMin) }
        if selectedNight == nil || !nights.contains(where: { $0.night == selectedNight }) {
            selectedNight = nights.first?.night
        }
        let watermark = store.lastExportWatermark()
        lastExported = watermark
        // Counted from the same bounded window, so it is a floor rather than a total. The store is
        // still the authority at export time — this number only sizes the user's expectation.
        newSessionCount = rows.filter { row in
            guard let watermark else { return true }
            return row.night > watermark
        }.count
    }

    // MARK: - Destination

    private func chooseFolder(_ result: Swift.Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if ExportDestination.remember(folder: url) {
                folderName = ExportDestination.chosenFolderName
                statusMessage = "Exports will be saved to \(url.lastPathComponent)."
            } else {
                // Keeping the bookmark failed, so a later export could not reach the folder. Say so
                // now rather than showing a folder name that silently won't be used.
                errorMessage = "Couldn't keep access to that folder — exports will use the share sheet."
            }
        case .failure(let error):
            errorMessage = "Couldn't open that folder: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    @MainActor
    private func runExport() async {
        isExporting = true
        errorMessage = nil
        statusMessage = nil
        defer { isExporting = false }

        // Give the main runloop a turn before the build takes the main thread, so the disabled
        // button and its spinner get a chance to render. `ExportBuilder` and `LocalStore` are both
        // `@MainActor` and the build is synchronous, so without a suspension point the whole export
        // ran inside the SAME main-actor turn that set `isExporting`: the progress state was
        // written and never drawn, and the screen simply froze with an enabled-looking button.
        //
        // This is a scheduling hop, not a fix for a long build — the actual protection against a
        // main-thread stall is the bound (`ExportBuilder.maxExportDays`), not this line.
        await Task.yield()

        let store = LocalStore(modelContext)
        let builderMode: ExportBuilder.Mode
        switch mode {
        case .dateRange:
            builderMode = .dateRange(start: startDate, end: endDate)
        case .singleSession:
            guard let night = selectedNight else {
                errorMessage = "Pick a night to export."
                return
            }
            builderMode = .singleSession(night: night)
        case .newSessions:
            builderMode = .newSessions
        }

        do {
            switch try ExportBuilder.build(store: store, mode: builderMode, format: format) {
            case .nothingNew(let since):
                // An empty file would look like a night that contained nothing. Say what actually
                // happened instead.
                statusMessage = since.map {
                    "Nothing new — every night up to "
                    + "\($0.formatted(date: .abbreviated, time: .omitted)) has already been exported."
                } ?? "There are no recorded nights to export yet."

            case .file(let payload):
                switch try ExportDestination.deliver(payload) {
                case .savedToFolder(_, let folder):
                    // Durably written: the watermark may advance now (I2/I3).
                    commitWatermark(payload, store: store)
                    statusMessage = joined("Saved \(payload.fileName) to \(folder).",
                                           payload.rangeNotice)
                    refreshSessions()

                case .temporaryFile(let url, let reason):
                    // NOT yet delivered — the user still has to pick a destination in the sheet, and
                    // they may cancel. The watermark waits for `shareFinished`.
                    pendingSharePayload = payload
                    exportURL = url
                    statusMessage = joined(reason, payload.rangeNotice)
                    showShareSheet = true
                }
            }
        } catch ExportBuilder.Failure.sessionNotStored {
            errorMessage = "That night is no longer in the local store."
        } catch ExportBuilder.Failure.serializationFailed {
            errorMessage = "Failed to serialise the export — please try again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Join the delivery message with the range notice, dropping whichever is absent. The notice
    /// must survive on BOTH delivery paths — a clamped range the user is never told about is a file
    /// that quietly covers less than they asked for.
    private func joined(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// The share sheet closed. `completed` is true only when the user actually sent the file
    /// somewhere; a cancel leaves the watermark where it was, so those nights stay claimable.
    private func shareFinished(_ completed: Bool) {
        guard let payload = pendingSharePayload else { return }
        pendingSharePayload = nil
        guard completed else { return }
        commitWatermark(payload, store: LocalStore(modelContext))
        refreshSessions()
    }

    /// Failing to persist the watermark costs a duplicate export next time, which is strictly better
    /// than telling the user their finished export failed — so it is swallowed on purpose.
    private func commitWatermark(_ payload: ExportBuilder.Payload, store: LocalStore) {
        try? ExportBuilder.commitWatermark(payload, store: store)
    }
}

// MARK: - UIActivityViewController bridge

/// Wraps `UIActivityViewController` for the system share sheet (iOS 17 compatible).
/// Internal (not file-private) — also reused by the Debug card's raw-capture export (ContentView).
struct ShareActivityView: UIViewControllerRepresentable {
    let url: URL
    /// Called when the sheet closes, with whether the user actually completed a share. Optional and
    /// defaulted so existing call sites that only want to present the sheet are unchanged.
    var onFinish: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let onFinish {
            controller.completionWithItemsHandler = { _, completed, _, _ in onFinish(completed) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
