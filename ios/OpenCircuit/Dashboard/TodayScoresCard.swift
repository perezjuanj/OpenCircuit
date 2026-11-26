// Today's scores card (#391, decision 93): Sleep, Recovery and Strain as three separate dials, pinned
// first under the date, then the synthesis sentence and an estimates footer that opens the sources.
//
// It replaces the Readiness card and the lone Strain tile. Every number has ONE source:
//   - Sleep is the stored score of the newest night, credited only when that night ended today
//     (`LastNight`, the same rule the Goals Sleep ring uses; the Sleep tab's badge reads the same
//     row through the same `LastNight.score`).
//   - Recovery is `WellnessBalance.recoveryScore` over that night's sleep score and overnight stress,
//     computed here synchronously and handed up (`ReadinessReport`, for the sentence) and down (the
//     Recovery detail), so the ring, the sentence and the detail can never disagree.
//   - Strain is `TrendsData.todayStrain`, the reading the Strain detail shows.
//
// A missing value is an empty ring and a reason, never a 0. Only "No night yet" may lead anywhere near
// a sync, and the ring captions stay neutral: the sentence carries that advice. Copy names no device.

import SwiftUI
import SwiftData
import OpenCircuitKit

// MARK: - Last night (the shared predicate)

/// What counts as "last night" for Today, and what score it shows. Shared by the scores card, the
/// Goals Sleep ring and the Sleep card's badge, so they can never disagree about either.
enum LastNight {
    /// The newest stored night counts for today only when it ended today (#147). A missing wake
    /// (`inBedEnd` not after `inBedStart`, a legacy rollup) falls back to the night key.
    static func isCredited(nightKey: Date, inBedStart: Date, inBedEnd: Date,
                           now: Date = Date(), calendar: Calendar = .current) -> Bool {
        MissedNight.endedToday(inBedEnd: inBedEnd > inBedStart ? inBedEnd : nil, nightKey: nightKey,
                               now: now, calendar: calendar)
    }

    static func isCredited(_ row: StoredSleepSummary, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        isCredited(nightKey: row.night, inBedStart: row.inBedStart, inBedEnd: row.inBedEnd,
                   now: now, calendar: calendar)
    }

    /// The night's sleep score, or nil when it has none: 0 is the app-wide "never computed" sentinel
    /// for this column (`TrendsEngine`'s filter, the backup restore).
    static func score(_ sleepScore: Int?) -> Int? {
        guard let sleepScore, sleepScore > 0 else { return nil }
        return sleepScore
    }
}

// MARK: - Model

/// The card's three scores, built by one pure function so a test can pin every state.
struct TodayScores: Equatable {

    /// The newest stored night, as plain values.
    struct Night: Equatable, Sendable {
        var nightKey: Date
        var inBedStart: Date
        var inBedEnd: Date
        /// 0 = never scored.
        var sleepScore: Int
        /// 0 = no overnight stress (no sleeping HRV).
        var stressScore: Int
        var asleepMin: Int

        init(nightKey: Date, inBedStart: Date, inBedEnd: Date, sleepScore: Int, stressScore: Int, asleepMin: Int) {
            self.nightKey = nightKey
            self.inBedStart = inBedStart
            self.inBedEnd = inBedEnd
            self.sleepScore = sleepScore
            self.stressScore = stressScore
            self.asleepMin = asleepMin
        }

        init(_ row: StoredSleepSummary) {
            self.init(nightKey: row.night, inBedStart: row.inBedStart, inBedEnd: row.inBedEnd,
                      sleepScore: row.sleepScore, stressScore: row.stressScore, asleepMin: row.asleepMin)
        }
    }

    enum Sleep: Equatable {
        case scored(score: Int, asleepMin: Int)
        /// No night that ended today is stored: a sync can fix this.
        case noNight
        /// Last night is stored without a score: a sync cannot fix this.
        case noScore
    }

    enum Recovery: Equatable {
        case scored(WellnessBalance.Result)
        case noNight
        case noScore

        var result: WellnessBalance.Result? {
            if case let .scored(r) = self { return r }
            return nil
        }
        /// Rests on last night's sleep alone (no sleeping HRV): the ring's track is dashed.
        var isLowConfidence: Bool { (result?.factors.count ?? 0) <= 1 && result != nil }
    }

    enum Strain: Equatable {
        /// Before the first trends load: a redacted placeholder.
        case loading
        case scored(DailyStrain.Reading)
        case noHeartRate
        /// Under the 10 minutes `Strain` needs; whole minutes so far.
        case needsMinutes(soFar: Int)
        case needsRestingHR
    }

