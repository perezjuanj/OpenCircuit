import SwiftUI
import SwiftData
import OpenRingKit

/// Dedicated, always-visible Sleep section (its own card, sits below Vitals).
///
/// The whole point of this view is PERSISTENCE: the most recent night's sleep stays on screen
/// all day — across reconnects, foreground auto-refreshes, and manual "Sync from ring" taps —
/// until a *newer* night replaces it. Earlier, sleep was only drawn from the live session's
/// `stagedSegments` (and the sync card's just-synced batch), so a daytime sync that returned no
/// new history cleared those and the morning's sleep vanished. Here the source of truth is the
/// persisted `StoredSleepSummary` rollup (upserted by night in `LocalStore.saveSleepSummary`,
/// untouched by sample-retention pruning), so it survives offline and across launches.
///
/// A just-finished sync is still reflected instantly: `liveSegments` (this connection's freshly
/// staged night) is preferred over the store when present, mirroring the #67 rationale for the
/// vitals rows. Once the link drops, `liveSegments` is empty and the @Query store fallback
/// carries the same night forward.
///
/// Stages (Deep/Light/REM/Awake) are an on-device ESTIMATE — the ring doesn't transmit a
/// hypnogram (PROTOCOL.md §5.3) — so the card labels them "est.".
struct SleepCardView: View {
    @Environment(\.modelContext) private var modelContext
    /// Temperature display unit (#83). Syncs with the Units section in UserProfileSettingsView.
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue
    /// Trailing persisted nights (latest first) — the offline source of truth. The window is
    /// wider than 1 so the rolling skin-temp baseline + the offset mini-chart (#69) have history;
    /// `latest` (= `storedSleep.first`) still drives the headline night.
    @Query private var storedSleep: [StoredSleepSummary]
    /// Today's auto-detected naps (#76), latest first.
    @Query private var todayNaps: [StoredNap]
    /// Freshly staged segments from the just-finished sync (empty when none / after disconnect).
    /// Preferred over the store so a completed sync updates the card immediately.
    var liveSegments: [SleepSegment]
    /// Sleep-vitals samples (HR / HRV / SpO₂) over the last few days — narrowed in memory to the
    /// resolved night window for the "overnight average" row under the stage breakdown. Bounded
    /// (value-positive + windowed) so it never scans all history (#32), mirroring
    /// `VitalsTableView.recentTemp`. A night older than this window keeps its totals but omits the
    /// averages (its raw samples have aged out of the query window).
    @Query private var recentVitals: [StoredSample]
    /// Days of HR/HRV/SpO₂ history scanned before the precise night window is applied in memory.
    private static let vitalsWindowDays: TimeInterval = 3

    /// Trailing nights queried for the baseline + temp chart (#69). 35 ≥ the 30-night baseline.
    private static let historyNights = 35

