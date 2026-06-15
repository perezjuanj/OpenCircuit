import SwiftUI
import SwiftData
import OpenRingKit

/// Persistent vitals dashboard. Reads the latest stored sample per metric (so values
/// are always visible offline) and prefers the live session reading when connected.
struct VitalsTableView: View {
    @Environment(\.modelContext) private var modelContext
    /// Most-recent samples first; we reduce to the latest per kind in `latest`.
    @Query(sort: \StoredSample.start, order: .reverse) private var samples: [StoredSample]
    /// Persisted sleep summaries (latest night first) — the offline fallback for `sleep`.
    @Query(sort: \StoredSleepSummary.night, order: .reverse) private var storedSleep: [StoredSleepSummary]
    /// Persisted daily rollups (latest day first) — the offline fallback for live steps.
    @Query(sort: \StoredDaily.day, order: .reverse) private var storedDaily: [StoredDaily]
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

    private var latest: [MetricKind: StoredSample] {
        var out: [MetricKind: StoredSample] = [:]
        for s in samples {
            guard let k = MetricKind(rawValue: s.kindRaw), out[k] == nil else { continue }
            out[k] = s
        }
        return out
    }

    /// Resting HR ≈ the lowest HR over the last 24 h (sleep low), derived from stored HR.
    private var restingHR: Int? {
        let dayAgo = Date().addingTimeInterval(-86_400)
        let hrs = samples
            .filter { $0.kindRaw == MetricKind.heartRate.rawValue && $0.start > dayAgo && $0.value > 0 }
            .map { $0.value }
        return hrs.min().map { Int($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Heart Rate", value: hrText, time: timeFor(.heartRate, live: session?.liveHR != nil))
            divider
            row("SpO₂", value: spo2Text, time: timeFor(.spo2, live: session?.liveSpO2 != nil))
            divider
            skinTempRow
            divider
            row("HRV", value: valueText(.hrvSDNN) { "\(Int($0)) ms" }, time: timeFor(.hrvSDNN))
            divider
            row("Resting HR", value: restingHR.map { "\($0) bpm" } ?? "—", time: nil)
            divider
            row("Steps (today)", value: stepsText, time: stepsTime)
            divider
            row("Respiratory Rate", value: valueText(.respiratoryRate) { String(format: "%.1f /min", $0) },
                time: timeFor(.respiratoryRate))
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

    private var divider: some View { Divider().opacity(0.4) }

    // MARK: value formatting (live overrides stored)

    private var hrText: String {
        if let hr = session?.liveHR { return "\(hr) bpm" }
        return valueText(.heartRate) { "\(Int($0)) bpm" }
    }
    private var spo2Text: String {
        if let s = session?.liveSpO2 { return "\(s) %" }
        return valueText(.spo2) { "\(Int(($0 * 100).rounded())) %" }
    }
    // MARK: Skin temp (overnight headline; daytime live value is noisy, shown only as "now")

    /// Skin Temp row. The headline is the OVERNIGHT average (skin temp is noisy during the
    /// day from ambient/activity), never the live daytime value. When connected we still
    /// show the live reading as a small secondary line, clearly labeled "now".
    private var skinTempRow: some View {
        HStack {
            Text("Skin Temp").font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(nightTemp.map(tempString) ?? "—")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                if let secondary = skinTempSecondary {
                    Text(secondary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Secondary caption under the Skin Temp headline: "overnight" when we have a night
    /// average, plus the live value as "now …" when actively connected.
    private var skinTempSecondary: String? {
        let now = session?.liveTemperature.map { "now \(tempString($0))" }
        switch (nightTemp != nil, now) {
        case (true, let now?):  return "overnight · \(now)"
        case (true, nil):       return "overnight"
        case (false, let now?): return now
        case (false, nil):      return nil
        }
    }

    /// Average skin temp (°C) over the most recent NIGHT window, or nil if that window has
    /// no temperature samples (then the headline shows "—", never the noisy daytime value).
    /// Window: the latest stored sleep summary's span (night..night+inBed) when available,
    /// else local 00:00–06:00 of the most recent date that has temperature samples.
    private var nightTemp: Double? {
        guard let window = nightWindow else { return nil }
        // Filter the already-loaded @Query array in memory — no synchronous fetch in `body`
        // (that hazard once caused a black-screen launch). #14
        let tempKind = MetricKind.temperature.rawValue
        let vals = samples.lazy
            .filter { $0.kindRaw == tempKind && $0.value > 0
                      && $0.start >= window.start && $0.start <= window.end }
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
    /// "live" while connected; else the relative time of today's stored count (nil if the
    /// only stored count is from a prior day — `effectiveSteps` shows "—" then).
    private var stepsTime: String? {
        if session?.steps != nil { return "live" }
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
        String(format: "%.1f °C  (%.1f °F)", celsius, celsius * 9 / 5 + 32)
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
}
