// Device-agnostic metric models — the typed values the codec produces and the
// HealthKit writer consumes. Shapes follow docs/HEALTHKIT_MAPPING.md. These are
// app-side data structures, not protocol facts; the byte-level decoders that
// populate them stay 🔴 until captures decode each metric (PROTOCOL.md §5).

import Foundation

/// One metric family. Raw values are stable string ids (persistence/cursor keys).
public enum MetricKind: String, Codable, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case hrvSDNN          // HealthKit stores SDNN, not RMSSD (see mapping notes)
    case spo2
    case temperature
    case respiratoryRate
    case steps
    case activeEnergy
    case sleep            // modeled as SleepSegment, not QuantitySample
    /// Estimated walking/running distance derived from steps × stride (#81).
    /// ESTIMATE only — NOT GPS distance. Written to HealthKit `.distanceWalkingRunning`.
    /// Replaced by decoded device distance once 0x4c activity-epoch [15:22] is decoded (#93).
    case distance
    /// Estimated Apple Exercise Time from elevated-HR minutes (#82).
    /// ESTIMATE only — basic threshold model. Full 4-level intensity follows #93 decode.
    /// Written to HealthKit `.appleExerciseTime`.
    case exerciseMinutes

    /// Canonical unit each `QuantitySample.value` is expressed in, matching the
    /// HealthKit type it maps to in docs/HEALTHKIT_MAPPING.md.
    public var unit: String {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: return "count/min"
        case .hrvSDNN: return "ms"
        case .spo2: return "fraction"        // HealthKit oxygenSaturation wants 0…1
        case .temperature: return "degC"
        case .steps: return "count"
        case .activeEnergy: return "kcal"
        case .sleep: return "category"
        case .distance: return "m"           // meters
        case .exerciseMinutes: return "min"  // minutes
        }
    }

    /// Human-readable label for dashboards.
    public var displayName: String {
        switch self {
        case .heartRate: return "Heart Rate"
        case .restingHeartRate: return "Resting HR"
        case .hrvSDNN: return "HRV"
        case .spo2: return "SpO₂"
        case .temperature: return "Skin Temp"
        case .respiratoryRate: return "Respiratory Rate"
        case .steps: return "Steps"
        case .activeEnergy: return "Active Energy"
        case .sleep: return "Sleep"
        case .distance: return "Distance (est.)"
        case .exerciseMinutes: return "Exercise Time (est.)"
        }
    }
}

/// A scalar metric sample carrying the device's own timestamps so history
/// backfills correctly. `end == start` for instantaneous readings.
public struct QuantitySample: Equatable, Codable, Sendable {
    public let kind: MetricKind
    public let start: Date
    public let end: Date
    public let value: Double

    public init(kind: MetricKind, start: Date, end: Date? = nil, value: Double) {
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.value = value
    }
}

/// HealthKit `sleepAnalysis` category values (docs/HEALTHKIT_MAPPING.md §sleep).
///
/// ⚠️ EXACTLY FIVE CASES, AND THAT IS DELIBERATE. `HealthKitWriter.sleepValue` is an exhaustive
/// switch over this enum with no `default:`, so a sixth case would force a decision at the write
/// site — but it would ALSO force one at every other switch in the app, and the next person to add
/// a `default:` re-buries it silently. Worse, `SleepHypnogramCodec` looks stages up in a
/// DICTIONARY, so a sixth case would compile clean and its segments would vanish from the stored
/// hypnogram while the MINUTES still counted them. "Time we did not measure" is therefore carried
/// as `SleepProvenance` — an orthogonal per-segment attribute — never as a stage.
public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case inBed, awake, asleepCore, asleepDeep, asleepREM
}

/// WHERE A SEGMENT'S CLAIM COMES FROM — orthogonal to its `stage`.
///
/// The defect this exists for: `SleepEdit.recompute` took no record timestamps and performed no
/// coverage test, so when a user dragged their sleep window it emitted one `.asleepCore` block
/// spanning the whole extension — measured or not. On a real tester's 2026-08-18 night that block
/// was 246 minutes over ground holding 2 of ~98 expected epochs (2.0 % covered), and it was counted
/// in full: 403 min asleep, 0.918 efficiency, score 71, and 1:1 into Apple Health as real sleep.
///
/// The governing rule, in four clauses:
///   1. AN ASSERTION ALWAYS WINS FOR DISPLAY — it is the user's record and they were there.
///   2. A MEASUREMENT IS NEVER DESTROYED — the ring-derived hypnogram is persisted separately.
///   3. ASSERTED-**PROVEN-UNMEASURED** TIME NEVER ENTERS A DERIVED NUMBER — not a stage minute, not
///      efficiency, not the sleep score, not a headache feature. It IS written to Apple Health, as
///      the stage the wearer's edit assigned and carrying `HKMetadataKeyWasUserEntered: true`, so
///      the claim travels with its own provenance instead of being silently dropped. (This clause
///      read "and never Apple Health as sleep" in build 47; the maintainer reversed that half on
///      2026-08-24 — see `SleepHealthPublication`. The quarantine of DERIVED NUMBERS is unchanged.)
///   4. AND WE MUST BE ABLE TO PROVE IT. "We hold no records here" is only evidence of absence when
///      our record set could have held them. Where it could not — the ground predates what we still
///      retain — the honest answer is `.assertedCoverageUnknown`, which behaves EXACTLY as this app
///      behaved before provenance existed: counted, displayed, published.
///
/// Note clause 3 excludes `.asserted` only. `.assertedOverMeasured` is a user label sitting on top
/// of real recorded ground: the label wins (clause 1) and the ground is real, so it participates in
/// derived numbers normally.
public enum SleepProvenance: String, Codable, CaseIterable, Sendable {
    /// The ring recorded epochs across this span and this is what they said.
    case measured
    /// The user asserted this span and the ring recorded NOTHING here, AND our record set reaches
    /// back far enough to prove it. Honoured for display and for in-bed; excluded from every derived
    /// statistic; written to Apple Health tagged `HKMetadataKeyWasUserEntered` (see clause 3).
    case asserted
    /// The user asserted this span and the ring DID record here — the two disagree. The user's
    /// label is displayed and counted; the ring's reading survives in the recorded hypnogram.
    case assertedOverMeasured
    /// The user asserted this span and WE CANNOT SAY whether the ring recorded across it, because
    /// the span lies outside the reach of the records we still hold (see `MeasuredCoverage.trusted`).
    ///
    /// ⚠️ THIS IS "WE DO NOT KNOW", NOT "NOTHING WAS RECORDED", AND THE DIFFERENCE IS THE WHOLE
    /// POINT. 🟢 Measured on the branch this case was added to fix: editing a fully-recorded night
    /// two days later, after the 30-hour epoch archive had rolled past it, published **0.0** asleep
    /// minutes to Apple Health where the shipped build published 403.0 — and deleted the previously
    /// written samples on the way. Retention had been read as absence. This case behaves in every
    /// respect like the pre-provenance build (counted, displayed, published, never a delete driver),
    /// so an unprovable claim can only ever cost us a caveat, never a user's data.
    case assertedCoverageUnknown

