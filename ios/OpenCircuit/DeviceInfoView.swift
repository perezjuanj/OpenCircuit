import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import OpenCircuitKit

/// Read-only device information screen (#79). Shows the DIS fields recovered from the
/// connected ring — firmware version (with generation label), manufacturer, hardware
/// revision, and MAC address — plus a non-alarming banner when the firmware version
/// differs from the pinned build we reverse-engineered.
///
/// Data source: the `RingSession`'s `firmwareInfo` property, populated incrementally
/// as each DIS characteristic is read after connection. Unread fields show "--".
struct DeviceInfoView: View {
    var session: RingSession?
    @State private var showRingPicker = false
    /// Shared scanner — used for the "Disconnect ring" control (#140) so it works even when `session`
    /// is nil (i.e. the app is stuck "Connecting…" to a ring that's gone).
    @State private var scanner = RingScanner.shared
    /// Confirmation gate for the destructive Disconnect action (#140).
    @State private var showDisconnectConfirm = false
    @Environment(\.modelContext) private var modelContext
    @AppStorage(RingSession.diagnosticsCaptureKey) private var captureEnabled = false
    @State private var diagnosticsURL: URL?
    @State private var showDiagnosticShare = false
    @State private var diagnosticsError: String?
    @State private var showRepairImporter = false
    @State private var repairResult: String?
    /// Set when the picked export's ring identity doesn't match this one — the merge waits on an
    /// explicit confirmation rather than silently polluting a per-ring archive.
    @State private var pendingForeignImport: (DiagnosticsFrameImport.Result, String, String)?
    /// A real export with the 1500-frame cap is well under 1 MB.
    private static let maxRepairFileBytes = 8 * 1_000_000
    /// Confirmation gate for airplane mode — it turns the ring's radio off and drops the link (#96).
    @State private var showAirplaneConfirm = false

    private var info: FirmwareInfo { session?.firmwareInfo ?? FirmwareInfo() }

    /// True only for a POSITIVELY identified Gen 2 Air, the one model RingConn doesn't ship the
    /// sleep-apnea assessment on (#186). Deliberately fails OPEN: `generation` is `.unknown` until
    /// the DIS Firmware-Revision read lands (and while `session` is nil), and every other case —
    /// Gen 1/2/3, unknown — keeps the normal toggle, so the unavailable state can never flash
    /// during connection.
    private var sleepApneaUnavailable: Bool { info.generation == .gen2Air }

