import Foundation
import OpenCircuitKit

// MARK: - Activity sleep blocks (decision 73, #278)

/// Decision 73: the strap writes one `0x48` session record per night and leaves a later sleep of that
/// night only in its per-minute activity data (`0x01` minutes of kind `0x78`, ZEPP_PROTOCOL.md §6.5,
/// 🟡 one night). These turn those minutes into sleeps a session's night can join. A block is a night's
/// part only when it joins a night built from a `0x48` session (73c); one that stands alone is handed
/// back (`ActivityJoin.aloneNights`) for the store to judge as a nap (decision 76, #327).
extension HelioSleepSelection {

    /// Decision 73a: non-sleep minutes inside a run, this many or fewer, are an awake gap of the block;
    /// more end it.
    public static let activityBlockMaxGapMinutes = 5

    /// Decision 73d: a block whose last sleep minute is less than this before the newest activity
    /// minute of the sync may still be going on, so it is not used until a later sync.
    public static let activityBlockSettleTime: TimeInterval = 20 * 60

    /// Decision 73b: a block's sleep minutes are generic sleep, the stage `stage(for:)` gives a stage
    /// byte it doesn't name (the byte itself plays no part).
    public static let activityBlockStage = stage(for: .other(0))

    /// Decision 73a/73b: the activity sleep blocks in one sync's activity `minutes`, oldest first, each as
    /// a strap sleep `Night`.
    ///
    /// A block is a maximal run of kind-sleep minutes outside every staged session's in-bed span
    /// (`sessions`, each session's own night from `night(from:now:)`); a run crosses no in-bed span.
    /// Up to `activityBlockMaxGapMinutes` non-sleep (or missing) minutes inside a run are an awake gap and
    /// stay a gap. A run shorter than `minNapLength` (first sleep minute … last + 1 min) is no block, and
    /// neither is one still in progress (73d), longer than `maxNightLength`, or ending more than an hour
    /// past `now` (as `night(from:now:)`).
    ///
    /// Each block has one `.inBed` segment over the block, then its sleep minutes as stage segments
    /// (consecutive minutes merged) with `activityBlockStage`, no strap score, and the recorded zone of
    /// the staged session nearest to it (the one it can join; nil without one). Measured data from the
    /// strap: no minute is filled in.
    public static func activityBlocks(from minutes: [ZeppActivityMinute], sessions: [Night], now: Date) -> [Night] {
        guard let newest = minutes.map(\.time).max() else { return [] }
        let minute: TimeInterval = 60
        let runs = sleepRuns(in: minutes, outside: sessions.flatMap(\.inBedSpans))
        return runs.compactMap { run -> Night? in
            guard let first = run.first, let last = run.last else { return nil }
            let window = DateInterval(start: first, end: last.addingTimeInterval(minute))
            guard window.duration >= minNapLength, window.duration <= maxNightLength,
                  newest.timeIntervalSince(last) >= activityBlockSettleTime,
                  window.end <= now.addingTimeInterval(3600) else { return nil }
            var stages: [SleepSegment] = []
            for t in run {
                if let previous = stages.last, previous.end == t {
                    stages[stages.count - 1] = SleepSegment(start: previous.start, end: t.addingTimeInterval(minute), stage: previous.stage)
                } else {
                    stages.append(SleepSegment(start: t, end: t.addingTimeInterval(minute), stage: activityBlockStage))
                }
            }
            let zone = sessions.min { gap($0.window, window) < gap($1.window, window) }?.recordedTimeZone
            return Night(segments: [SleepSegment(start: window.start, end: window.end, stage: .inBed)] + stages,
                         window: window, strapScore: nil, recordedTimeZone: zone)
        }
    }

