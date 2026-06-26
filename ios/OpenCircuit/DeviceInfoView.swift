import SwiftUI
import SwiftData
import UIKit
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
    @Environment(\.modelContext) private var modelContext
    @AppStorage(RingSession.diagnosticsCaptureKey) private var captureEnabled = false
    @State private var diagnosticsURL: URL?
    @State private var showDiagnosticShare = false
    @State private var diagnosticsError: String?

    private var info: FirmwareInfo { session?.firmwareInfo ?? FirmwareInfo() }

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

            diagnosticsSection
        }
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
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
                 + "data — share it only with someone you trust.")
        }
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