    var body: some View {
        List {
            // FW-pin warning banner — only when a version IS known and it mismatches.
            if info.hasFirmwareMismatch {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Firmware version differs from tested build")
                                .font(.subheadline.weight(.medium))
                            Text("This app was reverse-engineered on \(FirmwareInfo.pinnedVersion). "
                                 + "The ring may still work, but some sensor offsets could differ. "
                                 + "If you see unexpected readings, check for app updates.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Firmware") {
                infoRow("Version",    value: info.version)
                infoRow("Generation", value: info.generation.rawValue)
                infoRow("Pinned build", value: FirmwareInfo.pinnedVersion)
            }

            Section("Hardware") {
                infoRow("Model",     value: info.modelName)
                infoRow("Manufacturer", value: info.manufacturer)
                infoRow("Hardware revision", value: info.hardwareRevision)
            }

            Section("Connectivity") {
                infoRow("MAC address", value: info.mac)
                Text("The MAC address is read from the Device Information Service "
                     + "(DIS 0x2A23 System ID). CoreBluetooth hides the live MAC on iOS; "
                     + "this is the only way to recover it without Bluetooth scanning permissions.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Ring hardware actions (#96, reverse-engineered from the official app): find-my-ring
            // blinks the LED to locate the ring; airplane mode turns its radio off to save power.
            Section {
                NavigationLink {
                    FindMyRingView(session: session)
                } label: {
                    Label("Find My Ring", systemImage: "wave.3.right")
                }
                .disabled(session?.ready != true)
                Button(role: .destructive) {
                    showAirplaneConfirm = true
                } label: {
                    Label("Turn on airplane mode", systemImage: "airplane")
                }
                .disabled(session?.ready != true)
            } header: {
                Text("Ring actions")
            } footer: {
                Text("Find My Ring shows how close the ring is over Bluetooth and can flash its LED so "
                     + "you can locate it. Airplane mode turns off the ring's Bluetooth to save power — "
                     + "the ring reconnects only after you put it back in the charging case (there's no "
                     + "way to turn it back on over Bluetooth).")
            }

            // Sleep-apnea assessment (#91). Arms the ring's dense overnight blood-oxygen recording;
            // the morning sync drains it and the results land on the Sleep card. Experimental.
            //
            // Gen 2 Air (#186): RingConn does NOT ship this feature on the Air (vendor comparison
            // table — Sleep Apnea Pattern: Gen 3 yes / Gen 2 yes / Gen 2 Air no). That's a PRODUCT
            // removal, not a sensor one: the Air still streams 0x47 PPG and real SpO₂, so we say so
            // out loud instead of silently hiding the row, and nothing else on the Air is gated.
            // UI-layer only — OpenCircuitKit stays device-agnostic.
            //
            // ⚠️ COPY CORRECTION (2026-08-27). This row said "Not available" and its footer told Air
            // owners "the ring never records the overnight burst". 🟢 That is FALSE — a Gen 2 Air
            // delivered a ≈5.67 h `0x48` burst. THE ARITHMETIC, so the next reader can redo it: a
            // real export carried `odi = 0.17638724911452186`, and `OSASpO2.summarize` defines
            // `odi = desaturationEvents / durationHours` with
            // `durationHours = totalSamples / sampleRateHz / 3600`. Inverting at ONE event gives
            // 5.6693 h — and 5.6693 × 4.15 Hz × 3600 = exactly 84,700 samples/channel. (Two events
            // would mean an 11.3 h night, so one is the only plausible reading; the integer sample
            // count does not discriminate between them.) The decode path is device-agnostic and
            // `SleepCardView.osaRow` gates only on `osaValidWindows > 0`, so those results DID reach
            // the Sleep card on that Air. Only the ARMING toggle is withheld here, and that is all
            // this row may claim. 🔴 HOW an unarmed Air came to record a burst is NOT established —
            // we never send `05 22 01` on this model — so claim no mechanism.
            Section {
                if sleepApneaUnavailable {
                    HStack {
                        Label("Sleep apnea assessment", systemImage: "lungs.fill")
                        Spacer()
                        Text("Not offered on this model")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else {
                    Toggle(isOn: Binding(
                        get: { session?.osaAssessmentArmed ?? false },
                        set: { session?.setOSAAssessment(armed: $0) }
                    )) {
                        Label("Sleep apnea assessment", systemImage: "lungs.fill")
                    }
                    .disabled(session?.ready != true)
                }
                osaBurstProvenanceRow()
            } header: {
                Text("Sleep apnea (experimental)")
            } footer: {
                if sleepApneaUnavailable {
                    Text("RingConn doesn't list the sleep-apnea assessment for the Gen 2 Air, so "
                         + "OpenCircuit doesn't offer the switch on this ring. That's about the "
                         + "feature, not the sensor — a Gen 2 Air has been seen recording a full "
                         + "night of the dense blood-oxygen data this assessment reads, and when "
                         + "that happens OpenCircuit decodes it and the results appear on the Sleep "
                         + "card just like on any other model. Your ring's blood oxygen, heart rate, "
                         + "and sleep tracking all work normally.")
                } else {
                    Text("Turn this on before bed and wear the ring overnight — it records a dense "
                         + "blood-oxygen reading. Open the app in the morning to sync, and the results appear "
                         + "on the Sleep card. Charge the ring above ~30% first so it lasts the night. This is "
                         + "an experimental estimate, not a medical diagnosis.")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { session?.automaticWorkoutDetectionEnabled ?? false },
                    set: { session?.setAutomaticWorkoutDetection(enabled: $0) }
                )) {
                    Label("Automatic Workout Detection", systemImage: "figure.run.circle")
                }
                .disabled(session?.ready != true || session?.syncing == true || session?.monitoring == true)
            } header: {
                Text("Workouts")
            } footer: {
                Text("The ring recognizes continuous workouts lasting at least 10 minutes and stores "
                     + "their heart-rate and motion samples. Open OpenCircuit within two days to sync "
                     + "and review detected periods; OpenCircuit notifies you when one arrives. This "
                     + "uses more battery, matching the RingConn feature.")
            }

            // Switching rings is uncommon (most people have one ring), so it lives here rather than
            // on the main screen. Opens a picker that scans for OTHER nearby rings — it keeps the
            // current link until you actually pick another, so cancelling is non-destructive. Data
            // from all rings stays in one shared timeline. (#multi-ring)
            Section {
                Button {
                    showRingPicker = true
                } label: {
                    Label("Connect a different ring", systemImage: "arrow.left.arrow.right")
                }
            } footer: {
                Text("Shows other nearby rings so you can switch. Each ring's data merges into one "
                     + "shared health timeline — switching never erases the other's data.")
            }

            // Disconnect / forget the ACTIVE ring (#140). Reads the SHARED scanner (not `session`) so
            // it's reachable even while the app is wedged "Connecting…" to a ring that's out of range /
            // gone. Only shown when there's an active ring to let go of (`hasSavedRing`). Non-destructive
            // to the remembered set: the ring stays in the picker for a one-tap reconnect.
            if scanner.hasSavedRing {
                Section {
                    Button(role: .destructive) {
                        showDisconnectConfirm = true
                    } label: {
                        Label("Disconnect ring", systemImage: "wifi.slash")
                    }
                } footer: {
                    Text("Stops automatically reconnecting and drops the current link. The ring stays "
                         + "in your list, so you can reconnect with one tap from “Connect a different ring.”")
                }
            }

            diagnosticsSection
        }
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect this ring?", isPresented: $showDisconnectConfirm,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { scanner.forgetActiveRing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenCircuit will stop reconnecting to this ring. It stays in your list for a one-tap "
                 + "reconnect from “Connect a different ring.”")
        }
        .confirmationDialog("Turn on airplane mode?", isPresented: $showAirplaneConfirm,
                            titleVisibility: .visible) {
            Button("Turn on airplane mode", role: .destructive) { session?.setAirplaneModeOn() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This turns off the ring's Bluetooth and disconnects it. To turn it back on, put the "
                 + "ring in its charging case — there's no way to re-enable Bluetooth remotely.")
        }
        .sheet(isPresented: $showRingPicker) { RingPickerSheet() }
        .sheet(isPresented: $showDiagnosticShare) {
            if let url = diagnosticsURL { DiagnosticShareView(url: url) }
        }
    }

    // MARK: - Diagnostics — exportable triage bundle (#111)
    //
    // Available in Release (testers run TestFlight, not Debug). "Export diagnostics" writes a text
    // bundle — the EpochArchive gap report (which sleep epochs drained + the holes where they
    // didn't), the stored nightly summaries, the sync cursors + activity log, and (if the capture
    // toggle is on) the raw history frames — so a tester we can't pull from a Mac can hand us the
    // same diagnosis we'd get from a live device dump. Assembled by `DiagnosticsReport`.

    private var diagnosticsSection: some View {
        Section {
            Button {
                exportDiagnostics()
            } label: {
                Label("Export diagnostics", systemImage: "square.and.arrow.up")
            }
            .disabled(session == nil)
            // Re-arm the BGTask chain and snapshot what iOS has queued, on demand (#bg-observability).
            // Tap this, wait a few seconds (the pending-requests probe is async), then Export
            // diagnostics — the "# Background scheduling" section then shows submit outcomes + the
            // pending requests, which is how we diagnose "no background sync ever runs".
            Button {
                let scheduler = BackgroundRefreshScheduler()
                scheduler.schedule()
                scheduler.scheduleProcessing()
                ObservabilityStore().recordScheduled()
                scheduler.probePendingRequests()
                ObservabilityStore().recordMetricEvent(source: "bgtask", detail: "manual reschedule+probe from Diagnostics")
            } label: {
                Label("Reschedule & probe background tasks", systemImage: "arrow.clockwise")
            }
            // Repair from a PREVIOUS export (#188). The raw-frame capture taps the inbound stream
            // above the retention gate, so a page that was acked-and-discarded is still in the
            // exported text even though its epoch never reached the archive — and the ring's resume
            // pointer moved past it long ago, so this file is the only remaining copy. Import merges
            // those records back and re-stages the night.
            Button {
                showRepairImporter = true
            } label: {
                Label("Repair from a diagnostics file", systemImage: "bandage")
            }
            .disabled(session == nil)
            if let repairResult {
                Text(repairResult).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Capture raw history frames", isOn: $captureEnabled)
            LabeledContent("Frames captured", value: "\(session?.diagnosticsFrameCount ?? 0)")
            if (session?.diagnosticsFrameCount ?? 0) > 0 {
                Button(role: .destructive) {
                    session?.clearDiagnosticsCapture()
                } label: {
                    Label("Clear frame capture", systemImage: "trash")
                }
            }
            if let err = diagnosticsError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("If your sleep, HRV, or other data isn't showing up, tap Export diagnostics and send "
                 + "us the file — it tells us exactly what your ring synced. The optional frame capture "
                 + "records raw bytes to help support new ring models; turn it on, wear the ring "
                 + "overnight, then export in the morning. The file contains your overnight HR/HRV/SpO₂ "
                 + "data — share it only with someone you trust.\n\n"
                 + "Repair reads an older diagnostics file from this ring and restores any sleep epochs "
                 + "it contains that are missing from the app. It only ever adds data.")
        }
        .alert("Different ring?", isPresented: Binding(
            get: { pendingForeignImport != nil },
            set: { if !$0 { pendingForeignImport = nil } })) {
            Button("Cancel", role: .cancel) { pendingForeignImport = nil }
            Button("Import anyway", role: .destructive) {
                if let (parsed, _, _) = pendingForeignImport, let session {
                    applyRepair(parsed, session: session)
                }
                pendingForeignImport = nil
            }
        } message: {
            if let (_, from, mine) = pendingForeignImport {
                Text("That file looks like it came from \(from), but this ring is \(mine). "
                     + "Importing it would mix another ring's history into this one.")
            }
        }
        .fileImporter(isPresented: $showRepairImporter,
                      allowedContentTypes: [.plainText, .text, .data],
                      allowsMultipleSelection: false) { result in
            repairFromDiagnostics(result)
        }
    }

    /// Merge epoch records recovered from a previously exported diagnostics file back into the
    /// archive, then re-stage. Additive only — `EpochArchive.merge` dedups by counter and
    /// `saveSleepSummary` is merge-protected, so a repair can only ever GROW a night.
    private func repairFromDiagnostics(_ result: Swift.Result<[URL], Error>) {
        repairResult = nil
        diagnosticsError = nil
        pendingForeignImport = nil
        guard let session else { return }
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // The picker accepts any file, so guard the size BEFORE reading it whole into memory on
            // the main actor. A real export (1500-frame cap) is well under 1 MB (#188 review).
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > Self.maxRepairFileBytes {
                diagnosticsError = "That file is too large to be a diagnostics export "
                    + "(\(size / 1_000_000) MB). Pick the .txt this app produced."
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = DiagnosticsFrameImport.records(fromDiagnosticsText: text)
            guard !parsed.isEmpty else {
                repairResult = parsed.pagesSeen == 0
                    ? "No raw history frames in that file — it was exported with frame capture off, so there is nothing to recover."
                    : "Found \(parsed.pagesSeen) frames but none decoded (\(parsed.pagesRejected) rejected). Nothing imported."
                return
            }
            // RING IDENTITY. The archive is per-ring; merging another ring's (or another person's)
            // export would silently corrupt this one's history with no way to tell afterwards. The
            // check is conservative — unknown on either side is NOT a match — so an older export
            // without a device header prompts rather than merging blind (#188 review).
            let mine = session.sourceRingIdentity
            if !parsed.sourceRing.matches(mine) {
                pendingForeignImport = (parsed, describe(parsed.sourceRing), describe(mine))
                return
            }
            applyRepair(parsed, session: session)
        } catch {
            diagnosticsError = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    private func applyRepair(_ parsed: DiagnosticsFrameImport.Result, session: RingSession) {
        let outcome = session.repairFromRecoveredRecords(parsed.records)
        let span = parsed.coverage.map {
            let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
            return " (\(f.string(from: $0.lowerBound)) → \(f.string(from: $0.upperBound)))"
        } ?? ""
        var msg: String
        if outcome.added > 0 {
            msg = "Recovered \(outcome.added) epochs\(span) from \(parsed.pagesSeen) frames."
            msg += outcome.restagedNights > 0
                ? " Re-staged \(outcome.restagedNights) night\(outcome.restagedNights == 1 ? "" : "s")."
                : " Nothing to re-stage."
        } else {
            msg = "All \(parsed.records.count) epochs in that file were already in the app."
        }
        // Never claim success for records the 30 h retention refused to keep.
        if outcome.agedOut > 0 {
            msg += " \(outcome.agedOut) were too old to store (the app keeps ~30 hours of raw epochs) "
                + "and could not be recovered."
        }
        repairResult = msg
    }

    private func describe(_ r: DiagnosticsFrameImport.SourceRing) -> String {
        let parts = [r.model, r.firmware, r.macSuffix.map { "…\($0)" }].compactMap { $0 }
        return parts.isEmpty ? "an unknown ring" : parts.joined(separator: " · ")
    }

    /// Build the diagnostics bundle, write it to a temp file, and present the share sheet.
    private func exportDiagnostics() {
        guard let session else { return }
        diagnosticsError = nil
        let report = DiagnosticsReport.build(session: session, store: LocalStore(modelContext))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-diagnostics-\(stamp).txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsURL = url
            showDiagnosticShare = true
        } catch {
            diagnosticsError = "Couldn't write diagnostics: \(error.localizedDescription)"
        }
    }

    private func infoRow(_ label: String, value: String?) -> some View {
        LabeledContent(label) {
            Text(value?.isEmpty == false ? value! : "--")
                .foregroundStyle(value?.isEmpty == false ? .primary : .tertiary)
                .textSelection(.enabled)
        }
    }

    /// Identity of the last `0x48` burst this session decoded. WHY it is on screen at all: the OSA
    /// summary carries no date and no cursor, so last night's burst and a morning re-dump of an
    /// OLDER night read identically in a report — the only way anyone has dated one is by inverting
    /// `odi` for a duration, which says nothing about WHICH night. The session cursor (`frame[6..9]`)
    /// is the per-night key: two reports quoting the same cursor are the same night, dumped twice.
    /// Selectable so a tester can copy it into a message. Absent until a burst decodes, so this
    /// costs a non-OSA user nothing.
    @ViewBuilder
    private func osaBurstProvenanceRow() -> some View {
        if let burst = session?.latestOSABurst {
            let cursor = burst.sessionCursor.map { String(format: "0x%08X", $0) } ?? "unknown"
            let hours = burst.durationHours.map { String(format: "%.2f h", $0) }
                ?? "no usable series"
            VStack(alignment: .leading, spacing: 2) {
                Text("Last oxygen burst")
                    .font(.subheadline)
                Text("\(burst.decodedAt.formatted(date: .abbreviated, time: .shortened)) · "
                     + "\(burst.nightFrames) of \(burst.wireFrames) frames · \(hours)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("session \(cursor)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Modal picker for "Connect a different ring". Scans for OTHER nearby rings (the connected ring
/// doesn't advertise, so it won't list itself) and lets the user switch. The current link is kept
/// alive while browsing, so cancelling leaves you connected; picking a row switches to it. (#multi-ring)
private struct RingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = RingScanner.shared

    private var rings: [RingScanner.DiscoveredRing] {
        scanner.discovered.sorted {
            $0.name != $1.name ? $0.name < $1.name : $0.id.uuidString < $1.id.uuidString
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rings.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for nearby rings…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(rings) { ring in
                            Button {
                                scanner.connect(to: ring.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                    Text(ring.name.isEmpty ? "RingConn" : ring.name)
                                    Spacer()
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(signalStyle(ring.rssi))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("Make sure the other ring is awake (worn or just off the charger) and not "
                         + "connected to another app. Switching keeps both rings' data in one timeline.")
                }
            }
            .navigationTitle("Choose a ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { scanner.startBrowsing() }
            .onDisappear { scanner.stopBrowsing() }
        }
    }

    /// RSSI is negative dBm; closer to 0 = stronger. Fade the glyph by proximity.
    private func signalStyle(_ rssi: Int) -> some ShapeStyle {
        if rssi > -65 { return AnyShapeStyle(.primary) }
        if rssi > -80 { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }
}

/// Wraps `UIActivityViewController` for sharing the diagnostics file (#111). Mirrors `ExportView`'s
/// share bridge.
private struct DiagnosticShareView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