    /// The kind-sleep minutes of `minutes` outside every span of `spans`, as runs, oldest first: each
    /// run its minutes' times in order. Up to `activityBlockMaxGapMinutes` non-sleep (or missing)
    /// minutes inside a run are an awake gap; more end it, and so does crossing a span. The one
    /// run-forming rule of `activityBlocks` (73a) and the nap hold (76j), so the two agree to the minute.
    static func sleepRuns(in minutes: [ZeppActivityMinute], outside spans: [DateInterval] = []) -> [[Date]] {
        let minute: TimeInterval = 60
        func inBed(_ t: Date) -> Bool { spans.contains { $0.start <= t && t < $0.end } }
        let sleepTimes = Set(minutes.filter { $0.kind == ZeppActivityMinute.kindSleep }.map(\.time))
            .filter { !inBed($0) }
            .sorted()
        var runs: [[Date]] = []
        for t in sleepTimes {
            if let previous = runs.last?.last,
               t.timeIntervalSince(previous) <= TimeInterval(activityBlockMaxGapMinutes + 1) * minute,
               !spans.contains(where: { $0.start < t && previous.addingTimeInterval(minute) < $0.end }) {
                runs[runs.count - 1].append(t)
            } else {
                runs.append([t])
            }
        }
        return runs
    }

    /// Decision 76j (review-327b B2, superseding the hold rules of 76h/76i): whether `nap`, a nap
    /// candidate that holds an activity block, is held (not settled yet, judged again on a later sync)
    /// by the sleep that follows it in `minutes` (one sync's fetched activity minutes).
    ///
    /// The sleep that follows is a CHAIN, built the way `stitch` builds a night: the kind-sleep runs
    /// (`sleepRuns`, every fetched sleep minute from the nap's end on) that start within `napGap` after
    /// the nap's end, then each next run that starts within `napGap` of the chain's end so far. The nap
    /// is held while that chain may still become a night it lies within 60 min of: its last run may
    /// still be going on (its last sleep minute less than `activityBlockSettleTime` before the newest
    /// minute, 73d), OR the chain ended less than `napGap` before the newest minute (a next run could
    /// still join it). The night's own minutes and its `0x48` record may still be on their way (the
    /// strap lets the phone read a night in progress, and 73d keeps an unfinished run out of the
    /// blocks), so nothing else anchors the nap to it (76e). A nap with no run starting within
    /// `napGap` after it is never held. A chain over and older than `napGap` no longer holds: a run of
    /// 20 min or more in it is a block the stitch and nap rules judge, and a lone blip lets the nap go.
    /// Nothing is lost by holding: the activity re-fetch starts at the last session night's end at the
    /// latest, so the sync that delivers the night's record still sees the nap's minutes and judges it.
    /// Judged on the nap's end, so the blocks a nap holds never hold it.
    public static func sleepFollowsWithinNapGap(_ nap: DateInterval, in minutes: [ZeppActivityMinute]) -> Bool {
        guard let newest = minutes.map(\.time).max() else { return false }
        let runs = sleepRuns(in: minutes.filter { $0.time >= nap.end })
        var chainEnd = nap.end
        var lastRunEnd: Date?
        for run in runs {
            guard let first = run.first, let last = run.last, first.timeIntervalSince(chainEnd) <= napGap else { break }
            lastRunEnd = last
            chainEnd = last.addingTimeInterval(60)
        }
        guard let lastSleepMinute = lastRunEnd else { return false }
        let mayGoOn = newest.timeIntervalSince(lastSleepMinute) < activityBlockSettleTime
        let mayBeJoined = newest.timeIntervalSince(chainEnd) < napGap
        return mayGoOn || mayBeJoined
    }

    /// What `nights(sessions:activityBlocks:)` made of a sync's sleeps.
    public struct ActivityJoin: Equatable {
        /// The nights, oldest first: `stitch` over the sessions and the blocks, keeping only the nights
        /// that hold a session.
        public var nights: [Night]
        /// The blocks that joined a session's night (73c).
        public var joinedBlocks: Int
        /// The blocks that would stand alone, used in no night (73c).
        public var aloneBlocks: Int
        /// Decision 76a: those `aloneBlocks` blocks themselves, oldest first, as `activityBlocks` built
        /// them, for the store to judge as naps (`naps(from:mainSleeps:now:)`). No night holds one.
        public var aloneNights: [Night]

