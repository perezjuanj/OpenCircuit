// The Today synthesis line (#216): today's date at the top of the Today tab, and the inputs of the one
// plain-language sentence. The sentence is `TodaySynthesis.sentence` (OpenCircuitKit, unit-tested) and
// since decision 93 it sits inside Today's scores card, under the dials; this file only gathers its
// inputs from what the tab already holds, and draws the date.

import SwiftUI
import OpenCircuitKit

/// What Today's scores card is showing for Recovery, handed up so the synthesis line agrees with it.
struct ReadinessReport: Equatable {
    var readiness: TodaySynthesis.Readiness
    /// Last night's asleep minutes, when a night that ended today is stored.
    var lastNightAsleepMin: Int?
    /// Recovery counted vitals but no sleeping HRV: still low confidence (decision 95a).
    var withoutSleepingHRV = false
}

extension TodaySynthesis {
    /// Assemble the synthesis input from the Today tab's state.
    ///
    /// - `trends`: the shared two-week load (tiles are built from the same data).
    /// - `readiness`: what the scores card reported for Recovery; nil until it has.
    /// - `feverSuspected`: the Vitals Status card's own fever verdict; false until it has reported.
    ///   The only thing that lets this line pair skin temperature with resting HR as fever signs.
    /// - `lastSyncAt`: only used to tell "never had data" from "nothing in the last two weeks".
    static func input(trends: TrendsData, tiles: [TodayTile], readiness: ReadinessReport?,
                      feverSuspected: Bool = false, lastSyncAt: Date?, now: Date = Date()) -> Input {
        func direction(_ m: TodayTile.Metric) -> BaselineTrend.Direction? {
            guard let t = tiles.first(where: { $0.metric == m }), !t.isStale(now: now) else { return nil }
            return t.trend?.direction
        }
        // Usual sleep = the nights BEFORE the newest one, so last night isn't compared with itself, and
        // only the newest night's device's (decision 29; every night with an empty log).
        let scope = TodayTiles.DeviceScope.from(trends)
        let sleepPoints = trends.points.filter { ($0.sleepMinutes ?? 0) > 0 }
        let sameDevice = sleepPoints.last.map { newest in
            sleepPoints.filter { scope == nil || scope!.night($0.date) == scope!.night(newest.date) }
        } ?? []
        let nights = sameDevice.compactMap(\.sleepMinutes)
        let prior = nights.dropLast()
        let usualSleep = prior.isEmpty ? nil : Double(prior.reduce(0, +)) / Double(prior.count)
        // Nothing in the window but the app HAS synced before: the data is at least as old as the
        // window, which is exactly what the "more than two weeks old" wording says.
        let newest = trends.newestSampleAt
            ?? lastSyncAt.flatMap { _ in Calendar.current.date(byAdding: .day, value: -TrendsData.lookbackDays, to: now) }
        return Input(readiness: readiness?.readiness ?? .pending,
                     hrv: direction(.hrv), restingHR: direction(.restingHR), skinTemp: direction(.skinTemp),
                     feverSuspected: feverSuspected,
                     lastNightSleepMinutes: readiness?.lastNightAsleepMin, usualSleepMinutes: usualSleep,
                     newestDataAt: newest, now: now,
                     withoutSleepingHRV: readiness?.withoutSleepingHRV ?? false)
    }
}

/// Today's date above the scores card ("THURSDAY, NOVEMBER 26").
struct TodayDateRow: View {
    var date: Date = Date()

    var body: some View {
        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
            .font(.caption.weight(.semibold)).tracking(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityLabel("Today, \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
    }
}

// MARK: - On-device brief

// With Apple Intelligence on (iOS 26+), the scores card's fixed sentence is shown first and then
// replaced by a brief written by the ON-DEVICE model from the same input (`TodaySynthesis.briefFacts`),
// once the reply passes `TodaySynthesis.vetBrief`. Unavailable, slow, refused or rejected: the fixed
// sentence stays. The last accepted brief is kept in UserDefaults with the prompt it answered, so
// reopening the app shows it at once while the input is unchanged.

/// The Today brief's words. Tests pin them.
enum TodayBriefCopy {
    static let byline = "Written on this iPhone by Apple Intelligence"
}

/// The last accepted brief and the prompt it answered (one entry: only the current day matters).
enum TodayBriefCache {
    static let key = "todayBrief.cache.v1"

    static func load(_ defaults: UserDefaults = .standard) -> TodayBrief? {
        guard let d = defaults.dictionary(forKey: key) as? [String: String],
              let prompt = d["prompt"], let text = d["text"] else { return nil }
        return TodayBrief(prompt: prompt, text: text)
    }

    static func save(_ brief: TodayBrief, _ defaults: UserDefaults = .standard) {
        defaults.set(["prompt": brief.prompt, "text": brief.text], forKey: key)
    }
}

struct TodayBrief: Equatable {
    let prompt: String
    let text: String
}

/// The scores card's sentence: the fixed `sentence`, or the vetted on-device brief for `briefFacts`.
struct TodayBriefSentence: View {
    let sentence: String
    /// The facts for the on-device brief; nil keeps the fixed sentence (missing data, still loading).
    var briefFacts: SleepRecap.Facts? = nil

    @State private var brief: TodayBrief? = TodayBriefCache.load()

    /// The brief only while it answers the CURRENT facts: a new sync or score shows the fixed sentence
    /// until the brief for the new numbers is ready, never a stale one.
    private var currentBrief: String? {
        guard let brief, let briefFacts, brief.prompt == briefFacts.prompt, SleepRecapModel.isAvailable else { return nil }
        return brief.text
    }
    private var shown: String { currentBrief ?? sentence }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shown)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if currentBrief != nil {
                Text(TodayBriefCopy.byline)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: shown)
        .task(id: briefFacts?.prompt) { await refreshBrief() }
    }

    /// Writes the brief for the current facts, off the render path. Waits a moment first: readiness,
    /// tiles and the fever verdict report one after another on launch, and each changes the facts.
    private func refreshBrief() async {
        guard let facts = briefFacts, SleepRecapModel.isAvailable else { return }
        if brief?.prompt == facts.prompt { return }
        if let cached = TodayBriefCache.load(), cached.prompt == facts.prompt { brief = cached; return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        let text = await SleepRecapModel.write(prompt: facts.prompt, instructions: TodaySynthesis.briefInstructions,
                                               maxTokens: 100) {
            if case .success(let t) = TodaySynthesis.vetBrief($0, facts: facts) { return t }
            return nil
        }
        guard let text, !Task.isCancelled else { return }
        let new = TodayBrief(prompt: facts.prompt, text: text)
        brief = new
        TodayBriefCache.save(new)
    }
}
