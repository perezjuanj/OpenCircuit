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
    @State private var showWorkout = false
    /// Women's health feature gate (#78). Matches the key in UserProfileSettingsView.
    @AppStorage("userProfile.womensHealthEnabled") private var womensHealthEnabled = false

    /// Freshness timestamps mirrored from the UserDefaults-backed observability store (#44).
    /// Held in @State because UserDefaults writes (from the background task / a flush) don't
    /// publish to SwiftUI — we re-read them on the lifecycle hooks below.
    @State private var lastSyncAt: Date?
    @State private var lastHealthWriteAt: Date?
    private let observability = ObservabilityStore()

    /// Armed when a foreground activation wants a one-shot history sync, fired once the
    /// link is `ready`. A user "Scan & connect" never sets this, so the auto-refresh can't
    /// fire on top of a manual connect.
    @State private var pendingAutoSync = false
    /// Tracks whether the ring was at 100 % (charged) in the current connection so the
    /// charging-complete notification fires exactly once per charge cycle. (#86)
    @State private var batteryWasFull = false
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
                    vitalsStatusCard
                    sleepCard
                    caloriesCard
                    card { GoalsCardView() }
                    workoutCard
                    if womensHealthEnabled { cycleCalendarCard }
                    trendsNavigationCard
                    syncCard
                    deviceInfoCard
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
                if healthAuthorized { observability.markHealthEverAuthorized() }
                refreshObservability()
                if healthAuthorized { flushHealth() }
            }
            // Foreground auto-refresh: reconnect to the last-known ring and pull fresh data
            // when the app becomes active, so opening it after a while shows updated vitals
            // without a manual Scan/Sync.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    handleForegroundActivation()
                    refreshObservability()        // pick up anything a background run wrote
                    evaluateForegroundAlerts()    // live battery + Health-auth check (#44)
                }
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
                if syncing == false {
                    recordForegroundSync()
                    flushHealth()
                    evaluateHealthAlerts()   // #73/#85: a fresh sync may cross a threshold
                }
            }
            .onChange(of: session?.monitoring) { _, monitoring in
                if monitoring == false { flushHealth() }
            }
            // Battery: TTE + charging-complete notification (#86).
            .onChange(of: session?.batteryPercent) { _, pct in
                guard let pct else { return }
                let charging = session?.inferredCharging ?? false
                if BatteryTTE.justReachedFull(percent: pct, inferredCharging: charging,
                                              wasFull: batteryWasFull) {
                    batteryWasFull = true
                    let store = LocalStore(modelContext)
                    Task { await HealthNotificationCenter().postChargingComplete(store: store) }
                }
                if pct < 100 { batteryWasFull = false }
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

    // MARK: Observability (#44)

    /// Re-read the persisted freshness timestamps into @State (UserDefaults writes don't publish
    /// to SwiftUI on their own).
    private func refreshObservability() {
        lastSyncAt = observability.lastSuccessfulSync
        lastHealthWriteAt = observability.lastHealthWrite
    }

    /// A foreground history sync just finished — record its outcome so "Last successful sync"
    /// reflects manual/auto foreground refreshes too, not only background runs. Success = the
    /// session actually received frames on this connection.
    private func recordForegroundSync() {
        let gotData = session?.lastFrameAt != nil || (session?.historySamples.isEmpty == false)
        observability.recordSyncOutcome(kind: .foreground, success: gotData,
                                        detail: gotData ? "synced from ring" : "no frames received")
        refreshObservability()
    }

    /// Foreground alert evaluation with a LIVE battery reading (the background path can't see
    /// battery once its session is torn down) and a fresh Health-auth probe (so a revocation made
    /// in Settings while we were away is caught). Latches "ever authorized" so an auth-lost alert
    /// can be told apart from a user who simply never opted into Health.
    private func evaluateForegroundAlerts() {
        let authorized = health.isShareAuthorized
        healthAuthorized = authorized
        if authorized { observability.markHealthEverAuthorized() }
        let battery = session?.batteryPercent
        Task { await LocalAlertCenter().evaluate(batteryPercent: battery, healthAuthorized: authorized) }
        evaluateHealthAlerts()
        evaluateReminders()
    }

    /// Evaluate the three app-side reminders (#84: sedentary / wear / bedtime) against the
    /// current session and persisted UserDefaults state, routing survivors through the shared
    /// notification engine (quiet hours + anti-spam backoff).
    private func evaluateReminders() {
        let d = UserDefaults.standard
        SleepScheduleDefaults.register(d)
        let bedMinutes  = d.integer(forKey: SleepScheduleDefaults.bedMinutes)
        let wakeMinutes = d.integer(forKey: SleepScheduleDefaults.wakeMinutes)
        let sleepEnabled = d.bool(forKey: SleepScheduleDefaults.enabled)
        let s = session
        Task {
            await HealthNotificationCenter().evaluateReminders(
                session: s,
                sleepBedMinutes: bedMinutes,
                sleepWakeMinutes: wakeMinutes,
                sleepEnabled: sleepEnabled)
        }
    }

    /// Evaluate the user's body-vital alert rules (#73 high-HR / low-SpO2 / elevated-HR-while-inactive
    /// and #85 skin-temp / fever) against the latest stored + just-synced readings, posting any that
    /// cross a threshold through the ONE shared notification engine (quiet hours + anti-spam backoff).
    private func evaluateHealthAlerts() {
        let store = LocalStore(modelContext)
        let s = session
        Task { await HealthNotificationCenter().evaluate(store: store, session: s) }
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
                } else if session?.userMeasuring == true, session?.livePreparing == true {
                    // User-initiated: draining the history backlog before live mode starts (#55).
                    ProgressView().controlSize(.small)
                    Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                } else if userMeasureInProgress {
                    // Polling — sensor warming up; no raw byte shown (#55).
                    ProgressView().controlSize(.small)
                    Text(measureStatusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Ring battery (a device stat, not a body vital) sits with the connection. When
                // no 0x10/0x87 descriptor has arrived recently, gray it and show "as of Xm ago"
                // so a minutes-old % doesn't read as current (#36 / #57). Uses the dedicated
                // battery-freshness window (batteryStale, ~120 s) rather than the broader
                // liveReadingsStale (360 s) — battery updates only on descriptor frames, not
                // the 2-s live-HR polls that keep liveReadingsStale fresh during monitoring.
                if let b = session?.batteryPercent {
                    let stale = session?.batteryStale == true   // (#57) dedicated battery freshness
                    VStack(alignment: .trailing, spacing: 0) {
                        Label("\(b)%", systemImage: batteryIcon(b))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(stale ? AnyShapeStyle(.tertiary)
                                             : AnyShapeStyle(b <= 20 ? Color.red : Color.secondary))
                        if let asOf = batteryAsOf {
                            Text(asOf).font(.caption2).foregroundStyle(.tertiary)
                        }
                        // TTE estimate (#86): only shown when discharging (not inferred charging)
                        // and the window has enough data for a clean rate.
                        if session?.inferredCharging != true,
                           let samples = session?.batteryTTESamples,
                           let tte = BatteryTTE.timeToEmpty(samples) {
                            Text("~\(tteString(tte)) est.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            // Link up + subscribed but the ring sends only status replies, no data (#54) — the
            // un-activated/un-bonded signature. Until the activate step is reverse-engineered, the
            // only fix is to open the official app once; say so instead of spinning forever.
            if connected, session?.notStreaming == true { activationHint }
            // Connected + streaming, but the ring reads off-wrist / on the charger (#56) — surface
            // it (estimated) instead of silently backing the auto-measure off. notStreaming takes
            // precedence (an un-activated ring's wear state is meaningless), and we hide it during
            // an active measurement so it can't contradict the "measuring" cue.
            if connected, session?.notStreaming != true, session?.monitoring != true,
               session?.appearsNotWorn == true {
                notWornHint
            }
            // User-initiated measure timed out without locking a reading. Persists until the
            // user taps Measure again (which clears it naturally). (#55)
            if session?.userMeasureFailed == true { measureFailedHint }
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

    /// Shown when `RingSession.notStreaming` — the ring is connected but not delivering data (not
    /// yet activated/bonded by the official app). #54.
    private var activationHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ring isn't streaming").font(.subheadline.weight(.medium))
                Text("Connected, but the ring isn't sending data. Open the official RingConn app once to activate it, then return here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    /// Shown when `RingSession.appearsNotWorn` — connected but the ring reads off-wrist / on the
    /// charger (a proxy from auto-measures that never lock + a cold skin-temp reading, #56). Honest
    /// that it's an estimate; manual Measure/Sync are never blocked by it.
    private var notWornHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
            Text("Ring looks off-wrist or charging (estimated) — auto-measure paused")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A user (non-auto) measurement that's converging but hasn't locked yet — covers both HR
    /// and SpO₂ modes. Only true AFTER the preparing (drain) phase so "Preparing…" and
    /// "Measuring…" are distinct states in the connection-card header. (#55)
    private var userMeasureInProgress: Bool {
        session?.userMeasuring == true
            && session?.monitoring == true
            && session?.livePreparing == false
            && (session?.liveMode == .hr ? session?.liveHR == nil : session?.liveSpO2 == nil)
    }
    /// Status copy for the polling phase of a user-initiated measure. No raw byte shown —
    /// the warmup byte value is a low-level sentinel that reads as noise to the user. Instead,
    /// "Hold still" when frames are arriving (liveHRWarmup != nil) proves contact without
    /// exposing internals; a plain "Measuring" covers SpO₂ and the no-frame case. (#55)
    private var measureStatusText: String {
        if session?.liveMode == .hr {
            if session?.liveHRWarmup != nil { return "Hold still — getting a reading" }
            return "Measuring heart rate…"
        }
        return "Measuring SpO₂…"
    }
    /// Inline failure banner: shown when a user-initiated measure timed out without a lock.
    /// Styled like `activationHint` (orange, inside the connection card) for visual consistency.
    /// Dismissed naturally when the user taps Measure again. (#55)
    private var measureFailedHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading timed out").font(.subheadline.weight(.medium))
                Text(session?.userMeasureFailedMessage
                     ?? "Couldn't get a reading — make sure the ring is worn snugly and not on the charger, then hold still.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    /// "as of Xm ago" for the connection-header battery, shown once the battery reading goes
    /// stale (#36 / #57). Anchored to `batteryFetchedAt` (the last 0x10/0x87 descriptor that
    /// carried a valid %) rather than `lastFrameAt` (any frame), so a 2-s HR poll doesn't
    /// keep the timestamp artificially fresh while the actual battery reading is minutes old.
    private var batteryAsOf: String? {
        guard session?.batteryStale == true, let at = session?.batteryFetchedAt else { return nil }
        return "as of " + Self.rel.localizedString(for: at, relativeTo: Date())
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    /// Human-readable battery time-to-empty string (#86): "Xh Ym" or just "Xm" for < 1 h.
    private func tteString(_ tte: TimeInterval) -> String {
        let totalMin = Int(tte / 60)
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(totalMin, 1))m"
    }

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
            VitalsTableView(session: session)
        }
    }

    /// Vitals Status (#72): compares the latest day's resting HR / overnight SpO₂ / overnight HRV /
    /// skin temp to the user's PERSONAL 7–30 day baseline and surfaces normal / watch / anomaly with
    /// the contributing signals (incl. suspected fever). Self-contained view (its own @Query).
    private var vitalsStatusCard: some View { VitalsStatusCardView() }

    /// Dedicated, always-visible sleep section below vitals. Reads the persisted nightly summary
    /// so the most recent night stays on screen all day — across reconnects and syncs — and
    /// reflects a just-finished sync instantly via the live staged segments. (See SleepCardView.)
    private var sleepCard: some View {
        SleepCardView(liveSegments: session?.stagedSegments ?? [])
    }

    /// Workout session card — taps through to WorkoutView (#75).
    /// Displays a start-workout prompt; tapping opens the sport-picker sheet.
    private var workoutCard: some View {
        Button {
            showWorkout = true
        } label: {
            card {
                HStack(spacing: 8) {
                    Image(systemName: "figure.run").foregroundStyle(.blue)
                    Text("WORKOUT")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Text("Record a workout with HR zones + GPS route (outdoor)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showWorkout) {
            WorkoutView(session: session)
        }
    }

    /// Cycle calendar nav card — taps through to CycleCalendarView (#78).
    /// Only rendered when `womensHealthEnabled` (settings toggle). All predictions
    /// are labeled as estimates in the destination view.
    private var cycleCalendarCard: some View {
        NavigationLink {
            CycleCalendarView()
        } label: {
            card {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(.pink)
                    Text("CYCLE CALENDAR")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Text("Log periods, view predictions, fertile window (estimates only)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// 7-day trends nav card — taps through to the full TrendsView (#74).
    private var trendsNavigationCard: some View {
        NavigationLink {
            TrendsView()
        } label: {
            card {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.purple)
                    Text("7-DAY TRENDS")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Calories on the home page (was buried in the profile page). Headline is today's
    /// estimated burn; the reference figures stay as a small secondary line.
    private var caloriesCard: some View {
        card { CaloriesCardView() }
    }

    // MARK: Sync + Health

    /// Prominent "is this thing actually working?" line (#44): when we last pulled from the ring
    /// and when we last wrote to Apple Health, tapping through to the full background-activity log.
    private var freshnessRow: some View {
        NavigationLink {
            ActivityLogView()
        } label: {
            HStack(spacing: 16) {
                freshnessStat("Last sync", lastSyncAt)
                Divider().frame(height: 30)
                freshnessStat("Health write", lastHealthWriteAt)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func freshnessStat(_ label: String, _ date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(date.map { Self.rel.localizedString(for: $0, relativeTo: Date()) } ?? "never")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(date == nil ? .secondary : .primary)
        }
    }

    private var syncCard: some View {
        card {
            HStack {
                Text("History & sleep").font(.headline)
                Spacer()
                if session?.syncing == true { ProgressView() }
            }
            freshnessRow
            Divider()
            Button {
                session?.syncHistory()
            } label: {
                Label(session?.syncing == true ? "Syncing…" : "Sync from ring",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session?.ready != true || session?.syncing == true
                      || session?.monitoring == true        // stop live before syncing
                      || session?.probing == true           // a #99 stream probe owns the link
                      || session?.notStreaming == true)     // a not-streaming ring would sync nothing (#54)

            if session?.monitoring == true {
                Text("Stop live HR/SpO₂ before syncing.").font(.caption2).foregroundStyle(.secondary)
            }
            if let status = session?.syncStatus, session?.syncing != true {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            // The Health mirror controls. What this sync pulled (avg HR/HRV/SpO₂) now lives with
            // the night it describes — the Sleep card's "overnight average" row — instead of here,
            // where the overnight averages read as a current "latest from the ring" value and
            // contradicted the live Vitals readings (HR/SpO₂ are also measured on demand).
            if session?.historySamples.isEmpty == false {
                Divider()
                healthRow
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
                        if healthAuthorized { observability.markHealthEverAuthorized() }
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

    // MARK: Device Info (#79)

    /// Taps through to the read-only device information screen (FW version / generation /
    /// manufacturer / MAC address). Sits between the sync card and the debug card.
    private var deviceInfoCard: some View {
        NavigationLink {
            DeviceInfoView(session: session)
        } label: {
            card {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(.teal)
                    Text("DEVICE INFO")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let v = session?.firmwareInfo.version, !v.isEmpty {
                        Text(v).font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Debug

    private var debugCard: some View {
        card {
            DisclosureGroup(isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(session?.lastFrame ?? "no frames yet")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    Divider()
                    allDayProbeSection
                }
            } label: {
                Text("Debug — last frame").font(.subheadline.weight(.medium))
            }
        }
    }

    /// #99 — on-device probe for the all-day HR/SpO₂ sync streams. Sweeps the `0x02` sync-open
    /// `byte[6]` (DataSyncType) selector and shows each selector's raw responses so the wire format
    /// can be ground-truthed. A capture/RE aid (the values are NOT decoded into health metrics yet).
    private var allDayProbeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All-day HR/SpO₂ stream probe (#99)").font(.subheadline.weight(.medium))
            Text("Sweeps the sync-open byte[6] selector to find the HrSync/Spo2Sync stream. Pauses live/sync for ~45 s; read the per-selector opcodes below (a NOVEL opcode is the all-day stream).")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                session?.probeAllDayStreams()
            } label: {
                Label(session?.probing == true ? "Probing…" : "Probe all-day streams",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(session?.ready != true || session?.probing == true
                      || session?.syncing == true || session?.monitoring == true
                      || session?.notStreaming == true)
            if let report = session?.probeReport {
                Text(report)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(session?.probeResults ?? []) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "0x%02x", r.selector) + (r.sawAck ? " ACK✓" : " no-ACK")
                         + " · op[" + r.opcodes.map { String(format: "%02x", $0) }.joined(separator: " ") + "]")
                        .font(.caption2.monospaced().weight(.medium))
                    // Every captured raw frame (up to the cap) — for a novel HR/SpO₂ stream this is
                    // the record-byte evidence to ground-truth, so show them all, not just the first.
                    ForEach(Array(r.sampleFrames.enumerated()), id: \.offset) { _, frame in
                        Text(frame).font(.system(size: 9).monospaced()).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                observability.recordHealthWrite()
                refreshObservability()
                lastWrite = "Synced to Health: \(r.samples) samples"
                    + (r.sleepSegments > 0 ? ", \(r.sleepSegments) sleep segs" : "")
                    + (r.steps > 0 ? ", \(r.steps) steps" : "")
                    + (r.distanceM > 0 ? ", \(Int(r.distanceM.rounded()))m est." : "")
                    + (r.restingDays > 0 ? ", \(r.restingDays) resting HR" : "")
                    + (r.passiveHours > 0 ? ", \(r.passiveHours)h basal" : "")
                    + (r.activeKcal > 0 ? ", \(Int(r.activeKcal.rounded())) active kcal" : "")
                    + (r.exerciseMinutes > 0 ? ", \(Int(r.exerciseMinutes.rounded()))min exercise est." : "")
                    + (r.naps > 0 ? ", \(r.naps) nap\(r.naps == 1 ? "" : "s")" : "")
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
            // After repeated failed reconnects, swap the permanent "Connecting…" for a calm note
            // (#35). The backoff count is NOT a charging signal — we never claim the ring is
            // charging from the reconnect count (#41 / #60). "Ring unreachable" is the honest state.
            // If the last session's battery trend was strictly rising (🟢 proxy), append an honest
            // "inferred charging" hint — labeled so to avoid overstating certainty (#60).
            if scanner.reconnectStalled {
                let chargingHint = lastInferredCharging ? " · inferred charging" : ""
                return "Ring unreachable\(chargingHint) — reconnecting automatically"
            }
            return "Connecting to \(n)…"
        case .connected(let n): return n
        }
    }

    /// The charging inference from the last session, persisted to UserDefaults before session
    /// teardown (#60). Readable during the reconnect-backoff window when session == nil.
    private var lastInferredCharging: Bool {
        UserDefaults.standard.bool(forKey: "battery.inferredCharging")
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
    /// Today's step rollup — drives the step/distance active-calorie fallback when HR is sparse.
    @Query private var todayDaily: [StoredDaily]

    init() {
        let hr = MetricKind.heartRate.rawValue
        let dayStart = Calendar.current.startOfDay(for: Date())
        _hrSamples = Query(
            filter: #Predicate { $0.kindRaw == hr && $0.start >= dayStart },
            sort: \.start)
        _todayDaily = Query(filter: #Predicate<StoredDaily> { $0.day == dayStart }, sort: \.day)
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
    /// Active kcal today — the larger of the HR-TRIMP estimate (sparse; ~0 without dense HR) and a
    /// step/distance estimate, so a day with walking still shows honest active calories instead of
    /// 0. Both are clearly-labeled estimates (the ring transmits no active-energy value).
    private var activeToday: Double {
        let samples = hrSamples.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        let hrKcal = Calories.activeKcal(hrSamples: samples, maxHR: maxHR)
        let stepKcal = Calories.activeKcalFromSteps(steps: todayDaily.first?.steps ?? 0, profile: profile)
        return max(hrKcal, stepKcal)
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
            // "max HR" here is the 220−age zone/calorie reference, NOT an observed peak — so it's
            // constant by design. Label it as an age estimate so it doesn't read as a live "max HR"
            // stat that looks stuck day to day.
            Text("BMR \(Int(Calories.bmrKcalPerDay(profile: profile).rounded())) kcal/day · est. max HR \(maxHR) bpm (220−age)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
