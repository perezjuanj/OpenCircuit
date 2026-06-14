import SwiftUI
import OpenRingKit

struct ContentView: View {
    @State private var scanner = RingScanner()
    @State private var healthAuthorized = false

    private let health = HealthKitWriter()

    var body: some View {
        NavigationStack {
            List {
                Section("Ring") {
                    LabeledContent("Status", value: statusText)
                    if let hr = scanner.session?.liveHR {
                        LabeledContent("Live HR", value: "\(hr) bpm")
                    }
                    if let frame = scanner.session?.lastFrame {
                        LabeledContent("Last frame", value: frame)
                            .font(.caption.monospaced())
                    }
                }

                Section("Actions") {
                    Button("Scan & connect") { scanner.start() }
                    Button("Start live HR") { scanner.session?.startLiveHR() }
                        .disabled(scanner.session?.ready != true)
                    Button("Poll live HR") { scanner.session?.pollLiveHR() }
                        .disabled(scanner.session?.ready != true)
                    Button(healthAuthorized ? "Health authorized" : "Authorize Apple Health") {
                        Task {
                            try? await health.requestAuthorization()
                            healthAuthorized = true
                        }
                    }
                    .disabled(!HealthKitWriter.isAvailable)
                }

                Section("Sleep & history") {
                    Button(scanner.session?.syncing == true ? "Syncing…" : "Sync history") {
                        scanner.session?.syncHistory()
                    }
                    .disabled(scanner.session?.ready != true || scanner.session?.syncing == true)

                    if let samples = scanner.session?.historySamples, !samples.isEmpty {
                        LabeledContent("Decoded samples", value: "\(samples.count)")
                    }
                    if let segs = scanner.session?.sleepSegments, !segs.isEmpty,
                       let inBed = segs.first(where: { $0.stage == .inBed }) {
                        LabeledContent("Sleep window",
                                       value: "\(inBed.start.formatted(date: .omitted, time: .shortened))–\(inBed.end.formatted(date: .omitted, time: .shortened))")
                    }
                    if let samples = scanner.session?.historySamples, !samples.isEmpty {
                        Button("Write to Apple Health") {
                            Task {
                                try? await health.write(samples)
                                if let segs = scanner.session?.sleepSegments, !segs.isEmpty {
                                    try? await health.write(sleep: segs)
                                }
                            }
                        }
                        .disabled(!healthAuthorized)
                    }
                }
            }
            .navigationTitle("OpenRingConn")
        }
    }

    private var statusText: String {
        switch scanner.state {
        case .idle: return "Idle"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth unauthorized"
        case .scanning: return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected(let n): return "Connected: \(n)"
        }
    }
}
