// The Today synthesis line (#216): today's date and one plain-language sentence at the top of the
// Today tab. The sentence is `TodaySynthesis.sentence` (OpenCircuitKit, unit-tested); this file
// only gathers its inputs from what the tab already holds and draws it.
//
// With Apple Intelligence on (iOS 26+), the template sentence is shown first and then replaced by a
// brief written by the ON-DEVICE model from the same input (`TodaySynthesis.briefFacts`), once the
// reply passes `TodaySynthesis.vetBrief`. Unavailable, slow, refused or rejected: the template stays.
// The last accepted brief is kept in UserDefaults with the prompt it answered, so reopening the app
// shows it at once while the input is unchanged.

import SwiftUI
import OpenCircuitKit

/// What the readiness card is showing, handed up so the synthesis line agrees with it.
struct ReadinessReport: Equatable {
    var readiness: TodaySynthesis.Readiness
    /// Last night's asleep minutes, when a night that ended today is stored.
    var lastNightAsleepMin: Int?
}

extension TodaySynthesis {
    /// Assemble the synthesis input from the Today tab's state.
    ///
    /// - `trends`: the shared two-week load (tiles are built from the same data).
    /// - `readiness`: what the readiness card reported; nil until it has.
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
                     newestDataAt: newest, now: now)
    }
}

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

struct TodaySynthesisHeader: View {
    let sentence: String
    /// The facts for the on-device brief; nil keeps the template (missing data, still loading).
    var briefFacts: SleepRecap.Facts? = nil
    var date: Date = Date()

    @State private var brief: TodayBrief? = TodayBriefCache.load()

    /// The brief only while it answers the CURRENT facts: a new sync or score shows the template
    /// until the brief for the new numbers is ready, never a stale one.
    private var currentBrief: String? {
        guard let brief, let briefFacts, brief.prompt == briefFacts.prompt, SleepRecapModel.isAvailable else { return nil }
        return brief.text
    }
    private var shown: String { currentBrief ?? sentence }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                KeylineGlyph(.sparkles, size: 18, relativeTo: .title3)
                    .foregroundStyle(Theme.accent)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown)
                        .font(.system(.title3, design: .rounded).weight(.medium))
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today, \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))). \(shown)")
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
