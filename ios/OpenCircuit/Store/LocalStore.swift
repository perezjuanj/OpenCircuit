import Foundation
import SwiftData
import OpenCircuitKit

// SwiftData persistence: raw decoded samples + the per-metric sync cursor. The
// cursor mirrors OpenCircuitKit.SyncCursor (the testable source of truth); these
// @Model types are just its on-disk form.

@Model
final class StoredSample {
    var kindRaw: String
    var start: Date
    var end: Date
    var value: Double
    var rawValue: Double?
    // Default required so SwiftData can auto-migrate stores written before these
    // cumulative-counter columns existed (#21) — a new non-optional attribute with no
    // default fails lightweight migration and traps at ModelContainer init on launch.
    var isDelta: Bool = false
    var dailyTotal: Double?

    init(
        kindRaw: String,
        start: Date,
        end: Date,
        value: Double,
        rawValue: Double? = nil,
        isDelta: Bool = false,
        dailyTotal: Double? = nil
    ) {
        self.kindRaw = kindRaw
        self.start = start
        self.end = end
        self.value = value
        self.rawValue = rawValue
        self.isDelta = isDelta
        self.dailyTotal = dailyTotal
    }

    convenience init(
        _ s: QuantitySample,
        rawValue: Double? = nil,
        isDelta: Bool = false,
        dailyTotal: Double? = nil
    ) {
        self.init(
            kindRaw: s.kind.rawValue,
            start: s.start,
            end: s.end,
            value: s.value,
            rawValue: rawValue,
            isDelta: isDelta,
            dailyTotal: dailyTotal
        )
    }

    var sample: QuantitySample? {
        guard let kind = MetricKind(rawValue: kindRaw) else { return nil }
        return QuantitySample(kind: kind, start: start, end: end, value: value)
    }
}

@Model
final class StoredCursor {
    @Attribute(.unique) var kindRaw: String
    var last: Date

    init(kindRaw: String, last: Date) {
        self.kindRaw = kindRaw
        self.last = last
    }
}

/// Persisted nightly sleep summary (total asleep + estimated stage breakdown) so the
/// dashboard shows the last night OFFLINE, after the ring disconnects. Keyed by `night` — the start
/// of the day the sleep block ENDS on (`SleepNightKey`; it used to be the day it STARTED, which
/// aliased two consecutive nights onto one key and silently ate one of them) — and UPSERTED so
/// re-syncing the same night replaces rather than duplicates. The night's IDENTITY is its in-bed
/// SPAN, though, not this key: `saveSleepSummary` resolves the row by overlap first, because a night
/// staged in pieces can produce different keys as it grows past midnight. Stage minutes are an
/// on-device ESTIMATE — the ring doesn't transmit stage labels (PROTOCOL.md §5.3).
///
/// Every non-optional attribute has a default so SwiftData lightweight migration can add
/// this table to stores written before it existed without trapping at launch (cf. #21).
@Model
final class StoredSleepSummary {
    @Attribute(.unique) var night: Date = Date.distantPast
    var asleepMin: Int = 0
    var deepMin: Int = 0
    var lightMin: Int = 0
    var remMin: Int = 0
    var awakeMin: Int = 0
    var efficiency: Double = 0
    /// IN-BED window clock times (first segment start … last segment end), NOT start-of-day — so a
    /// night-temp window aligns to real bedtime/get-up, not midnight. This is TIME IN BED: it
    /// includes the pre-sleep and post-wake awake-in-bed spans, so it is wider than the sleep window.
    var inBedStart: Date = Date.distantPast
    var inBedEnd: Date = Date.distantPast
    /// ACTUAL SLEEP window clock times: real onset (first asleep epoch) … final wake (last asleep
    /// epoch). Narrower than [inBedStart, inBedEnd] by the sleep latency + any lie-in. `distantPast`
    /// = not recorded (a legacy row written before these columns; the card falls back to the in-bed
    /// window). Defaulted so SwiftData lightweight migration adds them to older stores (cf. #21).
    var sleepOnset: Date = Date.distantPast
    var sleepWake: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast

    // MARK: Wave-1 sleep analytics (#69/#70/#71). Every column is DEFAULTED so SwiftData
    // lightweight migration can add it to stores written before it existed (cf. #21). A 0
    // sentinel means "not computed" for the optional metrics (skin temp / scores), since a
    // worn night's skin temp is always > 28 °C and the scores are 1…100.

    /// Nightly MEAN sleeping skin temperature (°C), 0 = none. Baseline/offset are derived at
    /// display time from the trailing nights' `skinTempC` (#69) — only the nightly value is stored.
    var skinTempC: Double = 0
    /// Composite 0–100 Sleep Score (#70), 0 = not computed.
    var sleepScore: Int = 0
    /// Overnight stress score 1–100 from sleep-window RMSSD (#71), 0 = not computed.
    var stressScore: Int = 0
    /// Subjective "how did you sleep?" rating 1–9 (#70), 0 = unrated. Set by the user; NEVER
    /// overwritten by a re-sync.
    var feelScore: Int = 0
    /// Per-stage average HR (bpm), 0 = none (#70).
    var hrDeep: Int = 0
    var hrLight: Int = 0
    var hrRem: Int = 0
    var hrAwake: Int = 0
    /// Per-epoch (2.5-min) movement levels 0/1/2 across the night (#70) — small enough to
    /// persist so the movement chart redraws offline.
    var movementLevels: [Int] = []

    /// The night's staged hypnogram, `SleepHypnogramCodec`-encoded. Empty = not recorded (every night
    /// staged before this column existed). Persisted because the stage MINUTES above are a rollup that
    /// cannot be un-summed: without the segments a session export can say "1 h 10 m deep" but never
    /// WHEN. DEFAULTED so SwiftData lightweight migration adds it to existing stores (cf. #21).
    /// Written ONLY in the same branch that writes the minutes (`saveSleepSummary` / `applySleepEdit`),
    /// so a night's segments and its minutes can never describe two different captures — and only when
    /// that caller actually STATED a timeline: `applySleepEdit`'s `hypnogram` is nil-defaulted so an
    /// omitted argument leaves a recorded timeline in place rather than silently erasing it.
    var hypnogramData: Data = Data()

    // MARK: OSA sleep-apnea SpO₂ (#91) — decoded locally from the dense `0x48` assessment burst.
    // Every column DEFAULTED for SwiftData lightweight migration (cf. #21). `osaValidWindows == 0`
    // = no assessment drained that night (the card row stays hidden). `osaAvgSpO2` is validated
    // (±1 % vs the RingConn app); `osaMinSpO2`/`osaTimeBelow90Sec`/`osaODI` are ESTIMATES — the UI
    // labels them EXPERIMENTAL. Set post-construction via `LocalStore.applyOSASummary` (the burst
    // finalizes ~5 s after the sleep drain), so they are NOT init parameters.
    var osaAvgSpO2: Double = 0
    var osaMinSpO2: Double = 0
    var osaTimeBelow90Sec: Double = 0
    var osaODI: Double = 0
    var osaValidWindows: Int = 0

    // MARK: Manual sleep-time edit overlay (#176) — RingConn parity (EditSleepStagePage /
    // SleepEditableTimeRange). DEFAULTED for SwiftData lightweight migration (cf. #21). `distantPast`
    // = not edited. When set, this night's display window + durations were recomputed for the user's
    // edited [editedInBedStart, editedInBedEnd] (within ±3 h of the recorded onset/wake), and a
    // re-sync must NOT overwrite them — the raw epoch archive still holds the original staging, so the
    // edit is a non-destructive overlay. Set via `LocalStore.applySleepEdit`.
    var editedInBedStart: Date = Date.distantPast
    var editedInBedEnd: Date = Date.distantPast
    /// Persisted (rather than inferred from the dates) so an unchanged Save can never accidentally
    /// turn a recorded night into a manual edit, and so lightweight migration has an explicit flag.
    var isManuallyEdited: Bool = false

    // MARK: Widened-recorded overlay for the EDIT CLAMP only. An edited night's re-syncs hit
    // `keptManualEdit` and are discarded, but the ±3 h edit clamp anchors on the RECORDED window —
    // freezing it with the minutes trapped a tester in a wrong wake she could never correct
    // (🟢 2026-08-16, see `SleepEdit.widenRecorded`). Fuller stagings widen THESE columns
    // (outward-only), and only `sleepEditClamp*` reads them. The original `inBedStart…sleepWake`
    // columns stay FROZEN on an edited row on purpose: `pendingSleepEditHealthWrites` /
    // `markSleepEditHealthCovered` / the edited-night reconcile treat them as "what the ordinary
    // flush wrote to Health", and a keptManualEdit drain writes NOTHING to Health — widening those
    // would overstate Health coverage and silently drop a user's extension append (review find).
    // DEFAULTED for SwiftData lightweight migration (cf. #21); `distantPast` = never widened.
    var widenedRecordedInBedStart: Date = Date.distantPast
    var widenedRecordedInBedEnd: Date = Date.distantPast
    var widenedRecordedOnset: Date = Date.distantPast
    var widenedRecordedWake: Date = Date.distantPast

    // MARK: Reversibility + provenance (measured-vs-asserted). DEFAULTED for SwiftData lightweight
    // migration (cf. #21) AND pinned behind SchemaV7 (cf. the build-44 wipe — a defaulted column is
    // necessary but NOT sufficient once a migration plan exists).

    /// THE RING-DERIVED HYPNOGRAM, written ONLY by the staging path and NEVER by the edit path.
    ///
    /// ⚠️ THE SINGLE MOST IMPORTANT COLUMN IN THIS BLOCK. `hypnogramData` is one column that
    /// `applySleepEdit` overwrites in place (`:1768`), so before this existed the moment a user
    /// edited a night the recording was gone forever, with no backup anywhere. 🟢 Device-proven on
    /// `R2_2026-08-17`: 102.5 minutes of 97.6 %-covered, stage-resolved sleep — 30 min of it deep —
    /// became unrecoverable the instant she corrected her wake time, and the card then displayed
    /// every one of those minutes as awake with no way back.
    ///
    /// Empty = no recording captured (a legacy row, or a night staged before this column existed).
    /// An empty value must NEVER be presented as "the ring recorded nothing".
    var recordedHypnogramData: Data = Data()

    /// Measured-versus-asserted split for this night, in SECONDS, so no consumer re-derives them and
    /// the export is auditable. `-1` = NOT COMPUTED, which is deliberately distinct from 0: a night
    /// with genuinely zero asserted time is a real and common answer, and conflating the two is how
    /// `efficiency == 0` became a silent sentinel at `:235`.
    var measuredAsleepSeconds: Double = -1
    var assertedAsleepSeconds: Double = -1
    /// Share of the in-bed window the ring recorded across, 0…1. `-1` = not computed.
    var coverageFraction: Double = -1
    /// Longest single unmeasured run inside the in-bed window, seconds. `-1` = not computed.
    var longestGapSeconds: Double = -1

    /// Sleep efficiency over COVERED GROUND ONLY — the honest ratio. `-1` = withheld or not
    /// computed; render it as "—", never as 0 and never as a number.
    ///
    /// ⚠️ THIS IS A SEPARATE COLUMN FOR ONE SPECIFIC REASON, AND IT MUST STAY ONE. `efficiency`
    /// above is load-bearing in an identity: `asSummary` (`:275`) recovers the in-bed span as
    /// `asleep / efficiency`, where `asleep` is the DISPLAY-basis stage total. Writing the
    /// measured-only ratio into `efficiency` therefore mixes bases and silently corrupts in-bed for
    /// every downstream reader — on `R2_2026-08-18` it would reconstruct 490 min of in-bed for a
    /// 439-minute night. `efficiency` stays display-basis; the honest number lives here.
    var measuredEfficiency: Double = -1

    /// WHICH BASIS THIS ROW'S MINUTES WERE COMPUTED ON. Empty = unknown (every row written before
    /// this column existed).
    ///
    /// Why a version stamp and not a boolean: `HeadacheEngine.swift:368` never recomputes a frozen
    /// day, so priors already on testers' phones hold asserted-INCLUSIVE `asleepMin` (403) and
    /// `efficiency` (0.918). Switching today's rows to a measured-only basis without a stamp would
    /// make `sleepDurationDeviation` compare a measured-only today against asserted-inclusive priors
    /// and produce a spurious z for one whole baseline window — a wave of false headache flags at
    /// exactly the moment we ship an honesty fix. With the stamp the builder can refuse to mix bases,
    /// and the transition surfaces as `.buildingBaseline(daysRemaining:)`, an existing honest verdict
    /// with existing UI (`HeadacheSignals.swift:433`).
    var sleepBasis: String = ""

    init(
        night: Date,
        asleepMin: Int = 0,
        deepMin: Int = 0,
        lightMin: Int = 0,
        remMin: Int = 0,
        awakeMin: Int = 0,
        efficiency: Double = 0,
        inBedStart: Date = Date.distantPast,
        inBedEnd: Date = Date.distantPast,
        sleepOnset: Date = Date.distantPast,
        sleepWake: Date = Date.distantPast,
        updatedAt: Date = Date(),
        skinTempC: Double = 0,
        sleepScore: Int = 0,
        stressScore: Int = 0,
        feelScore: Int = 0,
        hrDeep: Int = 0,
        hrLight: Int = 0,
        hrRem: Int = 0,
        hrAwake: Int = 0,
        movementLevels: [Int] = []
    ) {
        self.night = night
        self.asleepMin = asleepMin
        self.deepMin = deepMin
        self.lightMin = lightMin
        self.remMin = remMin
        self.awakeMin = awakeMin
        self.efficiency = efficiency
        self.inBedStart = inBedStart
        self.inBedEnd = inBedEnd
        self.sleepOnset = sleepOnset
        self.sleepWake = sleepWake
        self.updatedAt = updatedAt
        self.skinTempC = skinTempC
        self.sleepScore = sleepScore
        self.stressScore = stressScore
        self.feelScore = feelScore
        self.hrDeep = hrDeep
        self.hrLight = hrLight
        self.hrRem = hrRem
        self.hrAwake = hrAwake
        self.movementLevels = movementLevels
    }

    /// Rebuild a `SleepStaging.Summary` for the dashboard. `inBed` is recovered from the
    /// stored efficiency (asleep / efficiency) so the displayed % matches; the per-stage
    /// minutes round-trip exactly since they're already whole minutes.
    var asSummary: SleepStaging.Summary {
        let light = Double(lightMin) * 60
        let deep = Double(deepMin) * 60
        let rem = Double(remMin) * 60
        let awake = Double(awakeMin) * 60
        let asleep = light + deep + rem
        let inBed = efficiency > 0 ? asleep / efficiency : asleep + awake
        return SleepStaging.Summary(inBed: inBed, awake: awake, light: light, deep: deep, rem: rem)
    }

    var sleepEditRecordedInBedStart: Date {
        inBedStart
    }
    var sleepEditRecordedInBedEnd: Date {
        inBedEnd
    }
    var sleepEditRecordedOnset: Date {
        sleepOnset
    }
    var sleepEditRecordedWake: Date {
        sleepWake
    }

    /// The recorded window AS THE EDIT CLAMP should see it: the frozen recorded columns, widened
    /// outward by any fuller stagings a `keptManualEdit` drain recorded into the overlay columns.
    /// ONLY the edit sheet/validator anchors on this — Health bookkeeping keeps reading the frozen
    /// `sleepEditRecorded*` values (see the overlay columns' comment).
    var sleepEditClampWindow: SleepEdit.RecordedWindow {
        let recorded = SleepEdit.RecordedWindow(
            inBedStart: inBedStart, inBedEnd: inBedEnd,
            sleepOnset: sleepOnset, sleepWake: sleepWake)
        let widened = SleepEdit.RecordedWindow(
            inBedStart: widenedRecordedInBedStart, inBedEnd: widenedRecordedInBedEnd,
            sleepOnset: widenedRecordedOnset, sleepWake: widenedRecordedWake)
        return SleepEdit.widenRecorded(stored: recorded, incoming: widened) ?? recorded
    }

    var sleepEditCurrentInBedStart: Date {
        isManuallyEdited ? editedInBedStart : inBedStart
    }
    var sleepEditCurrentInBedEnd: Date {
        isManuallyEdited ? editedInBedEnd : inBedEnd
    }
    var sleepEditCurrentOnset: Date {
        guard isManuallyEdited else { return sleepOnset }
        if let onset = SleepEditOnsetOverlay.load(night: night) { return onset }
        // A night edited under the pre-3-anchor editor (or one whose overlay desynced) has no stored
        // onset: fall back to the RECORDED onset clamped into the edited window — never bedtime, which
        // would read as onset==bedtime / 100% efficiency.
        let recorded = sleepOnset > .distantPast ? sleepOnset : editedInBedStart
        return min(max(recorded, editedInBedStart), editedInBedEnd)
    }
    var sleepEditCurrentWake: Date {
        isManuallyEdited ? editedInBedEnd : sleepWake
    }
}

/// Move a night-scoped UserDefaults value from one night key to another. Used ONLY by the one-shot
/// night-key re-key migration (`LocalStore.rekeySleepNightsToWakeDay`): every overlay below is keyed
/// by `startOfDay(row.night)`, so moving a row's key without moving its overlays would strand the
/// user's edited onset, the Health sample UUIDs a later edit must delete, and the mirror signature.
///
/// STRICTLY NON-DESTRUCTIVE. An occupied destination returns `false` and leaves BOTH values where
/// they are — it must never keep the sitting tenant while dropping the value it was asked to move.
/// (The first version did exactly that: it wrote only when the destination was free but removed the
/// source unconditionally, so a stale orphaned overlay silently ate the live night's. For the Health
/// sample UUIDs that means a later edit deletes the WRONG samples and the night's real ones are
/// orphaned in Apple Health forever — a sample the user can never delete through our UI.)
///
/// Callers pre-flight every key with `canMoveNightScopedDefault` and refuse the whole row move if
/// any one of them is blocked, so a row is never half-relocated.
@discardableResult
private func moveNightScopedDefault(from oldKey: String, to newKey: String) -> Bool {
    let defaults = UserDefaults.standard
    guard let value = defaults.object(forKey: oldKey) else { return true }   // nothing to move
    guard defaults.object(forKey: newKey) == nil else { return false }       // occupied — hands off
    defaults.set(value, forKey: newKey)
    defaults.removeObject(forKey: oldKey)
    return true
}

/// Whether the destination is free.
///
/// ⚠️ IT IS THE DESTINATION THAT MATTERS, NOT THE SOURCE. The first version short-circuited to `true`
/// whenever the source was empty — but "I have nothing to move" is not "the move is safe". A row with
/// no overlay of its own would then be relocated onto a key holding an ORPHANED overlay (one whose own
/// row was eaten by the original collision bug, or written by `mirrorSettledNight` before any row
/// existed) and silently INHERIT it: a foreign night's mirror span widening this night's Health delete
/// window, or a foreign night's sample UUIDs becoming what a later edit deletes.
private func canMoveNightScopedDefault(from oldKey: String, to newKey: String) -> Bool {
    UserDefaults.standard.object(forKey: newKey) == nil
}