    let sleep: Sleep
    let recovery: Recovery
    let strain: Strain
    /// What the sentence speaks about: the same Recovery the ring shows.
    let report: ReadinessReport

    static func build(night: Night?, strain reading: DailyStrain.Reading?, trendsLoaded: Bool,
                      now: Date = Date(), calendar: Calendar = .current) -> TodayScores {
        let credited = night.map {
            LastNight.isCredited(nightKey: $0.nightKey, inBedStart: $0.inBedStart, inBedEnd: $0.inBedEnd,
                                 now: now, calendar: calendar)
        } ?? false
        let asleep: Int? = credited ? night.flatMap { $0.asleepMin > 0 ? $0.asleepMin : nil } : nil

        let sleep: Sleep
        let recovery: Recovery
        let report: ReadinessReport
        if let night, credited {
            if let score = LastNight.score(night.sleepScore) {
                sleep = .scored(score: score, asleepMin: night.asleepMin)
                let r = WellnessBalance.recoveryScore(sleepScore: score,
                                                      overnightStress: night.stressScore > 0 ? night.stressScore : nil)
                // Never nil with a sleep score; the fallback only keeps the type honest.
                recovery = r.map(Recovery.scored) ?? .noScore
                report = ReadinessReport(readiness: r.map { .scored(score: $0.score, tier: $0.tier,
                                                                    factorCount: $0.factors.count) } ?? .noScore,
                                         lastNightAsleepMin: asleep)
            } else {
                sleep = .noScore
                recovery = .noScore
                report = ReadinessReport(readiness: .noScore, lastNightAsleepMin: asleep)
            }
        } else {
            sleep = .noNight
            recovery = .noNight
            report = ReadinessReport(readiness: .noNight, lastNightAsleepMin: nil)
        }

        return TodayScores(sleep: sleep, recovery: recovery,
                           strain: strainState(reading, trendsLoaded: trendsLoaded), report: report)
    }

    /// The same order of reasons as `StrainTileText.status`.
    static func strainState(_ reading: DailyStrain.Reading?, trendsLoaded: Bool) -> Strain {
        guard trendsLoaded else { return .loading }
        guard let reading, !reading.hasNoData else { return .noHeartRate }
        if reading.strain != nil { return .scored(reading) }
        if reading.coveredSeconds < DailyStrain.minCoveredSeconds {
            return .needsMinutes(soFar: reading.coveredSeconds / 60)
        }
        return .needsRestingHR
    }
}

// MARK: - Copy

/// Every word the card shows or speaks (SCOPE §4.3), kept out of the views so a test pins each one.
enum TodayScoresCopy {
    /// The ring's centre for a missing value: a dash, never a 0.
    static let missing = "—"

    static let sleepLabel = "SLEEP"
    static let recoveryLabel = "RECOVERY"
    static let strainLabel = "STRAIN"
    static let footer = "On-device estimates · not medical advice"
    static let footerAccessibility = "On-device estimates, not medical advice. Sources and methods"

    static let sleepHint = "Opens Sleep"
    static let recoveryHint = "Shows what went into recovery"
    static let strainHint = "Shows today's strain"

    static func tier(_ t: WellnessBalance.Tier) -> String {
        switch t {
        case .excellent:        return "Excellent"
        case .good:             return "Good"
        case .needsImprovement: return "Needs improvement"
        }
    }

    // Sleep
    static func sleepValue(_ s: TodayScores.Sleep) -> String {
        if case let .scored(score, _) = s { return "\(score)" }
        return missing
    }

    static func sleepStatus(_ s: TodayScores.Sleep) -> String {
        switch s {
        // A scored night always has time asleep; the fallback never prints "0m" for a missing one.
        case let .scored(_, asleep): return asleep > 0 ? StageDuration.label(minutes: asleep) : "Last night"
        case .noNight:               return "No night yet"
        case .noScore:               return "No score"
        }
    }

    static func sleepAccessibility(_ s: TodayScores.Sleep) -> String {
        switch s {
        case let .scored(score, asleep):
            return "Sleep score, \(score) out of 100"
                + (asleep > 0 ? ", \(StageDuration.spoken(minutes: asleep)) asleep" : "")
        case .noNight: return "Sleep score unavailable. Last night hasn't synced yet."
        case .noScore: return "Sleep score unavailable. Last night has no score."
        }
    }

    // Recovery
    static func recoveryValue(_ r: TodayScores.Recovery) -> String {
        r.result.map { "\($0.score)" } ?? missing
    }

    static func recoveryStatus(_ r: TodayScores.Recovery) -> String {
        switch r {
        case let .scored(result): return tier(result.tier)
        case .noNight:            return "No night yet"
        case .noScore:            return "No score"
        }
    }

