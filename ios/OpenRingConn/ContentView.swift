import SwiftUI
import SwiftData
import OpenRingKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var scanner = RingScanner()
    @State private var healthAuthorized = false
    @State private var lastWrite: String?
    @State private var showDebug = false

    private let health = HealthKitWriter()

    private var session: RingSession? { scanner.session }
    private var connected: Bool {
        if case .connected = scanner.state { return true } else { return false }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    liveCard
                    syncCard
                    debugCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("OpenRingConn")
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        card {
            HStack {
                Circle().fill(connected ? .green : .secondary).frame(width: 10, height: 10)
                Text(statusText).font(.subheadline.weight(.medium))
                Spacer()
            }
            if !connected {
                Button {
                    scanner.start()
                } label: {
                    Label("Scan & connect", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Live

    private var liveCard: some View {
        card {
            Text("LIVE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: session?.monitoring == true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session?.liveHR.map(String.init) ?? "—")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: session?.liveHR)
                    Text("BPM").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let spo2 = session?.liveSpO2 {
                Label("SpO₂ \(spo2)%", systemImage: "lungs.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                if session?.monitoring == true { session?.stopLiveMonitoring() }
                else { session?.startLiveMonitoring() }
            } label: {
                Label(session?.monitoring == true ? "Stop" : "Start live HR",
                      systemImage: session?.monitoring == true ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(session?.monitoring == true ? .red : .accentColor)
            .disabled(session?.ready != true)
        }
    }

    // MARK: Sync + Health

    private var syncCard: some View {
        card {
            HStack {
                Text("History & sleep").font(.headline)
                Spacer()
                if session?.syncing == true { ProgressView() }
            }
            Button {
                session?.syncHistory()
            } label: {
                Label(session?.syncing == true ? "Syncing…" : "Sync from ring",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session?.ready != true || session?.syncing == true)

            if let samples = session?.historySamples, !samples.isEmpty {
                Divider()
                metricSummary(samples)
                if let inBed = session?.sleepSegments.first(where: { $0.stage == .inBed }) {
                    LabeledContent("Sleep window") {
                        Text("\(inBed.start.formatted(date: .omitted, time: .shortened))–\(inBed.end.formatted(date: .omitted, time: .shortened))")
                    }
                    .font(.subheadline)
                }
                if let staged = session?.stagedSegments, !staged.isEmpty {
                    stageBar(staged)
                }
                Divider()
                healthRow(samples)
            }
        }
    }

    /// avg HR / HRV / SpO2 across the synced samples.
    private func metricSummary(_ samples: [QuantitySample]) -> some View {
        func avg(_ kind: MetricKind, scale: Double = 1) -> String {
            let vs = samples.filter { $0.kind == kind }.map(\.value)
            guard !vs.isEmpty else { return "—" }
            return String(Int((vs.reduce(0, +) / Double(vs.count)) * scale))
        }
        return HStack(spacing: 24) {
            stat("HR", "\(avg(.heartRate))", "bpm")
            stat("HRV", "\(avg(.hrvSDNN))", "ms")
            stat("SpO₂", "\(avg(.spo2, scale: 100))", "%")
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func healthRow(_ samples: [QuantitySample]) -> some View {
        VStack(spacing: 8) {
            if !healthAuthorized {
                Button {
                    Task { try? await health.requestAuthorization(); healthAuthorized = true }
                } label: {
                    Label("Authorize Apple Health", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!HealthKitWriter.isAvailable)
            } else {
                Button {
                    writeToHealth(samples)
                } label: {
                    Label("Write to Apple Health", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.pink)
            }
            if let lastWrite {
                Text(lastWrite).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Stage bar (experimental)

    private func stageBar(_ segs: [SleepSegment]) -> some View {
        let order: [(SleepStage, Color, String)] = [
            (.asleepDeep, .indigo, "Deep"), (.asleepCore, .teal, "Light"),
            (.asleepREM, .purple, "REM"), (.awake, .orange, "Awake"),
        ]
        func mins(_ s: SleepStage) -> Double {
            segs.filter { $0.stage == s }.reduce(0) { $0 + $1.duration } / 60
        }
        let total = order.reduce(0.0) { $0 + mins($1.0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Stages (experimental)").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(order, id: \.0) { stage, color, _ in
                        Rectangle().fill(color)
                            .frame(width: total > 0 ? geo.size.width * mins(stage) / total : 0)
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(order, id: \.0) { stage, color, name in
                    if mins(stage) > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 7, height: 7)
                            Text("\(name) \(Int(mins(stage)))m").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Debug

    private var debugCard: some View {
        card {
            DisclosureGroup(isExpanded: $showDebug) {
                Text(session?.lastFrame ?? "no frames yet")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text("Debug — last frame").font(.subheadline.weight(.medium))
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground)))
    }

    private func writeToHealth(_ samples: [QuantitySample]) {
        let store = LocalStore(modelContext)
        let segments = session?.sleepSegments ?? []
        Task {
            do {
                let freshSamples = try store.ingest(samples)
                try await health.write(freshSamples)
                let freshSleep = try store.ingestSleep(segments)
                if !freshSleep.isEmpty { try await health.write(sleep: freshSleep) }
                lastWrite = "Wrote \(freshSamples.count) samples, \(freshSleep.count) sleep segments"
            } catch {
                lastWrite = "Error: \(error.localizedDescription)"
            }
        }
    }

    private var statusText: String {
        switch scanner.state {
        case .idle: return "Ready"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth not authorized"
        case .scanning: return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected(let n): return n
        }
    }
}
