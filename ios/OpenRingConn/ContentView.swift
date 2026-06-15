import SwiftUI
import SwiftData
import OpenRingKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var scanner = RingScanner.shared
    @State private var healthAuthorized = false
    @State private var lastWrite: String?
    @State private var showDebug = false
    /// Last HR persisted to the store (from a prior session or a background refresh),
    /// shown on launch before BLE reconnects. #14
    @State private var lastKnownHR: QuantitySample?

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
                    vitalsCard
                    hrCard
                    spo2Card
                    stepsCard
                    syncCard
                    debugCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("OpenRingConn")
            .onAppear {
                // Wire persistence into the scanner/session so the (currently gated)
                // epoch-sync decoder can persist Layer-A records once enabled. #24
                scanner.setLocalStore(LocalStore(modelContext))
            }
            .task {
                // Load the last persisted HR AFTER the first frame renders. Running this
                // SwiftData fetch synchronously in .onAppear blocked the launch render and
                // showed a black screen on launch. #14
                loadLaunchSnapshot()
            }
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

    // MARK: Vitals dashboard (persisted — always visible)

    private var vitalsCard: some View {
        card {
            Text("VITALS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VitalsTableView(session: session, sleepMinutes: sleepMinutes)
        }
    }

    /// Total time asleep for the most recent night (minutes), from the last sync's
    /// segments — sum of the asleep stages (excludes the inBed wrapper and awake).
    private var sleepMinutes: Int? {
        guard let segs = session?.sleepSegments, !segs.isEmpty else { return nil }
        let asleep = segs.filter { $0.stage != .inBed && $0.stage != .awake }
        let secs = asleep.reduce(0.0) { $0 + $1.duration }
        return secs > 0 ? Int(secs / 60) : nil
    }

    // MARK: Live — two independent sections, but only one reads at a time

    private func hrActive() -> Bool { session?.monitoring == true && session?.liveMode == .hr }
    private func spo2Active() -> Bool { session?.monitoring == true && session?.liveMode == .spo2 }

    /// Heart-rate section. Shows its own latest reading; the value persists as the last
    /// reading whenever SpO₂ has taken the link (ring measures one metric at a time).
    private var hrCard: some View {
        card {
            metricHeader("HEART RATE", icon: "heart.fill", color: .red, active: hrActive())
            // Fall back to the last persisted reading on launch / before reconnect. #14
            bigReading(session?.liveHR ?? lastKnownHR.map { Int($0.value) },
                       unit: "BPM", color: .red, active: hrActive())

            if hrActive() {
                // Optical HR is a windowed average that climbs over ~20–60 s of stillness,
                // so show the trend/warm-up rather than one misleading number.
                if session?.livePreparing == true {
                    Label("Preparing… syncing the ring's history first",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let trend = session?.liveHRTrend, trend.count >= 2 {
                    let lo = trend.min() ?? 0, hi = trend.max() ?? 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trend.map(String.init).joined(separator: "  "))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(lo == hi ? "steady at \(lo) — give it 20–60 s of stillness to settle"
                                      : "range \(lo)–\(hi) bpm (converging)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else if session?.liveHR == nil, let warm = session?.liveHRWarmup {
                    Label("Warming up… (\(warm)) — hold still, keep the ring snug",
                          systemImage: "hourglass")
                        .font(.caption2).foregroundStyle(.orange)
                } else if session?.liveHR == nil {
                    Text("Waiting for HR frames… if this never moves, the ring isn't in HR mode.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if session?.liveHR != nil {
                Text("Last reading — tap Measure to refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if lastKnownHR != nil {
                Text("Last synced reading — connect to refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            liveButton(.hr, title: "Measure heart rate", active: hrActive(), color: .red,
                       icon: "heart.fill")
        }
    }

    /// SpO₂ section — same shape, blue. Latest reading persists when HR has the link.
    private var spo2Card: some View {
        card {
            metricHeader("BLOOD OXYGEN", icon: "lungs.fill", color: .blue, active: spo2Active())
            bigReading(session?.liveSpO2, unit: "%", color: .blue, active: spo2Active())

            if spo2Active() {
                Text(session?.livePreparing == true ? "Preparing… syncing the ring's history first"
                     : session?.liveSpO2 == nil ? "Measuring… hold still." : "Measuring — live.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if session?.liveSpO2 != nil {
                Text("Last reading — tap Measure to refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            liveButton(.spo2, title: "Measure SpO₂", active: spo2Active(), color: .blue,
                       icon: "lungs.fill")
        }
    }

    /// Steps in its own compact card once connected.
    @ViewBuilder
    private var stepsCard: some View {
        if session?.ready == true {
            card {
                let steps = session?.steps
                Label(steps.map { "\($0) steps today" } ?? "Steps: waiting for ring…",
                      systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(steps == nil ? Color.secondary : Color.green)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: steps)
            }
        }
    }

    private func metricHeader(_ title: String, icon: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(active ? color : .secondary)
                .symbolEffect(.pulse, isActive: active)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if active {
                Text("● MEASURING").font(.caption2.weight(.bold)).foregroundStyle(color)
            }
        }
    }

    private func bigReading(_ value: Int?, unit: String, color: Color, active: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
                .foregroundStyle(active ? color : .primary)
                .animation(.snappy, value: value)
            Text(unit).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Start/stop control for one metric. Starting one calls `startMonitoring(mode:)`,
    /// which switches the ring's mode so the other stops reading — preserving the
    /// "only one at a time" guarantee. Tapping the active one stops entirely.
    private func liveButton(_ mode: RingSession.LiveMode, title: String,
                            active: Bool, color: Color, icon: String) -> some View {
        Button {
            if active { session?.stopLiveMonitoring() }
            else { session?.startMonitoring(mode: mode) }
        } label: {
            Label(active ? "Stop" : title, systemImage: active ? "stop.fill" : icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? color : Color(.systemGray3))
        .disabled(session?.ready != true || session?.syncing == true)   // no live while syncing
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
            .disabled(session?.ready != true || session?.syncing == true
                      || session?.monitoring == true)   // stop live before syncing

            if session?.monitoring == true {
                Text("Stop live HR/SpO₂ before syncing.").font(.caption2).foregroundStyle(.secondary)
            }
            if let status = session?.syncStatus, session?.syncing != true {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

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

                Section("Settings") {
                    NavigationLink("User Profile") {
                        UserProfileSettingsView()
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
        let steps = session?.steps
        Task {
            do {
                let freshSamples = try store.ingest(samples)
                try await health.write(freshSamples)
                let freshSleep = try store.ingestSleep(segments)
                if !freshSleep.isEmpty { try await health.write(sleep: freshSleep) }
                // Steps: write today's cumulative count over [startOfDay, now].
                if let steps, steps > 0 {
                    let startOfDay = Calendar.current.startOfDay(for: Date())
                    try await health.write([QuantitySample(kind: .steps, start: startOfDay,
                                                           end: Date(), value: Double(steps))])
                }
                lastWrite = "Wrote \(freshSamples.count) samples, \(freshSleep.count) sleep segs"
                    + (steps.map { ", \($0) steps" } ?? "")
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

    // MARK: Background-refresh support (#14)

    /// Load the last persisted HR so the UI can show it immediately on launch.
    private func loadLaunchSnapshot() {
        guard let snapshot = try? LaunchSnapshot.load(from: LocalStore(modelContext)) else { return }
        lastKnownHR = snapshot.lastHeartRate
    }

    /// One-shot foreground refresh: read a live HR, persist it, and update the snapshot.
    /// Mirrors what the background task does, for an on-demand pull.
    private func refreshLiveHeartRate() async {
        guard let hr = await scanner.readLiveHeartRate(timeout: 10) else { return }
        let sample = QuantitySample(kind: .heartRate, start: Date(), value: Double(hr))
        if let fresh = try? LocalStore(modelContext).ingest([sample]) {
            try? await health.write(fresh)
        }
        loadLaunchSnapshot()
    }
}
