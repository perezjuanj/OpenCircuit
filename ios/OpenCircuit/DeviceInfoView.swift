import SwiftUI
import OpenCircuitKit
#if DEBUG
import UIKit
#endif

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

            #if DEBUG
            diagnosticsSection
            #endif
        }
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRingPicker) { RingPickerSheet() }
        #if DEBUG
        .sheet(isPresented: $showDiagnosticShare) {
            if let url = diagnosticsURL { DiagnosticShareView(url: url) }
        }
        #endif
    }

    #if DEBUG
    // MARK: - Diagnostics (DEBUG only) — raw history-frame capture for protocol triage (#111)
    //
    // Reachable ONLY in a local Debug build (which is what a tester building the app gets), never
    // in the Release build that goes to Apple beta review. Lets a tester on a new ring generation
    // capture the raw `0x4c`/`0x47` history bytes — pinned to Gen 2 in BulkSleep — and share them.

    @AppStorage(RingSession.diagnosticsCaptureKey) private var captureEnabled = false
    @State private var showDiagnosticShare = false
    @State private var diagnosticsURL: URL?
    @State private var diagnosticsError: String?

    private var diagnosticsSection: some View {
        Section {
            Toggle("Capture history frames", isOn: $captureEnabled)
            LabeledContent("Frames captured", value: "\(session?.diagnosticsFrameCount ?? 0)")
            Button {
                shareDiagnostics()
            } label: {
                Label("Share capture", systemImage: "square.and.arrow.up")
            }
            .disabled((session?.diagnosticsFrameCount ?? 0) == 0)
            Button(role: .destructive) {
                session?.clearDiagnosticsCapture()
            } label: {
                Label("Clear capture", systemImage: "trash")
            }
            .disabled((session?.diagnosticsFrameCount ?? 0) == 0)
            if let err = diagnosticsError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Diagnostics (debug)")
        } footer: {
            Text("Records the ring's raw history frames so they can be decoded offline — used to "
                 + "support new ring generations. Wear the ring overnight with capture on, then "
                 + "sync and tap Share in the morning. The file includes overnight HR/HRV/SpO₂ "
                 + "bytes; only share it with someone you trust.")
        }
    }

    private func shareDiagnostics() {
        guard let session else { return }
        diagnosticsError = nil
        let report = session.diagnosticsReport()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-frames-\(stamp).txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsURL = url
            showDiagnosticShare = true
        } catch {
            diagnosticsError = "Couldn't write capture: \(error.localizedDescription)"
        }
    }
    #endif

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

#if DEBUG
/// Wraps `UIActivityViewController` for sharing the diagnostic capture file (DEBUG only, #111).
/// Mirrors `ExportView`'s share bridge; kept separate so it's compiled out of Release builds.
private struct DiagnosticShareView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
