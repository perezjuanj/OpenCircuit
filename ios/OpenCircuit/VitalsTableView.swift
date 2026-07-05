import SwiftUI
import SwiftData
import OpenCircuitKit

/// Persistent vitals dashboard. Reads the latest stored sample per metric (so values
/// are always visible offline) and prefers the live session reading when connected.
struct VitalsTableView: View {
    @Environment(\.modelContext) private var modelContext
    // BOUNDED fetches replace the old unbounded `@Query` that loaded every StoredSample on every
    // view update (#32). Each "latest" query is `fetchLimit = 1`; the two windowed queries cap
    // the scan to a recent time slice instead of all history. All filtering done in `body` is
    // over these already-bounded arrays — never a synchronous fetch (the #14 black-screen hazard).
    /// Latest stored sample per displayed kind (newest first, capped at 1 each).
    @Query private var latestHR: [StoredSample]
    @Query private var latestSpO2: [StoredSample]
    @Query private var latestTempSample: [StoredSample]
    @Query private var latestHRV: [StoredSample]
    @Query private var latestRR: [StoredSample]
    @Query private var latestDaytimeTemp: [StoredDaytimeTemp]
    /// Heart-rate samples over the last 24 h — the window resting HR (the sleep low) scans.
    @Query private var recentHR: [StoredSample]
    /// Temperature samples over the last few days — narrowed in memory to the precise night
    /// window for the overnight average (the exact window depends on async @State).
    @Query private var recentTemp: [StoredSample]
    /// Nightly metric samples (HRV + Respiratory Rate) over the last few days — narrowed in memory
    /// to the night window for the overnight MEAN shown in the HRV/RR rows, so the Vitals figure
    /// matches the Sleep card's (it previously showed the single newest epoch). Bounded like
    /// recentHR/recentTemp (#32).
    @Query private var recentHRV: [StoredSample]
    /// Latest persisted sleep summary (capped at 1). The sleep BREAKDOWN now lives in the
    /// dedicated SleepCardView; this query is retained only to bound the skin-temp night window
    /// (`nightWindow`) to the most recent night's actual onset/wake span.
    @Query private var storedSleep: [StoredSleepSummary]
    /// Latest persisted daily rollup (capped at 1) — the offline fallback for live steps.
    @Query private var storedDaily: [StoredDaily]
    /// Live session (optional) — its readings override stored ones while connected.
    var session: RingSession?

    /// The user's sleep window (from the manual schedule, or the iOS Sleep schedule once
    /// HealthKit is authorized) — the preferred bound for the night-temp window. Resolved
    /// asynchronously into @State (see `.task`), never fetched synchronously in `body`.
    @State private var scheduleWindow: DateInterval?
    // Mirror the sleep-schedule settings so the window re-resolves when the user edits them.
    @AppStorage(SleepScheduleDefaults.enabled) private var sleepEnabled = false
    @AppStorage(SleepScheduleDefaults.bedMinutes) private var bedMinutes = SleepScheduleDefaults.defaultBedMinutes
    @AppStorage(SleepScheduleDefaults.wakeMinutes) private var wakeMinutes = SleepScheduleDefaults.defaultWakeMinutes
    /// Temperature display unit (#83). Syncs with the Units section in UserProfileSettingsView.
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    /// Days of temperature history the night-temp window query scans before the precise night
    /// window is applied in memory — generous enough to cover the most recent night, still tiny
    /// versus all history.
    private static let tempWindowDays: TimeInterval = 3

