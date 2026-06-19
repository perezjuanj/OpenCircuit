import SwiftUI
import OpenRingKit

/// Read-only device information screen (#79). Shows the DIS fields recovered from the
/// connected ring — firmware version (with generation label), manufacturer, hardware
/// revision, and MAC address — plus a non-alarming banner when the firmware version
/// differs from the pinned build we reverse-engineered.
///
/// Data source: the `RingSession`'s `firmwareInfo` property, populated incrementally
/// as each DIS characteristic is read after connection. Unread fields show "--".
struct DeviceInfoView: View {
    var session: RingSession?
    @Environment(\.dismiss) private var dismiss

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

            // Switching rings is an uncommon action (most people have one ring), so it lives here
            // rather than on the main screen. Drops the current link and scans so a different ring
            // can be picked; dismiss back to the dashboard where the picker appears. Data from all
            // rings stays in one shared timeline. (#multi-ring)
            Section {
                Button {
                    RingScanner.shared.chooseRing()
                    dismiss()
                } label: {
                    Label("Connect a different ring", systemImage: "arrow.left.arrow.right")
                }
            } footer: {
                Text("Disconnects this ring and scans so you can choose another. Each ring's data "
                     + "merges into one shared health timeline — switching never erases the other's data.")
            }
        }
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ label: String, value: String?) -> some View {
        LabeledContent(label) {
            Text(value?.isEmpty == false ? value! : "--")
                .foregroundStyle(value?.isEmpty == false ? .primary : .tertiary)
                .textSelection(.enabled)
        }
    }
}