/// Which basis a `StoredSleepSummary`'s minutes were computed on. Persisted as a raw string on the
/// row so the value survives an enum rename, and so an unrecognised future value degrades to
/// `.unknown` rather than being silently read as one of the known bases.
enum SleepBasis: String {
    /// Written before this column existed, or by an edit whose recording is already destroyed. The
    /// row's split is NOT known and must never be presented as if it were.
    case unknown = ""
    /// Every segment is measured — which is every unedited, staged night.
    case measuredOnly
    /// The row carries user-asserted time, correctly tagged, with the split in the sibling columns.
    case assertedTagged

    init(stored: String) { self = SleepBasis(rawValue: stored) ?? .unknown }
}

/// THE UNDO STACK FOR SLEEP EDITS — every step, not merely the original state.
///
/// A user's stored health history is theirs, and changing it is destructive and hard to reverse, so
/// each edit pushes the window it replaced. Night-keyed UserDefaults, following exactly the
/// `SleepEditOnsetOverlay` pattern below (including the rename hook the one-shot night-key migration
/// needs — an overlay without one is stranded when a row is re-keyed, which for the Health-sample
/// overlay once meant deleting another night's samples).
///
/// Bounded at `maxDepth` so a user who nudges a picker fifty times cannot grow UserDefaults without
/// limit; the OLDEST entry is dropped, never the original, because the original is the one a
/// "restore what the ring recorded" affordance needs.
enum SleepEditPriorTimesOverlay {
    struct Snapshot: Codable, Equatable {
        var inBedStart: Date
        var sleepOnset: Date
        var sleepWake: Date
    }

    static let maxDepth = 20

    private static func key(_ night: Date) -> String {
        let day = Calendar.current.startOfDay(for: night).timeIntervalSince1970
        return "sleep.edit.priorTimes.\(day)"
    }

    static func stack(night: Date) -> [Snapshot] {
        guard let data = UserDefaults.standard.data(forKey: key(night)),
              let out = try? JSONDecoder().decode([Snapshot].self, from: data) else { return [] }
        return out
    }

    /// Record the window being replaced. A no-op when the incoming snapshot has no usable window
    /// (a legacy row with `.distantPast` edges has nothing to restore TO, and pushing it would put a
    /// meaningless entry at the bottom of the stack where the original belongs).
    static func push(_ snapshot: Snapshot, night: Date) {
        guard snapshot.sleepWake > snapshot.inBedStart,
              snapshot.inBedStart > .distantPast else { return }
        var out = stack(night: night)
        guard out.last != snapshot else { return }        // an unchanged Save must not grow the stack
        out.append(snapshot)
        // Drop from the FRONT+1 so entry 0 — the ring's own window — always survives.
        if out.count > maxDepth { out.removeSubrange(1 ..< (out.count - maxDepth + 1)) }
        guard let data = try? JSONEncoder().encode(out) else { return }
        UserDefaults.standard.set(data, forKey: key(night))
    }

    /// Pop the most recent snapshot, for an "undo this edit" affordance.
    static func pop(night: Date) -> Snapshot? {
        var out = stack(night: night)
        guard let last = out.popLast() else { return nil }
        if let data = try? JSONEncoder().encode(out) {
            UserDefaults.standard.set(data, forKey: key(night))
        }
        return last
    }

    /// One-shot night-key migration hook — see `moveNightScopedDefault`.
    static func rename(from oldNight: Date, to newNight: Date) {
        moveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }
    static func canRename(from oldNight: Date, to newNight: Date) -> Bool {
        canMoveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }
}

/// One extra edited clock value is needed beyond the existing two-edge SwiftData overlay. Keeping
/// it in UserDefaults avoids changing the production SwiftData schema (and therefore avoids a
/// destructive migration on phones with an existing sleep database). Wake remains editedInBedEnd.
private enum SleepEditOnsetOverlay {
    private static func key(_ night: Date) -> String {
        let day = Calendar.current.startOfDay(for: night).timeIntervalSince1970
        return "sleep.edit.onset.\(day)"
    }

    static func load(night: Date) -> Date? {
        UserDefaults.standard.object(forKey: key(night)) as? Date
    }

    static func save(_ onset: Date, night: Date) {
        UserDefaults.standard.set(onset, forKey: key(night))
    }

    /// One-shot night-key migration hook — see `moveNightScopedDefault`.
    static func rename(from oldNight: Date, to newNight: Date) {
        moveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }

    /// Pre-flight for `rename` — see `canMoveNightScopedDefault`.
    static func canRename(from oldNight: Date, to newNight: Date) -> Bool {
        canMoveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }
}

/// The UUIDs of the Apple Health sleep samples this app last wrote for an edited night, so a later
/// edit deletes EXACTLY those (never a nap, never another night) before rewriting — mirroring the
/// menstrual-flow UUID-tracked delete/replace. UserDefaults (keyed by night) avoids a SwiftData
/// migration, matching the onset overlay above.
enum SleepEditHealthSampleOverlay {
    private static func key(_ night: Date) -> String {
        let day = Calendar.current.startOfDay(for: night).timeIntervalSince1970
        return "sleep.edit.hkuuids.\(day)"
    }

    static func load(night: Date) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(night)) ?? []
    }

    static func save(_ uuids: [String], night: Date) {
        UserDefaults.standard.set(uuids, forKey: key(night))
    }

    /// Add UUIDs to the night's tracked set (order-preserving de-dup). Used by the flush's
    /// leading-extension backfill so those samples are also deletable by a later edit.
    static func append(_ uuids: [String], night: Date) {
        guard !uuids.isEmpty else { return }
        var seen = Set<String>()
        let merged = (load(night: night) + uuids).filter { seen.insert($0).inserted }
        save(merged, night: night)
    }

    /// One-shot night-key migration hook — see `moveNightScopedDefault`. Load-bearing: these UUIDs
    /// are what a later edit DELETES from Apple Health. Stranded under the old key, a re-edit would
    /// leave the previous samples orphaned in Health and write a duplicate night alongside them.
    static func rename(from oldNight: Date, to newNight: Date) {
        moveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }

    /// Pre-flight for `rename` — see `canMoveNightScopedDefault`.
    static func canRename(from oldNight: Date, to newNight: Date) -> Bool {
        canMoveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }
}

/// What this app last MIRRORED to Apple Health for an unedited night: a content signature of the
/// staged segments plus the time span they covered. Nights routinely re-stage hours after wake, and
/// the forward-only `.sleep` cursor makes the ordinary write append-only — so without this the card
/// grows to the fuller staging while Health stays frozen at the first write. Comparing the current
/// signature to the stored one lets the flush delete-and-replace the night ONLY when the staging
/// actually changed (no churn otherwise). The span drives the union-cleanup so a re-stage that
/// SHRINKS the night still removes the old tail from Health. UserDefaults (keyed by night) —
/// no SwiftData migration, matching the overlays above.
struct MirroredNightRecord: Codable {
    var signature: String
    var spanStart: Date
    var spanEnd: Date
}

enum MirroredNightOverlay {
    private static func key(_ night: Date) -> String {
        let day = Calendar.current.startOfDay(for: night).timeIntervalSince1970
        return "sleep.mirror.night.\(day)"
    }

    static func load(night: Date) -> MirroredNightRecord? {
        guard let data = UserDefaults.standard.data(forKey: key(night)) else { return nil }
        return try? JSONDecoder().decode(MirroredNightRecord.self, from: data)
    }

    static func save(_ record: MirroredNightRecord, night: Date) {
        UserDefaults.standard.set(try? JSONEncoder().encode(record), forKey: key(night))
    }

    /// One-shot night-key migration hook — see `moveNightScopedDefault`. Without it every migrated
    /// night would look "never mirrored", and the next flush would delete-and-replace it in Apple
    /// Health for no reason.
    static func rename(from oldNight: Date, to newNight: Date) {
        moveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }

    /// Pre-flight for `rename` — see `canMoveNightScopedDefault`.
    static func canRename(from oldNight: Date, to newNight: Date) -> Bool {
        canMoveNightScopedDefault(from: key(oldNight), to: key(newNight))
    }
}

/// A sleep-edit Health reconcile that couldn't run because the periodic flush held the Health-write
/// gate. Persisted so the NEXT flush drains it — otherwise a trim made while a flush was in flight
/// would silently never reach Apple Health (the flush's own sleep path is append-only and can't trim).
struct PendingSleepReconcile: Codable, Equatable {
    var night: Date
    var inBedStart: Date
    var sleepOnset: Date
    var sleepWake: Date
    var segments: [SleepSegment]
}

enum PendingSleepReconcileStore {
    /// ⚠️ THE VERSION SUFFIX IS LOAD-BEARING — BUMP IT WHENEVER `SleepSegment`'S ENCODING GAINS A
    /// MEANING AN OLDER BUILD DID NOT WRITE.
    ///
    /// A queued item holds `[SleepSegment]`, and `SleepSegment.init(from:)` decodes a missing
    /// `provenance` key as `.measured` — which is right for a segment an older build STAGED, and
    /// exactly wrong for the invented fill an older build's EDIT produced. Left on `v1`, the first
    /// launch after upgrade would drain a queue written before coverage existed, read every invented
    /// minute in it as measured, and write the whole thing to Apple Health once — the one outcome
    /// this entire change exists to prevent, executed by the fix itself.
    ///
    /// The cost of the bump is that a reconcile queued by the old build never drains: the user's TRIM
    /// does not reach Health until they touch that night again. That is a stale wider night in
    /// Health, which is the pre-existing behaviour of every build before the reconcile queue existed
    /// — non-destructive, and strictly better than one confident invented write.
    private static let key = "sleep.edit.pending-reconcile.v2"
    /// The queue this build refuses to read. Dropped once, on first access, so it cannot sit in
    /// UserDefaults forever — and dropping it is safe for the reason above: it can only ever cause
    /// Health to keep MORE sleep than the user asked for, never less.
    private static let abandonedKey = "sleep.edit.pending-reconcile.v1"