    static func recoveryAccessibility(_ r: TodayScores.Recovery) -> String {
        switch r {
        case let .scored(result):
            return "Recovery, estimate, \(result.score) out of 100, \(tier(result.tier))"
                + (r.isLowConfidence ? ", based on last night's sleep alone" : "")
        case .noNight: return "Recovery unavailable. Last night hasn't synced yet."
        case .noScore: return "Recovery unavailable. Last night has no score."
        }
    }

    // Strain
    static func strainValue(_ s: TodayScores.Strain) -> String {
        if case let .scored(reading) = s, let v = StrainTileText.value(reading) { return v }
        return missing
    }

    static func strainStatus(_ s: TodayScores.Strain) -> String {
        switch s {
        case .loading:                return " "
        case let .scored(reading):    return reading.band.map { "\($0.label) · so far" } ?? " "
        case .noHeartRate:            return "No HR yet"
        case let .needsMinutes(soFar): return "\(soFar) of \(DailyStrain.minCoveredSeconds / 60) min"
        case .needsRestingHR:         return "Needs resting HR"
        }
    }

    static func strainAccessibility(_ s: TodayScores.Strain) -> String {
        switch s {
        case .loading:             return "Strain, loading"
        case let .scored(reading): return StrainTileText.accessibilityLabel(reading)
        case .noHeartRate:         return "Strain unavailable. No heart rate yet today."
        case let .needsMinutes(soFar):
            return "Strain needs \(DailyStrain.minCoveredSeconds / 60) minutes of heart rate, \(soFar) so far."
        case .needsRestingHR:      return "Strain needs a resting heart rate first."
        }
    }

    // Recovery detail
    static let detailBasis = "From last night's sleep"
    static let detailSleepFactor = "Sleep score"
    static let detailHRVFactor = "Sleeping HRV vs your usual"
    static let detailSleepAlone = "Based on last night's sleep alone: no sleeping HRV was recorded."
    static let detailMethod = "An OpenCircuit estimate from last night's sleep score and your sleeping HRV "
        + "against your usual. Not your device app's own score, and not medical advice."

    /// "Sleep score counts 62%, sleeping HRV 38%." from the Kit's weights, never typed.
    static func detailShares(_ shares: WellnessBalance.RecoveryShares = WellnessBalance.recoveryShares) -> String {
        "Sleep score counts \(shares.sleep)%, sleeping HRV \(shares.hrv)%."
    }

    /// The Recovery detail's hero for VoiceOver: the dial's label, then the empty state in full.
    static func detailAccessibility(_ r: TodayScores.Recovery) -> String {
        [recoveryAccessibility(r), detailGap(r)].compactMap { $0 }.joined(separator: " ")
    }

    /// The detail's empty state, in full. Only the no-night case advises a sync.
    static func detailGap(_ r: TodayScores.Recovery) -> String? {
        switch r {
        case .scored:  return nil
        case .noNight: return "Sync last night's sleep to see today's recovery."
        case .noScore: return "Last night doesn't have a sleep score, so there's no recovery to show today."
        }
    }
}

// MARK: - Source

/// Builds `TodayScores` from the newest stored night and today's strain. Follows the calendar day
/// (#297), so "last night" is re-judged after midnight. Its content gets the one model.
struct TodayScoresSource<Content: View>: View {
    let strain: DailyStrain.Reading?
    let trendsLoaded: Bool
    @ViewBuilder let content: (TodayScores) -> Content

    var body: some View {
        CurrentDayView("todayScores") { _ in
            TodayScoresQuery(strain: strain, trendsLoaded: trendsLoaded, content: content)
        }
    }
}

private struct TodayScoresQuery<Content: View>: View {
    let strain: DailyStrain.Reading?
    let trendsLoaded: Bool
    let content: (TodayScores) -> Content

    @Query private var latestSleep: [StoredSleepSummary]
    @Environment(\.dayClock) private var clock

    init(strain: DailyStrain.Reading?, trendsLoaded: Bool, content: @escaping (TodayScores) -> Content) {
        self.strain = strain
        self.trendsLoaded = trendsLoaded
        self.content = content
        var d = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        d.fetchLimit = 1
        _latestSleep = Query(d)
    }

    var body: some View {
        content(TodayScores.build(night: latestSleep.first.map(TodayScores.Night.init), strain: strain,
                                  trendsLoaded: trendsLoaded, now: clock.now(), calendar: clock.calendar()))
    }
}

// MARK: - Card