    init(liveSegments: [SleepSegment] = []) {
        self.liveSegments = liveSegments
        var d = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        d.fetchLimit = Self.historyNights
        _storedSleep = Query(d)

        // Naps that started today (#76).
        let dayStart = Calendar.current.startOfDay(for: Date())
        _todayNaps = Query(FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.start >= dayStart },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))

        // Anchor the window to the start of the current hour so the descriptor stays stable across
        // rapid re-renders (re-fetching hourly or when data changes), not on every render.
        let hourStart = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let lookback = hourStart.addingTimeInterval(-Self.vitalsWindowDays * 86_400)
        let hr = MetricKind.heartRate.rawValue
        let hrv = MetricKind.hrvSDNN.rawValue
        let spo2 = MetricKind.spo2.rawValue
        _recentVitals = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                ($0.kindRaw == hr || $0.kindRaw == hrv || $0.kindRaw == spo2)
                    && $0.start > lookback && $0.value > 0
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]))
    }

    /// One night resolved for display, from either the live staging or the persisted rollup.
    private struct Night {
        let summary: SleepStaging.Summary
        let inBedStart: Date?
        let inBedEnd: Date?
        /// Reference time for the "last night / yesterday / date" label.
        let when: Date
        /// True when `when` is a real wake time. When false (a legacy rollup with no in-bed clock
        /// times, where `when` is only the start-of-day key) the label shows the date instead of a
        /// relative term, so a pre-midnight night isn't mislabeled "yesterday".
        let wakeKnown: Bool
    }

    /// Latest persisted night — the source of the detail metrics (#69/#70/#71). Aligns with the
    /// displayed `night`: a fresh sync upserts it before the card settles, and the store fallback
    /// already reads from it.
    private var latest: StoredSleepSummary? { storedSleep.first }

    /// The night to show: prefer this connection's freshly synced staging (instant), else the
    /// most recent persisted night (survives all day / offline). Only ever a real night (asleep > 0).
    /// The live `liveSegments` are already gated to overnight sleep by RingSession (review #1), so a
    /// daytime nap never reaches here as "last night".
    private var night: Night? {
        if !liveSegments.isEmpty {
            let s = SleepStaging.summary(liveSegments)
            if s.minutes.asleep > 0 {
                let start = liveSegments.map(\.start).min()
                let end = liveSegments.map(\.end).max()
                return Night(summary: s, inBedStart: start, inBedEnd: end,
                             when: end ?? start ?? Date(), wakeKnown: end != nil)
            }
        }
        if let s = storedSleep.first, s.asleepMin > 0 {
            let start = s.inBedStart > .distantPast ? s.inBedStart : nil
            let end = (s.inBedEnd > s.inBedStart) ? s.inBedEnd : nil
            return Night(summary: s.asSummary, inBedStart: start, inBedEnd: end,
                         when: end ?? start ?? s.night, wakeKnown: end != nil)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                Text("SLEEP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let night {
                    Text(Self.nightLabel(night.when, wakeKnown: night.wakeKnown))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let night {
                content(night)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func content(_ night: Night) -> some View {
        let s = night.summary
        let m = s.minutes
        // Headline: total time asleep + the composite Sleep Score badge (#70).
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(m.asleep / 60)h \(m.asleep % 60)m")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
            Text("asleep").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let score = latest?.sleepScore, score > 0 { scoreBadge(score) }
        }
        stageBar(m)
        stageLegend(m)
        // Overnight HR / HRV / SpO₂ averages for this night (moved out of the sync card, where
        // they read as a current "latest" reading). Computed over the night window from stored
        // samples, so they describe the same night the card is showing and persist with it.
        if let avg = overnightAverages(night) {
            overnightVitals(avg)
        }
        // Detail metrics (#69/#70/#71/#76), grouped so this builder stays under the ViewBuilder
        // child limit. All read from the latest persisted summary, so they survive offline.
        detailSection()
        // Footer: sleep window · efficiency · est. caveat.
        Text(footer(night).joined(separator: " · "))
            .font(.caption2).foregroundStyle(.tertiary)
    }

    /// The Wave-1 sleep-detail rows in one group: per-stage HR, overnight stress, skin-temp
    /// baseline, movement chart, naps, and the subjective rating.
    @ViewBuilder
    private func detailSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            perStageHR()       // #70 per-stage average HR
            stressRow()        // #71 overnight stress
            skinTempSection()  // #69 nightly skin-temp + baseline offset + mini chart
            movementSection()  // #70 2.5-min / 3-level movement chart
            napsRow()          // #76 daytime naps
            feelRating()       // #70 subjective rating
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sleep Score badge (#70)

    /// Tier color for a 0–100 composite Sleep Score (≥85 / 70–84 / <70).
    private func scoreColor(_ score: Int) -> Color {
        switch SleepScore.Tier.of(score) {
        case .excellent: return .green
        case .good: return .teal
        case .needsImprovement: return .orange
        }
    }

    private func scoreBadge(_ score: Int) -> some View {
        VStack(spacing: 0) {
            Text("\(score)")
                .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            Text("score").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(scoreColor(score).opacity(0.18)))
        .foregroundStyle(scoreColor(score))
    }

    // MARK: Per-stage HR (#70)

    @ViewBuilder
    private func perStageHR() -> some View {
        let stages: [(name: String, bpm: Int)] = [
            ("Deep", latest?.hrDeep ?? 0), ("Light", latest?.hrLight ?? 0),
            ("REM", latest?.hrRem ?? 0), ("Awake", latest?.hrAwake ?? 0),
        ].filter { $0.1 > 0 }
        if !stages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Avg HR by stage").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ForEach(stages, id: \.name) { stage in stat(stage.name, "\(stage.bpm)", "bpm") }
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Overnight stress (#71)

    @ViewBuilder
    private func stressRow() -> some View {
        if let score = latest?.stressScore, score > 0 {
            let band = SleepStress.Band.of(score)
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg").font(.caption2).foregroundStyle(stressColor(band))
                Text("Overnight stress").font(.caption2).foregroundStyle(.secondary)
                Text("\(score)").font(.caption.weight(.semibold)).monospacedDigit()
                Text(band.label).font(.caption2).foregroundStyle(stressColor(band))
                Text("· est.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }

    private func stressColor(_ band: SleepStress.Band) -> Color {
        switch band {
        case .relaxed: return .green
        case .normal: return .teal
        case .medium: return .orange
        case .high: return .red
        }
    }

    // MARK: Skin-temperature baseline + nightly deviation (#69)

    /// Build a `SkinTempBaseline.NightReport` for the latest night from the trailing stored nights.
    private var tempReport: SkinTempBaseline.NightReport? {
        guard let latest, latest.skinTempC > 0 else { return nil }
        let priorNights = storedSleep
            .filter { $0.skinTempC > 0 && $0.night != latest.night }
            .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
        return SkinTempBaseline.report(tonight: latest.skinTempC, priorNights: priorNights)
    }

    @ViewBuilder
    private func skinTempSection() -> some View {
        if let r = tempReport {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium").font(.caption2).foregroundStyle(.pink)
                    Text("Skin temp").font(.caption2).foregroundStyle(.secondary)
                    Text(skinTempString(r.nightlyC))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                    if let off = r.offsetC {
                        Text(String(format: "%+.1f°C vs baseline", off))
                            .font(.caption2).foregroundStyle(tempColor(r.band))
                    } else {
                        Text("baseline building").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                tempChart()
            }
            .padding(.top, 2)
        }
    }

    /// Format a Celsius skin-temp value in the user's chosen unit (#83).
    private func skinTempString(_ celsius: Double) -> String {
        let unit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
        return UnitsFormatter.temperature(celsius, unit: unit)
    }

    private func tempColor(_ band: SkinTempBaseline.DeviationBand?) -> Color {
        switch band {
        case .abnormalRise: return .red
        case .abnormalDrop: return .blue
        default: return .secondary
        }
    }

    /// Bar color for a nightly offset: green within ±1 °C, red/blue when abnormal.
    private func tempBarColor(_ off: Double) -> Color {
        let band = SkinTempBaseline.deviationBand(offset: off)
        return band == .normal ? .green : tempColor(band)
    }

    /// Compact baseline chart (#69): each recent night's offset from the rolling baseline as a
    /// bar above (warmer) / below (cooler) a center baseline line.
    @ViewBuilder
    private func tempChart() -> some View {
        let nights = storedSleep.filter { $0.skinTempC > 0 }
        if nights.count >= SkinTempBaseline.minBaselineNights,
           let baseline = SkinTempBaseline.baseline(
                priorNights: nights.map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }) {
            // Oldest→newest, last ~14 nights, as offsets from the baseline.
            let points = nights.sorted { $0.night < $1.night }.suffix(14).map { $0.skinTempC - baseline }
            let maxAbs = max(points.map { abs($0) }.max() ?? 0.5, 0.5)
            GeometryReader { geo in
                let halfH = geo.size.height / 2
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, off in
                        let frac = min(max(off / maxAbs, -1), 1)         // -1…1
                        let barH = max(abs(frac) * halfH, 1)
                        VStack(spacing: 0) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                if frac >= 0 { Rectangle().fill(tempBarColor(off)).frame(height: barH) }
                            }.frame(height: halfH)
                            ZStack(alignment: .top) {
                                Color.clear
                                if frac < 0 { Rectangle().fill(tempBarColor(off)).frame(height: barH) }
                            }.frame(height: halfH)
                        }
                    }
                }
                .overlay(alignment: .center) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1)
                }
            }
            .frame(height: 24)
        }
    }

    // MARK: Body-movement chart (#70)

    @ViewBuilder
    private func movementSection() -> some View {
        let levels = latest?.movementLevels ?? []
        if !levels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Movement").font(.caption2).foregroundStyle(.secondary)
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { _, lvl in
                            Rectangle().fill(movementColor(lvl))
                                .frame(width: max(geo.size.width / CGFloat(levels.count) - 1, 0.5))
                        }
                    }
                }
                .frame(height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(.top, 2)
        }
    }

    private func movementColor(_ level: Int) -> Color {
        switch level {
        case 2: return .orange       // active
        case 1: return .yellow       // light
        default: return Color.secondary.opacity(0.25)   // still
        }
    }

    // MARK: Naps (#76)

    @ViewBuilder
    private func napsRow() -> some View {
        if !todayNaps.isEmpty {
            let totalMin = todayNaps.reduce(0) { $0 + $1.durationMin }
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill").font(.caption2).foregroundStyle(.yellow)
                Text("Naps today").font(.caption2).foregroundStyle(.secondary)
                Text("\(todayNaps.count)").font(.caption.weight(.semibold)).monospacedDigit()
                Text("· \(totalMin)m total").font(.caption2).foregroundStyle(.secondary)
                Text("· est.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Subjective rating (#70)

    @ViewBuilder
    private func feelRating() -> some View {
        if let latest {
            VStack(alignment: .leading, spacing: 4) {
                Text("How did you sleep?").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(1...9, id: \.self) { n in
                        Circle()
                            .fill(n <= latest.feelScore ? Color.indigo : Color.secondary.opacity(0.18))
                            .frame(width: 16, height: 16)
                            .overlay(Text("\(n)").font(.system(size: 9))
                                .foregroundStyle(n <= latest.feelScore ? .white : .secondary))
                            .onTapGesture { setFeel(n, night: latest.night) }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func setFeel(_ score: Int, night: Date) {
        try? LocalStore(modelContext).setFeelScore(score, night: night)
    }

    /// Mean HR (bpm) / HRV (ms) / SpO₂ (%) over the night's in-bed window, from the bounded
    /// `recentVitals` query narrowed in memory. nil when the window is unknown (a legacy rollup
    /// with no clock times) or no samples fall inside it (e.g. a night older than the query
    /// window). SpO₂ is stored 0…1 and surfaced as a whole percent.
    private func overnightAverages(_ night: Night) -> (hr: Int?, hrv: Int?, spo2: Int?)? {
        guard let start = night.inBedStart, let end = night.inBedEnd, end > start else { return nil }
        // Shared overnight-mean helper — the SAME computation the Vitals HRV/RR rows use, so the
        // two surfaces can't disagree (HRV "86 in Vitals vs 64 in Sleep" was a point-vs-mean clash).
        let window = DateInterval(start: start, end: end)
        func mean(_ kind: MetricKind) -> Double? {
            let raw = kind.rawValue
            let points = recentVitals
                .filter { $0.kindRaw == raw }
                .map { OvernightAverages.Point(value: $0.value, start: $0.start) }
            return OvernightAverages.mean(points, window: window)
        }
        let hr = mean(.heartRate).map { Int($0.rounded()) }
        let hrv = mean(.hrvSDNN).map { Int($0.rounded()) }
        let spo2 = mean(.spo2).map { Int(($0 * 100).rounded()) }   // SpO₂ stored 0…1, surfaced as %
        return (hr == nil && hrv == nil && spo2 == nil) ? nil : (hr, hrv, spo2)
    }

    /// "Overnight average" mini-stat row (omits any metric with no samples that night).
    @ViewBuilder
    private func overnightVitals(_ avg: (hr: Int?, hrv: Int?, spo2: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Overnight average").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                if let hr = avg.hr { stat("HR", "\(hr)", "bpm") }
                if let hrv = avg.hrv { stat("HRV", "\(hrv)", "ms") }
                if let spo2 = avg.spo2 { stat("SpO₂", "\(spo2)", "%") }
            }
        }
        .padding(.top, 2)
    }

    /// Compact labeled stat for the overnight-average row.
    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Proportional Deep/Light/REM/Awake bar, driven by the night's stage minutes.
    private func stageBar(_ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)) -> some View {
        let total = Double(m.deep + m.light + m.rem + m.awake)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Self.stages, id: \.name) { stage in
                    let mins = stage.minutes(m)
                    Rectangle().fill(stage.color)
                        .frame(width: total > 0 ? geo.size.width * Double(mins) / total : 0)
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
    }

    /// Color key with per-stage minutes (omits stages with no time).
    private func stageLegend(_ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)) -> some View {
        HStack(spacing: 12) {
            ForEach(Self.stages, id: \.name) { stage in
                let mins = stage.minutes(m)
                if mins > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(stage.color).frame(width: 7, height: 7)
                        Text("\(stage.name) \(mins)m").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Footer parts: clock window (when known) + efficiency + the estimate caveat.
    private func footer(_ night: Night) -> [String] {
        var parts: [String] = []
        if let start = night.inBedStart, let end = night.inBedEnd {
            parts.append("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
        }
        parts.append("\(Int((night.summary.efficiency * 100).rounded()))% efficiency")
        parts.append("est.")
        return parts
    }

    /// No-sleep state, scoped to SLEEP only. It deliberately does NOT claim HRV / Resting HR /
    /// Respiratory Rate are unavailable: those are decoded independently and can already be present
    /// (e.g. a daytime HR measurement gives a Resting HR) while no stageable sleep block exists, so
    /// asserting otherwise here would contradict the populated vitals rows above. (Review #2, #58.)
    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz").font(.subheadline).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your sleep appears here after an overnight sync")
                    .font(.subheadline.weight(.medium))
                Text("Wear the ring to bed and connect in the morning. Once it syncs, last night's sleep stays here all day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Stage table

    private struct Stage {
        let name: String
        let color: Color
        let minutes: (_ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)) -> Int
    }
    /// Display order + colors (match the prior sync-card stage bar): Deep, Light, REM, Awake.
    private static let stages: [Stage] = [
        Stage(name: "Deep", color: .indigo, minutes: { $0.deep }),
        Stage(name: "Light", color: .teal, minutes: { $0.light }),
        Stage(name: "REM", color: .purple, minutes: { $0.rem }),
        Stage(name: "Awake", color: .orange, minutes: { $0.awake }),
    ]

    // MARK: Night label

    private static let nightDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    /// "last night" when the sleep ended today, "yesterday" when it ended yesterday, else the date —
    /// so a days-old persisted night isn't mistaken for this morning's. Falls back to the date when
    /// the wake time is unknown (a legacy rollup with only a start-of-day key), since the relative
    /// term can't be computed reliably from the start-of-day alone. (Review #3.)
    private static func nightLabel(_ when: Date, wakeKnown: Bool) -> String {
        guard wakeKnown else { return nightDate.string(from: when) }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: when),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<0: return nightDate.string(from: when)   // future (shouldn't happen) — show date
        case 0: return "last night"
        case 1: return "yesterday"
        default: return nightDate.string(from: when)
        }
    }
}