        public init(nights: [Night], joinedBlocks: Int, aloneBlocks: Int, aloneNights: [Night] = []) {
            self.nights = nights
            self.joinedBlocks = joinedBlocks
            self.aloneBlocks = aloneBlocks
            self.aloneNights = aloneNights
        }
    }

    /// Decision 73c: the nights of a sync's (owned) session sleeps and (owned) activity blocks. They are
    /// stitched together by the one rule (`stitch`: 28f's 60 minutes, 71b's overnight sleeps of one
    /// night key), and a night is kept only when it holds a session; a block that stands alone, or with
    /// other blocks only, is in no night: it is counted and handed back in `aloneNights` (decision 76a).
    /// Without blocks this is `stitch(sessions)`, unchanged.
    ///
    /// Decision 73f/73i: no lead-in, and nothing between fragments. A block is used only when it starts
    /// at or after the in-bed end of the LAST session of the night it joins; any other block is taken out
    /// and the rest is stitched again, until every block left qualifies. That is where the next sync's
    /// activity re-fetch starts (the temperature watermark, held at the session nights' end), so every
    /// block that is ever written is fetched again by every later sync and no extension's union delete
    /// can remove it. A block before or between a night's records would not be fetched again.
    ///
    /// Decision 73g: a block never costs a night. A night holding blocks that is no overnight sleep
    /// (`overnightVerdict`, 28c/28d) or is longer than `maxNightLength`, while the stitch of its sessions
    /// alone has an overnight sleep, is replaced by that stitch, and its blocks are counted alone. So the
    /// nights kept with blocks cover every night kept without them, each at least as wide.
    public static func nights(sessions: [Night], activityBlocks blocks: [Night]) -> ActivityJoin {
        guard !blocks.isEmpty else { return ActivityJoin(nights: stitch(sessions), joinedBlocks: 0, aloneBlocks: 0) }
        func holds(_ night: Night, _ sleep: Night) -> Bool {
            let start = stageSpan(of: sleep).start
            return night.window.start <= start && start < night.window.end
        }
        func withSession(_ nights: [Night]) -> [Night] {
            nights.filter { night in sessions.contains { holds(night, $0) } }
        }
        // 73f/73i: drop every block that doesn't start after its night's last session, then stitch again.
        var used = blocks
        var kept = withSession(stitch(sessions + used))
        while true {
            let misplaced = used.filter { block in
                guard let night = kept.first(where: { holds($0, block) }) else { return false }
                guard let lastEnd = sessions.filter({ holds(night, $0) }).map(\.window.end).max() else { return true }
                return block.window.start < lastEnd
            }
            guard !misplaced.isEmpty else { break }
            used.removeAll { block in misplaced.contains(block) }
            kept = withSession(stitch(sessions + used))
        }
        // 73g: a night its blocks would cost goes back to its sessions' own stitch.
        var joined: [Night] = []
        kept = kept.flatMap { night -> [Night] in
            let held = used.filter { holds(night, $0) }
            guard !held.isEmpty, !isOvernightSleep(night) || night.window.duration > maxNightLength else {
                joined += held
                return [night]
            }
            let alone = stitch(sessions.filter { holds(night, $0) })
            guard alone.contains(where: isOvernightSleep) else {
                joined += held
                return [night]
            }
            return alone
        }
        // 76a: every block no kept night holds, in the order `activityBlocks` gave them.
        let aloneNights = blocks.filter { block in !joined.contains(block) }
        return ActivityJoin(nights: kept, joinedBlocks: joined.count, aloneBlocks: blocks.count - joined.count,
                            aloneNights: aloneNights)
    }
}
