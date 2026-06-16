import SwiftUI
import SwiftData
import OpenRingKit

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
    /// Heart-rate samples over the last 24 h — the window resting HR (the sleep low) scans.
    @Query private var recentHR: [StoredSample]
    /// Temperature samples over the last few days — narrowed in memory to the precise night
    /// window for the overnight average (the exact window depends on async @State).
    @Query private var recentTemp: [StoredSample]
    /// Latest persisted sleep summary (capped at 1) — the offline fallback for `sleep`.
    @Query private var storedSleep: [StoredSleepSummary]
    /// Latest persisted daily rollup (capped at 1) — the offline fallback for live steps.
    @Query private var storedDaily: [StoredDaily]
    /// Live session (optional) — its readings override stored ones while connected.
    var session: RingSession?
    /// LIVE sleep summary for the most recent night (total asleep + estimated stage
    /// breakdown). When nil (no live session), `effectiveSleep` falls back to the store.
    var sleep: SleepStaging.Summary?

    /// The user's sleep window (from the manual schedule, or the iOS Sleep schedule once
    /// HealthKit is authorized) — the preferred bound for the night-temp window. Resolved
    /// asynchronously into @State (see `.task`), never fetched synchronously in `body`.
    @State private var scheduleWindow: DateInterval?
    // Mirror the sleep-schedule settings so the window re-resolves when the user edits them.
    @AppStorage(SleepScheduleDefaults.enabled) private var sleepEnabled = false
    @AppStorage(SleepScheduleDefaults.bedMinutes) private var bedMinutes = SleepScheduleDefaults.defaultBedMinutes
    @AppStorage(SleepScheduleDefaults.wakeMinutes) private var wakeMinutes = SleepScheduleDefaults.defaultWakeMinutes

    /// Days of temperature history the night-temp window query scans before the precise night
    /// window is applied in memory — generous enough to cover the most recent night, still tiny
    /// versus all history.
    private static let tempWindowDays: TimeInterval = 3

    init(session: RingSession? = nil, sleep: SleepStaging.Summary? = nil) {
        self.session = session
        self.sleep = sleep

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
        _recentHR = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hr && $0.start > dayAgo && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))
        _recentTemp = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == temp && $0.start > tempLookback && $0.value > 0 },
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
            predicate: #Predicate { $0.kindRaw == kindRaw },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    /// Prefer the live session summary; fall back to the latest stored night offline.
    private var effectiveSleep: SleepStaging.Summary? {
        if let sleep { return sleep }
        guard let s = storedSleep.first, s.asleepMin > 0 else { return nil }
        return s.asSummary
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

    /// Resting HR ≈ the lowest HR over the last 24 h (sleep low). `recentHR` is already the
    /// bounded 24 h, value-positive HR window, so this is just its min. (#32)
    private var restingHR: Int? {
        recentHR.map(\.value).min().map { Int($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            measurableRow("Heart Rate", value: hrText, mode: .hr, active: hrActive,
                          time: hrActive && session?.liveHR == nil
                              ? "measuring…" : timeFor(.heartRate, live: hrLive))
            divider
            measurableRow("SpO₂", value: spo2Text, mode: .spo2, active: spo2Active,
                          time: spo2Active && session?.liveSpO2 == nil
                              ? "measuring…" : timeFor(.spo2, live: spo2Live))
            divider
            skinTempRow
            divider
            row("HRV", value: valueText(.hrvSDNN) { "\(Int($0)) ms" }, time: nightlyWhen(.hrvSDNN))
            divider
            row("Resting HR", value: restingHR.map { "\($0) bpm" } ?? "—", time: nil)
            divider
            row("Steps (today)", value: stepsText, time: stepsTime)
            divider
            row("Respiratory Rate", value: valueText(.respiratoryRate) { String(format: "%.1f /min", $0) },
                time: nightlyWhen(.respiratoryRate))
            divider
            sleepSection
        }
        .padding(.vertical, 4)
        // Resolve the (async) sleep-schedule window once the view appears. The selector
        // returns the HealthKit window when authorized, else the manual one, else nil.
        .task(id: "\(sleepEnabled)-\(bedMinutes)-\(wakeMinutes)") {
            scheduleWindow = await SleepSchedule.current(forNightEndingNear: Date())
        }
    }

    /// Sleep: total asleep + estimated Deep/Light/REM/Awake breakdown (stages are an
    /// on-device estimate — the ring doesn't send stage labels).
    @ViewBuilder private var sleepSection: some View {
        if let s = effectiveSleep, s.minutes.asleep > 0 {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Sleep").font(.subheadline)
                    Spacer()
                    Text("\(s.minutes.asleep / 60)h \(s.minutes.asleep % 60)m")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text("Deep \(s.minutes.deep)m · Light \(s.minutes.light)m · REM \(s.minutes.rem)m · Awake \(s.minutes.awake)m")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("est.\(sleepWhen.map { " · \($0)" } ?? "") · \(Int((s.efficiency * 100).rounded()))% efficiency")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        } else {
            row("Sleep", value: "—", time: nil)
        }
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

    // MARK: On-demand metrics (HR / SpO₂) — an inline Measure control replaces the old big cards

    private var hrActive: Bool { session?.monitoring == true && session?.liveMode == .hr }
    private var spo2Active: Bool { session?.monitoring == true && session?.liveMode == .spo2 }

    /// True when the link has gone quiet so a lingering live value must NOT read as "live" (#36).
    /// A silently-dropped link keeps its last HR/SpO₂/steps/temp until CoreBluetooth fires
    /// `didDisconnect`; staleness lets us show "Xm ago" instead of a minutes-old value as current.
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

    /// Small circular start/stop control. Appears only when the ring link is ready; disabled
    /// while a history sync holds the link. Starting one metric stops the other (the ring
    /// measures one at a time); tapping the active one stops it.
    @ViewBuilder
    private func measureButton(_ mode: RingSession.LiveMode, active: Bool) -> some View {
        if session?.ready == true {
            let color: Color = mode == .hr ? .red : .blue
            let icon = mode == .hr ? "heart.fill" : "lungs.fill"
            Button {
                if active { session?.stopLiveMonitoring() }
                else { session?.startMonitoring(mode: mode) }
            } label: {
                Image(systemName: active ? "stop.fill" : icon)
                    .font(.caption2.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(active ? color : Color(.systemGray5)))
                    .foregroundStyle(active ? .white : color)
                    .symbolEffect(.pulse, isActive: active)
            }
            .buttonStyle(.plain)
            .disabled(session?.syncing == true)
        }
    }

    private var divider: some View { Divider().opacity(0.4) }

    // MARK: value formatting (live overrides stored)

    /// HR/SpO₂ count as "live" only while we're actively measuring that metric AND frames are
    /// still arriving. A leftover value after monitoring stops, or a silently-dropped link, falls
    /// back to the stored sample's timestamp instead of a false "live" caption (#36).
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

    /// Latest skin-temp reading for the headline: the live value when connected, else the most
    /// recent stored sample (ignoring zero/invalid placeholders), or nil if we have none.
    private var latestTemp: Double? {
        if let live = session?.liveTemperature { return live }
        return latest[.temperature].map(\.value).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Secondary caption under the Skin Temp headline: how fresh the headline reading is
    /// ("live" when connected, else relative time) and the overnight average for context.
    private var skinTempSecondary: String? {
        var parts: [String] = []
        if session?.liveTemperature != nil, !liveStale {
            parts.append("live")
        } else if latestTemp != nil, let s = latest[.temperature] {
            parts.append(Self.rel.localizedString(for: s.start, relativeTo: Date()))
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
        guard let lastTemp = latest[.temperature]?.start else { return nil }
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
        if session?.steps != nil, !liveStale { return "live" }
        let today = Calendar.current.startOfDay(for: Date())
        guard let d = storedDaily.first, d.day == today, d.steps > 0 else { return nil }
        return Self.rel.localizedString(for: d.updatedAt, relativeTo: Date())
    }

    /// For a STORED (not live) sleep summary, the night it covers, so a days-old summary
    /// isn't shown as if it were last night. nil when the value is live.
    private var sleepWhen: String? {
        guard sleep == nil, let s = storedSleep.first else { return nil }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: s.night)
    }

    private func tempString(_ celsius: Double) -> String {
        String(format: "%.1f °F", celsius * 9 / 5 + 32)
    }

    /// Latest stored value for `kind`, formatted, or "—" if none.
    private func valueText(_ kind: MetricKind, _ fmt: (Double) -> String) -> String {
        latest[kind].map { fmt($0.value) } ?? "—"
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private func timeFor(_ kind: MetricKind, live: Bool = false) -> String? {
        if live { return "live" }
        guard let s = latest[kind] else { return nil }
        return Self.rel.localizedString(for: s.start, relativeTo: Date())
    }

    private static let nightlyDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    /// Freshness label for NIGHTLY metrics (HRV, Respiratory Rate) — the ring only derives
    /// these from sleep, so a relative "5h ago" misreads as a stale live value. Show which
    /// night it's from instead: "last night" for this morning's sleep, else the date.
    private func nightlyWhen(_ kind: MetricKind) -> String? {
        guard let s = latest[kind] else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: s.start),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<0: return nil            // future timestamp (shouldn't happen) — omit
        case 0: return "last night"
        case 1: return "yesterday"
        default: return Self.nightlyDate.string(from: s.start)
        }
    }
}
