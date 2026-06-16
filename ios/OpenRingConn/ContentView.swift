import SwiftUI
import SwiftData
import OpenRingKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanner = RingScanner.shared
    @State private var healthAuthorized = false
    @State private var lastWrite: String?
    @State private var showDebug = false

    /// Armed when a foreground activation wants a one-shot history sync, fired once the
    /// link is `ready`. A user "Scan & connect" never sets this, so the auto-refresh can't
    /// fire on top of a manual connect.
    @State private var pendingAutoSync = false
    /// Last time the foreground auto-refresh ran a sync; debounces repeated foregrounds.
    @State private var lastForegroundSync: Date?
    /// Minimum spacing between foreground auto-syncs — one bounded refresh per foreground,
    /// never a loop, and conservative about battery/contention with the official app.
    private static let autoSyncInterval: TimeInterval = 120

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
                    caloriesCard
                    syncCard
                    debugCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("OpenRingConn")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        UserProfileSettingsView()
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .onAppear {
                // Wire persistence into the scanner/session so the (currently gated)
                // epoch-sync decoder can persist Layer-A records once enabled. #24
                scanner.setLocalStore(LocalStore(modelContext))
            }
            .task {
                // Reflect any prior Health authorization so the UI shows the mirrored state,
                // and backfill anything the background refresh persisted while we were away.
                // Runs in `.task` (after first frame), never `.onAppear` — a synchronous store
                // read there once blocked the launch render into a black screen. #14
                healthAuthorized = health.isShareAuthorized
                if healthAuthorized { flushHealth() }
            }
            // Foreground auto-refresh: reconnect to the last-known ring and pull fresh data
            // when the app becomes active, so opening it after a while shows updated vitals
            // without a manual Scan/Sync.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { handleForegroundActivation() }
            }
            // Fire the armed one-shot sync the moment the (re)connected link is ready.
            .onChange(of: session?.ready) { _, ready in
                if ready == true { maybeAutoSyncOnReady() }
            }
            // Seamless Apple Health mirroring: whenever a history sync finishes or live
            // monitoring stops (both persist fresh samples to the store), push whatever's
            // pending to Health. Each metric is watermark-gated, so this never double-writes
            // and is a no-op until the user has authorized Health.
            .onChange(of: session?.syncing) { _, syncing in
                if syncing == false { flushHealth() }
            }
            .onChange(of: session?.monitoring) { _, monitoring in
                if monitoring == false { flushHealth() }
            }
        }
    }

    // MARK: Foreground auto-refresh

    /// On foreground: reconnect by identifier (no scan) to the saved ring and ARM a single
    /// debounced history sync for when the link is ready. Conservative: skips entirely if
    /// there's no saved ring or the user is mid-measurement, and never loops.
    private func handleForegroundActivation() {
        guard scanner.hasSavedRing else { return }      // never connected — nothing to do
        if session?.monitoring == true { return }       // don't interrupt a live measurement
        scanner.reconnectKnownPeripheral()              // idempotent: no-op if already connected
        if session?.syncing != true { pendingAutoSync = true }
        // If the link is already up, kick the sync now; otherwise onChange(ready) will.
        if session?.ready == true { maybeAutoSyncOnReady() }
    }

    /// One-shot, debounced history sync once the link is `ready`. Only fires for an armed
    /// foreground activation (not a user Scan), and not while a sync/live read is running.
    /// `syncHistory()` is itself bounded (watchdog), and the descriptor stream refreshes
    /// steps/temp meanwhile — so this is a single bounded refresh, not a poll loop.
    private func maybeAutoSyncOnReady() {
        guard pendingAutoSync, let session, session.ready,
              !session.monitoring, !session.syncing else { return }
        if let last = lastForegroundSync,
           Date().timeIntervalSince(last) < Self.autoSyncInterval {
            pendingAutoSync = false   // too soon — consume the request without syncing
            return
        }
        pendingAutoSync = false
        lastForegroundSync = Date()
        session.syncHistory()
    }

    // MARK: Connection

    private var connectionCard: some View {
        card {
            HStack(spacing: 8) {
                Circle().fill(connected ? .green : .secondary).frame(width: 10, height: 10)
                Text(statusText).font(.subheadline.weight(.medium))
                // Top-of-screen freshness cue so opening the app reads as "updating" without
                // scrolling to the sync card. Shows while the foreground auto-refresh (or a
                // manual sync) is pulling fresh data.
                if session?.syncing == true {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                } else if session?.autoMeasuring == true {
                    ProgressView().controlSize(.small)
                    Text("Auto-measuring…").font(.caption).foregroundStyle(.secondary)
                } else if hrMeasuring {
                    // A user HR measure that's converging but hasn't locked — show warm-up
                    // progress so a fresh Measure reads as "still climbing", not dead/stale (#45 C).
                    ProgressView().controlSize(.small)
                    Text(hrWarmupText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Ring battery (a device stat, not a body vital) sits with the connection. When
                // the link has gone quiet (no frames), gray it and show "as of Xm ago" so a
                // minutes-old % from a silently-dropped link doesn't read as current (#36).
                if let b = session?.batteryPercent {
                    let stale = session?.liveReadingsStale == true
                    VStack(alignment: .trailing, spacing: 0) {
                        Label("\(b)%", systemImage: batteryIcon(b))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(stale ? AnyShapeStyle(.tertiary)
                                             : AnyShapeStyle(b <= 20 ? Color.red : Color.secondary))
                        if let asOf = batteryAsOf {
                            Text(asOf).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
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

    /// A user (non-auto) HR measurement that's converging but hasn't locked yet (#45 C). The
    /// auto-measure branch above takes precedence, so this only lights up for a hand-started read.
    private var hrMeasuring: Bool {
        session?.monitoring == true && session?.liveMode == .hr && session?.liveHR == nil
    }
    /// Warm-up label: surfaces the climbing raw HR byte when present (proves frames are arriving
    /// and the sensor is warming up vs. no contact), else a plain measuring note.
    private var hrWarmupText: String {
        if let w = session?.liveHRWarmup { return "Warming up HR… (\(w))" }
        return "Measuring HR…"
    }

    /// "as of Xm ago" for the connection-header battery, shown only once the link has gone quiet
    /// (#36) — a dropped link can otherwise show a minutes-old battery % as if it were current.
    private var batteryAsOf: String? {
        guard session?.liveReadingsStale == true, let at = session?.lastFrameAt else { return nil }
        return "as of " + Self.rel.localizedString(for: at, relativeTo: Date())
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    /// SF Symbol for the ring's battery level.
    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Vitals dashboard (persisted — always visible)

    private var vitalsCard: some View {
        card {
            Text("VITALS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VitalsTableView(session: session, sleep: sleepSummary)
        }
    }

    /// Sleep summary (total asleep + Deep/Light/REM/Awake breakdown) for the most recent
    /// night, from the staged segments. Stages are an on-device ESTIMATE — the ring doesn't
    /// transmit stage labels (PROTOCOL.md §5.3) — so the dashboard labels them "est.".
    private var sleepSummary: SleepStaging.Summary? {
        guard let segs = session?.stagedSegments, !segs.isEmpty else { return nil }
        return SleepStaging.summary(segs)
    }

    /// Calories on the home page (was buried in the profile page). Headline is today's
    /// estimated burn; the reference figures stay as a small secondary line.
    private var caloriesCard: some View {
        card { CaloriesCardView() }
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
                healthRow
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

    private var healthRow: some View {
        VStack(spacing: 8) {
            if !healthAuthorized {
                Button {
                    Task {
                        try? await health.requestAuthorization()
                        healthAuthorized = health.isShareAuthorized
                        flushHealth()   // backfill everything already in the store
                    }
                } label: {
                    Label("Authorize Apple Health", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!HealthKitWriter.isAvailable)
            } else {
                // Mirroring is automatic after every sync; this is just a reassurance line
                // plus a manual nudge for the impatient.
                Label("Auto-syncing to Apple Health", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
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

    /// Push everything pending to Apple Health (scalars + sleep + step delta), each gated by
    /// its own watermark so it never double-writes. Safe to call liberally — it's a no-op
    /// until the user authorizes and whenever nothing is pending.
    private func flushHealth() {
        guard healthAuthorized else { return }
        let store = LocalStore(modelContext)
        let segments = session?.sleepSegments ?? []
        Task {
            let r = await health.flushToHealth(store: store, sleepSegments: segments)
            if r.wroteAnything {
                lastWrite = "Synced to Health: \(r.samples) samples"
                    + (r.sleepSegments > 0 ? ", \(r.sleepSegments) sleep segs" : "")
                    + (r.steps > 0 ? ", \(r.steps) steps" : "")
                    + (r.restingDays > 0 ? ", \(r.restingDays) resting HR" : "")
                    + (r.passiveHours > 0 ? ", \(r.passiveHours)h basal" : "")
                    + (r.activeKcal > 0 ? ", \(Int(r.activeKcal.rounded())) active kcal" : "")
            }
        }
    }

    private var statusText: String {
        switch scanner.state {
        case .idle: return "Ready"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth not authorized"
        case .scanning: return "Scanning…"
        case .connecting(let n):
            // After repeated failed reconnects (e.g. the ring is on the charger / out of range),
            // swap the permanent "Connecting…" for a calm note so normal charging doesn't read as
            // a stuck connection (#35). Heuristic on elapsed attempts — not a charging byte (#41).
            return scanner.reconnectStalled
                ? "Ring unreachable or charging — will reconnect automatically"
                : "Connecting to \(n)…"
        case .connected(let n): return n
        }
    }
}

/// Home-page calories card. Headline = today's estimated burn; secondary lines break it
/// into resting (BMR prorated over the elapsed day) + active (Edwards-TRIMP from today's
/// measured HR), then the static BMR/max-HR reference figures. Body inputs (age/weight/
/// height/sex) still come from the profile page — the ring transmits none of them.
struct CaloriesCardView: View {
    // Shared @AppStorage keys with UserProfileSettingsView (single source of truth).
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage("userProfile.weightKg") private var weightKg = 70.0
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue

    /// Today's HR samples (for the active-calorie TRIMP estimate). Predicate-limited to
    /// heart rate since start-of-day so the fetch stays small.
    @Query private var hrSamples: [StoredSample]

    init() {
        let hr = MetricKind.heartRate.rawValue
        let dayStart = Calendar.current.startOfDay(for: Date())
        _hrSamples = Query(
            filter: #Predicate { $0.kindRaw == hr && $0.start >= dayStart },
            sort: \.start)
    }

    private var profile: UserProfile {
        UserProfile(age: age, weightKg: max(weightKg, 1), heightCm: max(heightCm, 1),
                    sex: BiologicalSex(rawValue: sexRaw) ?? .male)
    }
    private var maxHR: Int { max(220 - age, 1) }

    /// Resting kcal accrued so far today: full-day BMR scaled by the elapsed fraction of today.
    private var restingToday: Double {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let fraction = Date().timeIntervalSince(dayStart) / 86_400
        return Calories.bmrKcalPerDay(profile: profile) * fraction
    }
    /// Active kcal from today's measured HR (0 until HR is measured — it's sparse, so this
    /// is a rough floor, not a continuous-wear estimate).
    private var activeToday: Double {
        let samples = hrSamples.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        return Calories.activeKcal(hrSamples: samples, maxHR: maxHR)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("CALORIES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((restingToday + activeToday).rounded()))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Text("kcal today").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text("resting \(Int(restingToday.rounded())) · active \(Int(activeToday.rounded()))")
                .font(.caption).foregroundStyle(.secondary)
            Text("BMR \(Int(Calories.bmrKcalPerDay(profile: profile).rounded())) kcal/day · max HR \(maxHR) bpm")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