struct TodayScoresCard: View {
    let scores: TodayScores
    let sentence: String
    var onSleep: () -> Void = {}
    var onRecovery: () -> Void = {}
    var onStrain: () -> Void = {}

    @State private var showSources = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            layout {
                column(stacked: stacked, label: TodayScoresCopy.sleepLabel,
                       value: TodayScoresCopy.sleepValue(scores.sleep),
                       status: TodayScoresCopy.sleepStatus(scores.sleep),
                       progress: sleepProgress, tint: Theme.sleep, lowConfidence: false,
                       accessibility: TodayScoresCopy.sleepAccessibility(scores.sleep),
                       hint: TodayScoresCopy.sleepHint, action: onSleep)
                column(stacked: stacked, label: TodayScoresCopy.recoveryLabel,
                       value: TodayScoresCopy.recoveryValue(scores.recovery),
                       status: TodayScoresCopy.recoveryStatus(scores.recovery),
                       progress: scores.recovery.result.map { Double($0.score) / 100 },
                       tint: scores.recovery.result?.tier.ringColor ?? Theme.readiness,
                       lowConfidence: scores.recovery.isLowConfidence,
                       accessibility: TodayScoresCopy.recoveryAccessibility(scores.recovery),
                       hint: TodayScoresCopy.recoveryHint, action: onRecovery)
                column(stacked: stacked, label: TodayScoresCopy.strainLabel,
                       value: TodayScoresCopy.strainValue(scores.strain),
                       status: TodayScoresCopy.strainStatus(scores.strain),
                       progress: strainProgress, tint: Theme.energy, lowConfidence: false,
                       accessibility: TodayScoresCopy.strainAccessibility(scores.strain),
                       hint: TodayScoresCopy.strainHint, action: onStrain)
                    .redacted(reason: scores.strain == .loading ? .placeholder : [])
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                KeylineGlyph(.sparkles, size: 16, relativeTo: .callout)
                    .foregroundStyle(Theme.accent)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .accessibilityHidden(true)
                Text(sentence)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.default, value: sentence)
            }

            Button { showSources = true } label: {
                HStack(spacing: 6) {
                    Text(TodayScoresCopy.footer)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    KeylineGlyph(.info, size: 14, relativeTo: .caption2).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TodayScoresCopy.footerAccessibility)
            .accessibilityHint("Opens how these numbers are worked out")
            .accessibilityAddTraits(.isButton)
        }
        .ocCardSurface()
        .sheet(isPresented: $showSources) {
            NavigationStack {
                HealthSourcesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showSources = false }
                        }
                    }
            }
        }
    }

    private var sleepProgress: Double? {
        if case let .scored(score, _) = scores.sleep { return Double(score) / 100 }
        return nil
    }

    private var strainProgress: Double? {
        if case let .scored(reading) = scores.strain { return reading.gaugeFraction }
        return nil
    }

    private func column(stacked: Bool, label: String, value: String, status: String,
                        progress: Double?, tint: Color, lowConfidence: Bool,
                        accessibility: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ScoreDial(stacked: stacked, label: label, value: value, status: status,
                      progress: progress, tint: tint, lowConfidence: lowConfidence)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }
}

/// One score: a dial with its value inside, then the label and a status line. Side by side at
/// accessibility text sizes (a 64 pt dial with the words beside it), else centred in a column.
private struct ScoreDial: View {
    let stacked: Bool
    let label: String
    let value: String
    let status: String
    let progress: Double?
    let tint: Color
    let lowConfidence: Bool

    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 92

    private var isMissing: Bool { value == TodayScoresCopy.missing }

    var body: some View {
        if stacked {
            HStack(spacing: 14) {
                dial(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    labelText
                    Text(status).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 0) {
                dial(size: ringSize)
                labelText.padding(.top, 9)
                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.caption2.weight(.semibold)).tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func dial(size: CGFloat) -> some View {
        ReadinessRing(progress: progress, tint: tint, lowConfidence: lowConfidence,
                      lineWidth: size < 80 ? 7 : 9) {
            Text(value)
                .font(.system(size: size * 0.29, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
        }
        .modifier(DialFrame(size: size, fixed: stacked))
    }
}

/// Side by side the dial is a fixed square, so a long status line beside it can never squeeze it (and
/// truncate its value). In a column it may shrink to the column's width, as a square.
private struct DialFrame: ViewModifier {
    let size: CGFloat
    let fixed: Bool

    func body(content: Content) -> some View {
        if fixed {
            content.frame(width: size, height: size).fixedSize()
        } else {
            content.frame(maxWidth: size, maxHeight: size).aspectRatio(1, contentMode: .fit)
        }
    }
}