    static func all() -> [PendingSleepReconcile] {
        if UserDefaults.standard.object(forKey: abandonedKey) != nil {
            UserDefaults.standard.removeObject(forKey: abandonedKey)
        }
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingSleepReconcile].self, from: data)) ?? []
    }

    static func upsert(_ item: PendingSleepReconcile) {
        var items = all().filter { Calendar.current.isDate($0.night, inSameDayAs: item.night) == false }
        items.append(item)
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    static func clear(night: Date) {
        let items = all().filter { Calendar.current.isDate($0.night, inSameDayAs: night) == false }
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    /// Whether `rekey` can run without breaking `upsert`'s one-item-per-day invariant. False when
    /// items exist for BOTH nights: rewriting would leave two items for one day, and the next flush
    /// would drain both against the same night — the second reconcile's delete/rewrite running over
    /// the first one's freshly written samples, then `clear(night:)` removing both, so one night's
    /// trim silently never reaches Apple Health.
    static func canRekey(from oldNight: Date, to newNight: Date) -> Bool {
        let items = all()
        let hasOld = items.contains { Calendar.current.isDate($0.night, inSameDayAs: oldNight) }
        let hasNew = items.contains { Calendar.current.isDate($0.night, inSameDayAs: newNight) }
        return !(hasOld && hasNew)
    }

    /// One-shot night-key migration hook. A reconcile queued under the OLD key would otherwise be
    /// drained against a night that no longer exists, so the user's trim would never reach Health.
    static func rekey(from oldNight: Date, to newNight: Date) {
        let items = all()
        guard items.contains(where: { Calendar.current.isDate($0.night, inSameDayAs: oldNight) }) else { return }
        let updated = items.map { item -> PendingSleepReconcile in
            guard Calendar.current.isDate(item.night, inSameDayAs: oldNight) else { return item }
            var moved = item
            moved.night = newNight
            return moved
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(updated), forKey: key)
    }
}

/// Per-day rollups for values that are NOT epoch samples and must NOT flow through the
/// cumulative-counter `ingest` path (which computes HealthKit deltas). Currently the
/// ring's onboard step count for the day. Keyed by `day` (start-of-day) and UPSERTED, so
/// the dashboard can show "steps today" offline without disturbing `SyncCursor` /
/// `cumulativeState` / Apple Health writes.
@Model
final class StoredDaily {
    @Attribute(.unique) var day: Date = Date.distantPast
    var steps: Int = 0
    var updatedAt: Date = Date.distantPast
    /// SUPERSEDED as the Health-write gate by `StoredStepSample.healthWritten` (#steps-history)
    /// — Health now receives each timestamped snapshot individually rather than one per-day
    /// delta off this watermark. Kept (frozen, no longer written) only so existing stores don't
    /// need a destructive migration; safe to ignore when reasoning about what's in Health.
    var healthWrittenSteps: Int = 0

    init(day: Date, steps: Int = 0, updatedAt: Date = Date(), healthWrittenSteps: Int = 0) {
        self.day = day
        self.steps = steps
        self.updatedAt = updatedAt
        self.healthWrittenSteps = healthWrittenSteps
    }
}

/// One timestamped step DELTA as actually observed off the ring's `0x10/0x87` descriptor
/// counter (#steps-history). Unlike `StoredDaily` (a single running per-day total with no
/// timing info), `start`/`end` bound the window this delta was folded over, so:
///   - Apple Health receives a narrow, correctly-timed `stepCount` sample instead of one
///     `startOfDay→now` write that HealthKit's hourly view would smear evenly across every
///     elapsed hour of the day.
///   - A Trends/table view can show the actual intraday step shape, not just a daily total.
/// Append-only, no unique key — many rows per day are expected.
@Model
final class StoredStepSample {
    var start: Date = Date.distantPast
    var end: Date = Date.distantPast
    var delta: Int = 0
    var healthWritten: Bool = false

    init(start: Date, end: Date, delta: Int, healthWritten: Bool = false) {
        self.start = start
        self.end = end
        self.delta = delta
        self.healthWritten = healthWritten
    }
}

/// One auto-detected daytime nap (#76) — daytime stillness ≥ 15 min OUTSIDE the main overnight
/// sleep window. Kept separate from `StoredSleepSummary` so naps never double-count against the
/// night. Keyed by `start` and UPSERTED, so re-syncing the same day replaces rather than
/// duplicates. `healthWritten` gates the (separate) Apple Health sleep write so a nap is written
/// once. Every column is defaulted for SwiftData lightweight migration (cf. #21).
@Model
final class StoredNap {
    @Attribute(.unique) var start: Date = Date.distantPast
    var end: Date = Date.distantPast
    var asleepMin: Int = 0
    var isLongNap: Bool = false
    var healthWritten: Bool = false
    var updatedAt: Date = Date.distantPast
    // Manual nap edit/add overlay (RingConn `SleepNapModel.isEdited` parity). DEFAULTED for SwiftData
    // lightweight migration (cf. #21). A manual nap (edited window or user-added) is PRESERVED across
    // auto re-detection — see `saveNap`. `isManuallyAdded` marks a nap the ring never detected.
    var isManuallyEdited: Bool = false
    var isManuallyAdded: Bool = false
    /// Encoded staged `[SleepSegment]` hypnogram for the Apple Health write (Deep/Light/REM — RingConn
    /// `sleepPhases` parity). nil = coarse, and `flushNaps` then writes a plain inBed+asleepCore pair.
    var napSegmentsData: Data? = nil
    /// Edit overlay (#nap-parity): the user-adjusted window. The unique `start` KEY is kept STABLE on
    /// edit so auto re-detection updates the SAME row (no duplicate at the old start); display + Health
    /// use the effective window below. nil = unedited.
    var editedStart: Date? = nil
    var editedEnd: Date? = nil

    /// The AUTO-DETECTED staged hypnogram, kept so an edit is reversible. `editNap` used to replace
    /// `napSegmentsData` with a whole-window `inBed + asleepCore` pair, destroying the ring's real
    /// per-nap staging with no backup — the nap-scale twin of the night-scale defect
    /// `recordedHypnogramData` exists for. nil = the nap was always coarse, or predates this column.
    var recordedNapSegmentsData: Data? = nil

    /// The window last MIRRORED to Apple Health. `healthWritten` is a bare bool, so when a user
    /// SHRANK an already-mirrored nap the wider sleep stayed in Health permanently — there is no nap
    /// analogue of `reconcileEditedNightSleep`, and `pendingNaps()` only offers rows with
    /// `healthWritten == false`. Recording the written span lets `flushNaps` clean the stale
    /// remainder. `distantPast` = never written.
    var healthWrittenStart: Date = Date.distantPast
    var healthWrittenEnd: Date = Date.distantPast

    init(start: Date, end: Date, asleepMin: Int = 0, isLongNap: Bool = false,
         healthWritten: Bool = false, updatedAt: Date = Date()) {
        self.start = start
        self.end = end
        self.asleepMin = asleepMin
        self.isLongNap = isLongNap
        self.healthWritten = healthWritten
        self.updatedAt = updatedAt
    }

    /// The window actually shown + written to Health — the manual edit if present, else the detected
    /// window. `start` stays the stable dedup key; everything user-facing uses these.
    var effectiveStart: Date { editedStart ?? start }
    var effectiveEnd: Date { editedEnd ?? end }
    var durationMin: Int { max(Int(effectiveEnd.timeIntervalSince(effectiveStart) / 60), 0) }

    /// The staged per-nap hypnogram (decoded from `napSegmentsData`), or nil when the nap is coarse.
    var stagedSegments: [SleepSegment]? {
        get { napSegmentsData.flatMap { try? JSONDecoder().decode([SleepSegment].self, from: $0) } }
        set { napSegmentsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

/// A DAYTIME skin-temp reading, kept entirely separate from the nightly `StoredSleepSummary
/// .skinTempC` baseline and from Apple Health (#41 deliberately blocks daytime readings from
/// that path — mixing them in would skew the nightly cycle-tracking baseline and mis-report a
/// daytime spot reading as the night's value). This table exists purely so the Trends UI can
/// show a true intraday temperature line; it is re-derivable from the ring's live descriptor
/// stream (not backed up before a schema-wipe, like `StoredSample`) and pruned on the same
/// retention window. Every column is defaulted for SwiftData lightweight migration (cf. #21).
@Model
final class StoredDaytimeTemp {
    var time: Date = Date.distantPast
    var celsius: Double = 0

    init(time: Date, celsius: Double) {
        self.time = time
        self.celsius = celsius
    }
}

@MainActor
struct LocalStore {
    let context: ModelContext

    init(_ context: ModelContext) { self.context = context }

    // MARK: Shared fetch descriptors
    //
    // `nonisolated` so the SAME descriptor can be run on the main-actor `context` (the instance
    // methods below) and on a background `ModelContext` (`TrendsSnapshotReader`, which pulls ~25 k
    // rows and must never do it on the main thread). They live here, and the instance methods are
    // thin wrappers over them, so the two callers can never drift into fetching different sets —
    // a background reader with its own hand-copied predicate is exactly how a "why does Trends
    // disagree with the card" bug gets born.

    nonisolated static func samplesDescriptor(kind: MetricKind, from start: Date,
                                              to end: Date) -> FetchDescriptor<StoredSample> {
        let kindRaw = kind.rawValue
        return FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start, order: .forward)]
        )
    }

    nonisolated static func daytimeTemperaturesDescriptor(from start: Date,
                                                          to end: Date) -> FetchDescriptor<StoredDaytimeTemp> {
        FetchDescriptor<StoredDaytimeTemp>(
            predicate: #Predicate { $0.time >= start && $0.time < end },
            sortBy: [SortDescriptor(\.time)]
        )
    }

    nonisolated static func stepSamplesDescriptor(from: Date,
                                                  to: Date) -> FetchDescriptor<StoredStepSample> {
        FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.start >= from && $0.start < to },
            sortBy: [SortDescriptor(\.start, order: .forward)])
    }

    /// Newest sample of `kind` strictly BEFORE `before`, or nil. One row, index-ordered — this is
    /// the bedtime-provenance probe (#198) and runs on the sleep card's render path, so it must
    /// never become a scan.
    func latestSample(kind: MetricKind, before: Date) throws -> QuantitySample? {
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start < before },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sample
    }

    /// Oldest sample of `kind` strictly AFTER `after`, or nil. The trailing-edge mirror of
    /// `latestSample(kind:before:)` and the WAKE-provenance probe (`WakeProvenance.classify`,
    /// `SleepConfidence.Coverage.firstMeasurementAfterEnd`): it answers "did the ring keep recording
    /// past the wake we printed, or is that wake just where the data stopped?".
    ///
    /// Same shape as its mirror — one row, index-ordered, `fetchLimit = 1` — because it runs on the
    /// same sleep-card render path and must never become a scan. Pass `.heartRate`: HR is
    /// band-guarded to 30…220 bpm, so a charging or pocketed ring produces none, while a skin-temp
    /// row keeps arriving from a docked ring and would report a dead night as "still recording".
    func earliestSample(kind: MetricKind, after: Date) throws -> QuantitySample? {
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start > after },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sample
    }

    /// Oldest retained sample of `kind`, or nil when none is stored. Tells "the ring recorded
    /// nothing" from "retention no longer reaches back that far" (#198). One row.
    func earliestSample(kind: MetricKind) throws -> QuantitySample? {
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sample
    }

    nonisolated static func recentSleepSummariesDescriptor(limit: Int) -> FetchDescriptor<StoredSleepSummary> {
        var descriptor = FetchDescriptor<StoredSleepSummary>(
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    nonisolated static func recentDailiesDescriptor(limit: Int) -> FetchDescriptor<StoredDaily> {
        var descriptor = FetchDescriptor<StoredDaily>(
            sortBy: [SortDescriptor(\.day, order: .reverse)])
        descriptor.fetchLimit = limit
        return descriptor
    }

    struct IngestPreview: Equatable {
        var inputCount = 0
        var plausibleCount = 0
        var freshCount = 0
        var duplicateCount = 0
        var invalidTimestampCount = 0
        var invalidHeartRateCount = 0
    }

    /// The store-ingest cursor rows (live `@Model` objects, so mutating `.last` updates the
    /// context). Skips the `hk:`-prefixed HealthKit-watermark rows (see `pendingHealthSamples`)
    /// and the `export:`-prefixed export watermark — they live in the same table but track
    /// separate concerns and must not pollute the store-ingest cursor.
    private func storeCursorRows() throws -> [StoredCursor] {
        try context.fetch(FetchDescriptor<StoredCursor>())
            .filter { !$0.kindRaw.hasPrefix(Self.healthCursorPrefix)
                && !$0.kindRaw.hasPrefix(Self.exportCursorPrefix) }
    }

    /// Dry-run of `ingest(_:)` for logging/observability. Lets the caller tell whether a captured
    /// sample would be rejected as implausible or duplicate before the real write runs.
    func previewIngest(_ samples: [QuantitySample], now: Date = Date()) throws -> IngestPreview {
        let rows = try storeCursorRows()
        let cursor = SyncCursor(lastByKind: Dictionary(uniqueKeysWithValues: rows.map { ($0.kindRaw, $0.last) }))

        var preview = IngestPreview()
        preview.inputCount = samples.count
        var plausible: [QuantitySample] = []
        plausible.reserveCapacity(samples.count)

        let epochFloor = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch))
        let futureCeiling = now.addingTimeInterval(86_400)
        for s in samples {
            if s.start < epochFloor || s.start > futureCeiling {
                preview.invalidTimestampCount += 1
                continue
            }
            if s.kind == .heartRate, !LiveHR.validBPM.contains(Int(s.value)) {
                preview.invalidHeartRateCount += 1
                continue
            }
            plausible.append(s)
        }

        preview.plausibleCount = plausible.count
        preview.freshCount = cursor.selectNewStaged(plausible).fresh.count
        preview.duplicateCount = max(preview.plausibleCount - preview.freshCount, 0)
        return preview
    }

    /// Rebuild the in-memory SyncCursor from persisted rows.
    func loadCursor() throws -> SyncCursor {
        var map: [String: Date] = [:]
        for r in try storeCursorRows() { map[r.kindRaw] = r.last }
        return SyncCursor(lastByKind: map)
    }

    /// Persist new samples and advance the cursor in one step.
    ///
    /// Ordering matters (#22): the cursor advance is STAGED in memory and only the rows that
    /// actually moved are written, then samples + cursor commit together in a single
    /// `context.save()`. On a save failure we roll back, so the persisted cursor never moves
    /// ahead of un-stored samples — they're retried on the next ingest instead of being lost.
    func ingest(_ samples: [QuantitySample]) throws -> [QuantitySample] {
        // Fetch the cursor rows ONCE and reuse them for both the in-memory cursor and the
        // post-insert upsert — no per-`MetricKind` fetch loop (#33).
        let rows = try storeCursorRows()
        var rowByKind: [String: StoredCursor] = [:]
        for r in rows { rowByKind[r.kindRaw] = r }
        let cursor = SyncCursor(lastByKind: rowByKind.mapValues(\.last))

        // Plausibility BEFORE the cursor ever sees these samples. A SyncCursor only moves
        // FORWARD (never resets), so a single corrupted-timestamp sample (e.g. a misaligned
        // bulk-page parse computing a date decades off) or an out-of-band HR value advancing a
        // kind's watermark would silently block every later LEGITIMATE sample of that kind
        // forever — exactly what happened to `.heartRate` (and, transitively, sleep staging,
        // which can't run without HR). Filtering here, before `selectNewStaged`, means a sample
        // that's about to be discarded can never poison the watermark in the first place. (See
        // `repairFutureSyncCursors` for undoing damage from before this reordering existed.)
        let plausible = samples.filter { Self.isPlausible($0) }

        // Stage the advance — don't touch the persisted cursor until the save commits (#22).
        let (fresh, advanced) = cursor.selectNewStaged(plausible)
        guard !fresh.isEmpty else { return [] }

        var cumulativeStates: [MetricKind: CumulativeMetricState] = [:]
        var cumulativeStateDays: [MetricKind: Date] = [:]
        var ingested: [QuantitySample] = []

        for s in fresh {
            guard s.kind.isCumulativeCounter else {
                context.insert(StoredSample(s))
                ingested.append(s)
                continue
            }

            // The daily total resets at midnight. `fresh` is sorted oldest→newest, so a
            // single batch can span a day boundary; when it does, carry the raw counter
            // forward (so the delta stays correct) but reset the running total to 0 for the
            // new day. The initial DB-backed state is already day-bounded by `cumulativeState`.
            let dayStart = Calendar.current.startOfDay(for: s.start)
            let state: CumulativeMetricState
            if let existing = cumulativeStates[s.kind] {
                state = cumulativeStateDays[s.kind] == dayStart
                    ? existing
                    : CumulativeMetricState(previousRawValue: existing.previousRawValue, dailyTotal: 0)
            } else {
                // First sample of this kind in the batch: the ONLY DB hit for cumulative state.
                // Subsequent samples of the same kind reuse the in-memory `cumulativeStates`
                // cache above, so no further per-sample lookups occur this ingest (#33).
                state = try cumulativeState(for: s.kind, before: s.start)
            }

            let result = CumulativeMetricAccumulator.accumulate(s, state: state)
            let deltaSample = QuantitySample(kind: s.kind, start: s.start, end: s.end, value: result.deltaValue)
            context.insert(StoredSample(
                deltaSample,
                rawValue: result.rawValue,
                isDelta: true,
                dailyTotal: result.dailyTotal
            ))
            cumulativeStates[s.kind] = CumulativeMetricState(
                previousRawValue: result.rawValue,
                dailyTotal: result.dailyTotal
            )
            cumulativeStateDays[s.kind] = dayStart
            // Return the per-epoch DELTA, not the running total: HealthKit *sums* cumulative
            // quantity types (stepCount / activeEnergyBurned), so writing the daily total on
            // every epoch would massively overcount. Deltas sum back to the daily total in Health.
            ingested.append(deltaSample)
        }
        // Persist ONLY the kinds whose cursor actually advanced, reusing the rows already
        // fetched above — no fetch-per-`MetricKind.allCases` loop (#33).
        for kind in advanced.advancedKinds(since: cursor) {
            guard let last = advanced.last(kind) else { continue }
            if let existing = rowByKind[kind.rawValue] {
                existing.last = last
            } else {
                context.insert(StoredCursor(kindRaw: kind.rawValue, last: last))
            }
        }
        do {
            // Samples + cursor advance commit atomically. On failure, roll back the staged
            // inserts and cursor moves so the next ingest re-stores the same samples (#22).
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return ingested
    }

    /// Single ingest choke point for sample plausibility, checked BEFORE the SyncCursor — see the
    /// ordering note in `ingest`. Two independent gates:
    /// - TIMESTAMP: reject any sample whose `start` predates the ring's own counter epoch
    ///   (2019-12-31 — nothing real can be older) or sits implausibly far in the future
    ///   (clock-skew tolerance). Catches a corrupted epoch-counter decode that would otherwise
    ///   surface as something like "13y ago" — or, worse, decades in the FUTURE.
    /// - HEART RATE: reject values outside `LiveHR.validBPM` (30…220), including 0-bpm
    ///   placeholders — covers paths the sleep-vitals decoder guard doesn't (e.g. EpochSync
    ///   value-0 placeholders).
    private static func isPlausible(_ s: QuantitySample, now: Date = Date()) -> Bool {
        let epochFloor = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch))
        guard s.start >= epochFloor, s.start <= now.addingTimeInterval(86_400) else { return false }
        if s.kind == .heartRate, !LiveHR.validBPM.contains(Int(s.value)) { return false }
        return true
    }

    // MARK: Retention (#32)
    //
    // Days of raw `StoredSample` history kept on-device. Older epochs are pruned — the data
    // already lives in Apple Health — while the rollup tables (`StoredSleepSummary` /
    // `StoredDaily`) are kept long-term so the offline dashboard still shows past nights/days.
    static let sampleRetentionDays = 30

    /// Delete raw samples older than the retention window; rollup tables are untouched. Meant to
    /// run occasionally (e.g. once at launch), NOT per write: with no column index a predicate
    /// delete scans `start`, so running it on every live sample would reintroduce the unbounded
    /// scan #32 is removing. The cumulative-counter day chain is unaffected (it only reaches back
    /// to the current day, far inside the window).
    func pruneExpiredSamples(olderThan days: Int = LocalStore.sampleRetentionDays,
                             now: Date = Date()) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        try context.delete(model: StoredSample.self,
                           where: #Predicate { $0.start < cutoff })
        try context.delete(model: StoredDaytimeTemp.self,
                           where: #Predicate { $0.time < cutoff })
        try context.delete(model: StoredStepSample.self,
                           where: #Predicate { $0.start < cutoff })
        try context.save()
    }

    /// Record one DAYTIME skin-temp reading (Trends-only — see `StoredDaytimeTemp`). Plain
    /// insert, no upsert: readings are frequent and timestamped, so duplicates aren't a
    /// dedup concern the way a single nightly summary row is.
    func recordDaytimeTemperature(_ celsius: Double, at time: Date) throws {
        context.insert(StoredDaytimeTemp(time: time, celsius: celsius))
        try context.save()
    }

    /// Daytime skin-temp readings in `[start, end)`, oldest first.
    func daytimeTemperatures(from start: Date, to end: Date) throws -> [StoredDaytimeTemp] {
        try context.fetch(Self.daytimeTemperaturesDescriptor(from: start, to: end))
    }

    /// One-time cleanup: delete physiologically-impossible heart-rate samples — those outside
    /// `LiveHR.validBPM` (30…220 bpm), including 0-bpm placeholders — that were persisted BEFORE
    /// the decoder gained its band guard. A single garbage epoch (e.g. 4 bpm) otherwise surfaced
    /// as an impossible "Resting HR 4 bpm" and depressed the sleep score / per-stage HR / Health
    /// mirror across every consumer, not just one view. The decoder now blocks NEW out-of-band
    /// values at the source, so this only scrubs the existing rows once. Returns the number deleted.
    @discardableResult
    func purgeImplausibleHeartRate() throws -> Int {
        let hr = MetricKind.heartRate.rawValue
        let lo = Double(LiveHR.minValidBPM)
        let hi = Double(LiveHR.maxValidBPM)
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hr && ($0.value < lo || $0.value > hi) })
        let stale = try context.fetch(descriptor)
        guard !stale.isEmpty else { return 0 }
        for row in stale { context.delete(row) }
        try context.save()
        return stale.count
    }

    /// One-time scrub for samples with an implausible TIMESTAMP, predating the `ingest` epoch
    /// guard added alongside it. A single misaligned bulk-page parse can mint a sample dated years
    /// off (e.g. before the ring's own counter epoch), which then surfaces as something like "13y
    /// ago" in any relative-time caption that reads it — every consumer, not just one view. New
    /// out-of-band timestamps are now blocked at `ingest`'s source; this only scrubs existing rows
    /// once. Returns the number deleted.
    @discardableResult
    func purgeImplausibleTimestamps() throws -> Int {
        let epochFloor = Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch))
        let futureCeiling = Date().addingTimeInterval(86_400)
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.start < epochFloor || $0.start > futureCeiling })
        let stale = try context.fetch(descriptor)
        guard !stale.isEmpty else { return 0 }
        for row in stale { context.delete(row) }
        try context.save()
        return stale.count
    }

    /// Repair for a `SyncCursor` watermark stuck in the far future — the lasting damage from a
    /// corrupted-timestamp sample that advanced a kind's cursor BEFORE `ingest` checked
    /// plausibility ahead of the cursor (see the ordering note there). A cursor only moves
    /// FORWARD, so once poisoned it silently blocks every later legitimate sample of that kind —
    /// `purgeImplausibleTimestamps` cleans the bad SAMPLE rows but never touches the cursor itself,
    /// so without this the block persists even after the source bug is fixed.
    ///
    /// Covers BOTH cursor families sharing this table: the plain ingest cursor (`heartRate`) and
    /// the `hk:`-prefixed HealthKit-mirror cursor (`hk:heartRate`) — a poisoned mirror cursor would
    /// keep new, valid LOCAL samples from ever reaching Apple Health even after the ingest side is
    /// fixed. Each poisoned row is reset to the latest ALREADY-STORED plausible sample of its bare
    /// kind, or removed entirely when none exists, so the next ingest/flush re-admits the backlog
    /// instead of staying stuck forever.
    ///
    /// Deliberately run on EVERY launch (not gated to once) rather than a one-time scrub like the
    /// sample purges above: it's a handful of cursor rows (cheap to re-check), and a single
    /// one-time pass turned out NOT to be reliably sufficient — `hk:heartRate` was still observed
    /// stuck after the first run (cause unconfirmed; likely launch-task ordering against the other
    /// one-time scrubs). Re-running it every launch is a self-healing no-op once nothing's stuck,
    /// and guarantees this can't silently stay broken from one bad run. Returns the number of rows
    /// repaired (logged by the caller).
    @discardableResult
    func repairFutureSyncCursors(now: Date = Date()) throws -> Int {
        let ceiling = now.addingTimeInterval(86_400)
        let rows = try context.fetch(FetchDescriptor<StoredCursor>())
        let stuck = rows.filter { $0.last > ceiling }
        guard !stuck.isEmpty else { return 0 }
        // Capture kind names BEFORE any `context.delete` below — reading a property off a
        // deleted-but-unsaved SwiftData model is unreliable, so the log message must not touch
        // `stuck` again after the mutation loop.
        let stuckKinds = stuck.map(\.kindRaw)

        for row in stuck {
            let bareKind = row.kindRaw.hasPrefix(Self.healthCursorPrefix)
                ? String(row.kindRaw.dropFirst(Self.healthCursorPrefix.count))
                : row.kindRaw
            var latestDescriptor = FetchDescriptor<StoredSample>(
                predicate: #Predicate { $0.kindRaw == bareKind && $0.start <= now },
                sortBy: [SortDescriptor(\.start, order: .reverse)]
            )
            latestDescriptor.fetchLimit = 1
            if let latest = try context.fetch(latestDescriptor).first {
                row.last = latest.start
            } else {
                context.delete(row)
            }
        }
        try context.save()
        ringLog.notice("cursor repair: reset \(stuckKinds.count) stuck row(s): \(stuckKinds.joined(separator: ", "), privacy: .public)")
        return stuckKinds.count
    }

    /// Stored samples of one kind within `[start, end)`, oldest→newest. Used by the
    /// dashboard to average overnight skin-temperature samples (which only exist while the
    /// ring was connected) over a night window.
    func samples(kind: MetricKind, from start: Date, to end: Date) throws -> [QuantitySample] {
        try context.fetch(Self.samplesDescriptor(kind: kind, from: start, to: end)).compactMap(\.sample)
    }

    /// Stored samples of one kind newer than `since`, oldest→newest. Bounded by the predicate so
    /// it never scans all history — used by the health-alert engine (#73/#85) to evaluate recent
    /// HR/SpO2 readings against the user's thresholds.
    func recentSamples(kind: MetricKind, since: Date) throws -> [QuantitySample] {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start >= since && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor).compactMap(\.sample)
    }

    func latestSample(kind: MetricKind) throws -> QuantitySample? {
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sample
    }

    // MARK: HealthKit write watermark (decoupled from the store-ingest cursor)
    //
    // The store-ingest cursor (`ingest`) dedupes ROWS in the local store so the dashboard
    // never double-counts a re-synced night. Apple Health needs its OWN high-water mark:
    // previously both shared one cursor, so the dashboard's auto-persist advanced it before
    // the Health write could claim the samples — HR/HRV/SpO2/respiratory/temperature were
    // persisted for the dashboard but NEVER reached Apple Health. This watermark reads from
    // the store (the single source of truth the auto-persist fills) and only advances after
    // a confirmed write, so an un-authorized or failed write safely backfills next time.

    /// Non-cumulative scalar metrics mirrored into Apple Health straight from the store.
    /// (Sleep uses `pendingHealthSleep`/`markSleepWritten`; cumulative step/energy counters
    /// take their own paths.)
    static let healthMirroredKinds: [MetricKind] = [.heartRate, .hrvSDNN, .spo2, .respiratoryRate, .temperature]
    private static let healthCursorPrefix = "hk:"

    /// Stored samples of the Health-mirrored kinds newer than the Health watermark,
    /// oldest→newest — everything synced to the store but not yet written to Apple Health.
    /// Does NOT advance the watermark (call `markHealthWritten` after a successful write).
    func pendingHealthSamples() throws -> [QuantitySample] {
        let cursor = try loadHealthCursor()
        var out: [QuantitySample] = []
        for kind in Self.healthMirroredKinds {
            let kindRaw = kind.rawValue
            let last = cursor.last(kind) ?? .distantPast
            let descriptor = FetchDescriptor<StoredSample>(
                predicate: #Predicate { $0.kindRaw == kindRaw && $0.start > last && $0.value > 0 },
                sortBy: [SortDescriptor(\.start, order: .forward)])
            out += try context.fetch(descriptor).compactMap(\.sample)
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Sleep segments for a night not yet mirrored to Apple Health, gated on the `.sleep`
    /// cursor — WITHOUT advancing it (call `markSleepWritten` only after a confirmed write,
    /// so a failed save backfills next time instead of losing the night). Returns `[]` when
    /// this night is already in Health.
    func pendingHealthSleep(_ segments: [SleepSegment]) throws -> [SleepSegment] {
        guard let latest = segments.map(\.end).max() else { return [] }
        let cursor = try loadCursor()
        guard cursor.isNew(.sleep, latest) else { return [] }
        // A stitched multi-fragment night re-includes earlier fragments that an earlier drain may have
        // ALREADY mirrored to Health (the watermark sits inside this night). Write only segments that
        // extend past it — otherwise the morning sync re-writes the earlier fragment, duplicating /
        // overlapping sleep samples (HealthKit doesn't dedup). With the cursor before the night (the
        // common case) every segment passes, so a whole night still lands. (Adversarial review.)
        if let last = cursor.last(.sleep) {
            // Clip a segment that crosses the watermark instead of re-writing its already-saved
            // prefix. This matters for a re-edited wake extension: 08:00→10:00 presented after a
            // prior 08:00→09:00 extension must append only 09:00→10:00, not duplicate an hour.
            return segments.compactMap { segment in
                let start = max(segment.start, last)
                return segment.end > start
                    ? SleepSegment(start: start, end: segment.end, stage: segment.stage)
                    : nil
            }
        }
        return segments
    }

    /// Advance the `.sleep` cursor past the night just written to Apple Health.
    func markSleepWritten(_ segments: [SleepSegment]) throws {
        guard let latest = segments.map(\.end).max() else { return }
        try forceSleepCursorAtLeast(latest)
    }

    /// Ensure the forward `.sleep` watermark is at least `date`. Used after a TRIM reconcile so the
    /// deleted recorded tail `(editedWake, recordedWake]` can never be re-presented as "new" by
    /// `pendingHealthSleep` on a later full-base flush (which would re-add the trimmed sleep).
    func forceSleepCursorAtLeast(_ date: Date) throws {
        var cursor = try loadCursor()
        guard cursor.isNew(.sleep, date) else { return }
        cursor.advance(.sleep, to: date)
        if let last = cursor.last(.sleep) {
            upsertCursor(kind: MetricKind.sleep.rawValue, last: last)
        }
        try context.save()
    }

    /// The Apple Health sleep-sample UUIDs this app last wrote for `night` (edit delete/replace).
    func sleepEditHealthUUIDs(night: Date) -> [String] {
        SleepEditHealthSampleOverlay.load(night: night)
    }

    /// Remember the Apple Health sleep-sample UUIDs written for `night`, so the next edit deletes
    /// exactly those and nothing else.
    func setSleepEditHealthUUIDs(_ uuids: [String], night: Date) {
        SleepEditHealthSampleOverlay.save(uuids, night: night)
    }

    /// Append to the night's tracked Apple Health sleep-sample UUIDs (leading-extension backfill).
    func appendSleepEditHealthUUIDs(_ uuids: [String], night: Date) {
        SleepEditHealthSampleOverlay.append(uuids, night: night)
    }

    /// What this app last mirrored to Apple Health for `night` (signature + span), or nil if never.
    /// Drives the flush's "night re-staged → correct Health" delete/replace (see `mirrorSettledNight`).
    func mirroredNight(night: Date) -> MirroredNightRecord? {
        MirroredNightOverlay.load(night: night)
    }

    /// Record the staging signature + span just mirrored to Apple Health for `night`, so a later flush
    /// re-mirrors ONLY when the staging changed.
    func setMirroredNight(night: Date, signature: String, spanStart: Date, spanEnd: Date) {
        MirroredNightOverlay.save(.init(signature: signature, spanStart: spanStart, spanEnd: spanEnd),
                                  night: night)
    }

    /// Persist a sleep-edit reconcile deferred because a flush held the Health gate (drained by the
    /// next flush). Keyed by night — a newer deferral for the same night supersedes the older.
    func setPendingSleepReconcile(night: Date, times: SleepEdit.Times, segments: [SleepSegment]) {
        PendingSleepReconcileStore.upsert(.init(night: night, inBedStart: times.inBedStart,
                                                sleepOnset: times.sleepOnset, sleepWake: times.sleepWake,
                                                segments: segments))
    }

    /// The deferred sleep-edit reconciles awaiting a Health-gate-free flush to apply their trim/edit.
    func pendingSleepReconciles() -> [PendingSleepReconcile] {
        PendingSleepReconcileStore.all()
    }

    func clearPendingSleepReconcile(night: Date) {
        PendingSleepReconcileStore.clear(night: night)
    }

    /// Clear a deferred reconcile ONLY if the stored marker still equals the one just processed — so a
    /// NEWER same-night edit that was enqueued while this one was mid-flight is never wiped (avoids the
    /// lost-update where a stale drain clears a fresh trim).
    func clearPendingSleepReconcileIfUnchanged(_ item: PendingSleepReconcile) {
        let current = PendingSleepReconcileStore.all()
            .first { Calendar.current.isDate($0.night, inSameDayAs: item.night) }
        if current == item { PendingSleepReconcileStore.clear(night: item.night) }
    }

    /// Windows of naps ALREADY mirrored to Apple Health that overlap `[start, end]`. The sleep-edit
    /// recorded-span cleanup excludes these so a nap the night later widened over (a short first drain
    /// grew by a fuller re-drain) is never deleted from Apple Health.
    ///
    /// Uses the UNION of the ORIGINAL and EDITED nap windows: `editNap` keeps `healthWritten == true`
    /// and does NOT re-mirror, so the actual Health sample may sit at the original `start…end` even
    /// after the displayed window moved to `editedStart…editedEnd`. Excluding both covers wherever the
    /// sample actually is.
    func healthWrittenNapWindows(overlapping start: Date, to end: Date,
                                 manualOnly: Bool = false) -> [DateInterval] {
        let naps = (try? context.fetch(FetchDescriptor<StoredNap>())) ?? []
        return naps.compactMap { nap in
            guard nap.healthWritten else { return nil }
            if manualOnly, !nap.isManuallyAdded, !nap.isManuallyEdited { return nil }
            let lo = min(nap.start, nap.effectiveStart)
            let hi = max(nap.end, nap.effectiveEnd)
            guard hi > lo, lo < end, hi > start else { return nil }
            return DateInterval(start: lo, end: hi)
        }
    }

    /// Advance the Health watermark past the newest written sample per kind.
    func markHealthWritten(_ samples: [QuantitySample]) throws {
        guard !samples.isEmpty else { return }
        var cursor = try loadHealthCursor()
        _ = cursor.selectNew(samples)   // advances per kind to the newest start
        for kind in Self.healthMirroredKinds {
            guard let last = cursor.last(kind) else { continue }
            upsertCursor(kind: Self.healthCursorPrefix + kind.rawValue, last: last)
        }
        try context.save()
    }

    /// Health watermark, read from the `hk:`-prefixed cursor rows (keyed by bare kind).
    private func loadHealthCursor() throws -> SyncCursor {
        let rows = try context.fetch(FetchDescriptor<StoredCursor>())
        var map: [String: Date] = [:]
        for r in rows where r.kindRaw.hasPrefix(Self.healthCursorPrefix) {
            map[String(r.kindRaw.dropFirst(Self.healthCursorPrefix.count))] = r.last
        }
        return SyncCursor(lastByKind: map)
    }

    // MARK: Export watermark ("only the sessions I haven't exported yet")
    //
    // A third watermark in the same `StoredCursor` table, under an `export:` prefix — mirroring the
    // `hk:` convention above, so no new table and no schema migration. FORWARD-ONLY like every other
    // cursor here: moving it backward would silently re-offer nights the user already exported, and a
    // watermark that can regress is not a watermark.

    private static let exportCursorPrefix = "export:"
    /// The export NIGHT watermark row. The prefix is what keeps it out of `storeCursorRows` (and
    /// therefore out of the ingest `SyncCursor`), exactly as the `hk:` rows are kept out.
    private static let exportSessionsCursorKey = exportCursorPrefix + "sleepSessions"
    /// The export CONTENT watermark row: the instant the last committed export READ its rows.
    ///
    /// The night watermark alone answers "which nights have I seen", which is the wrong question —
    /// a night keeps growing after it is first exported (the ring hands the rest off hours later,
    /// #187/#188; the diagnostics repair widens one days later; a manual edit rewrites it whenever).
    /// Because the night watermark is forward-only and single-valued, a night that grew after being
    /// consumed could never be re-offered and the automated archive would keep only the truncated
    /// version. Comparing `StoredSleepSummary.updatedAt` against this second watermark catches every
    /// one of those rewrites — `updatedAt` is bumped by all of them.
    private static let exportContentCursorKey = exportCursorPrefix + "sleepSessions.content"

    /// End of the newest sleep session already exported, or nil before any export has been written.
    func lastExportWatermark() -> Date? {
        let key = Self.exportSessionsCursorKey
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return try? context.fetch(descriptor).first?.last
    }

    /// When the last committed export read its rows, or nil before any export has been written.
    /// A summary whose `updatedAt` is later than this changed after that file was produced.
    func lastExportContentWatermark() -> Date? {
        let key = Self.exportContentCursorKey
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return try? context.fetch(descriptor).first?.last
    }

    /// Advance the export watermarks. BOTH are FORWARD-ONLY: an earlier (or equal) date is a no-op,
    /// not a regression, and they advance INDEPENDENTLY — a payload that consumed no settled night
    /// still recorded which content it carried, and blocking that on the night watermark would leave
    /// a re-offered older night re-offered forever. Call it only AFTER the export file is durably
    /// written — the same advance-after-a-durable-write ordering the ingest cursor uses (#22), so a
    /// failed write leaves those sessions pending instead of marking them exported into a file that
    /// doesn't exist.
    func markExported(through: Date, contentAsOf: Date? = nil) throws {
        var dirty = false
        if advanceExportCursor(key: Self.exportSessionsCursorKey, to: through) { dirty = true }
        if let contentAsOf,
           advanceExportCursor(key: Self.exportContentCursorKey, to: contentAsOf) { dirty = true }
        if dirty { try context.save() }
    }

    /// Forward-only upsert of one `export:` cursor. Returns whether it actually moved.
    private func advanceExportCursor(key: String, to date: Date) -> Bool {
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        let existing = (try? context.fetch(descriptor).first?.last) ?? nil
        guard (existing ?? .distantPast) < date else { return false }
        upsertCursor(kind: key, last: date)
        return true
    }

    // MARK: Sleep summary + daily steps (offline dashboard, separate from `ingest`)

    /// Upsert the nightly sleep summary, keyed by start-of-day of `night`. Re-syncing the
    /// same night overwrites the existing row rather than inserting a duplicate. Does NOT
    /// touch the SyncCursor — gating sleep history for HealthKit stays in the `.sleep`
    /// watermark (`pendingHealthSleep`/`markSleepWritten`).
    /// The Wave-1 analytics computed for a night alongside the stage totals (#69/#70/#71). All
    /// optional — a value left at its default means "not computed" and the upsert leaves any
    /// existing value untouched isn't needed (these are recomputed each sync), but `feelScore`
    /// IS preserved across re-syncs since it's user-entered, not derived.
    struct SleepNightExtras {
        var skinTempC: Double = 0
        var sleepScore: Int = 0
        var stressScore: Int = 0
        var hrByStage: [SleepStage: Int] = [:]
        var movementLevels: [Int] = []
        /// The staged segments the stage minutes were rolled up FROM. Travels with the summary so both
        /// are written by the same call — see `applyExtras`.
        var hypnogram: [SleepSegment] = []
    }

    /// Compact local timestamp for observability breadcrumbs (never user-facing, never a health
    /// value — just enough to identify a night in a diagnostics bundle).
    private static let breadcrumbFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func stamp(_ date: Date) -> String { breadcrumbFormatter.string(from: date) }

    /// Latch for the one-shot night-key migration. Read by `App` too, so both entry points share it.
    static let nightRekeyDoneKey = "store.rekeyedSleepNightsToWakeDay.v1"

    enum StoreError: Error {
        /// The night-key migration has not succeeded yet, so a sleep write under the new key scheme
        /// would split a night across two rows. Deferred, not lost — see `ensureNightKeyMigrated`.
        case nightKeyMigrationPending
        /// The migration found the store in a shape it will not touch (two rows normalising to one
        /// calendar day, or its own occupancy bookkeeping tripping). Nothing was changed. THROWN
        /// rather than returned so the caller cannot mistake "refused to run" for "ran successfully"
        /// and latch the one-way done-flag over an unmigrated table.
        case nightKeyMigrationUnsafe
    }

    /// Run the night-key migration if it hasn't run yet.
    ///
    /// ⚠️ THIS IS THE REAL CHOKEPOINT, and it is not optional. The migration used to be wired ONLY
    /// to a SwiftUI `.task` on `ContentView` — i.e. only on a launch where a scene connects. But
    /// iOS creates the App instance for a BGTask / CoreBluetooth-restoration launch WITHOUT ever
    /// connecting a scene (App.swift says so in as many words), and that launch drains the ring and
    /// writes sleep summaries. So the very first write under the NEW key could land before any
    /// migration, inserting a SECOND row for a night whose un-migrated row still sits under the old
    /// key — with the user's manual edit, feelScore and OSA fields stranded on the row the card no
    /// longer shows. The later foreground migration would then find the destination occupied,
    /// refuse the move, and latch the flag: the split becomes permanent.
    ///
    /// Every sleep-summary write passes through `saveSleepSummary`, so gating it here closes the
    /// window for foreground, BGTask and restoration launches alike. The launch `.task` stays as the
    /// path that migrates history on a launch where no sleep is written at all.
    /// Returns whether the store is now on the new key scheme. A `false` return means the migration
    /// FAILED this attempt and the table is still on old keys.
    ///
    /// ⚠️ A FAILED MIGRATION MUST BLOCK THE WRITE, not just be retried later. Swallowing the error
    /// and writing anyway files the summary under the NEW key while all of history is still on the
    /// OLD one — which, for a night already stored from an earlier drain, inserts a SECOND row. The
    /// later successful migration then finds that destination occupied, refuses the move, and
    /// latches the flag: the split becomes permanent, with the user's manual edit, feelScore and OSA
    /// fields stranded on the row the card no longer shows. Deferring one drain is recoverable — the
    /// epochs are still in the ring's 30 h archive and the next drain re-stages them. A split row is
    /// not recoverable.
    @discardableResult
    func ensureNightKeyMigrated() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.nightRekeyDoneKey) else { return true }
        do {
            let outcome = try rekeySleepNightsToWakeDay()
            // ⚠️ ONLY LATCH ON A STORE THAT ACTUALLY HELD ROWS. `store.rekeyedSleepNightsToWakeDay.v1`
            // lives in UserDefaults while the rows live in SwiftData, and the two can be built over
            // DIFFERENT stores: on a pre-first-unlock background launch `resolveContainer` falls back
            // to an in-memory throwaway container (#131), which is empty by construction. Latching
            // against that would mark a store "migrated" that was never even opened — UserDefaults
            // survives the relaunch, so the real history would stay on old keys forever while every
            // new night is written on the new scheme. An empty real store has nothing to migrate
            // either, and re-checking it costs one fetch per launch until it has a row.
            guard outcome.examined > 0 else { return true }
            UserDefaults.standard.set(true, forKey: Self.nightRekeyDoneKey)
            return true
        } catch {
            // Visible in a diagnostics bundle rather than silent — a failed migration that blocks
            // sleep writes must be diagnosable from the tester's export alone.
            ObservabilityStore().recordMetricEvent(
                source: "sleep-rekey",
                detail: "FAILED \(error) — sleep writes deferred until the migration succeeds")
            return false
        }
    }

    /// The stored row this staging belongs to: by in-bed OVERLAP first (identity), then by calendar
    /// bucket (index). See the call site for why the order matters.
    private func resolveSleepRow(dayStart: Date, inBedStart: Date, inBedEnd: Date) -> StoredSleepSummary? {
        if inBedEnd > inBedStart,
           let overlapping = try? sleepSummaryOverlapping(start: inBedStart, end: inBedEnd) {
            return overlapping
        }
        let descriptor = FetchDescriptor<StoredSleepSummary>(predicate: #Predicate { $0.night == dayStart })
        return try? context.fetch(descriptor).first
    }

    /// Move a row that was resolved by span onto the key its current staging says it belongs to.
    ///
    /// Best-effort and strictly non-destructive: refused outright if another row already holds the
    /// destination, or if any night-scoped overlay could not move with it. `@Attribute(.unique)` does
    /// NOT protect this — a duplicate key makes `save()` succeed and silently destroy one row (see
    /// `rekeySleepNightsToWakeDay`) — so the occupancy check here is the only guard there is. A row
    /// left on its first-slice key is merely indexed a day off; a deleted row is unrecoverable.
    private func realignNightKey(of row: StoredSleepSummary, to dayStart: Date) {
        let occupiedDescriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night == dayStart })
        guard ((try? context.fetch(occupiedDescriptor).first) ?? nil) == nil else { return }
        let oldKey = Calendar.current.startOfDay(for: row.night)
        guard canRenameNightScopedOverlays(from: oldKey, to: dayStart),
              (try? renameNightScopedOverlays(from: oldKey, to: dayStart)) != nil else { return }
        row.night = dayStart
        ObservabilityStore().recordMetricEvent(
            source: "sleep-rekey",
            detail: "REALIGNED night=\(Self.stamp(oldKey)) -> \(Self.stamp(dayStart)) "
                + "reason=night-resolved-by-span-grew-past-midnight")
    }

    /// Store (or deliberately decline to store) a night's summary.
    ///
    /// Returns WHICH of its branches ran (#204). Every `return` below used to be indistinguishable
    /// from a successful write at the call site — three of them logged nothing at all — so a wearer
    /// could end a night with no stored row, no error and a Sleep card happily rendering live
    /// staging. The outcome is the caller's signal; the metric events are the tester's.
    @discardableResult
    func saveSleepSummary(_ summary: SleepStaging.Summary, night: Date,
                          inBedStart: Date, inBedEnd: Date,
                          sleepOnset: Date = .distantPast, sleepWake: Date = .distantPast,
                          extras: SleepNightExtras = SleepNightExtras()) throws -> SleepPersistOutcome {
        // Before the FIRST write under the new key — see `ensureNightKeyMigrated`. A failed
        // migration DEFERS the write rather than filing it under a scheme the rest of the table has
        // not adopted; the epochs survive in the archive and the next drain re-stages them.
        guard ensureNightKeyMigrated() else { throw StoreError.nightKeyMigrationPending }
        let dayStart = Calendar.current.startOfDay(for: night)
        let m = summary.minutes
        // ⚠️ IDENTITY IS THE SPAN; THE KEY IS ONLY AN INDEX. Resolve by in-bed OVERLAP before falling
        // back to the calendar bucket, because a night can legitimately produce two different keys as
        // it grows. `isOvernightBlock` accepts any block whose midpoint is in [21:00, 09:00), so an
        // evening drain that completes before midnight stages a pre-midnight-only partial keyed to
        // TODAY, while the same night's completed staging hours later is keyed TOMORROW. Bucket-only
        // resolution files those as two rows — a permanent 1 h 30 m phantom night alongside the real
        // one, double-counted in Trends, the goal rings and every export. (Under the old
        // start-anchored key both keyed to the same day and the merge healed it, so this regression
        // would have been INTRODUCED by end-anchoring.) Overlap resolution heals it instead: the
        // completed night finds the partial's row and grows it, exactly as it always did.
        let existingRow = resolveSleepRow(dayStart: dayStart, inBedStart: inBedStart, inBedEnd: inBedEnd)
        if let existing = existingRow {
            // ⚠️ COLLISION GUARD — applies to EDITED AND UNEDITED ROWS ALIKE.
            //
            // A night silently ate another night on a real device (2026-08-08): under the old
            // start-anchored key two consecutive nights collided, the stored one was manually
            // edited, and the incoming 9 h night hit the preserve-the-edit return below — no row, no
            // log, no metric, and permanently, since every retry hit it again. `SleepNightKey` fixes
            // that particular collision, but changing the key does not make collisions impossible:
            // it changes WHICH pattern collides (two blocks ENDING on one day instead of two
            // STARTING on one day). `SleepWindow.isOvernightBlock` accepts a block whose midpoint is
            // in [21:00, 09:00), so an evening drain that completes before midnight stages a partial
            // that keys to TODAY — which is last night's key.
            //
            // On an UNEDITED row that case is worse than the edited one, because the merge below
            // decides purely on totals: a 110-minute evening fragment "wider" than a truncated 60-
            // minute stored night would REPLACE it outright, hypnogram and all. So the window test
            // is hoisted above both branches and refuses the write either way.
            //
            // Only applied when BOTH windows are known — legacy rows predating the in-bed columns
            // carry `.distantPast` edges, and those must keep falling through to the merge as before
            // rather than being refused on a comparison that means nothing.
            //
            // The test allows ABUTTING windows (`>=` plus one epoch of slack): two halves of one
            // night handed off separately can meet exactly on an epoch boundary, and a strict `>`
            // would call those disjoint and throw the second half away.
            //
            // ⚠️ A DISJOINT WINDOW IS NOT AUTOMATICALLY A DIFFERENT NIGHT, and refusing every
            // non-overlap would itself lose data. A night handed off in two pieces with the middle
            // missing (the documented #188 late-handoff) produces two disjoint blocks that BOTH end
            // in the morning — before this guard existed, `SleepSummaryMerge` kept the fuller one,
            // and it must keep doing so. What actually distinguishes the case this guard was written
            // for is that the intruder ends in the EVENING: `isOvernightBlock` accepts a midpoint in
            // [21:00, 09:00), so a pre-midnight-only block keys to today and contends with the night
            // that genuinely ended this morning. So refuse only when the incoming block does NOT end
            // in the wake window while the stored one does — the key names the morning you woke into.
            // Everything else falls through to the completeness merge exactly as it always did.
            let bothWindowsKnown = existing.inBedEnd > existing.inBedStart && inBedEnd > inBedStart
            let slack = TimeInterval(BulkRecord.epochSeconds)
            let overlaps = min(existing.inBedEnd, inBedEnd) + slack >= max(existing.inBedStart, inBedStart)
            let incomingIsAnUnfinishedEveningBout =
                !SleepNightKey.endsInWakeWindow(inBedEnd)
                && SleepNightKey.endsInWakeWindow(existing.inBedEnd)
            if bothWindowsKnown, !overlaps, incomingIsAnUnfinishedEveningBout {
                let detail = "night=\(Self.stamp(dayStart)) kept=[\(Self.stamp(existing.inBedStart))..\(Self.stamp(existing.inBedEnd))] "
                    + "DISCARDED=[\(Self.stamp(inBedStart))..\(Self.stamp(inBedEnd))] "
                    + "edited=\(existing.isManuallyEdited) reason=night-key-collision"
                ObservabilityStore().recordMetricEvent(source: "sleep-drop", detail: detail)
                return .refusedNightKeyCollision
            }
            // A manually edited night (#176) is authoritative: a later re-sync must not overwrite the
            // user's window/durations. Preserve it. The raw epoch archive still holds the original
            // staging, so the edit stays reversible by re-editing. Reaching here means the incoming
            // staging genuinely overlaps the edited night, which is the case this guard is FOR.
            if existing.isManuallyEdited {
                // …but the ±3 h edit clamp anchors on the RECORDED window, and freezing that with
                // the minutes trapped a tester in a wrong wake she could never correct
                // (🟢 2026-08-16 — see `SleepEdit.widenRecorded`). Record this fuller staging into
                // the WIDENED-RECORDED overlay columns (outward-only) so the clamp can grow.
                // Deliberately NOT the frozen `inBedStart…sleepWake` columns — Health bookkeeping
                // reads those as "what the ordinary flush wrote", and this drain wrote nothing
                // (see the overlay columns' comment). Minutes/hypnogram stay the user's.
                var widenedDetail = ""
                if let w = SleepEdit.widenRecorded(
                    stored: existing.sleepEditClampWindow,
                    incoming: .init(inBedStart: inBedStart, inBedEnd: inBedEnd,
                                    sleepOnset: sleepOnset, sleepWake: sleepWake)) {
                    existing.widenedRecordedInBedStart = w.inBedStart
                    existing.widenedRecordedInBedEnd = w.inBedEnd
                    existing.widenedRecordedOnset = w.sleepOnset
                    existing.widenedRecordedWake = w.sleepWake
                    existing.updatedAt = Date()
                    widenedDetail = " clampWidened=[\(Self.stamp(w.inBedStart))..\(Self.stamp(w.inBedEnd))]"
                }
                // Breadcrumb BEFORE the save so a save throw can't lose the kept=MANUAL-EDIT trace.
                ObservabilityStore().recordMetricEvent(
                    source: "sleep-drop",
                    detail: "night=\(Self.stamp(dayStart)) kept=MANUAL-EDIT "
                        + "incoming=[\(Self.stamp(inBedStart))..\(Self.stamp(inBedEnd))] asleep=\(m.asleep)"
                        + widenedDetail)
                if !widenedDetail.isEmpty { try context.save() }
                return .keptManualEdit
            }
            // Non-destructive upsert. A night can be drained in MORE THAN ONE piece (e.g. a
            // background drain mid-night, then the foreground morning sync) — the ring hands off
            // un-delivered history incrementally, so each drain stages only its own slice. Blindly
            // overwriting let a later, SHORTER slice clobber a fuller capture already stored for this
            // date (a 4 h fragment replacing a full night). Replace only when the new staging is at
            // least as complete (wider in-bed span); otherwise keep the fuller stored night untouched.
            // Non-regressive vs. blind overwrite; truly stitching two disjoint partials into one night
            // (and the periodic overnight draining that needs it) is a follow-up that requires
            // per-epoch persistence. See OpenCircuitKit/SleepSummaryMerge.
            let storedSpan = existing.inBedEnd > existing.inBedStart
                ? existing.inBedEnd.timeIntervalSince(existing.inBedStart) : 0
            let newSpan = inBedEnd > inBedStart ? inBedEnd.timeIntervalSince(inBedStart) : 0
            // A classifier refinement can legitimately turn formerly-asleep quiet wake into
            // awake-in-bed while using the exact same archived coverage. Treat matching boundaries
            // (within one ring epoch) as a reclassification, not as a thinner fragment; otherwise the
            // old, larger asleep total would be merge-protected forever after an onset fix ships.
            let epochTolerance = TimeInterval(BulkRecord.epochSeconds)
            let sameCoverage = storedSpan > 0 && newSpan > 0
                && abs(existing.inBedStart.timeIntervalSince(inBedStart)) <= epochTolerance
                && abs(existing.inBedEnd.timeIntervalSince(inBedEnd)) <= epochTolerance
            // Completeness is judged on time ASLEEP (span is a fallback): a later, shorter slice — or a
            // wide window padded with awake — can't shrink a fuller night. See SleepSummaryMerge.
            guard SleepSummaryMerge.shouldReplace(
                storedInBed: storedSpan, newInBed: newSpan,
                storedAsleep: TimeInterval(existing.asleepMin) * 60,
                newAsleep: TimeInterval(m.asleep) * 60,
                sameCoverage: sameCoverage) else {
                // Keep the fuller existing night (its window, stages, extras + feelScore). NAMED,
                // not silent (#204) — but deliberately without a metric event of its own: this is
                // the most common outcome of all (every periodic re-drain of a settled night hits
                // it), and the caller's single `sleep-persist` event already carries the name. A
                // second event here would triple the metric log's fill rate and evict the rarer
                // breadcrumbs (`sleep-rekey`, `sleep-drop`, `archive-repair`) that testers need.
                //
                // …but the clamp anchors must still grow. This is the SAME defect the
                // `keptManualEdit` branch above was fixed for on 2026-08-16, sitting unfixed in the
                // sibling branch nobody checked: discarding the fuller staging's MINUTES is
                // correct, freezing the RECORDED WINDOW the edit clamp anchors on is not.
                //
                // 🟢 2026-08-22, measured on a Gen 2 Air tester's night. Her second drain, 13
                // minutes after the first, carried the last 10 minutes of the night
                // (02:21:51..02:31:51). Re-staging with them yields 108 asleep-min against the
                // stored 112 — that tail genuinely reads awake — so `shouldReplace` correctly
                // refused. The row then kept `inBedEnd = 02:08:51` even though the app holds epochs
                // through 02:33:51, and her edit clamp is anchored on that frozen edge.
                //
                // Outward-only, so it can only ever widen what an edit may reach. It writes the
                // OVERLAY columns for the same reason the branch above does: the frozen
                // `inBedStart…sleepWake` columns are Health's "what the ordinary flush wrote"
                // bookkeeping, and this drain wrote nothing. The event fires ONLY when a widen
                // actually happened — rare — so the fill-rate reasoning above still holds.
                if let w = SleepEdit.widenRecorded(
                    stored: existing.sleepEditClampWindow,
                    incoming: .init(inBedStart: inBedStart, inBedEnd: inBedEnd,
                                    sleepOnset: sleepOnset, sleepWake: sleepWake)) {
                    existing.widenedRecordedInBedStart = w.inBedStart
                    existing.widenedRecordedInBedEnd = w.inBedEnd
                    existing.widenedRecordedOnset = w.sleepOnset
                    existing.widenedRecordedWake = w.sleepWake
                    existing.updatedAt = Date()
                    ObservabilityStore().recordMetricEvent(
                        source: "sleep-drop",
                        detail: "night=\(Self.stamp(dayStart)) kept=FULLER "
                            + "incoming=[\(Self.stamp(inBedStart))..\(Self.stamp(inBedEnd))] "
                            + "asleep=\(m.asleep) "
                            + "clampWidened=[\(Self.stamp(w.inBedStart))..\(Self.stamp(w.inBedEnd))]")
                    try context.save()
                }
                return .keptFullerStoredNight
            }
            // Only NOW — every early return above is behind us, so this reaches `context.save()`.
            // A row resolved by SPAN may still be filed under the key its first slice produced; move
            // it onto the key this fuller staging says it belongs to. Deliberately not done at
            // resolution time: `realignNightKey` commits the UserDefaults overlay moves immediately
            // (UserDefaults has no rollback), so running it on a path that then returns early would
            // leave the overlays on the new key while the row stayed on the old one.
            if Calendar.current.startOfDay(for: existing.night) != dayStart {
                realignNightKey(of: existing, to: dayStart)
            }
            existing.asleepMin = m.asleep
            existing.deepMin = m.deep
            existing.lightMin = m.light
            existing.remMin = m.rem
            existing.awakeMin = m.awake
            existing.efficiency = summary.efficiency
            existing.inBedStart = inBedStart
            existing.inBedEnd = inBedEnd
            existing.sleepOnset = sleepOnset
            existing.sleepWake = sleepWake
            existing.updatedAt = Date()
            applyExtras(extras, to: existing)   // feelScore deliberately preserved
        } else {
            let row = StoredSleepSummary(
                night: dayStart,
                asleepMin: m.asleep,
                deepMin: m.deep,
                lightMin: m.light,
                remMin: m.rem,
                awakeMin: m.awake,
                efficiency: summary.efficiency,
                inBedStart: inBedStart,
                inBedEnd: inBedEnd,
                sleepOnset: sleepOnset,
                sleepWake: sleepWake
            )
            applyExtras(extras, to: row)
            context.insert(row)
        }
        try context.save()
        // The night just grew (or appeared) over this span — any AUTO-detected nap inside it is now
        // the same sleep counted twice (🟢 2026-08-16: a split night's 09:04–10:30 tail was stored
        // as an 86-min nap; once scoping re-absorbs the tail, night + nap overlap). Manual naps are
        // the user's word and stay. Deleting the row is also what heals Apple Health: the mirrors'
        // nap-safe delete exclusions come from `healthWrittenNapWindows` (Health-written STORED
        // naps), so once the row is gone the next `mirrorSettledNight` union-delete sweeps the nap's
        // samples out of the span the fresh night write covers.
        pruneAutoNaps(overlapping: inBedStart, inBedEnd, night: dayStart)
        return existingRow == nil ? .inserted : .updated
    }

    /// Auto-detected (non-manual) naps whose effective window overlaps `[start, end]`. The
    /// edited-night reconcile uses this to find naps the USER's edited window absorbed — those must
    /// be swept from Apple Health BEFORE their rows are deleted (the row is the only record the
    /// samples exist), so the row deletion is the CALLER's second step, not part of this read.
    func autoNaps(overlapping start: Date, to end: Date) -> [StoredNap] {
        guard end > start else { return [] }
        let naps = (try? context.fetch(FetchDescriptor<StoredNap>())) ?? []
        return naps.filter { nap in
            guard !nap.isManuallyAdded, !nap.isManuallyEdited else { return false }
            let lo = min(nap.start, nap.effectiveStart)
            let hi = max(nap.end, nap.effectiveEnd)
            return hi > lo && lo < end && hi > start
        }
    }

    /// Delete specific nap rows (after their Health samples were handled). Best-effort save; a
    /// failure leaves the rows for the next sweep.
    func deleteNaps(_ rows: [StoredNap], reason: String, night: Date? = nil) {
        guard !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        do { try context.save() } catch { context.rollback(); return }
        let nightDetail = night.map { " night=\(Self.stamp($0))" } ?? ""
        ObservabilityStore().recordMetricEvent(source: "nap-prune",
                                               detail: "removed=\(rows.count) reason=\(reason)" + nightDetail)
    }

    /// Delete auto-detected (non-manual) naps whose effective window overlaps `[start, end]` — a
    /// stored night now covers that sleep. Best-effort: a fetch/save failure leaves the naps for the
    /// next night write to prune. The pruned naps' Health samples are swept by the NEXT
    /// `mirrorSettledNight` of this just-written night (its union-delete stops excluding windows
    /// `healthWrittenNapWindows` no longer reports); the night was written one line above this call,
    /// so that mirror is on the very next flush — the orphan window is one flush cycle, not open-ended.
    private func pruneAutoNaps(overlapping start: Date, _ end: Date, night: Date) {
        guard end > start else { return }
        let naps = (try? context.fetch(FetchDescriptor<StoredNap>())) ?? []
        var removed = 0
        for nap in naps where !nap.isManuallyAdded && !nap.isManuallyEdited {
            let lo = min(nap.start, nap.effectiveStart)
            let hi = max(nap.end, nap.effectiveEnd)
            guard hi > lo, lo < end, hi > start else { continue }
            context.delete(nap)
            removed += 1
        }
        guard removed > 0 else { return }
        do { try context.save() } catch { context.rollback(); return }
        ObservabilityStore().recordMetricEvent(
            source: "nap-prune",
            detail: "night=\(Self.stamp(night)) removed=\(removed) span=[\(Self.stamp(start))..\(Self.stamp(end))]")
    }

    private func applyExtras(_ extras: SleepNightExtras, to row: StoredSleepSummary) {
        // 0 = "not computed this pass" — keep any previously stored value rather than wiping it
        // (a quick daytime live-read might re-stage the night with no temp/HRV coverage).
        if extras.skinTempC > 0 { row.skinTempC = extras.skinTempC }
        if extras.sleepScore > 0 { row.sleepScore = extras.sleepScore }
        if extras.stressScore > 0 { row.stressScore = extras.stressScore }
        if let v = extras.hrByStage[.asleepDeep] { row.hrDeep = v }
        if let v = extras.hrByStage[.asleepCore] { row.hrLight = v }
        if let v = extras.hrByStage[.asleepREM] { row.hrRem = v }
        if let v = extras.hrByStage[.awake] { row.hrAwake = v }
        if !extras.movementLevels.isEmpty { row.movementLevels = extras.movementLevels }
        // Deliberately NOT keep-if-empty like the values above: the caller just wrote this row's stage
        // MINUTES from `extras.hypnogram`, so retaining an older night's segments here would leave a
        // row whose timeline and whose minutes came from two different captures — a divergence no
        // consumer could detect. Empty in ⇒ empty stored ("not recorded"), which is honest.
        row.hypnogramData = SleepHypnogramCodec.encode(extras.hypnogram)
        // THE RING'S OWN READING, kept where an edit cannot reach it. `applySleepEdit` overwrites
        // `hypnogramData` in place, so before this line existed a single edit destroyed the
        // recording permanently (🟢 R2_2026-08-17: 102.5 min of 97.6 %-covered sleep, 30 min of it
        // deep). This is the ONLY writer of the column — the edit path must never touch it.
        row.recordedHypnogramData = row.hypnogramData
        // A staged row is all-measured by construction, so state the split rather than leaving the
        // columns at their "not computed" sentinel. `SleepStaging.classify` emits only `.measured`
        // segments; the audit measured the ordinary path at 22.4 asserted asleep-minutes across all
        // 21 staged corpus nights, so there is nothing here to withhold.
        let staged = SleepProvenanceBreakdown(segments: extras.hypnogram)
        row.measuredAsleepSeconds = staged.measuredAsleep
        row.assertedAsleepSeconds = staged.assertedAsleep
        row.coverageFraction = extras.hypnogram.isEmpty ? -1 : staged.coverageFraction
        row.longestGapSeconds = extras.hypnogram.isEmpty ? -1 : staged.longestUnmeasuredGap
        row.measuredEfficiency = extras.hypnogram.isEmpty ? -1 : (staged.efficiency ?? -1)
        row.sleepBasis = extras.hypnogram.isEmpty ? "" : SleepBasis.measuredOnly.rawValue
    }

    /// ONE-SHOT BACKFILL for the reversibility columns. Runs after the container opens, never inside
    /// the migration, so a failure here cannot take the store down (the build-44 wipe is what that
    /// rule is for).
    ///
    /// ⚠️ HONEST ABOUT WHAT IT CANNOT RECOVER. `recordedHypnogramData` is filled from `hypnogramData`
    /// ONLY where `isManuallyEdited == false`, because those rows are still pure recordings. For a
    /// row that was ALREADY EDITED the recording is ALREADY DESTROYED — `applySleepEdit` overwrote
    /// the single column, and nothing anywhere holds the ring's version. Those rows are stamped
    /// `unknown` and left empty. We must never present an edit's output as "what the ring recorded".
    ///
    /// Idempotent: a row that already has a recorded hypnogram or a basis stamp is skipped, so
    /// running it on every launch is free and re-running it can never overwrite a real value.
    /// Returns the number of rows it changed, for the diagnostics bundle.
    @discardableResult
    func backfillSleepProvenance() -> Int {
        let rows = (try? context.fetch(FetchDescriptor<StoredSleepSummary>())) ?? []
        var changed = 0
        for row in rows {
            guard SleepBasis(stored: row.sleepBasis) == .unknown else { continue }
            // AN ALREADY-EDITED LEGACY ROW IS LEFT EXACTLY AS IT IS, deliberately. Its
            // `hypnogramData` is edit OUTPUT — `applySleepEdit` overwrote the single column before
            // `recordedHypnogramData` existed — so copying it into the recorded slot would fabricate
            // a "recording" that never happened, and computing a split from it would report the
            // invented minutes as measured. It keeps the `.unknown` stamp, which is the true answer:
            // this row cannot say what it measured, and nothing may claim otherwise on its behalf.
            if row.isManuallyEdited { continue }
            guard !row.hypnogramData.isEmpty else { continue }
            if row.recordedHypnogramData.isEmpty { row.recordedHypnogramData = row.hypnogramData }
            let segs = SleepHypnogramCodec.decode(row.hypnogramData)
            let b = SleepProvenanceBreakdown(segments: segs)
            row.measuredAsleepSeconds = b.measuredAsleep
            row.assertedAsleepSeconds = b.assertedAsleep
            row.coverageFraction = b.coverageFraction
            row.longestGapSeconds = b.longestUnmeasuredGap
            row.measuredEfficiency = b.efficiency ?? -1
            row.sleepBasis = SleepBasis.measuredOnly.rawValue
            changed += 1
        }
        if changed > 0 { try? context.save() }
        return changed
    }

    /// Nights whose Apple Health record still holds sleep this app invented over unmeasured ground —
    /// the RETRACTION list.
    ///
    /// Invented blocks already written to testers' phones are recoverable because edited nights are
    /// UUID-tracked (`writeReturningSleepUUIDs` -> `SleepEditHealthSampleOverlay` ->
    /// `reconcileEditedNightSleep`), so this returns the nights a one-shot reconcile should re-run.
    /// A row qualifies when it is edited AND its stored hypnogram now carries asserted time — i.e.
    /// only nights re-saved under provenance. Legacy `unknown` rows are deliberately NOT retracted:
    /// we cannot tell which of their minutes were invented, and deleting a user's Health sleep on a
    /// guess is exactly the kind of destructive act this whole change exists to stop.
    func nightsNeedingHealthRetraction() -> [Date] {
        let rows = (try? context.fetch(FetchDescriptor<StoredSleepSummary>())) ?? []
        return rows.compactMap { row in
            guard row.isManuallyEdited,
                  SleepBasis(stored: row.sleepBasis) == .assertedTagged,
                  SleepHypnogramCodec.decode(row.hypnogramData).containsAssertedTime
            else { return nil }
            return row.night
        }
    }

    /// Attach a decoded OSA SpO₂ summary (#91) to the most recent night's stored summary. The
    /// `0x48` assessment burst finalizes ~5 s AFTER the `0x4c` sleep drain, so the night's row
    /// already exists — we update it in place rather than routing through `saveSleepSummary`.
    /// No-op if the summary has no valid windows or there's no stored night yet. Returns whether it
    /// was applied. `updatedAt` is bumped so the `@Query`-backed card refreshes.
    @discardableResult
    func applyOSASummary(_ osa: OSASpO2.NightSummary) -> Bool {
        guard osa.validWindows > 0, let row = try? latestSleepSummary() else { return false }
        row.osaAvgSpO2 = osa.averageSpO2
        row.osaMinSpO2 = osa.minSpO2
        row.osaTimeBelow90Sec = osa.timeBelow90Seconds
        row.osaODI = osa.odi
        row.osaValidWindows = osa.validWindows
        row.updatedAt = Date()
        try? context.save()
        return true
    }

    /// Most recent stored sleep summary (latest night), or nil.
    func latestSleepSummary() throws -> StoredSleepSummary? {
        var descriptor = FetchDescriptor<StoredSleepSummary>(
            sortBy: [SortDescriptor(\.night, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Trailing sleep summaries (latest first), for the rolling skin-temp baseline (#69) and
    /// any short-window trend. Bounded so it never scans the whole table.
    func recentSleepSummaries(limit: Int = 40) throws -> [StoredSleepSummary] {
        try context.fetch(Self.recentSleepSummariesDescriptor(limit: limit))
    }

    /// Sleep summaries whose `night` bucket falls within `[from, to)`, oldest first.
    func sleepSummaries(from: Date, to: Date) throws -> [StoredSleepSummary] {
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night >= from && $0.night < to },
            sortBy: [SortDescriptor(\.night, order: .forward)])
        return try context.fetch(descriptor)
    }

    func sleepSummary(night: Date) throws -> StoredSleepSummary? {
        let dayStart = Calendar.current.startOfDay(for: night)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night == dayStart })
        return try context.fetch(descriptor).first
    }

    /// The stored staged hypnogram for `night`, or `[]` when the night isn't stored, was staged before
    /// the column existed, or holds an unreadable blob. Non-throwing on purpose: the hypnogram is an
    /// export/display nicety, and one bad night must not abort a whole multi-night export
    /// (`SleepHypnogramCodec.decode` never throws and never fabricates a segment either).
    func hypnogram(night: Date) -> [SleepSegment] {
        guard let row = try? sleepSummary(night: night) else { return [] }
        return SleepHypnogramCodec.decode(row.hypnogramData)
    }

    /// The stored summary whose IN-BED window best overlaps `[start, end]`. Used by the Health mirror
    /// to resolve the night by its actual span rather than `startOfDay(firstSegmentStart)` — a bedtime
    /// that straddles midnight (or a lead-in trim that moves the earliest start across it) can otherwise
    /// key the mirror to a different calendar day than the summary the card shows, letting the mirror
    /// miss a manually-edited row or under-scope its cleanup. Prefers the row with the largest overlap.
    func sleepSummaryOverlapping(start: Date, end: Date) throws -> StoredSleepSummary? {
        guard end > start else { return nil }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        var best: (row: StoredSleepSummary, overlap: TimeInterval)?
        for row in rows {
            guard row.inBedEnd > row.inBedStart else { continue }
            let lo = max(start, row.inBedStart)
            let hi = min(end, row.inBedEnd)
            let overlap = hi.timeIntervalSince(lo)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (row, overlap) }
        }
        return best?.row
    }

    /// Persist the user's subjective sleep rating (1–9, #70) onto an existing night. No-op if
    /// the night isn't in the store yet (a rating only makes sense once a night exists).
    func setFeelScore(_ score: Int, night: Date) throws {
        let dayStart = Calendar.current.startOfDay(for: night)
        let descriptor = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night == dayStart })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.feelScore = max(0, min(score, 9))
        row.updatedAt = Date()
        try context.save()
    }

    /// Apply a manual sleep-time edit (#176) to an existing night: persist the edited in-bed window
    /// overlay and the recomputed durations/stages/efficiency/score. Non-destructive — the raw epoch
    /// archive is untouched, and `isManuallyEdited` makes a later re-sync preserve this row (see
    /// `saveSleepSummary`). `feelScore` is left as the user set it. Returns false if the night isn't
    /// in the store. The caller (RingSession) re-stages from the archive and appends the extension to
    /// Apple Health separately (append-only; nothing is deleted).
    ///
    /// `hypnogram` is the recomputed segment timeline `summary` was rolled up from. It is written in the
    /// same branch as the minutes for the same reason as in `saveSleepSummary`: an edited night whose
    /// stored segments still described the pre-edit staging would silently contradict its own totals.
    ///
    /// It is `nil`-defaulted, NOT `[]`-defaulted: an omitted argument means "I have no timeline to
    /// state", and it leaves the stored blob ALONE. Writing `[]` there — the original behaviour —
    /// meant any caller that simply forgot the parameter DESTROYED the night's segment timeline,
    /// which cannot be rebuilt once the ~30 h epoch archive rolls over, and the export contract then
    /// reports the night as "not recorded" (`ExportEngine.SleepSessionRow`) when it was recorded.
    /// Silent, unrecoverable, and one omitted argument away at every future call site. A caller that
    /// genuinely wants the timeline cleared still says so explicitly by passing `[]`.
    ///
    /// The only production caller (`RingSession.applySleepEdit`) always passes the recomputed
    /// segments, so the pass-through branch exists to make the omission safe rather than to be used.
    @discardableResult
    func applySleepEdit(night: Date, times: SleepEdit.Times,
                        summary: SleepStaging.Summary,
                        hypnogram: [SleepSegment]? = nil) throws -> Bool {
        let dayStart = Calendar.current.startOfDay(for: night)
        let descriptor = FetchDescriptor<StoredSleepSummary>(predicate: #Predicate { $0.night == dayStart })
        guard let row = try? context.fetch(descriptor).first else { return false }
        // Defense in depth behind the sheet/session dirty checks: submitting the recorded values
        // unchanged must not manufacture a manual edit or rewrite its score/timestamp.
        if SleepEdit.isSamePickerMinute(times.inBedStart, row.sleepEditCurrentInBedStart),
           SleepEdit.isSamePickerMinute(times.sleepOnset, row.sleepEditCurrentOnset),
           SleepEdit.isSamePickerMinute(times.sleepWake, row.sleepEditCurrentWake) {
            return true
        }
        let m = summary.minutes

        // REVERSIBILITY, BEFORE THE FIRST DESTRUCTIVE WRITE. `hypnogramData` is a single column and
        // the line below overwrites it, so the ring's own reading has to be somewhere else FIRST.
        // Only ever fill from a row that is still a pure recording; once a row is edited its
        // `hypnogramData` is edit output and copying that in would fabricate a "recording" that
        // never existed. Rows edited before this column shipped are already destroyed and are
        // marked `unknown` by the migration — never claimed as restored.
        if row.recordedHypnogramData.isEmpty, !row.isManuallyEdited, !row.hypnogramData.isEmpty {
            row.recordedHypnogramData = row.hypnogramData
        }
        // Every step is undoable, not merely the original state (SleepEditPriorTimesOverlay keeps a
        // night-keyed stack). Saved before the row mutates so the stack records what was replaced.
        SleepEditPriorTimesOverlay.push(
            .init(inBedStart: row.sleepEditCurrentInBedStart,
                  sleepOnset: row.sleepEditCurrentOnset,
                  sleepWake: row.sleepEditCurrentWake),
            night: row.night)

        row.editedInBedStart = times.inBedStart
        row.editedInBedEnd = times.inBedEnd
        SleepEditOnsetOverlay.save(times.sleepOnset, night: row.night)
        row.isManuallyEdited = true

        // ⚠️ THE MINUTES BELOW ARE THE **DISPLAY** HEADLINE AND STAY ASSERTION-INCLUSIVE (clause 1:
        // an assertion wins for display — a user who dragged their window to 06:43 must not be told
        // they slept until 02:37). What changes is that the row now also carries the split, so no
        // consumer has to mistake the headline for a measurement.
        row.asleepMin = m.asleep
        row.deepMin = m.deep
        row.lightMin = m.light
        row.remMin = m.rem
        row.awakeMin = m.awake

        let breakdown = hypnogram.map { SleepProvenanceBreakdown(segments: $0) }
        // ⚠️ `efficiency` STAYS DISPLAY-BASIS AND IS NOT TOUCHED BY PROVENANCE. Two separate traps
        // guard this line. (1) `asSummary` (`:275`) recovers in-bed as `asleep / efficiency` from the
        // DISPLAY minutes, so writing the measured-only ratio here mixes bases and corrupts in-bed
        // for every downstream reader — 490 min reconstructed for a 439-minute night on
        // R2_2026-08-18. (2) The same expression treats 0 as a live SENTINEL, so "withheld" can
        // never be signalled by zeroing it. The honest ratio goes in `measuredEfficiency`, and
        // `-1` there means withheld.
        row.efficiency = summary.efficiency
        if let hypnogram { row.hypnogramData = SleepHypnogramCodec.encode(hypnogram) }
        if let breakdown {
            row.measuredAsleepSeconds = breakdown.measuredAsleep
            row.assertedAsleepSeconds = breakdown.assertedAsleep
            row.coverageFraction = breakdown.coverageFraction
            row.longestGapSeconds = breakdown.longestUnmeasuredGap
            row.measuredEfficiency = breakdown.efficiency ?? -1
            row.sleepBasis = (breakdown.hasAssertedTime ? SleepBasis.assertedTagged
                                                        : SleepBasis.measuredOnly).rawValue
        }

        // Recompute the duration-driven Sleep Score from the edited night (HR/temp factors dropped →
        // renormalised, per SleepScore's contract — never fabricated).
        //
        // WITHHOLD it entirely when too much of the night was never measured. The score's dominant
        // factor is `timeAsleep` at weight 0.30 (`SleepScore.swift:93`) and "how long did she sleep"
        // is exactly the question an uncovered night cannot answer. 0 is this column's existing
        // "not computed" sentinel (see the live type), so withholding here is expressible without
        // inventing a new one — and it costs the headache engine nothing, because
        // `HeadacheEngine.swift:136-142` consumes efficiency/awakeMin/asleepMin only and never the
        // score.
        if breakdown?.isScorable == false {
            row.sleepScore = 0
        } else {
            row.sleepScore = SleepScore.composite(.init(
                totalAsleep: summary.totalAsleep, timeAwake: summary.awake,
                efficiency: summary.efficiency,
                deep: summary.deep, light: summary.light, rem: summary.rem)).score
        }
        row.updatedAt = Date()
        try context.save()
        return true
    }

    /// Compatibility entry point for callers/tests built around the original two-edge editor.
    /// Its explicit onset/wake arguments now become the persisted sleep window instead of being
    /// silently ignored. `hypnogram` is `nil`-defaulted and pass-through for the same reason as
    /// above: an omitted timeline must never erase a stored one.
    @discardableResult
    func applySleepEdit(night: Date, editedWindow: SleepEdit.Window,
                        summary: SleepStaging.Summary, sleepOnset: Date, sleepWake: Date,
                        hypnogram: [SleepSegment]? = nil) throws -> Bool {
        try applySleepEdit(night: night,
                           times: .init(inBedStart: editedWindow.inBedStart,
                                        sleepOnset: sleepOnset, sleepWake: sleepWake),
                           summary: summary, hypnogram: hypnogram)
    }

    /// RE-SCORE every manually-edited night's provenance labels against a record set that has GROWN
    /// since they were written, and queue the Apple Health rewrite that follows.
    ///
    /// 🟢 THE DEFECT (2026-08-24, Gen 2 Air FR04.009, Europe/Paris — "I got up to go to the bathroom,
    /// and the app assumed that I didn't go back to sleep"). She saved her corrected wake at 06:50,
    /// when the newest archived record was 02:42:47, so the span after it was scored `.asserted` —
    /// "we can prove no records exist here" — as one 14323 s block. Her export, pulled 50 minutes
    /// later, holds nine further 0x4c records covering 02:48:53 → 03:11:23: **1350 s of that "proven
    /// hole" was measurable data the app itself held within the hour.** Nothing re-derived it. The
    /// ordinary mirror bails on `isManuallyEdited` (correctly — that guard is what stops a re-drain
    /// overwriting her edit) and `pendingSleepEditHealthWrites` recovers coverage from the frozen
    /// labels, which by construction "can only repeat" the hole.
    ///
    /// THIS IS THE NARROW WAY THROUGH, and it deliberately leaves the mirror bail alone. The edit
    /// stays authoritative: her window, her onset, her wake and her displayed minutes are not read
    /// here, let alone written. Only the LABELS move, only in the direction of more measurement
    /// (`SleepProvenanceRederivation` cannot express a shrink), and the row's derived columns are
    /// re-rolled from the same upgraded segments so the timeline and the totals cannot disagree.
    ///
    /// It also repairs the second Health path for free: `pendingSleepEditHealthWrites` reads these
    /// same stored labels back, so upgrading the source of truth is what makes its
    /// `fromProvenanceLabels` recovery stop repeating a hole that has since filled.
    ///
    /// The Health rewrite is QUEUED, not performed — this type is synchronous and holds no HealthKit
    /// gate. `HealthKitWriter.flushToHealth` drains the queue through `reconcileEditedNightSleepLocked`,
    /// which is write-first and deletes only the tracked UUIDs of its own previous write, so a
    /// re-derivation cannot duplicate or lose a sample. An `upsert` here can replace a reconcile the
    /// user's own Save queued moments earlier; that is safe because the item we queue is built from
    /// the row that Save had already persisted, upgraded — never from a staler picture.
    ///
    /// - Parameter coverage: RAW coverage over the whole retained archive (never `trusted`) — see
    ///   `SleepProvenanceRederivation.upgraded`, which consumes presence of records only.
    /// - Returns: one entry per night actually changed, with the asleep seconds that moved out of the
    ///   asserted bucket. Empty is the steady state, and a second run over the same archive is empty.
    @discardableResult
    func rederiveEditedNightProvenance(coverage: MeasuredCoverage)
        throws -> [(night: Date, upgradedAsleepSeconds: TimeInterval)] {
        guard !coverage.isEmpty else { return [] }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        var changed: [(night: Date, upgradedAsleepSeconds: TimeInterval)] = []
        // Queued only AFTER the SwiftData save succeeds. UserDefaults has no rollback of its own —
        // the same rule `renameNightScopedOverlays` follows — so a throw here must not leave a
        // reconcile queued against labels the store then rolled back.
        var toQueue: [PendingSleepReconcile] = []
        var details: [String] = []

        for row in rows where row.isManuallyEdited && !row.hypnogramData.isEmpty {
            let stored = SleepHypnogramCodec.decode(row.hypnogramData)
            guard let upgraded = SleepProvenanceRederivation.upgraded(stored, against: coverage)
            else { continue }
            let gained = SleepProvenanceRederivation.upgradedAsleepSeconds(before: stored,
                                                                          after: upgraded)
            row.hypnogramData = SleepHypnogramCodec.encode(upgraded)

            // The same six columns `applySleepEdit` writes, from the same breakdown type, so the
            // stored split can never drift from the stored timeline. The DISPLAY minutes
            // (`asleepMin` and friends) and `efficiency` are deliberately untouched: they are the
            // wearer's assertion-inclusive headline (clause 1) and re-deriving coverage says nothing
            // about them.
            let breakdown = SleepProvenanceBreakdown(segments: upgraded)
            row.measuredAsleepSeconds = breakdown.measuredAsleep
            row.assertedAsleepSeconds = breakdown.assertedAsleep
            row.coverageFraction = breakdown.coverageFraction
            row.longestGapSeconds = breakdown.longestUnmeasuredGap
            row.measuredEfficiency = breakdown.efficiency ?? -1
            row.sleepBasis = (breakdown.hasAssertedTime ? SleepBasis.assertedTagged
                                                        : SleepBasis.measuredOnly).rawValue
            // ⚠️ `sleepScore` IS LEFT AS SAVED, including a withheld 0. Un-withholding it would mean
            // recomputing the composite from this row's ROUNDED display minutes rather than from the
            // second-precision summary `applySleepEdit` used, so the number could move by a point on
            // any drain that grew the archive — churning a health figure the wearer reads. The score
            // is recomputed the next time she edits the night, which is the only moment we hold the
            // inputs it was originally built from.
            row.updatedAt = Date()

            toQueue.append(PendingSleepReconcile(night: row.night,
                                                 inBedStart: row.sleepEditCurrentInBedStart,
                                                 sleepOnset: row.sleepEditCurrentOnset,
                                                 sleepWake: row.sleepEditCurrentWake,
                                                 segments: upgraded))
            changed.append((row.night, gained))
            // Breadcrumbed AFTER the save, unlike the `sleep-drop` traces above: this one asserts
            // that a Health rewrite is queued, and on a throw neither the labels nor the queue
            // would exist. A breadcrumb for something that did not happen is worse than none.
            details.append("night=\(Self.stamp(row.night)) REDERIVED asserted->measured "
                + "asleep=\(Int(gained.rounded()))s "
                + "assertedLeft=\(Int(breakdown.assertedAsleep.rounded()))s "
                + "(archive grew past the edit; Health rewrite queued)")
        }
        guard !changed.isEmpty else { return [] }
        try context.save()
        for item in toQueue { PendingSleepReconcileStore.upsert(item) }
        for detail in details {
            ObservabilityStore().recordMetricEvent(source: "sleep-provenance", detail: detail)
        }
        return changed
    }

    struct PendingSleepEditHealthWrite {
        let night: Date
        let segments: [SleepSegment]
    }

    private static func sleepEditLeadingCursorKey(_ night: Date) -> String {
        "hk:sleep-edit-leading:\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)"
    }

    private static func sleepEditLeadingAsleepCursorKey(_ night: Date) -> String {
        "hk:sleep-edit-leading-asleep:\(Calendar.current.startOfDay(for: night).timeIntervalSince1970)"
    }

    // MARK: One-shot night-key re-key (bedtime-day → wake-day)
    //
    // Rows written before `SleepNightKey` were keyed `startOfDay(inBedSTART)`. That aliases a
    // pre-midnight bedtime onto the day BEFORE the wake day, which is how two consecutive nights
    // collided on one key and one of them was silently discarded (see SleepNightKey for the
    // byte-exact device case). New writes are keyed on the wake day; this moves the existing rows
    // onto the same scheme so history, the Health mirror and the sleep-edit overlays all agree.

    /// Whether every night-scoped overlay for `oldKey` can move to `newKey` without clobbering an
    /// existing value. All-or-nothing: a row is never HALF relocated, because a half-move strands
    /// exactly the artefacts (Health sample UUIDs, edited onset) whose loss is unrecoverable.
    /// The SwiftData cursors are excluded — they fold forward rather than collide.
    private func canRenameNightScopedOverlays(from oldKey: Date, to newKey: Date) -> Bool {
        SleepEditOnsetOverlay.canRename(from: oldKey, to: newKey)
            && SleepEditHealthSampleOverlay.canRename(from: oldKey, to: newKey)
            && SleepEditPriorTimesOverlay.canRename(from: oldKey, to: newKey)
            && MirroredNightOverlay.canRename(from: oldKey, to: newKey)
            && PendingSleepReconcileStore.canRekey(from: oldKey, to: newKey)
            && ((try? canRenameCursor(from: Self.sleepEditLeadingCursorKey(oldKey),
                                      to: Self.sleepEditLeadingCursorKey(newKey))) ?? false)
            && ((try? canRenameCursor(from: Self.sleepEditLeadingAsleepCursorKey(oldKey),
                                      to: Self.sleepEditLeadingAsleepCursorKey(newKey))) ?? false)
    }

    /// Move every night-scoped overlay that hangs off a row's key. MUST run before `row.night` is
    /// reassigned — each helper derives its key from the night it is passed, so the old key has to
    /// still be the row's key when they are called. Call `canRenameNightScopedOverlays` first.
    private func renameNightScopedOverlays(from oldKey: Date, to newKey: Date) throws {
        // THROWING SwiftData work FIRST. Everything below it is UserDefaults, which has no rollback
        // of its own — if a fetch throws after the overlays moved, the row snaps back on rollback and
        // the two stores are left disagreeing, which is precisely the half-relocation the caller's
        // all-or-nothing rule exists to prevent. Ordered this way, a throw leaves UserDefaults clean.
        try renameCursor(from: Self.sleepEditLeadingCursorKey(oldKey),
                         to: Self.sleepEditLeadingCursorKey(newKey))
        try renameCursor(from: Self.sleepEditLeadingAsleepCursorKey(oldKey),
                         to: Self.sleepEditLeadingAsleepCursorKey(newKey))
        try renameFrozenHeadacheNightKey(from: oldKey, to: newKey)
        SleepEditOnsetOverlay.rename(from: oldKey, to: newKey)
        SleepEditHealthSampleOverlay.rename(from: oldKey, to: newKey)
        // The undo stack is night-keyed like the rest; leaving it behind would strand a user's only
        // route back to what the ring recorded.
        SleepEditPriorTimesOverlay.rename(from: oldKey, to: newKey)
        MirroredNightOverlay.rename(from: oldKey, to: newKey)
        PendingSleepReconcileStore.rekey(from: oldKey, to: newKey)
        Self.renameMorningNotificationLedger(from: oldKey, to: newKey)
    }

    /// `morning.lastNotifiedNight` (RingSession) dedups the one-per-night lock-screen summary by the
    /// row's `night` stamp. Left behind, a migrated night compares unequal and the notification is
    /// posted a SECOND time for the same night — or, if the stale value happens to equal some other
    /// night's new key, that night's genuine notification is suppressed. Scalar, so it is rewritten
    /// only when it names exactly the night being moved.
    private static func renameMorningNotificationLedger(from oldKey: Date, to newKey: Date) {
        let defaults = UserDefaults.standard
        let key = RingSession.lastNotifiedNightKey
        guard defaults.object(forKey: key) != nil,
              defaults.double(forKey: key) == oldKey.timeIntervalSince1970 else { return }
        defaults.set(newKey.timeIntervalSince1970, forKey: key)
    }

    /// The export NIGHT watermark names an already-exported night BY ITS KEY, so a re-key leaves it
    /// pointing one day behind: every migrated night would sort after it and be offered again under
    /// a new `sessionID`, giving the user's automated archive two files for one night that can't be
    /// reconciled by id. Nudge it along with the night it names. Forward-only by construction here —
    /// every move is +1 day.
    private func advanceExportWatermarkIfItNamesAMovedNight(_ moves: [SleepNightRekeyPlan.Move]) {
        guard let watermark = lastExportWatermark(),
              let move = moves.first(where: { $0.from == watermark }) else { return }
        let key = Self.exportSessionsCursorKey
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.last = move.to
    }

    /// `StoredHeadacheRisk.nightKey` persists a `StoredSleepSummary.night` value expressly as a
    /// TIMEZONE-STABLE identity for the night a frozen risk score belongs to (HeadacheStore's own
    /// doc: "`nightKey` comes from a persisted `StoredSleepSummary.night`, so it survives the
    /// move"). Re-keying the summary without it would point every historical risk row at a key that
    /// no longer exists, disarming the duplicate-freeze guard it was added to provide. No unique
    /// index there, so no fold is needed — and there can legitimately be more than one row.
    private func renameFrozenHeadacheNightKey(from oldKey: Date, to newKey: Date) throws {
        let descriptor = FetchDescriptor<StoredHeadacheRisk>(predicate: #Predicate { $0.nightKey == oldKey })
        for row in (try? context.fetch(descriptor)) ?? [] { row.nightKey = newKey }
    }

    /// Rename one `StoredCursor`. `kindRaw` is uniquely indexed, so an occupied destination is
    /// REFUSED (the caller pre-flights and then declines the whole row move) — never folded.
    ///
    /// ⚠️ DO NOT "improve" this into a max-fold. The first version did, on the reasoning that a
    /// cursor may only move forward. That is true of the `MetricKind` cursors and FALSE of the two
    /// this migration renames: `hk:sleep-edit-leading:` / `-asleep:` are LEADING watermarks that
    /// `markSleepEditHealthWritten` only ever moves EARLIER, and `pendingSleepEditHealthWrites`
    /// emits `[editedInBedStart, writtenStart)` whenever the edited bedtime precedes them. Keeping
    /// the max would record LESS coverage than was actually written and make the next flush write a
    /// duplicate `.inBed`/`.asleepCore` pair into Apple Health that the user must delete by hand.
    /// Two watermarks belonging to DIFFERENT nights have no correct fold at all.
    private func renameCursor(from oldKey: String, to newKey: String) throws {
        let sourceDescriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == oldKey })
        guard let source = try context.fetch(sourceDescriptor).first else { return }
        guard try canRenameCursor(from: oldKey, to: newKey) else { return }
        source.kindRaw = newKey
    }

    /// Whether `renameCursor` would succeed: nothing to move, or a free destination.
    private func canRenameCursor(from oldKey: String, to newKey: String) throws -> Bool {
        let sourceDescriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == oldKey })
        guard try context.fetch(sourceDescriptor).first != nil else { return true }
        let destDescriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == newKey })
        return try context.fetch(destDescriptor).first == nil
    }

    /// Re-key stored sleep summaries from the bedtime day onto the wake day. Idempotent — a second
    /// run moves nothing, because `SleepNightKey.rekeyed` returns nil for an already-correct row.
    ///
    /// ⚠️ THE UNIQUE INDEX IS NOT A GUARD. An earlier version of this doc claimed `@Attribute(.unique)`
    /// would refuse a move onto an occupied key. That is FALSE, and it was MEASURED to be false: with
    /// a unique `Date` attribute, mutating one row onto another's key makes `save()` SUCCEED and
    /// DESTROYS one of the rows — silently, with no throw to catch. So occupancy has to be enforced
    /// here, in code, before every assignment. Two independent mechanisms do it:
    ///
    ///   1. `occupied` is maintained LIVE against the rows' current keys, and re-checked immediately
    ///      before each `row.night = ` — never trusted from the plan. The plan's ordering guarantee
    ///      only holds if EVERY planned move runs, and this loop has its own refusal reason (an
    ///      occupied OVERLAY) that the pure plan cannot see; one such skip would otherwise leave a
    ///      later move writing onto the skipped row's key.
    ///   2. A final uniqueness assertion over all rows before `save()`. If it ever trips, nothing is
    ///      committed.
    ///
    /// ALL-OR-NOTHING. A throw anywhere — including out of the middle of the loop — rolls the
    /// SwiftData changes back AND reverses the UserDefaults overlay moves already applied, so the two
    /// stores can never be left disagreeing. The caller's done-flag stays unset, and the next attempt
    /// replays the (idempotent) plan from scratch.
    ///
    /// A refused row keeps its old key and gets a `sleep-rekey` breadcrumb naming both nights. That
    /// can legitimately happen with two sleeps ending on the same calendar day (biphasic sleep) —
    /// leaving both rows intact under mixed keys is strictly better than dropping one, which is
    /// exactly the class of silent loss this migration exists to end.
    @discardableResult
    func rekeySleepNightsToWakeDay(calendar: Calendar = .current)
        throws -> (examined: Int, moved: Int, skipped: Int) {
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        // `examined` lets the caller tell "nothing to migrate" from "migrated" — it must NOT latch
        // the one-way done-flag over a store it never saw a row in (see `ensureNightKeyMigrated`).
        guard !rows.isEmpty else { return (0, 0, 0) }
        // The decision is made by a PURE, TESTED function (SleepNightRekeyPlan) — ordering,
        // idempotence, partial-replay and the refusal to touch a row with no in-bed window are all
        // asserted in OpenCircuitKitTests, which actually runs. Its occupancy verdict is advisory
        // here; this method re-derives its own (see above).
        let plan = SleepNightRekeyPlan.plan(
            rows: rows.map { .init(night: $0.night, inBedStart: $0.inBedStart, inBedEnd: $0.inBedEnd) },
            calendar: calendar)
        guard !plan.moves.isEmpty || !plan.refused.isEmpty else { return (rows.count, 0, 0) }

        // Two rows normalising to one calendar day would make `byOldKey` lose one of them and let the
        // same row be moved twice while its sibling is silently left behind. Today's writer always
        // stores a midnight-aligned `night`, so this is a defensive bail-out, not an expected path.
        var byOldKey: [Date: StoredSleepSummary] = [:]
        for row in rows {
            let key = calendar.startOfDay(for: row.night)
            if byOldKey[key] != nil {
                ObservabilityStore().recordMetricEvent(
                    source: "sleep-rekey",
                    detail: "ABORTED night=\(Self.stamp(key)) reason=two-rows-normalise-to-one-day "
                        + "(nothing moved; store left exactly as it was)")
                throw StoreError.nightKeyMigrationUnsafe
            }
            byOldKey[key] = row
        }

        var occupied = Set(byOldKey.keys)
        var moved = 0
        var skipped = plan.refused.count
        var appliedMoves: [SleepNightRekeyPlan.Move] = []

        for refusal in plan.refused {
            ObservabilityStore().recordMetricEvent(
                source: "sleep-rekey",
                detail: "SKIPPED night=\(Self.stamp(refusal.from)) wanted=\(Self.stamp(refusal.to)) "
                    + "reason=destination-occupied (row left on its old key; nothing deleted)")
        }

        func abandon() {
            // Reverse the non-transactional half first — UserDefaults has no rollback of its own, and
            // leaving overlays on new keys while the rows snap back to old ones strands the user's
            // edited onset, the Health sample UUIDs a later edit must delete, and any queued reconcile.
            for move in appliedMoves.reversed() {
                // Guarded like the forward move. Unguarded, a forward move that relocated NOTHING
                // (the row had no overlay of its own) would reverse into a move of an ORPHAN that was
                // never ours — handing this row a foreign night's mirror span or sample UUIDs.
                guard canRenameNightScopedOverlays(from: move.to, to: move.from) else { continue }
                try? renameNightScopedOverlays(from: move.to, to: move.from)
            }
            context.rollback()
        }

        do {
            for move in plan.moves {
                guard let row = byOldKey[move.from] else { continue }
                // Re-check occupancy against the LIVE set, not the plan's snapshot.
                guard !occupied.contains(move.to) else {
                    skipped += 1
                    ObservabilityStore().recordMetricEvent(
                        source: "sleep-rekey",
                        detail: "SKIPPED night=\(Self.stamp(move.from)) wanted=\(Self.stamp(move.to)) "
                            + "reason=destination-occupied-at-apply (row left on its old key; nothing deleted)")
                    continue
                }
                // All-or-nothing per row: if any overlay can't move, the row stays put too, so a row
                // and its overlays can never end up on different keys.
                guard canRenameNightScopedOverlays(from: move.from, to: move.to) else {
                    skipped += 1
                    ObservabilityStore().recordMetricEvent(
                        source: "sleep-rekey",
                        detail: "SKIPPED night=\(Self.stamp(move.from)) wanted=\(Self.stamp(move.to)) "
                            + "reason=overlay-occupied (row left on its old key; nothing deleted)")
                    continue
                }
                try renameNightScopedOverlays(from: move.from, to: move.to)
                row.night = move.to
                occupied.remove(move.from)
                occupied.insert(move.to)
                appliedMoves.append(move)
                moved += 1
            }
            advanceExportWatermarkIfItNamesAMovedNight(appliedMoves)

            // Belt and braces: the unique index will not save us (see the doc above), so prove it
            // ourselves before committing. A trip here means the occupancy bookkeeping is wrong —
            // discard everything rather than let `save()` quietly delete a night.
            let keys = rows.map { calendar.startOfDay(for: $0.night) }
            guard Set(keys).count == keys.count else {
                ObservabilityStore().recordMetricEvent(
                    source: "sleep-rekey",
                    detail: "ABORTED reason=duplicate-night-key-before-save (nothing committed)")
                abandon()
                throw StoreError.nightKeyMigrationUnsafe
            }
            guard moved > 0 || skipped > 0 else { return (rows.count, 0, 0) }
            try context.save()
        } catch {
            abandon()
            throw error
        }

        ObservabilityStore().recordMetricEvent(
            source: "sleep-rekey",
            detail: "bedtime-day -> wake-day: moved=\(moved) skipped=\(skipped) of \(rows.count) nights")
        return (rows.count, moved, skipped)
    }

    private func sleepEditLeadingWatermark(_ night: Date) throws -> Date? {
        let key = Self.sleepEditLeadingCursorKey(night)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return try context.fetch(descriptor).first?.last
    }

    private func sleepEditLeadingAsleepWatermark(_ night: Date) throws -> Date? {
        let key = Self.sleepEditLeadingAsleepCursorKey(night)
        let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
        return try context.fetch(descriptor).first?.last
    }

    /// Extensions waiting for an append-only Health write. Wake-side progress uses the ordinary
    /// forward sleep cursor; bedtime-side progress uses the per-row leading watermark. Rows are
    /// offered only after their original night is known to be in Health; otherwise the ordinary
    /// first full-night write carries the extension once.
    func pendingSleepEditHealthWrites() throws -> [PendingSleepEditHealthWrite] {
        guard let sleepCursor = try loadCursor().last(.sleep) else { return [] }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        return rows.compactMap { row in
            guard row.isManuallyEdited else { return nil }
            let recordedStart = row.sleepEditRecordedInBedStart
            let recordedEnd = row.sleepEditRecordedInBedEnd
            let recordedOnset = row.sleepEditRecordedOnset > .distantPast
                ? row.sleepEditRecordedOnset : recordedStart
            guard recordedEnd > recordedStart, sleepCursor >= recordedEnd else { return nil }
            let writtenStart = (try? sleepEditLeadingWatermark(row.night)) ?? recordedStart
            let writtenOnset = (try? sleepEditLeadingAsleepWatermark(row.night)) ?? recordedOnset
            let writtenEnd = max(recordedEnd, min(sleepCursor, row.editedInBedEnd))

            // ⚠️ THIS IS THE SECOND, INDEPENDENT HEALTHKIT SLEEP CONSTRUCTION IN THE APP. It builds
            // segments straight from the user's anchors: it never calls `SleepEdit.recompute`, never
            // sees `baseSegments`, and holds no record timestamps of its own. A coverage fix confined
            // to `SleepEdit` would leave this path inventing sleep exactly as before — the audit
            // found it precisely because closing one of several paths is a false sense of safety.
            //
            // It recovers the coverage decision already persisted on the row's hypnogram rather than
            // making a second, possibly different one. `fromProvenanceLabels` returns nil when the
            // hypnogram carries no proven-unmeasured span — which means EITHER fully covered OR
            // written before provenance existed, and those must not be conflated — so a legacy row
            // keeps its previous behaviour untouched and is instead marked at the row level by the
            // migration.
            //
            // ⚠️ AND IT IS NOT RE-GUARDED HERE. The retention guard belongs to the RECORDS-based
            // call that wrote these labels; re-running `MeasuredCoverage.trusted(for:)` over the
            // labels resolved its "oldest record" horizon to "the first non-hole LABEL" and handed
            // every leading PROVEN hole back as `.unknown`, i.e. publishable — 🟢 measured at 60 min
            // of invented sleep reaching Health in `SleepEditStoreTests`. `ProvenanceLabelCoverage`
            // has no `trusted(for:)` at all, so that call cannot be written again.
            let coverage = MeasuredCoverage
                .fromProvenanceLabels(SleepHypnogramCodec.decode(row.hypnogramData))
            func fill(_ range: Range<Date>, _ stage: SleepStage) -> [SleepSegment] {
                guard range.upperBound > range.lowerBound else { return [] }
                guard let coverage else {
                    return [SleepSegment(start: range.lowerBound, end: range.upperBound, stage: stage)]
                }
                return coverage.partition(range).map {
                    SleepSegment(start: $0.range.lowerBound, end: $0.range.upperBound, stage: stage,
                                 provenance: SleepEdit.provenance(for: $0.ground))
                }
            }

            var segments: [SleepSegment] = []
            if row.editedInBedStart < writtenStart {
                segments += fill(row.editedInBedStart ..< writtenStart, .inBed)
            }
            let editedOnset = row.sleepEditCurrentOnset
            if editedOnset < writtenOnset {
                segments += fill(editedOnset ..< writtenOnset, .asleepCore)
            }
            if row.editedInBedEnd > writtenEnd {
                segments += fill(writtenEnd ..< row.editedInBedEnd, .inBed)
                segments += fill(writtenEnd ..< row.editedInBedEnd, .asleepCore)
            }
            return segments.isEmpty ? nil : PendingSleepEditHealthWrite(night: row.night,
                                                                         segments: segments)
        }
    }

    /// Advance both per-row manual-extension edges after one atomic HealthKit save.
    func markSleepEditHealthWritten(night: Date, segments: [SleepSegment]) throws {
        guard let row = try sleepSummary(night: night),
              let first = segments.map(\.start).min(), let last = segments.map(\.end).max() else { return }
        let recordedStart = row.sleepEditRecordedInBedStart
        let recordedOnset = row.sleepEditRecordedOnset > .distantPast
            ? row.sleepEditRecordedOnset : recordedStart
        var changed = false
        if let inBedFirst = segments.filter({ $0.stage == .inBed }).map(\.start).min(),
           inBedFirst < recordedStart {
            let key = Self.sleepEditLeadingCursorKey(row.night)
            let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
            if let cursor = try context.fetch(descriptor).first {
                if inBedFirst < cursor.last { cursor.last = inBedFirst; changed = true }
            } else {
                context.insert(StoredCursor(kindRaw: key, last: inBedFirst))
                changed = true
            }
        }
        if let asleepFirst = segments.filter({ $0.stage != .inBed && $0.stage != .awake })
            .map(\.start).min(), asleepFirst < recordedOnset {
            let key = Self.sleepEditLeadingAsleepCursorKey(row.night)
            let descriptor = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.kindRaw == key })
            if let cursor = try context.fetch(descriptor).first {
                if asleepFirst < cursor.last { cursor.last = asleepFirst; changed = true }
            } else {
                context.insert(StoredCursor(kindRaw: key, last: asleepFirst))
                changed = true
            }
        }
        // A retry can carry the wake-side extension after the ordinary sleep write failed. Advance
        // the shared forward cursor too, but never regress it for an older edited night; otherwise a
        // later re-edit can offer the same successful tail through `pendingHealthSleep` again.
        let cursor = try loadCursor()
        if cursor.isNew(.sleep, last) {
            upsertCursor(kind: MetricKind.sleep.rawValue, last: last)
            changed = true
        }
        if changed { try context.save() }
    }

    /// A normal first full-night write can already include the manual leading extension. Mark any
    /// such row covered so the separate bedtime append path never sends the same interval again.
    func markSleepEditHealthCovered(by segments: [SleepSegment]) throws {
        guard let first = segments.map(\.start).min(), let last = segments.map(\.end).max() else { return }
        let rows = try context.fetch(FetchDescriptor<StoredSleepSummary>())
        var changed = false
        for row in rows where row.isManuallyEdited {
            let recordedStart = row.sleepEditRecordedInBedStart
            let recordedEnd = row.sleepEditRecordedInBedEnd
            let recordedOnset = row.sleepEditRecordedOnset > .distantPast
                ? row.sleepEditRecordedOnset : recordedStart
            if row.editedInBedStart < recordedStart, first <= row.editedInBedStart,
               last >= recordedEnd, (try? sleepEditLeadingWatermark(row.night)) == nil {
                context.insert(StoredCursor(kindRaw: Self.sleepEditLeadingCursorKey(row.night),
                                            last: row.editedInBedStart))
                changed = true
            }
            let editedOnset = row.sleepEditCurrentOnset
            if editedOnset < recordedOnset, first <= editedOnset, last >= recordedEnd,
               (try? sleepEditLeadingAsleepWatermark(row.night)) == nil {
                context.insert(StoredCursor(kindRaw: Self.sleepEditLeadingAsleepCursorKey(row.night),
                                            last: editedOnset))
                changed = true
            }
        }
        if changed { try context.save() }
    }

    // MARK: Naps (#76) — separate from the night so they never double-count

    /// Upsert one auto-detected nap, keyed by start. A re-detected nap with the same start
    /// updates in place; a genuinely new nap inserts. Preserves `healthWritten` on update so a
    /// nap already mirrored to Health isn't re-written.
    func saveNap(start: Date, end: Date, asleepMin: Int, isLongNap: Bool,
                 segments: [SleepSegment] = []) throws {
        // Persistence-layer backstop mirroring the manual path's: a nap overlapping a STORED night
        // is that night's sleep counted twice. `NapDetection` only excludes the slice-local
        // `mainSleep`, so a partial drain slice holding just a post-arousal morning bout (too short
        // to be a night on its own) would otherwise re-save a "nap" the archive-union staging
        // absorbs into the night (🟢 2026-08-16 device case; review find).
        if overlapsStoredNight(start, end) { return }
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        if let existing = try? context.fetch(descriptor).first {
            // A manually edited/added nap is authoritative — auto re-detection must not overwrite it.
            if existing.isManuallyEdited || existing.isManuallyAdded { return }
            existing.end = end
            existing.asleepMin = asleepMin
            existing.isLongNap = isLongNap
            existing.stagedSegments = segments.isEmpty ? nil : segments
            existing.updatedAt = Date()
        } else {
            let row = StoredNap(start: start, end: end, asleepMin: asleepMin, isLongNap: isLongNap)
            row.stagedSegments = segments.isEmpty ? nil : segments
            context.insert(row)
        }
        try context.save()
    }

    /// Add a user-logged nap the ring never detected (#nap-parity, RingConn add-nap). Coarse segments
    /// (the user asserts the window). `isManuallyAdded` so re-detection can't remove it, and
    /// `healthWritten=false` so the next flush APPENDS it to Apple Health (never deletes). Returns
    /// false if a nap already exists at that exact start.
    @discardableResult
    func addManualNap(start: Date, end: Date) throws -> Bool {
        guard end > start else { return false }
        // Persistence-layer backstop for the night-overlap rule (the sheet's guard can be nil-fed):
        // a manual nap must not sit inside the recorded night, or it double-counts + duplicates Health.
        if overlapsStoredNight(start, end) { return false }
        let dup = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        if (try? context.fetch(dup).first) != nil { return false }
        let row = StoredNap(start: start, end: end,
                            asleepMin: Int((end.timeIntervalSince(start) / 60).rounded()),
                            isLongNap: end.timeIntervalSince(start) >= NapDetection.longNapDuration)
        row.isManuallyAdded = true
        // The user asserts they slept the whole window (no ring staging), so the coarse hypnogram is
        // the full window asleep — matching the full-window asleepMin above.
        row.stagedSegments = [
            SleepSegment(start: start, end: end, stage: .inBed),
            SleepSegment(start: start, end: end, stage: .asleepCore),
        ]
        context.insert(row)
        do { try context.save() } catch { context.rollback(); return false }
        return true
    }

    /// Edit an existing nap's window (#nap-parity, RingConn `isEdited`). OVERLAY: the unique `start`
    /// key is kept STABLE and the new window stored in `editedStart/editedEnd`, so a later auto
    /// re-detection updates the SAME row (no duplicate nap at the old start). Marks `isManuallyEdited`
    /// so re-detection can't clobber it.
    ///
    /// 🟢 TWO DEFECTS FIXED HERE, both found by the leak audit and both the nap-scale twins of
    /// night-scale ones:
    ///
    /// 1. IT DESTROYED THE RING'S STAGING. The line below replaces `stagedSegments` with a
    ///    whole-window `inBed + asleepCore` pair, so editing an AUTO-detected nap threw away its
    ///    real Deep/Light/REM hypnogram with no backup — the same irreversibility that made
    ///    `recordedHypnogramData` necessary for nights. The original now survives in
    ///    `recordedNapSegmentsData`.
    /// 2. A SHRINK LEFT THE OLD, WIDER SLEEP IN APPLE HEALTH FOREVER. `healthWritten` was left
    ///    as-is and `pendingNaps()` only offers rows with `healthWritten == false`, so there was no
    ///    nap analogue of `reconcileEditedNightSleep` and nothing ever removed the stale span. The
    ///    row now records what was written, and a window that is not a superset of it re-arms the
    ///    flush so the mirror can be corrected.
    ///
    /// Returns false if the nap isn't found or the new window overlaps the night.
    @discardableResult
    func editNap(originalStart: Date, newStart: Date, newEnd: Date) throws -> Bool {
        guard newEnd > newStart else { return false }
        if overlapsStoredNight(newStart, newEnd) { return false }
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == originalStart })
        guard let row = try? context.fetch(descriptor).first else { return false }

        // Reversibility BEFORE the destructive write, and only from a row that is still a pure
        // recording — an already-edited row's `napSegmentsData` is edit output, and copying it in
        // would fabricate a "recording" that never existed.
        if row.recordedNapSegmentsData == nil, !row.isManuallyEdited {
            row.recordedNapSegmentsData = row.napSegmentsData
        }

        let priorWrittenStart = row.healthWrittenStart
        let priorWrittenEnd = row.healthWrittenEnd

        row.editedStart = newStart          // keep `start` (the dedup key) stable — overlay the edit
        row.editedEnd = newEnd
        row.asleepMin = Int((newEnd.timeIntervalSince(newStart) / 60).rounded())
        row.isLongNap = newEnd.timeIntervalSince(newStart) >= NapDetection.longNapDuration
        row.isManuallyEdited = true
        row.stagedSegments = [
            SleepSegment(start: newStart, end: newEnd, stage: .inBed),
            SleepSegment(start: newStart, end: newEnd, stage: .asleepCore),
        ]

        // Re-arm the Health flush when the mirrored span is no longer covered by the new window.
        // A pure WIDENING is left alone: the existing append-only flush already handles it and
        // re-writing would duplicate. A shrink or a move needs the stale span cleaned up.
        if row.healthWritten, priorWrittenEnd > priorWrittenStart,
           priorWrittenStart < newStart || priorWrittenEnd > newEnd {
            row.healthWritten = false
        }
        row.updatedAt = Date()
        do { try context.save() } catch { context.rollback(); return false }
        return true
    }

    /// True when [start,end] overlaps a stored night's effective window — the persistence-layer
    /// guard that keeps a nap (manual or auto) from double-counting / duplicating a night in Apple
    /// Health. Checks the RECORDED in-bed window and, for an edited night, the user's edited window
    /// too (either overlap double-counts on screen). Nearby nights only — a nap and its night are
    /// within a calendar day of each other by construction.
    private func overlapsStoredNight(_ start: Date, _ end: Date) -> Bool {
        guard end > start else { return false }
        let lo = Calendar.current.date(byAdding: .day, value: -2, to: start) ?? start
        let hi = Calendar.current.date(byAdding: .day, value: 2, to: end) ?? end
        let d = FetchDescriptor<StoredSleepSummary>(
            predicate: #Predicate { $0.night >= lo && $0.night <= hi })
        let rows = (try? context.fetch(d)) ?? []
        return rows.contains { row in
            if row.inBedEnd > row.inBedStart,
               start < row.inBedEnd && end > row.inBedStart { return true }
            if row.isManuallyEdited, row.editedInBedEnd > row.editedInBedStart,
               start < row.editedInBedEnd && end > row.editedInBedStart { return true }
            return false
        }
    }

    /// Naps that started on `day` (start-of-day bucket), latest first.
    func naps(on day: Date = Date()) throws -> [StoredNap] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.start >= dayStart && $0.start < dayEnd },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        return try context.fetch(descriptor)
    }

    /// Naps whose start time falls within `[from, to)`, oldest first.
    func naps(from: Date, to: Date) throws -> [StoredNap] {
        let descriptor = FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.start >= from && $0.start < to },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Naps not yet mirrored to Apple Health (oldest first), for `HealthKitWriter.flushNaps`.
    func pendingNaps() throws -> [StoredNap] {
        let descriptor = FetchDescriptor<StoredNap>(
            predicate: #Predicate { $0.healthWritten == false },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Mark a nap written to Apple Health so it isn't written again, RECORDING THE SPAN so a later
    /// shrink can clean up what this write left behind (see `editNap`).
    func markNapWritten(start: Date) throws {
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        guard let row = try? context.fetch(descriptor).first else { return }
        row.healthWritten = true
        row.healthWrittenStart = row.effectiveStart
        row.healthWrittenEnd = row.effectiveEnd
        try context.save()
    }

    /// The span a nap previously mirrored to Health that the CURRENT window no longer covers — what
    /// `flushNaps` must delete before re-writing. Empty when nothing is stale.
    func staleNapHealthSpan(start: Date) -> DateInterval? {
        let descriptor = FetchDescriptor<StoredNap>(predicate: #Predicate { $0.start == start })
        guard let row = try? context.fetch(descriptor).first,
              row.healthWrittenEnd > row.healthWrittenStart else { return nil }
        let lo = min(row.healthWrittenStart, row.effectiveStart)
        let hi = max(row.healthWrittenEnd, row.effectiveEnd)
        guard hi > lo else { return nil }
        return DateInterval(start: lo, end: hi)
    }

    /// Accumulate a SAME-DAY step delta into the running total for `day`, UPSERTED by
    /// start-of-day, AND record a timestamped `StoredStepSample` snapshot (#steps-history) so the
    /// delta's actual observation window survives alongside the rollup. `RingSession` derives the
    /// delta from the descriptor's **quarter-hour step bucket** (🟢 #192, NOT a day total): while
    /// the bucket climbs it stores only the increment between repeated reads, and when the bucket
    /// rolls — or the calendar day turns — it credits the new raw value whole. The day total is
    /// therefore the sum of the buckets we were connected for; quarters nobody observed are gone
    /// (the ring keeps no cumulative counter to back-fill them). New day = new row. `day` is the
    /// SAMPLE time of the reading (when the descriptor arrived), so a value observed just after
    /// midnight is stamped onto its own day, not the prior one. `windowStart` comes from
    /// `StepAccumulator.windowStart`: the previous reading's timestamp, floored to the sample's
    /// own bucket so a delta is never smeared back over hours it cannot cover.
    func addDailySteps(_ delta: Int, day: Date = Date(), windowStart: Date? = nil) throws {
        guard delta > 0 else { return }
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        if let existing = try? context.fetch(descriptor).first {
            existing.steps += delta
            existing.updatedAt = Date()
        } else {
            context.insert(StoredDaily(day: dayStart, steps: delta))
        }
        context.insert(StoredStepSample(start: windowStart ?? dayStart, end: day, delta: delta))
        try context.save()
    }

    /// Today's accumulated step total (0 if none yet).
    func todaySteps(day: Date = Date()) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<StoredDaily>(predicate: #Predicate { $0.day == dayStart })
        return (try? context.fetch(descriptor).first)?.steps ?? 0
    }

    /// Step snapshots not yet mirrored to Apple Health, oldest first — each carries its own
    /// narrow `start`/`end` window (#steps-history), so `HealthKitWriter` can write accurately-
    /// timed `stepCount` samples instead of one `startOfDay→now` smear. Unbounded by "today":
    /// also picks up any earlier day's leftover delta a missed flush left pending.
    func pendingStepSamples() throws -> [StoredStepSample] {
        let descriptor = FetchDescriptor<StoredStepSample>(
            predicate: #Predicate { $0.healthWritten == false },
            sortBy: [SortDescriptor(\.start, order: .forward)])
        return try context.fetch(descriptor)
    }

    /// Mark step snapshots written to Apple Health so they aren't re-sent. Mutates the live
    /// `@Model` rows `pendingStepSamples()` just returned (same context) rather than re-fetching.
    func markStepSamplesWritten(_ samples: [StoredStepSample]) throws {
        guard !samples.isEmpty else { return }
        for row in samples { row.healthWritten = true }
        try context.save()
    }

    /// Step snapshots in `[from, to)`, oldest first — the timestamped step history for the
    /// Trends/day-detail intraday views (#steps-history); `StoredDaily` only has the day total.
    func stepSamples(from: Date, to: Date) throws -> [StoredStepSample] {
        try context.fetch(Self.stepSamplesDescriptor(from: from, to: to))
    }

    /// Most recent stored daily rollup (latest day), or nil.
    func latestDaily() throws -> StoredDaily? {
        var descriptor = FetchDescriptor<StoredDaily>(
            sortBy: [SortDescriptor(\.day, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Trailing daily rollups (latest first), bounded by `limit`. Used by TrendsView (#74) to
    /// build 7-day rolling aggregates for steps. Bounded so it never scans the whole table.
    func recentDailies(limit: Int = 14) throws -> [StoredDaily] {
        try context.fetch(Self.recentDailiesDescriptor(limit: limit))
    }

    /// Daily step rollups whose `day` bucket falls within `[from, to)`, oldest first.
    func dailies(from: Date, to: Date) throws -> [StoredDaily] {
        let descriptor = FetchDescriptor<StoredDaily>(
            predicate: #Predicate { $0.day >= from && $0.day < to },
            sortBy: [SortDescriptor(\.day, order: .forward)])
        return try context.fetch(descriptor)
    }

    private func upsertCursor(kind: String, last: Date) {
        let descriptor = FetchDescriptor<StoredCursor>(
            predicate: #Predicate { $0.kindRaw == kind })
        if let existing = try? context.fetch(descriptor).first {
            existing.last = last
        } else {
            context.insert(StoredCursor(kindRaw: kind, last: last))
        }
    }

    private func cumulativeState(for kind: MetricKind, before date: Date) throws -> CumulativeMetricState {
        let kindRaw = kind.rawValue
        var previousDescriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.start < date },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        previousDescriptor.fetchLimit = 1
        let previous = try context.fetch(previousDescriptor).first
        let previousRaw = previous.map { $0.rawValue ?? $0.value }

        let dayInterval = Calendar.current.dateInterval(of: .day, for: date)
        let dayStart = dayInterval?.start ?? date
        let nextDay = dayInterval?.end ?? date
        var dayDescriptor = FetchDescriptor<StoredSample>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.start >= dayStart && $0.start < nextDay && $0.start < date
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        dayDescriptor.fetchLimit = 1

        if let latestToday = try context.fetch(dayDescriptor).first {
            if let dailyTotal = latestToday.dailyTotal {
                return CumulativeMetricState(previousRawValue: previousRaw, dailyTotal: dailyTotal)
            }
            if !latestToday.isDelta {
                return CumulativeMetricState(
                    previousRawValue: previousRaw,
                    dailyTotal: latestToday.rawValue ?? latestToday.value
                )
            }
        }

        return CumulativeMetricState(previousRawValue: previousRaw)
    }
}

struct LaunchSnapshot {
    let lastHeartRate: QuantitySample?

    @MainActor
    static func load(from store: LocalStore) throws -> LaunchSnapshot {
        LaunchSnapshot(lastHeartRate: try store.latestSample(kind: .heartRate))
    }
}