    /// True when no measurement underlies this span AND we can prove it — the only case clause 3
    /// excludes. Named `isProvenUnmeasured`, not `isUnmeasured`, precisely so a reader cannot mistake
    /// `.assertedCoverageUnknown` for it.
    public var isProvenUnmeasured: Bool { self == .asserted }
    /// True when real recorded ground underlies this span, whoever chose the label. This is the
    /// predicate a DERIVED STATISTIC's covered ground is built from.
    public var hasMeasurement: Bool { self == .measured || self == .assertedOverMeasured }
    /// True when we hold no records here but cannot prove none were ever recorded.
    public var isCoverageUnknown: Bool { self == .assertedCoverageUnknown }
    /// True when the user, not the ring, chose this label.
    public var isAsserted: Bool { self != .measured }
}

/// One contiguous sleep-stage segment. A night = many of these, not one record.
public struct SleepSegment: Equatable, Codable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: SleepStage
    /// Where this segment's claim comes from. Defaults to `.measured` so every existing
    /// construction site — and every already-persisted row — keeps its exact present meaning.
    public let provenance: SleepProvenance

    public init(start: Date, end: Date, stage: SleepStage,
                provenance: SleepProvenance = .measured) {
        self.start = start
        self.end = end
        self.stage = stage
        self.provenance = provenance
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Same span and stage, re-tagged. Used where a caller learns the provenance after the fact.
    public func withProvenance(_ p: SleepProvenance) -> SleepSegment {
        SleepSegment(start: start, end: end, stage: stage, provenance: p)
    }

    // Hand-written Codable: `provenance` is decoded with `decodeIfPresent` because
    // `EpochArchiveStore.loadPendingSleepSegments` (`:145`) JSON-decodes `[SleepSegment]` written by
    // an EARLIER build. Synthesized Codable would fail the whole decode on the missing key and the
    // `?? []` fallback would silently drop a drain's pending segments on first launch after upgrade.
    private enum CodingKeys: String, CodingKey { case start, end, stage, provenance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        stage = try c.decode(SleepStage.self, forKey: .stage)
        // Decoded LENIENTLY, and never as the enum. `decodeIfPresent(SleepProvenance.self)` THROWS on
        // a raw value it does not know, and one throw here fails the whole array — which for
        // `EpochArchiveStore.loadPendingSleepSegments` (`?? []`) means silently dropping a drain's
        // pending segments. A label we cannot read must cost the LABEL, never the SLEEP; the lenient
        // reads below extend that to a value of the wrong TYPE, so no future encoding of this one key
        // can cost a night either.
        //
        // ⚠️ AN UNREADABLE LABEL IS NOT `.measured`. `encode(to:)` below OMITS the key for
        // `.measured`, so a value that is PRESENT was written to mean something OTHER than measured —
        // `.measured` is the one reading its writer has ruled out, and it is the reading that says a
        // sensor saw this span, which is how invented sleep reaches Apple Health. The honest degrade
        // is `.assertedCoverageUnknown`: counted, displayed and PUBLISHED exactly as before provenance
        // existed (so the sleep is still never lost) but never quoted as a measurement, never a
        // denominator, and never a delete driver.
        let carriesALabel = c.contains(.provenance) && (try? c.decodeNil(forKey: .provenance)) == false
        if carriesALabel {
            provenance = (try? c.decode(String.self, forKey: .provenance))
                .flatMap(SleepProvenance.init(rawValue:)) ?? .assertedCoverageUnknown
        } else {
            // No label: written by a build that predates provenance, or a `.measured` segment.
            provenance = .measured
        }
    }

    // Encode `provenance` only when it is not the default, so a fully-measured night's JSON is
    // byte-identical to what earlier builds wrote (and an older build can still read it back).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(stage, forKey: .stage)
        if provenance != .measured { try c.encode(provenance, forKey: .provenance) }
    }
}
