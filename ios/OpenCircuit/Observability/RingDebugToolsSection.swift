import SwiftUI

/// The ring reverse-engineering tools (last sync summary, last raw frame, activity-channel probe),
/// shown at the bottom of Background Activity rather than on Profile itself. Gated by the caller on
/// `DeveloperTools.isVisible`, so store builds show it only after the 7-tap unlock.
struct RingDebugToolsSection: View {
    let session: RingSession
    /// Presents the share sheet for a written capture file (the host screen owns the sheet).
    var onShare: (URL) -> Void
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    // Per-channel epochs from the last sync — `all-day N` with N>0 proves the 0x03
                    // (daytime SpO₂/HR) channel is being drained, not just sleep (#99).
                    if let drain = session.lastDrainSummary {
                        Text("Last sync — \(drain)")
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        Divider()
                    }
                    Text(session.lastFrame ?? "no frames yet")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    activityProbeRow
                }
            } label: {
                Text("Debug — last sync & frame").font(.subheadline.weight(.medium))
            }
        } header: {
            Text("Ring Debug")
        }
    }

    /// RE tool (issue #93): sweep untried sync-open `byte[6]` channels looking for the
    /// undecoded per-day activity/step history stream, then export every captured raw frame
    /// for offline decoding (`desktop/decode_activity.py`). See `RingSession.probeActivityChannels`.
    @ViewBuilder
    private var activityProbeRow: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity-channel probe (RE tool, #93)")
                .font(.caption.weight(.medium))
            Text("Looks for the per-day step/activity history stream. Take a walk first so there's "
                 + "motion to find, then run this and share the capture for decoding.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(session.probing ? "Probing…" : "Run probe") {
                    session.probeActivityChannels()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(!session.ready || session.probing || session.syncing || session.monitoring)
                if session.probing { ProgressView().controlSize(.small) }
                Spacer()
                if !session.rawCaptureLog.isEmpty, !session.probing {
                    Button("Share capture") { shareProbeCapture(session.rawCaptureLog) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            if let status = session.probeStatus {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Write the probe's captured raw frames to a temp file and hand it to the host's share sheet.
    private func shareProbeCapture(_ log: [String]) {
        let fileName = "opencircuit-activity-probe-\(Int(Date().timeIntervalSince1970)).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            onShare(url)
        } catch {
            ringLog.error("activity probe: failed to write capture file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