    init(session: RingSession? = nil) {
        self.session = session

        // Anchor the time windows to the start of the current hour so the @Query descriptors stay
        // stable across rapid SwiftUI re-renders (only re-fetching hourly or when data changes),
        // instead of churning on every render with a millisecond-fresh cutoff.
        let hourStart = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let dayAgo = hourStart.addingTimeInterval(-86_400)
        let tempLookback = hourStart.addingTimeInterval(-Self.tempWindowDays * 86_400)

        let hr = MetricKind.heartRate.rawValue
        let spo2 = MetricKind.spo2.rawValue
        let temp = MetricKind.temperature.rawValue
        let hrv = MetricKind.hrvSDNN.rawValue
        let rr = MetricKind.respiratoryRate.rawValue

        _latestHR = Query(Self.latestDescriptor(hr))
        _latestSpO2 = Query(Self.latestDescriptor(spo2))
        _latestTempSample = Query(Self.latestDescriptor(temp))
        _latestHRV = Query(Self.latestDescriptor(hrv))
        _latestRR = Query(Self.latestDescriptor(rr))
        var latestDaytimeTempDesc = FetchDescriptor<StoredDaytimeTemp>(
            predicate: #Predicate { $0.celsius > 0 },
            sortBy: [SortDescriptor(\.time, order: .reverse)])
        latestDaytimeTempDesc.fetchLimit = 1
        _latestDaytimeTemp = Query(latestDaytimeTempDesc)
        _recentHR = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hr && $0.start > dayAgo && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))
        _recentTemp = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == temp && $0.start > tempLookback && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))
        // Nightly metrics (HRV + RR) over the last few days, narrowed to the night window in memory
        // for the overnight mean (matches the Sleep card). Same bounded pattern as recentTemp.
        let nightlyLookback = hourStart.addingTimeInterval(-Self.tempWindowDays * 86_400)
        _recentHRV = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { ($0.kindRaw == hrv || $0.kindRaw == rr) && $0.start > nightlyLookback && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))

        var sleepDesc = FetchDescriptor<StoredSleepSummary>(
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        sleepDesc.fetchLimit = 1
        _storedSleep = Query(sleepDesc)
        var dailyDesc = FetchDescriptor<StoredDaily>(sortBy: [SortDescriptor(\.day, order: .reverse)])
        dailyDesc.fetchLimit = 1
        _storedDaily = Query(dailyDesc)
    }

    /// Newest-first, single-row descriptor for one metric kind. Predicate shape (`kindRaw` then
    /// `start`) is index-friendly so it can use a composite index if one is added later. (#32)
    private static func latestDescriptor(_ kindRaw: String) -> FetchDescriptor<StoredSample> {
        var d = FetchDescriptor<StoredSample>(
            // `value > 0` so a 0-bpm/0-value placeholder (e.g. an EpochSync HR placeholder) can't
            // become the displayed "latest" reading (it would render as "0 bpm").
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    /// Prefer the ring's live onboard count; fall back to the stored count ONLY if it's
    /// today's (the row is labeled "today", so a prior day's total must not appear).
    private var effectiveSteps: Int? {
        if let s = session?.steps { return s }
        let today = Calendar.current.startOfDay(for: Date())
        return storedDaily.first.flatMap { $0.day == today ? $0.steps : nil }
    }

    /// Latest stored sample per displayed kind, assembled from the per-kind `fetchLimit = 1`
    /// queries (absent kinds stay out of the dict). Replaces the old in-memory reduce over every
    /// stored row. (#32)
    private var latest: [MetricKind: StoredSample] {
        var out: [MetricKind: StoredSample] = [:]
        out[.heartRate] = latestHR.first
        out[.spo2] = latestSpO2.first
        out[.temperature] = latestTempSample.first
        out[.hrvSDNN] = latestHRV.first
        out[.respiratoryRate] = latestRR.first
        return out
    }

    /// Newest reading per kind from the JUST-SYNCED in-memory batch (`session.historySamples`),
    /// independent of the store. The sync drain always refreshes this, and it lives on the
    /// @Observable session so a completed sync re-renders the dashboard immediately — even when
    /// the cursor dedup (SyncCursor) keeps those overlapping/last-night epochs out of the store
    /// and the @Query therefore never changes. Without this, the sync card showed HR/HRV/SpO₂ the
    /// Vitals rows didn't, until a manual (now-timestamped) reading forced a refresh. (#67)
    private var latestSynced: [MetricKind: (value: Double, start: Date)] {
        guard let samples = session?.historySamples, !samples.isEmpty else { return [:] }
        var out: [MetricKind: (value: Double, start: Date)] = [:]
        for s in samples where s.value > 0 {
            if let cur = out[s.kind], cur.start >= s.start { continue }
            out[s.kind] = (s.value, s.start)
        }
        return out
    }

    /// The reading to DISPLAY for a kind: whichever is more recent between the persisted store
    /// sample and the just-synced in-memory batch (#67). After disconnect `latestSynced` is empty
    /// so this falls back to the store. Only ever returns a real decoded reading.
    private func latestReading(_ kind: MetricKind) -> (value: Double, start: Date)? {
        let stored = latest[kind].map { (value: $0.value, start: $0.start) }
        switch (stored, latestSynced[kind]) {
        case let (s?, h?): return h.start > s.start ? h : s
        case let (s?, nil): return s
        case let (nil, h?): return h
        case (nil, nil): return nil
        }
    }

    /// Resting HR ≈ the lowest HR over the last 24 h (sleep low). `recentHR` is the bounded 24 h,
    /// value-positive HR window from the store; the just-synced batch is folded in too so a fresh
    /// sync lowers it immediately rather than waiting for a manual reading. (#32, #67)
    private var restingHR: Int? {
        let dayAgo = Date().addingTimeInterval(-86_400)
        // Band-guard both sources to physiologically-plausible HR (LiveHR.validBPM, 30…220) so a
        // stray out-of-band sample — a garbage 4 bpm epoch, or a not-yet-purged legacy row — can't
        // become the displayed "Resting HR" (the impossible "4 bpm" bug). Defence in depth: the
        // decoder now blocks these at the source and a one-time purge clears existing ones.
        func plausible(_ v: Double) -> Bool { LiveHR.validBPM.contains(Int(v)) }
        var lows = recentHR.map(\.value).filter(plausible)
        if let samples = session?.historySamples {
            lows += samples
                .filter { $0.kind == .heartRate && plausible($0.value) && $0.start > dayAgo }
                .map(\.value)
        }
        return lows.min().map { Int($0) }
    }

    /// Overnight MEAN of a nightly metric (HRV / Respiratory Rate) over the most recent night's
    /// in-bed window — the SAME value the Sleep card shows (via `OvernightAverages`), so the two
    /// can't disagree (the cause of "HRV 86 ms in Vitals vs 64 ms in Sleep": Vitals showed the
    /// single newest epoch, Sleep the overnight mean). nil when there's no usable night window or
    /// no in-window samples, so the row falls back to "—" exactly like the Sleep card's empty state.
    private func overnightMean(_ kind: MetricKind) -> Double? {
        guard let s = storedSleep.first, s.asleepMin > 0,
              s.inBedStart > .distantPast, s.inBedEnd > s.inBedStart else { return nil }
        let window = DateInterval(start: s.inBedStart, end: s.inBedEnd)
        let raw = kind.rawValue
        let points = recentHRV
            .filter { $0.kindRaw == raw }
            .map { OvernightAverages.Point(value: $0.value, start: $0.start) }
        return OvernightAverages.mean(points, window: window)
    }

    /// Nightly metrics (HRV / Respiratory Rate) on the HOME screen follow the same "latest recorded
    /// reading + its timestamp" rule as the other vitals. Overnight means still matter for the Sleep
    /// card and Trends, but making Home prefer the overnight aggregate caused it to look stale even
    /// when a newer recorded spot reading already existed in the store and Trends showed it.
    @ViewBuilder
    private func nightlyMeanRow(_ label: String, _ kind: MetricKind,
                               _ fmt: (Double) -> String) -> some View {
        if let latestPoint = latestReading(kind) {
            row(label, value: fmt(latestPoint.value),
                time: Self.rel.localizedString(for: latestPoint.start, relativeTo: Date()))
        } else if let mean = overnightMean(kind) {
            row(label, value: fmt(mean), time: nightlyWhen(kind) ?? "last night")
        } else {
            row(label, value: "—", time: "after overnight sync")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            measurableRow("Heart Rate", value: hrText, mode: .hr, active: hrActive,
                          time: hrActive && session?.liveHR == nil
                              ? (session?.livePreparing == true ? "preparing…" : "measuring…")
                              : timeFor(.heartRate, live: hrLive))
            divider
            spo2Row
            divider
            skinTempRow
            divider
            // Sleep-derived rows: caption "after overnight sync" on each bare "—" row so the
            // user understands WHY they're empty, rather than seeing a bare dash with no context.
            // The full explanation lives in the dedicated Sleep card's empty state below. (#58)
            nightlyMeanRow("HRV", .hrvSDNN) { "\(Int($0.rounded())) ms" }
            divider
            row("Resting HR", value: restingHR.map { "\($0) bpm" } ?? "—",
                time: restingHR == nil ? "after overnight sync" : nil)
            divider
            row("Steps (today)", value: stepsText, time: stepsTime)
            divider
            nightlyMeanRow("Respiratory Rate", .respiratoryRate) {
                String(format: "%.1f \(UnitsFormatter.respiratoryRateUnit)", $0)
            }
        }
        .padding(.vertical, 4)
        // Resolve the (async) sleep-schedule window once the view appears. The selector
        // returns the HealthKit window when authorized, else the manual one, else nil.
        .task(id: "\(sleepEnabled)-\(bedMinutes)-\(wakeMinutes)") {
            scheduleWindow = await SleepSchedule.current(forNightEndingNear: Date())
        }
    }

    /// SpO₂ row with estimate caveat. Time logic mirrors `measurableRow` so the
    /// "preparing…"/"measuring…" split is preserved for user-initiated reads.
    @ViewBuilder private var spo2Row: some View {
        HStack(spacing: 10) {
            Text("SpO₂").font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(spo2Text).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("est.").font(.caption2).foregroundStyle(.tertiary)
                if let time = (spo2Active && session?.liveSpO2 == nil
                    ? (session?.livePreparing == true ? "preparing…" : "measuring…")
                    : timeFor(.spo2, live: spo2Live)) {
                    Text(time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            measureButton(.spo2, active: spo2Active)
        }
        .padding(.vertical, 8)
    }

    // MARK: rows

    private func row(_ label: String, value: String, time: String?) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let time { Text(time).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: On-demand metrics (HR / SpO2)

    /// The stop button belongs only to a user-initiated measurement. Auto-measure and workout
    /// cycles keep ownership of the link, so their live reads cannot be stopped from this row.
    private var hrActive: Bool { userMeasureActive(.hr) }
    private var spo2Active: Bool { userMeasureActive(.spo2) }

    private func userMeasureActive(_ mode: RingSession.LiveMode) -> Bool {
        session?.userMeasuring == true
            && session?.monitoring == true
            && session?.liveMode == mode
    }

    /// True when the link has gone quiet so a lingering live value must not read as current (#36).
    private var liveStale: Bool { session?.liveReadingsStale == true }

    /// A vitals row carrying an inline start/stop measure control for an on-demand metric.
    private func measurableRow(_ label: String, value: String, mode: RingSession.LiveMode,
                               active: Bool, time: String?) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let time { Text(time).font(.caption2).foregroundStyle(.secondary) }
            }
            measureButton(mode, active: active)
        }
        .padding(.vertical, 8)
    }

    /// Small circular start/stop control. Appears only when the ring link is ready. Starting one
    /// user measurement can switch between HR and SpO2, but auto/workout/calibration-owned live
    /// cycles are left alone.
    @ViewBuilder
    private func measureButton(_ mode: RingSession.LiveMode, active: Bool) -> some View {
        if session?.ready == true {
            let color: Color = mode == .hr ? .red : .blue
            let icon = mode == .hr ? "heart.fill" : "lungs.fill"
            Button {
                if active { session?.stopLiveMonitoring() }
                else { session?.startMonitoring(mode: mode, userInitiated: true, quickLiveRead: true) }
            } label: {
                Image(systemName: active ? "stop.fill" : icon)
                    .font(.caption2.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(active ? color : Color(.systemGray5)))
                    .foregroundStyle(active ? .white : color)
                    .symbolEffect(.pulse, isActive: active)
            }
            .buttonStyle(.plain)
            .disabled(measureDisabled())
        }
    }

    private func measureDisabled() -> Bool {
        guard let session else { return true }
        if session.syncing || session.notStreaming || session.calibrationCapturing { return true }
        if session.capturingHistoricPull || session.capturingForensicSweep || session.probing { return true }
        return session.workoutHolding
    }

    private var divider: some View { Divider().opacity(0.4) }

    // MARK: value formatting (live user reads override stored values)

    /// HR/SpO2 count as "live" only for user-initiated reads whose frames are still fresh.
    /// Auto-measure/workout cycles persist their samples through the existing owner paths.
    private var hrLive: Bool { hrActive && session?.liveHR != nil && !liveStale }
    private var spo2Live: Bool { spo2Active && session?.liveSpO2 != nil && !liveStale }

    private var hrText: String {
        if hrLive, let hr = session?.liveHR { return "\(hr) bpm" }
        return valueText(.heartRate) { "\(Int($0)) bpm" }
    }
    private var spo2Text: String {
        if spo2Live, let s = session?.liveSpO2 { return "\(s) %" }
        return valueText(.spo2) { "\(Int(($0 * 100).rounded())) %" }
    }
    // MARK: Skin temp (headline = latest reading; overnight average shown as context)

    /// Skin Temp row. The headline always shows the LATEST reading — the live value when
    /// connected, else the most recent stored sample. The ring only polls skin temp overnight
    /// (unless it sends one unsolicited), so the latest reading is normally last night's, which
    /// is what we want on top during the day. The overnight average rides the secondary caption.
    private var skinTempRow: some View {
        HStack {
            Text("Skin Temp").font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(latestTemp.map(tempString) ?? "—")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                if let secondary = skinTempSecondary {
                    Text(secondary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Latest skin-temp reading for the headline: prefer the newest available source across
    /// the live descriptor, the canonical overnight/sample lane, and the daytime Trends-only
    /// lane. Without the `StoredDaytimeTemp` comparison the home screen could show a stale
    /// "5 h ago" overnight value while Trends already had a newer daytime reading.
    private var latestTempReading: (value: Double, start: Date)? {
        var candidates: [(value: Double, start: Date)] = []
        if let live = session?.liveTemperature, let at = session?.lastFrameAt {
            candidates.append((live, at))
        }
        if let sample = latest[.temperature], sample.value > 0 {
            candidates.append((sample.value, sample.start))
        }
        if let daytime = latestDaytimeTemp.first, daytime.celsius > 0 {
            candidates.append((daytime.celsius, daytime.time))
        }
        return candidates.max { $0.start < $1.start }
    }

    private var latestTemp: Double? {
        latestTempReading?.value
    }

    /// Secondary caption under the Skin Temp headline: how fresh the headline reading is
    /// ("live" when connected, else relative time) and the overnight average for context.
    private var skinTempSecondary: String? {
        var parts: [String] = []
        if let temp = latestTempReading {
            parts.append(Self.rel.localizedString(for: temp.start, relativeTo: Date()))
        }
        if let night = nightTemp {
            parts.append("overnight \(tempString(night))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Average skin temp (°C) over the most recent NIGHT window, or nil if that window has
    /// no temperature samples (then the secondary caption simply omits the overnight figure).
    /// Window: the latest stored sleep summary's span (night..night+inBed) when available,
    /// else local 00:00–06:00 of the most recent date that has temperature samples.
    private var nightTemp: Double? {
        guard let window = nightWindow else { return nil }
        // Narrow the already-loaded (bounded) `recentTemp` window to the precise night in memory
        // — no synchronous fetch in `body` (that hazard once caused a black-screen launch). #14
        let vals = recentTemp.lazy
            .filter { $0.start >= window.start && $0.start <= window.end }
            .map(\.value)
        var sum = 0.0, n = 0
        for v in vals { sum += v; n += 1 }
        return n > 0 ? sum / Double(n) : nil
    }

    private var nightWindow: (start: Date, end: Date)? {
        // Prefer the user's sleep schedule (manual today; the iOS Sleep schedule once
        // HealthKit is authorized — see SleepSchedule.swift), but ONLY once that window has
        // actually started — otherwise an evening's *upcoming* night (start in the future)
        // would window the temp average over a range with no samples and blank the headline.
        // Before tonight's window begins, fall through to last night's completed span.
        if let w = scheduleWindow, w.start <= Date() { return (w.start, w.end) }
        // Else the most recent night's ACTUAL sleep span (real onset/wake clock times),
        // not a midnight-anchored guess — so pre-midnight sleep aligns correctly.
        if let s = storedSleep.first, s.asleepMin > 0,
           s.inBedStart > Date.distantPast, s.inBedEnd > s.inBedStart {
            return (s.inBedStart, s.inBedEnd)
        }
        // Fallback: 00:00–06:00 of the most recent date that has temperature samples.
        guard let lastTemp = latestTempReading?.start else { return nil }
        let dayStart = Calendar.current.startOfDay(for: lastTemp)
        return (dayStart, dayStart.addingTimeInterval(6 * 3600))
    }
    /// Ring's onboard step count — live while connected (the descriptor streams it). It's
    /// the ring's own count, which can differ from the official app's cloud daily total.
    private var stepsText: String {
        guard let s = effectiveSteps else { return "—" }
        return "\(s)"
    }
    /// "live" while the descriptor is fresh; else the relative time of today's stored count (nil
    /// if the only stored count is from a prior day — `effectiveSteps` shows "—" then). A quiet
    /// link no longer reads as "live" (#36) — it shows when the count was last updated instead.
    private var stepsTime: String? {
        let today = Calendar.current.startOfDay(for: Date())
        guard let d = storedDaily.first, d.day == today, d.steps > 0 else { return nil }
        return Self.rel.localizedString(for: d.updatedAt, relativeTo: Date())
    }

    /// Format a Celsius value in the user's chosen unit (#83).
    private func tempString(_ celsius: Double) -> String {
        let unit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
        return UnitsFormatter.temperature(celsius, unit: unit)
    }

    /// Latest stored value for `kind`, formatted, or "—" if none.
    private func valueText(_ kind: MetricKind, _ fmt: (Double) -> String) -> String {
        latestReading(kind).map { fmt($0.value) } ?? "—"
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private func timeFor(_ kind: MetricKind, live: Bool = false) -> String? {
        if live { return "live" }
        guard let r = latestReading(kind) else { return nil }
        return Self.rel.localizedString(for: r.start, relativeTo: Date())
    }

    private static let nightlyDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    /// Freshness label for NIGHTLY metrics (HRV, Respiratory Rate) — the ring only derives
    /// these from sleep, so a relative "5h ago" misreads as a stale live value. Show which
    /// night it's from instead: "last night" for this morning's sleep, else the date.
    private func nightlyWhen(_ kind: MetricKind) -> String? {
        guard let r = latestReading(kind) else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: r.start),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<0: return nil            // future timestamp (shouldn't happen) — omit
        case 0: return "last night"
        case 1: return "yesterday"
        default: return Self.nightlyDate.string(from: r.start)
        }
    }
}
