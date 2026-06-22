import SwiftUI
import SwiftData
import OpenCircuitKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanner = RingScanner.shared
    @State private var healthAuthorized = false
    /// Set when an explicit Authorize-Health attempt throws — the signature of a build WITHOUT the
    /// HealthKit entitlement (e.g. a free-Apple-ID sideload, which strips it). Drives the "needs the
    /// TestFlight build" note. Never set on a properly-provisioned build, where the request succeeds. (#104)
    @State private var healthUnavailable = false
    @State private var lastWrite: String?
    @State private var showDebug = false
    @State private var showWorkout = false
    /// Women's health feature gate (#78). Matches the key in UserProfileSettingsView.
    @AppStorage("userProfile.womensHealthEnabled") private var womensHealthEnabled = false

    /// Persisted user ordering of the reorderable dashboard sections (long-press-drag QoL). Stored
    /// as a comma-joined list of `DashboardSection.rawValue`; unknown/duplicate entries are ignored
    /// and any newly-added sections are appended in canonical order, so a saved order survives app
    /// updates. See `sectionOrder` / `moveSection`.
    @AppStorage("dashboard.sectionOrder") private var sectionOrderRaw = ""
    /// Typed navigation-stack path. Reorderable cards push by appending a `Route` instead of
    /// wrapping in a `NavigationLink`, so the enclosing `List` doesn't draw its own row chevron on
    /// top of each card's custom one.
    @State private var path: [Route] = []

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
        NavigationStack(path: $path) {
            // A List (not a ScrollView) so the middle cards can be long-press-dragged to reorder
            // via `.onMove`. The connection card (ring name + battery) is pinned at the top and the
            // device-info + debug cards are pinned at the bottom — only the sections in between are
            // user-orderable (QoL). Row chrome is stripped so each card keeps its own styling, and
            // the list background defers to the grouped background like the old ScrollView did.
            List {
                Group {
                    connectionCard
                    ForEach(visibleSections) { section in
                        sectionView(section)
                    }
                    .onMove(perform: moveSection)
                    deviceInfoCard
                    debugCard
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            // Pull-to-refresh: swipe down to force a history sync, mirroring the "Sync from ring"
            // button. The control stays up until the bounded sync settles (QoL). See `forceSync`.
            .refreshable { await forceSync() }
            .navigationTitle("OpenCircuit")
            .navigationDestination(for: Route.self) { route in destination(for: route) }
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
                } else if phase == .background {
                    // Don't leave a user-initiated foreground scan/picker running once we leave the
                    // foreground — a nil-filtered scan yields nothing in the background and just keeps
                    // the radio engaged. Preserves the active ring (cancelScan, not stop).
                    if case .scanning = scanner.state { scanner.cancelScan() }
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

    // MARK: Dashboard section ordering (long-press to reorder)

    /// The full canonical-or-saved order of reorderable sections. Decodes `sectionOrderRaw`,
    /// dropping unknown/duplicate ids, then appends any sections not yet present (new features) in
    /// their canonical `allCases` order — so a saved order keeps working across app updates that
    /// add cards.
    private var sectionOrder: [DashboardSection] {
        var result: [DashboardSection] = []
        var seen = Set<DashboardSection>()
        for raw in sectionOrderRaw.split(separator: ",") {
            if let s = DashboardSection(rawValue: String(raw)), !seen.contains(s) {
                result.append(s); seen.insert(s)
            }
        }
        for s in DashboardSection.allCases where !seen.contains(s) {
            result.append(s); seen.insert(s)
        }
        return result
    }

    /// The sections actually rendered right now — `sectionOrder` minus any feature-gated card that's
    /// switched off (currently just the women's-health cycle calendar).
    private var visibleSections: [DashboardSection] {
        sectionOrder.filter { $0 != .cycle || womensHealthEnabled }
    }

    /// Apply a long-press-drag reorder. The move arrives in `visibleSections` index space; we apply
    /// it there, then merge any hidden sections back at their prior absolute positions (so turning a
    /// feature on later restores its card roughly where it was) and persist the result.
    private func moveSection(from source: IndexSet, to destination: Int) {
        var visible = visibleSections
        visible.move(fromOffsets: source, toOffset: destination)
        var merged = visible
        for section in sectionOrder where !visible.contains(section) {
            let idx = min(sectionOrder.firstIndex(of: section) ?? merged.count, merged.count)
            merged.insert(section, at: idx)
        }
        sectionOrderRaw = merged.map(\.rawValue).joined(separator: ",")
    }

    /// Map a section id to its card view (the body's reorderable middle).
    @ViewBuilder
    private func sectionView(_ section: DashboardSection) -> some View {
        switch section {
        case .vitals:       vitalsCard
        case .vitalsStatus: vitalsStatusCard
        case .sleep:        sleepCard
        case .calories:     caloriesCard
        case .goals:        card { GoalsCardView() }
        case .workout:      workoutCard
        case .cycle:        cycleCalendarCard
        case .trends:       trendsNavigationCard
        case .sync:         syncCard
        }
    }

    /// Destination view for a programmatic navigation `Route`.
    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .trends:      TrendsView()
        case .cycle:       CycleCalendarView()
        case .deviceInfo:  DeviceInfoView(session: session)
        case .activityLog: ActivityLogView()
        }
    }

    // MARK: Pull-to-refresh

    /// Pull-to-refresh handler — mirrors the "Sync from ring" button (same guards), and holds the
    /// refresh control until the bounded history sync settles so the swipe reads as real work. If a
    /// ring is saved but not yet connected/ready, it kicks a reconnect + arms the one-shot sync (the
    /// same path as a foreground activation) instead of doing nothing.
    @MainActor
    private func forceSync() async {
        guard let session, session.ready else {
            // No live/ready session — try to (re)connect to a saved ring and arm a sync for when
            // the link comes up (no-op if there's no saved ring).
            handleForegroundActivation()
            return
        }
        // Respect the Sync button's guards: never fight a live read / in-flight sync, and a
        // not-streaming ring would sync nothing (#54).
        guard !session.syncing, !session.monitoring, !session.notStreaming else { return }
        session.syncHistory(manual: true)   // user-initiated: bypass the overnight-quiet gate
        // `syncHistory()` latches `syncing` from inside its own Task, so wait briefly for it to
        // start, then hold until it finalizes. The drain now covers TWO channels (sleep 0x00 +
        // all-day 0x03), each with its own end-marker/quiet/45 s-cap watchdog, so the hold cap is
        // sized for both; a degraded sync that exceeds it just releases the spinner while the
        // remaining channel commits in the background (the flag-flip guard, so it can't hang forever).
        for _ in 0 ..< 20 {            // ~1 s: wait for the sync to latch on
            if session.syncing { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0 ..< 950 {           // ~95 s cap: hold until BOTH channels' drain finalizes
            if !session.syncing { break }
            try? await Task.sleep(for: .milliseconds(100))
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
                    let charging = session?.charging == true     // (#61) decoded [2]==0x04, definite
                    VStack(alignment: .trailing, spacing: 0) {
                        // Charging (#61): green % + ⚡ — takes precedence over stale/low-battery red
                        // (a charging frame is by definition fresh, and "low but charging" reads green).
                        HStack(spacing: 3) {
                            Image(systemName: batteryIcon(b))
                            Text("\(b)%")
                            if charging { Image(systemName: "bolt.fill").font(.caption2) }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(charging ? AnyShapeStyle(Color.green)
                                         : stale ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(b <= 20 ? Color.red : Color.secondary))
                        if let asOf = batteryAsOf {
                            Text(asOf).font(.caption2).foregroundStyle(.tertiary)
                        }
                        // Time-to-FULL (#61) while charging: needs the rising charge slope, so it
                        // shows "estimating…" for the first ~2 pp of a charge, then "~Xh to full".
                        if charging {
                            if b >= 100 {
                                Text("Full").font(.caption2).foregroundStyle(.tertiary)
                            } else if let ttf = BatteryTTE.timeToFull(session?.batteryChargeSamples ?? []),
                                      ttf > 0 {
                                Text("~\(tteString(ttf)) to full")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                Text("estimating time to full…")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        // Time-to-empty (#86): shown whenever discharging. With the persisted
                        // history it's available almost always; right after a charge (no discharge
                        // slope yet) it shows "estimating…" until ~2 pp have drained. Suppressed
                        // while charging (decoded byte or rising-% inference) and when stale.
                        if session?.charging != true, session?.inferredCharging != true, !stale {
                            if let samples = session?.batteryTTESamples,
                               let tte = BatteryTTE.timeToEmpty(samples) {
                                Text("~\(tteString(tte)) left")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                Text("estimating time left…")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        // Charging-case battery (#89): shown only while the ring is docked in the
                        // case (the decoded [17] byte). ⚡ when the case itself is charging.
                        if let cs = session?.caseBattery {
                            HStack(spacing: 2) {
                                Image(systemName: "suitcase.fill").font(.caption2)
                                Text("Case \(cs.percent)%").font(.caption2)
                                if cs.isCharging { Image(systemName: "bolt.fill").font(.caption2) }
                            }
                            .foregroundStyle(cs.isCharging ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                        }
                    }
                }
            }
            // Link up + subscribed but the ring sends only status replies, no data (#54) — the
            // un-activated/un-bonded signature. Until the activate step is reverse-engineered, the
            // only fix is to open the official app once; say so instead of spinning forever.
            if connected, session?.notStreaming == true { activationHint }
            // Connected + streaming, but the ring is on the charger (#61, confirmed byte) or reads
            // off-wrist (#56, estimated) — surface it instead of silently backing the auto-measure
            // off. notStreaming takes precedence (an un-activated ring's wear state is meaningless),
            // and we hide it during an active measurement so it can't contradict the "measuring" cue.
            if connected, session?.notStreaming != true, session?.monitoring != true,
               session?.charging == true || session?.appearsNotWorn == true {
                notWornHint
            }
            // User-initiated measure timed out without locking a reading. Persists until the
            // user taps Measure again (which clears it naturally). (#55)
            if session?.userMeasureFailed == true { measureFailedHint }
            if !connected {
                switch scanner.state {
                case .scanning:
                    // >1 ring nearby on a fresh scan → let the user pick; otherwise we're still
                    // looking (a lone ring auto-connects after a short settle).
                    if scanner.discovered.count > 1 {
                        ringPicker
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching for ring…")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { scanner.cancelScan() }.font(.subheadline)
                        }
                    }
                case .connecting:
                    // The status line above already says "Connecting…", but a pending connect has no
                    // timeout — give the user an escape hatch so a ring that's out of range can't wedge
                    // the card forever.
                    HStack {
                        Spacer()
                        Button("Cancel") { scanner.disconnect() }.font(.subheadline)
                    }
                default:
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
    }

    /// The ring list shown on the dashboard when a fresh "Scan & connect" finds more than one ring.
    /// (Switching rings later uses the dedicated picker sheet in Device Info.) Tapping a row connects
    /// to that ring and makes it active. The "Last used" badge marks the previously active ring; rows
    /// are ordered active-first, then by name (a stable key), with a per-row signal glyph for proximity.
    private var ringPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scanner.choosingRing ? "Choose a ring" : "Multiple rings found — pick one")
                .font(.subheadline.weight(.medium))
            ForEach(sortedDiscoveredRings) { ring in
                Button {
                    scanner.connect(to: ring.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ring.name.isEmpty ? "RingConn" : ring.name)
                                .font(.subheadline.weight(.medium))
                            if ring.id.uuidString == scanner.activeRingID {
                                Text("Last used").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(signalStyle(ring.rssi))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            }
            Button("Cancel") { scanner.cancelScan() }.font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Discovered rings ordered for the picker: the active/last-used ring first, then by NAME. A
    /// stable key (not live RSSI) is deliberate — sorting by RSSI made rows jump several times a
    /// second as advertisements refreshed. The per-row signal glyph still conveys proximity.
    private var sortedDiscoveredRings: [RingScanner.DiscoveredRing] {
        scanner.discovered.sorted { lhs, rhs in
            let lActive = lhs.id.uuidString == scanner.activeRingID
            let rActive = rhs.id.uuidString == scanner.activeRingID
            if lActive != rActive { return lActive }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// RSSI is negative dBm; closer to 0 = stronger. Fade the signal glyph by proximity so the user
    /// can tell which physical ring is nearest.
    private func signalStyle(_ rssi: Int) -> some ShapeStyle {
        if rssi > -65 { return AnyShapeStyle(.primary) }
        if rssi > -80 { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
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

    /// Shown when the ring is on the charger or reads off-wrist (auto-measure paused; manual
    /// Measure/Sync are never blocked). When the decoded charging byte confirms the charger
    /// (#61, `RingSession.charging`) the copy is definite; otherwise it's the off-wrist proxy
    /// (auto-measures that never lock + a cold skin-temp reading, #56), labelled an estimate.
    private var notWornHint: some View {
        let onCharger = session?.charging == true
        return HStack(spacing: 6) {
            Image(systemName: onCharger ? "bolt.circle" : "pause.circle")
                .foregroundStyle(.secondary)
            Text(onCharger
                 ? "Ring is on the charger — auto-measure paused"
                 : "Ring looks off-wrist (estimated) — auto-measure paused")
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
        let d = totalMin / 1440
        let h = (totalMin % 1440) / 60
        let m = totalMin % 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
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
        Button {
            path.append(.cycle)
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
        Button {
            path.append(.trends)
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
        Button {
            path.append(.activityLog)
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
                session?.syncHistory(manual: true)   // user-initiated: drains both channels (0x00 sleep + 0x03 all-day), bypasses overnight-quiet gate
            } label: {
                Label(session?.syncing == true ? "Syncing…" : "Sync from ring",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session?.ready != true || session?.syncing == true
                      || session?.monitoring == true        // stop live before syncing
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
                        do {
                            try await health.requestAuthorization()
                        } catch {
                            // The request throws when the HealthKit entitlement is absent — the
                            // signature of a free-Apple-ID sideload (the entitlement is paid-account
                            // only and gets stripped on re-sign). Surface it instead of failing
                            // silently; the app still works as a local dashboard. (#104)
                            healthUnavailable = true
                        }
                        healthAuthorized = health.isShareAuthorized
                        if healthAuthorized {
                            healthUnavailable = false
                            observability.markHealthEverAuthorized()
                        }
                        flushHealth()   // backfill everything already in the store
                    }
                } label: {
                    Label("Authorize Apple Health", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!HealthKitWriter.isAvailable)
                if healthUnavailable {
                    Text("This build can't write to Apple Health — that needs the TestFlight build. "
                         + "(Free side-loaded builds can't use HealthKit.) OpenCircuit still works "
                         + "as a local dashboard.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        Button {
            path.append(.deviceInfo)
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
                    // Per-channel epochs from the last sync — `all-day N` with N>0 proves the 0x03
                    // (daytime SpO₂/HR) channel is being drained, not just sleep (#99).
                    if let drain = session?.lastDrainSummary {
                        Text("Last sync — \(drain)")
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        Divider()
                    }
                    Text(session?.lastFrame ?? "no frames yet")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Text("Debug — last sync & frame").font(.subheadline.weight(.medium))
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
        // Prefer stagedSegments (asleepCore/asleepDeep/asleepREM/awake — issue #15) when
        // both are non-empty:
        //   • coarse non-empty → wear gate passed (not a charging/off-wrist night)
        //   • staged non-empty → classifier detected a valid overnight block
        // Fall back to coarse segments (inBed/asleepCore/awake only) when staged is empty
        // — no HR data in the block, or a non-overnight detection.
        let staged = session?.stagedSegments ?? []
        let coarse = session?.sleepSegments ?? []
        let segments = !staged.isEmpty && !coarse.isEmpty ? staged : coarse
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

/// The reorderable dashboard sections — everything between the pinned connection card at the top and
/// the pinned device-info/debug cards at the bottom. `rawValue` is the persistence key written to
/// `dashboard.sectionOrder`, so keep these stable across releases; `allCases` order is the default
/// (first-run) layout.
private enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case vitals, vitalsStatus, sleep, calories, goals, workout, cycle, trends, sync
    var id: String { rawValue }
}

/// Programmatic navigation targets pushed onto the `NavigationStack` path. Using a typed route (vs a
/// `NavigationLink` per card) keeps the `List` from drawing its own disclosure chevron on top of the
/// cards' custom ones.
private enum Route: Hashable {
    case trends, cycle, deviceInfo, activityLog
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
