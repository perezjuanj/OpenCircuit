// Pure export serialization — no SwiftData dependency (#80). Callers fetch from the
// store and pass plain structs here, so these functions are unit-testable on the CLI.
//
// Three formats:
//   • samplesCSV   — one row per QuantitySample-equivalent (HR / SpO2 / temp / HRV / RR)
//   • sleepCSV     — one row per persisted nightly sleep summary
//   • dailyCSV     — one row per day's step rollup
//   • toJSON       — all three tables as a single JSON bundle with an exportedAt timestamp
//
// Timestamps: ISO 8601 with millisecond precision for sample start/end; yyyy-MM-dd for
// date-only fields (sleep night, daily rollup day) to keep the file readable.
//
// SCHEMA v3 (rich export). v3 is a strict SUPERSET of v2: every key v2 emitted is still
// emitted, at the same JSON path, with byte-identical bytes — there is no dual emitter and no
// compatibility mode, so a consumer written against v2 keeps working and `ExportSchemaV3Tests`
// is what stops that promise from rotting. New material (per-session sleep with its hypnogram,
// export metadata, sampling coverage, provenance/units/notes) lands only in NEW keys and NEW
// CSV sections.
//
// Two timestamp policies, deliberately: the v2 sections keep printing UTC ("…Z") because
// changing them would break the superset promise, while every NEW section prints the device's
// local UTC offset (`offsetISO8601`) so it agrees with the yyyy-MM-dd `night`/`day` labels,
// which have always been local. `ExportMetadata.timestampPolicy` states both facts in the file
// itself so a consumer never has to infer which is which.

import Foundation

public enum ExportEngine {

    /// Bumped from 2 unconditionally: v3 is a byte-superset of v2, so there is no variant to
    /// select between and nothing for a v2 consumer to fall back to.
    public static let schemaVersion = 3

    // MARK: - Row types

    public struct SampleRow: Equatable, Sendable {
        public let kind: String
        public let start: Date
        public let end: Date
        public let value: Double
        public init(kind: String, start: Date, end: Date, value: Double) {
            self.kind = kind; self.start = start; self.end = end; self.value = value
        }
    }

    public struct SleepRow: Equatable, Sendable {
        public let night: Date
        public let asleepMin: Int
        public let deepMin: Int
        public let lightMin: Int
        public let remMin: Int
        public let awakeMin: Int
        public let efficiency: Double
        public let inBedStart: Date?
        public let inBedEnd: Date?
        public let skinTempC: Double
        public let sleepScore: Int
        public let stressScore: Int
        public let feelScore: Int
        public let hrDeep: Int
        public let hrLight: Int
        public let hrRem: Int
        public let hrAwake: Int
        public let movementLevels: [Int]
        public init(night: Date, asleepMin: Int, deepMin: Int, lightMin: Int,
                    remMin: Int, awakeMin: Int, efficiency: Double,
                    inBedStart: Date? = nil, inBedEnd: Date? = nil,
                    skinTempC: Double, sleepScore: Int, stressScore: Int,
                    feelScore: Int = 0, hrDeep: Int = 0, hrLight: Int = 0,
                    hrRem: Int = 0, hrAwake: Int = 0, movementLevels: [Int] = []) {
            self.night = night; self.asleepMin = asleepMin; self.deepMin = deepMin
            self.lightMin = lightMin; self.remMin = remMin; self.awakeMin = awakeMin
            self.efficiency = efficiency; self.inBedStart = inBedStart; self.inBedEnd = inBedEnd
            self.skinTempC = skinTempC
            self.sleepScore = sleepScore; self.stressScore = stressScore
            self.feelScore = feelScore; self.hrDeep = hrDeep; self.hrLight = hrLight
            self.hrRem = hrRem; self.hrAwake = hrAwake; self.movementLevels = movementLevels
        }
    }

    public struct DailyRow: Equatable, Sendable {
        public let day: Date
        public let steps: Int
        public init(day: Date, steps: Int) { self.day = day; self.steps = steps }
    }

    public struct StepSampleRow: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let delta: Int
        public init(start: Date, end: Date, delta: Int) {
            self.start = start; self.end = end; self.delta = delta
        }
    }

    public struct NapRow: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let asleepMin: Int
        public let isLongNap: Bool
        public init(start: Date, end: Date, asleepMin: Int, isLongNap: Bool) {
            self.start = start; self.end = end; self.asleepMin = asleepMin; self.isLongNap = isLongNap
        }
    }

    public struct DaytimeTemperatureRow: Equatable, Sendable {
        public let time: Date
        public let celsius: Double
        public init(time: Date, celsius: Double) {
            self.time = time; self.celsius = celsius
        }
    }

    public struct HistorySyncEvidenceRow: Equatable, Sendable {
        public let capturedAt: Date
        public let ringID: String
        public let trigger: String
        public let sleepCommitted: Bool
        public let stagedSleepSegments: Int
        public let mergedRecordCount: Int
        public let historySampleCount: Int
        public let rawRecordBlobBase64: String
        public let channels: [HistoryChannelTrace]
        /// Which branch of the night-summary write ran (`SleepPersistOutcome.rawValue`), or nil when
        /// this drain staged no night (#204). `sleepCommitted` alone cannot distinguish "merge
        /// protection kept a fuller stored night" (healthy) from "nothing is stored" (the defect).
        public let nightRowOutcome: String?
        public init(capturedAt: Date, ringID: String, trigger: String,
                    sleepCommitted: Bool, stagedSleepSegments: Int,
                    mergedRecordCount: Int, historySampleCount: Int,
                    rawRecordBlobBase64: String, channels: [HistoryChannelTrace],
                    nightRowOutcome: String? = nil) {
            self.capturedAt = capturedAt
            self.ringID = ringID
            self.trigger = trigger
            self.sleepCommitted = sleepCommitted
            self.stagedSleepSegments = stagedSleepSegments
            self.mergedRecordCount = mergedRecordCount
            self.historySampleCount = historySampleCount
            self.rawRecordBlobBase64 = rawRecordBlobBase64
            self.channels = channels
            self.nightRowOutcome = nightRowOutcome
        }
    }

    /// The app's OWN rolling epoch archive — the record set staging actually runs on (#203).
    ///
    /// The per-drain `historySyncEvidence` blobs are a LOSSY view of it: they are a bounded ring
    /// buffer, so once a drain's row ages out its epochs appear in no blob at all, and a replay from
    /// the export alone then sees a data hole the app never had. This section carries the deduped
    /// archive itself plus an explicit statement of what the blobs miss, so a reader never has to
    /// assume the blobs are complete — they demonstrably were not on the export that motivated it.
    public struct EpochArchiveRow: Equatable, Sendable {
        public let ringID: String
        /// `EpochArchive.encode` output, base64 — fixed 23-byte records concatenated, deduped by
        /// epoch counter and ordered.
        public let recordsBase64: String
        public let recordCount: Int
        public let firstEpoch: Date?
        public let lastEpoch: Date?
        /// How the evidence blobs compare against this archive.
        public let coverage: ArchiveEvidenceCoverage.Report
        public init(ringID: String, recordsBase64: String, recordCount: Int,
                    firstEpoch: Date?, lastEpoch: Date?,
                    coverage: ArchiveEvidenceCoverage.Report) {
            self.ringID = ringID
            self.recordsBase64 = recordsBase64
            self.recordCount = recordCount
            self.firstEpoch = firstEpoch
            self.lastEpoch = lastEpoch
            self.coverage = coverage
        }
    }

    // MARK: - Schema v3 row types

    /// Fixed string carried in `meta.timestampPolicy`. Verbatim in the file so a consumer never
    /// has to guess which of the two policies a given key follows.
    public static let timestampPolicyDescription =
        "Timestamps in the schema-2 sections (samples, sleep, daily, stepSamples, naps, " +
        "daytimeTemperatures, historySyncEvidence) are ISO-8601 in UTC and end in 'Z'. " +
        "Timestamps in the schema-3 sections (meta, sleepSessions and its hypnogram/coverage) " +
        "are ISO-8601 with the exporting device's UTC offset. Date-only labels (night, day) are " +
        "yyyy-MM-dd in the device's local calendar in BOTH, which is the calendar the night/day " +
        "buckets were formed with."

    /// Device / app / ring context for the export file. Filled by the app; every field is a
    /// plain string so an unknown value is "" rather than a fabricated placeholder.
    ///
    /// PRIVACY: `ringIdentifier` is the CoreBluetooth peripheral UUID (per-install, resettable),
    /// never the ring MAC — this file is one a user hands to third parties, and Diagnostics
    /// redacts the MAC for the same reason. There is deliberately no device NAME field.
    /// `ringModel` is a model FAMILY ("RingConn Gen2"): the ring's advertised name ends in the
    /// last two bytes of its MAC, and the app strips that suffix before caching (see
    /// `RingMetadataStore.modelFamily`) so no MAC-derived byte can reach this struct.
    ///
    /// The ring fields describe the LAST CONNECTED ring, which on a multi-ring install need not be
    /// the ring that produced every night — `notes["ringIdentity"]` says so in the file itself.
    public struct ExportMetadata: Equatable, Sendable {
        public let schemaVersion: Int
        public let exportedAt: Date
        public let rangeStart: Date
        public let rangeEnd: Date
        public let appVersion: String
        public let appBuild: String
        public let deviceModel: String
        public let osVersion: String
        public let ringModel: String
        public let ringFirmware: String
        public let ringGeneration: String
        public let ringIdentifier: String
        public let timeZoneIdentifier: String
        public let timeZoneOffsetSeconds: Int
        public let timestampPolicy: String

        public init(schemaVersion: Int = ExportEngine.schemaVersion,
                    exportedAt: Date, rangeStart: Date, rangeEnd: Date,
                    appVersion: String = "", appBuild: String = "",
                    deviceModel: String = "", osVersion: String = "",
                    ringModel: String = "", ringFirmware: String = "",
                    ringGeneration: String = "", ringIdentifier: String = "",
                    // Same live accessor the serializer's own device-local formatters use, so the
                    // zone this block DECLARES is by construction the zone the file PRINTS in.
                    timeZoneIdentifier: String = ExportEngine.localTimeZone.identifier,
                    timeZoneOffsetSeconds: Int = ExportEngine.localTimeZone.secondsFromGMT(),
                    timestampPolicy: String = ExportEngine.timestampPolicyDescription) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.deviceModel = deviceModel
            self.osVersion = osVersion
            self.ringModel = ringModel
            self.ringFirmware = ringFirmware
            self.ringGeneration = ringGeneration
            self.ringIdentifier = ringIdentifier
            self.timeZoneIdentifier = timeZoneIdentifier
            self.timeZoneOffsetSeconds = timeZoneOffsetSeconds
            self.timestampPolicy = timestampPolicy
        }
    }

    /// A night's OSA SpO₂ assessment. `avgSpO2` is the validated metric (±1 % vs the RingConn
    /// app); the event metrics are EXPERIMENTAL estimates — see `OSAWaveform`'s header.
    /// A row with `validWindows == 0` means nothing was drained: omit the row entirely rather
    /// than export zeros, which read as measured values.
    public struct OSARow: Equatable, Sendable {
        public let avgSpO2: Double
        public let minSpO2: Double
        public let timeBelow90Sec: Double
        public let odi: Double
        public let validWindows: Int
        public init(avgSpO2: Double, minSpO2: Double, timeBelow90Sec: Double,
                    odi: Double, validWindows: Int) {
            self.avgSpO2 = avgSpO2; self.minSpO2 = minSpO2
            self.timeBelow90Sec = timeBelow90Sec; self.odi = odi
            self.validWindows = validWindows
        }
    }

    /// One sleep SESSION: the night's bed/sleep boundaries, its per-epoch hypnogram, the derived
    /// summary, and — when we have them — the OSA assessment and sampling coverage.
    ///
    /// `hypnogram == []` means NOT RECORDED (a night staged before the hypnogram was persisted),
    /// not "a night with no stages". `osa`/`coverage` are optional for the same reason: absence
    /// and zero are different facts and the export must not conflate them.
    ///
    /// `hypnogram` is accepted in the shape `SleepStaging.stageSegments` produces, i.e. INCLUDING
    /// the overlapping `.inBed` envelope — the serializer drops it (`emittableHypnogram`) so what
    /// reaches the file is a partition. Callers hand the stored array over unfiltered.
    public struct SleepSessionRow: Equatable, Sendable {
        public let sessionID: String
        public let night: Date
        public let inBedStart: Date?
        public let inBedEnd: Date?
        public let sleepOnset: Date?
        public let sleepWake: Date?
        public let isManuallyEdited: Bool
        /// What the ALGORITHM originally produced, before any manual correction. Present only on an
        /// edited night; `nil` otherwise (nothing was overridden, so the fields above already are the
        /// algorithm's output). Paired with the edited values above these form a supervised LABEL:
        /// "the detector said X, the person who slept the night says Y". That is the only ground
        /// truth this project can obtain without the vendor app — see `SleepEditLabel`.
        public let recordedInBedStart: Date?
        public let recordedInBedEnd: Date?
        public let recordedOnset: Date?
        public let recordedWake: Date?
        public let hypnogram: [SleepSegment]
        public let summary: SleepRow
        public let osa: OSARow?
        public let coverage: ExportCoverage.Assessment?
        /// What the record stream says about the two EDGES of this night (`SleepConfidence.assess`).
        /// nil when the night has no clock times to measure against.
        public let edgeProvenance: SleepEdgeProvenanceRow?
        public init(sessionID: String, night: Date,
                    inBedStart: Date? = nil, inBedEnd: Date? = nil,
                    sleepOnset: Date? = nil, sleepWake: Date? = nil,
                    isManuallyEdited: Bool = false,
                    recordedInBedStart: Date? = nil, recordedInBedEnd: Date? = nil,
                    recordedOnset: Date? = nil, recordedWake: Date? = nil,
                    hypnogram: [SleepSegment] = [],
                    summary: SleepRow,
                    osa: OSARow? = nil,
                    coverage: ExportCoverage.Assessment? = nil,
                    edgeProvenance: SleepEdgeProvenanceRow? = nil) {
            self.sessionID = sessionID; self.night = night
            self.inBedStart = inBedStart; self.inBedEnd = inBedEnd
            self.sleepOnset = sleepOnset; self.sleepWake = sleepWake
            self.isManuallyEdited = isManuallyEdited
            self.recordedInBedStart = recordedInBedStart; self.recordedInBedEnd = recordedInBedEnd
            self.recordedOnset = recordedOnset; self.recordedWake = recordedWake
            self.hypnogram = hypnogram; self.summary = summary
            self.osa = osa; self.coverage = coverage
            self.edgeProvenance = edgeProvenance
        }
    }

    /// The acquisition verdict on ONE night's two edges, in a form a tester bundle can carry.
    ///
    /// This is how we find out whether the coverage caveat HELPED. `coverage` next door answers
    /// "how much of the detected window do we hold?" and measures 0.976–1.049 on 21 of 21 corpus
    /// nights — vacuous by construction, because the detected window is DEFINED by the records. The
    /// question that discriminates is what sits just OUTSIDE each edge, which is what this row
    /// carries: on both 246-minute corpus errors the ~4 h hole begins exactly AT the in-bed end
    /// (02:39:14 / 02:37:02), so it is never inside any window a coverage fraction can see.
    ///
    /// `reasons` is the payload that makes a future analysis possible: with the night's
    /// `recorded*`/edited columns beside it, a bundle answers *would the caveat have fired on the
    /// nights the wearer went on to correct?* — the question 21 corpus nights cannot answer.
    ///
    /// ⚠️ IT IS THE CLASSIFIER'S REASON LIST, NOT "WHAT THE CARD SHOWED". No user-visible caveat
    /// ships yet: the card change these verdicts were written for is deliberately parked (its
    /// "never fires on a night we get right" claim is an absence of measurement, not a measurement).
    /// Even once a card renders them it will apply its OWN render guards — the shipped duration
    /// hint is suppressed on a non-contiguous or front-truncated night — so this list is an
    /// UPPER BOUND on what a wearer saw, and describing it as verbatim card copy would be wrong in
    /// both directions. Instrumentation first, on purpose.
    ///
    /// ⚠️ MEASURED AT THE RECORDED (DETECTOR) EDGES, NOT THE EDITED ONES — see the note under the
    /// `edgeProvenance` key in `notes`.
    public struct SleepEdgeProvenanceRow: Equatable, Sendable {
        /// The window the verdicts below were measured against.
        public let windowStart: Date
        public let windowEnd: Date
        /// `witnessed` · `resumedAfterGap` · `noPriorMeasurement` · `unknown`.
        public let bedtimeVerdict: String
        /// Seconds of silence before `windowStart`, or nil when the verdict carries none.
        /// ABSENT rather than 0: `witnessed` means the stream ran right into the edge and `unknown`
        /// means we could not look, and writing 0 for the second would claim the first.
        public let bedtimeGapSeconds: TimeInterval?
        /// `witnessed` · `stoppedThenResumed` · `unknown`.
        public let wakeVerdict: String
        /// Seconds of silence after `windowEnd`, or nil. Same absence-is-not-zero rule.
        public let wakeGapSeconds: TimeInterval?
        /// `SleepConfidence.exportName` of every reason the classifier produced, in its order.
        /// `[]` means it found nothing to say about this night — the common case.
        public let reasons: [String]
        /// The gap threshold in force when these reasons were produced, so a bundle collected under
        /// a different cut is still interpretable. Not fitted — see `WakeProvenance.materialGapSeconds`.
        public let materialGapSeconds: TimeInterval

        public init(windowStart: Date, windowEnd: Date,
                    bedtimeVerdict: String, bedtimeGapSeconds: TimeInterval?,
                    wakeVerdict: String, wakeGapSeconds: TimeInterval?,
                    reasons: [String], materialGapSeconds: TimeInterval) {
            self.windowStart = windowStart; self.windowEnd = windowEnd
            self.bedtimeVerdict = bedtimeVerdict; self.bedtimeGapSeconds = bedtimeGapSeconds
            self.wakeVerdict = wakeVerdict; self.wakeGapSeconds = wakeGapSeconds
            self.reasons = reasons; self.materialGapSeconds = materialGapSeconds
        }

        /// Build the row from an assessment measured over `[windowStart, windowEnd]`.
        ///
        /// Takes the assessment rather than re-deriving the verdicts, so anything that renders the
        /// same `SleepConfidence.Assessment` and this file cannot drift apart.
        ///
        /// The threshold comes off the assessment for the same reason. It used to be a defaulted
        /// argument here, which meant a caller sweeping the cut — the one purpose the parameter has
        /// — could assess at 0 and export `3600` beside those reasons, misstating the cut behind its
        /// own evidence with nothing able to notice. `materialGapSeconds` is now a fact about the
        /// verdict, not about the call site.
        public init(windowStart: Date, windowEnd: Date,
                    assessment: SleepConfidence.Assessment) {
            self.init(windowStart: windowStart, windowEnd: windowEnd,
                      bedtimeVerdict: SleepConfidence.exportName(assessment.bedtime),
                      bedtimeGapSeconds: SleepConfidence.gapSeconds(assessment.bedtime),
                      wakeVerdict: SleepConfidence.exportName(assessment.wake),
                      wakeGapSeconds: SleepConfidence.gapSeconds(assessment.wake),
                      reasons: assessment.reasons.map(SleepConfidence.exportName),
                      materialGapSeconds: assessment.materialGapSeconds)
        }
    }

    /// Stable, human-sortable session id for a night bucket. Built from the SAME local calendar
    /// the night key was bucketed with, so the id and the `night` label can never disagree.
    public static func sessionID(night: Date) -> String {
        "night-\(dateOnly.string(from: night))"
    }

    /// `yyyy-MM-dd` in the device's CURRENT local calendar — the same formatter the `night`/`day`
    /// labels inside the file use. Callers that need a local day string (an export FILENAME, say)
    /// must route through this rather than keep their own `DateFormatter`: a second formatter is
    /// invariably a `static let` that snapshots `TimeZone.current` once per process, so after a
    /// zone change or a DST transition it silently disagrees with the labels in the file it names.
    public static func dayStamp(_ date: Date) -> String {
        dateOnly.string(from: date)
    }

    // MARK: - Date formatters

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The zone every DEVICE-LOCAL label and offset in an export is printed in, and the zone
    /// `ExportMetadata` declares by default. Read LIVE on every use — never captured — so the two
    /// can never describe different zones. See `localFormatters` for why that matters.
    ///
    /// Taken from `Calendar.current` rather than a bare `TimeZone.current` read, for two reasons.
    /// It is the CORRECT source: the `night`/`day` buckets these labels describe are formed with
    /// `Calendar.current.startOfDay` at write time (LocalStore / ExportBuilder), so this is by
    /// definition the same calendar the buckets came from. And it is the TESTABLE one: measured on
    /// this toolchain, `Calendar.current` honours an `NSTimeZone.default` override while
    /// `TimeZone.current` does not, so the zone-change behaviour below can be asserted rather than
    /// argued about. On a device with no override the two are the same zone.
    public static var localTimeZone: TimeZone { Calendar.current.timeZone }

    // The two DEVICE-LOCAL formatters, cached but NEVER frozen.
    //
    // `night`/`day` are bucketed with `Calendar.current.startOfDay` (the DEVICE's local timezone)
    // at write time — e.g. a `StoredDaily.day` value IS local midnight. Formatting that Date back
    // out in UTC (the original behavior here) silently shifts the printed label a day earlier for
    // any positive UTC offset (and a day later for negative), e.g. local midnight 2026-06-24
    // 00:00 +02:00 prints as "2026-06-23" — exactly the mismatch that showed up between this CSV's
    // `day` column and the same steps' date in Apple Health. So both must follow the device zone.
    //
    // But neither may be a `static let`: `TimeZone.current` is a SNAPSHOT taken when the formatter
    // is built, and a `static let` is built ONCE PER PROCESS. An app that stays resident across a
    // flight or a DST boundary would keep printing the offset it launched with, while
    // `ExportBuilder` reads the zone live for `meta.timeZoneOffsetSeconds` — so the file would
    // DECLARE one zone and PRINT another, in an export whose entire selling point is unambiguous
    // timestamps. Rebuilt only when the zone actually CHANGES, so the steady state costs one
    // comparison rather than a fresh formatter per row (an export formats thousands of them).
    //
    // `DateFormatter` and `ISO8601DateFormatter` are documented thread-safe for formatting, so only
    // the cache swap needs the lock; a caller that formats with an instance being replaced holds
    // its own strong reference and simply finishes with the zone it started in.
    private static let localFormatterLock = NSLock()
    private static var localFormatterZone: TimeZone?
    private static var cachedDateOnly: DateFormatter?
    private static var cachedISO8601Offset: ISO8601DateFormatter?

    private static func localFormatters()
        -> (dateOnly: DateFormatter, offset: ISO8601DateFormatter) {
        let zone = localTimeZone
        localFormatterLock.lock()
        defer { localFormatterLock.unlock() }
        if localFormatterZone != zone || cachedDateOnly == nil || cachedISO8601Offset == nil {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = zone
            let offset = ISO8601DateFormatter()
            offset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            offset.timeZone = zone
            cachedDateOnly = day
            cachedISO8601Offset = offset
            localFormatterZone = zone
        }
        return (cachedDateOnly!, cachedISO8601Offset!)
    }

    private static var dateOnly: DateFormatter { localFormatters().dateOnly }

    /// ISO 8601 carrying the DEVICE's UTC offset (e.g. `2026-08-03T23:14:00.000+02:00`), with an
    /// overridable zone. Used by the NEW v3 sections only — see the file header for why the v2
    /// sections keep UTC. The parameter exists so the offset policy can be asserted against a
    /// pinned zone instead of whatever the test machine happens to be set to (a CI box in UTC would
    /// print "Z" and make the assertion vacuous).
    static func offsetISO8601(_ date: Date, timeZone: TimeZone? = nil) -> String {
        guard let timeZone else { return localFormatters().offset.string(from: date) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    private static func jsonOrNull(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func jsonOrNull<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    // MARK: - CSV

    /// RFC-4180 field escaper. Every CSV field goes through this.
    ///
    /// WHY: the writers used to interpolate values straight into comma-joined lines, so a single
    /// comma, quote or newline inside a free-form value (`historySyncEvidenceCSV`'s `ringID` and
    /// `trigger` are user/ring-supplied strings) silently shifted every later column of that row —
    /// a corrupt file that still parses, which is the worst kind. Leading/trailing spaces are
    /// quoted too because many parsers strip them, which would round-trip the value wrongly.
    /// It is a no-op for values needing no quoting, so pre-existing well-formed output stays
    /// byte-identical (locked by `ExportEngineTests`).
    static func csvField(_ value: String) -> String {
        // Line breaks are tested on UNICODE SCALARS, not Characters: Swift treats CRLF as ONE
        // grapheme cluster, so `value.contains("\n")` is false for "a\r\nb" and a Windows-style
        // newline would slip through unquoted — the exact row-splitting corruption this guards.
        let hasLineBreak = value.unicodeScalars.contains("\n") || value.unicodeScalars.contains("\r")
        let needsQuoting = value.contains(",") || value.contains("\"") || hasLineBreak
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Whole numbers without a decimal point, fractions as-is — the formatting `samplesCSV` has
    /// always used, extracted so the new sections print numbers the same way.
    private static func plainNumber(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(value)
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    /// CSV for QuantitySample-equivalent rows. Header: `kind,start,end,value`
    public static func samplesCSV(_ rows: [SampleRow]) -> String {
        var lines = ["kind,start,end,value"]
        for r in rows {
            lines.append(csvLine([
                r.kind,
                iso8601.string(from: r.start),
                iso8601.string(from: r.end),
                plainNumber(r.value)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for nightly sleep summaries. Header includes all stored columns.
    public static func sleepCSV(_ rows: [SleepRow]) -> String {
        var lines = ["night,asleepMin,deepMin,lightMin,remMin,awakeMin,efficiency,inBedStart,inBedEnd,skinTempC,sleepScore,stressScore,feelScore,hrDeep,hrLight,hrRem,hrAwake,movementLevels"]
        for r in rows {
            lines.append(csvLine([
                dateOnly.string(from: r.night),
                "\(r.asleepMin)", "\(r.deepMin)", "\(r.lightMin)",
                "\(r.remMin)", "\(r.awakeMin)",
                String(format: "%.4f", r.efficiency),
                r.inBedStart.map { iso8601.string(from: $0) } ?? "",
                r.inBedEnd.map { iso8601.string(from: $0) } ?? "",
                String(format: "%.2f", r.skinTempC),
                "\(r.sleepScore)", "\(r.stressScore)",
                "\(r.feelScore)",
                "\(r.hrDeep)", "\(r.hrLight)", "\(r.hrRem)", "\(r.hrAwake)",
                r.movementLevels.map(String.init).joined(separator: "|")
            ]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for daily step rollups. Header: `day,steps`
    public static func dailyCSV(_ rows: [DailyRow]) -> String {
        var lines = ["day,steps"]
        for r in rows {
            lines.append(csvLine([dateOnly.string(from: r.day), "\(r.steps)"]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for intraday step deltas. Header: `start,end,delta`
    public static func stepSamplesCSV(_ rows: [StepSampleRow]) -> String {
        var lines = ["start,end,delta"]
        for r in rows {
            lines.append(csvLine([
                iso8601.string(from: r.start), iso8601.string(from: r.end), "\(r.delta)"
            ]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for daytime naps. Header: `start,end,asleepMin,isLongNap`
    public static func napsCSV(_ rows: [NapRow]) -> String {
        var lines = ["start,end,asleepMin,isLongNap"]
        for r in rows {
            lines.append(csvLine([
                iso8601.string(from: r.start), iso8601.string(from: r.end),
                "\(r.asleepMin)", "\(r.isLongNap)"
            ]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for daytime temperature samples. Header: `time,celsius`
    public static func daytimeTemperatureCSV(_ rows: [DaytimeTemperatureRow]) -> String {
        var lines = ["time,celsius"]
        for r in rows {
            lines.append(csvLine([
                iso8601.string(from: r.time), String(format: "%.2f", r.celsius)
            ]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for history-sync evidence. Channel traces are flattened to a compact summary string.
    public static func historySyncEvidenceCSV(_ rows: [HistorySyncEvidenceRow]) -> String {
        // `nightRowOutcome` is APPENDED, never interleaved: every column a v2 consumer indexes
        // keeps its position (`ExportEngine`'s header states that contract for sections; it holds
        // for columns too, and `testHostileValuesRoundTripThroughTheCSV` is what enforces it).
        var lines = ["capturedAt,ringID,trigger,sleepCommitted,stagedSleepSegments,mergedRecordCount,historySampleCount,channelSummary,rawRecordBlobBase64,nightRowOutcome"]
        for r in rows {
            let channelSummary = r.channels.map {
                "\($0.label):\($0.outcome.rawValue):4c=\($0.page4CCount):47=\($0.page47Count):50=\($0.endMarkerCount):added=\($0.recordsAdded)"
            }.joined(separator: "|")
            lines.append(csvLine([
                iso8601.string(from: r.capturedAt),
                r.ringID,
                r.trigger,
                String(r.sleepCommitted),
                "\(r.stagedSleepSegments)",
                "\(r.mergedRecordCount)",
                "\(r.historySampleCount)",
                channelSummary,
                r.rawRecordBlobBase64,
                r.nightRowOutcome ?? ""
            ]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Schema v3 CSV

    /// Ordered (key, JSON value) pairs for the metadata block. ONE source of truth so the JSON
    /// `meta` object and `metadataCSV` can never name or order their fields differently — a
    /// consumer that reads one and joins on the other would otherwise silently mismatch.
    private static func metadataFields(_ m: ExportMetadata) -> [(String, Any)] {
        [("schemaVersion", m.schemaVersion),
         ("exportedAt", offsetISO8601(m.exportedAt)),
         ("rangeStart", offsetISO8601(m.rangeStart)),
         ("rangeEnd", offsetISO8601(m.rangeEnd)),
         ("appVersion", m.appVersion),
         ("appBuild", m.appBuild),
         ("deviceModel", m.deviceModel),
         ("osVersion", m.osVersion),
         ("ringModel", m.ringModel),
         ("ringFirmware", m.ringFirmware),
         ("ringGeneration", m.ringGeneration),
         ("ringIdentifier", m.ringIdentifier),
         ("timeZoneIdentifier", m.timeZoneIdentifier),
         ("timeZoneOffsetSeconds", m.timeZoneOffsetSeconds),
         ("timestampPolicy", m.timestampPolicy)]
    }

    /// CSV for the export metadata block. Header: `field,value`; one row per metadata field, in
    /// the same order and under the same names as the JSON `meta` object.
    public static func metadataCSV(_ meta: ExportMetadata) -> String {
        var lines = ["field,value"]
        for (key, value) in metadataFields(meta) {
            lines.append(csvLine([key, value as? String ?? "\(value)"]))
        }
        return lines.joined(separator: "\n")
    }

    /// The OSA row to actually emit. `validWindows == 0` means nothing was drained, so every
    /// other field is a default rather than a reading — enforced HERE, in the tested pure layer,
    /// rather than trusted to each caller, because the failure mode is silent: a row of zeros
    /// looks exactly like a measured perfect night.
    private static func emittableOSA(_ row: SleepSessionRow) -> OSARow? {
        guard let osa = row.osa, osa.validWindows > 0 else { return nil }
        return osa
    }

    /// The hypnogram rows to actually emit: the staged stages, with the overlapping `.inBed`
    /// envelope removed so the emitted timeline is a PARTITION of the night.
    ///
    /// `SleepStaging.stageSegments` seeds its array with one `.inBed` segment spanning the whole
    /// bedtime window and then appends the awake/core/deep/REM segments that tile that SAME span
    /// (SleepStaging.swift:669-688); a stitched multi-fragment night carries one envelope PER
    /// fragment. Emitted verbatim, the obvious consumer query — `SUM(durationSec) GROUP BY
    /// sessionID` — returned exactly twice the real in-bed time, `hypnogramSegments` over-counted
    /// the stage blocks, and a timeline plot drew an all-night bar across every stage bar. The
    /// in-bed window is already carried losslessly by `inBedStart`/`inBedEnd` on the same row, so
    /// dropping the envelope loses nothing. `SleepStaging.stageTotals` excludes it for exactly the
    /// same reason (SleepStaging.swift:693-697). Filtered HERE, in the tested pure layer, so the
    /// CSV, the JSON and the `hypnogramSegments` count can never disagree about it.
    private static func emittableHypnogram(_ row: SleepSessionRow) -> [SleepSegment] {
        row.hypnogram.filter { $0.stage != .inBed }
    }

    /// `hypnogramSegments` as it must serialize: EMPTY when no timeline was recorded at all, a real
    /// count otherwise — including "0" for a night whose stored blob holds only the `.inBed`
    /// envelope and therefore partitions to no stage blocks.
    ///
    /// The two are different facts and the file's own contract says so (`SleepSessionRow`:
    /// "`hypnogram == []` means NOT RECORDED … not 'a night with no stages'";
    /// `notes["hypnogram"]`: "a night with no rows means no timeline was recorded"). Printing 0 for
    /// both made a night whose timeline predates the hypnogram column read exactly like a night we
    /// staged and found nothing in — the same absence-is-not-zero rule the OSA and coverage columns
    /// already follow, applied to the one column that was still breaking it.
    private static func hypnogramSegmentCount(_ row: SleepSessionRow) -> String {
        row.hypnogram.isEmpty ? "" : "\(emittableHypnogram(row).count)"
    }

    /// CSV for sleep SESSIONS — one row per night, carrying the boundaries, the derived summary,
    /// the OSA assessment and the coverage measurement side by side.
    ///
    /// Absent OSA / coverage / hypnogram serialize as EMPTY fields, never as 0: 0 is a real reading
    /// (an ODI of 0 is a good night) and writing it for "we have nothing" would fabricate a
    /// measurement. Decimal places are display precision only — they carry no physiological meaning
    /// and mirror `sleepCSV`'s existing `%.4f` efficiency / `%.2f` choices.
    public static func sleepSessionsCSV(_ rows: [SleepSessionRow]) -> String {
        var lines = ["sessionID,night,inBedStart,inBedEnd,sleepOnset,sleepWake,isManuallyEdited,asleepMin,deepMin,lightMin,remMin,awakeMin,efficiency,sleepScore,stressScore,hypnogramSegments,osaAvgSpO2,osaMinSpO2,osaTimeBelow90Sec,osaODI,osaValidWindows,coverageFraction,expectedSamples,observedSamples,longestGapSeconds,bedtimeVerdict,bedtimeGapSeconds,wakeVerdict,wakeGapSeconds,confidenceReasons"]
        for r in rows {
            let osa = emittableOSA(r)
            let cov = r.coverage
            let edge = r.edgeProvenance
            lines.append(csvLine([
                r.sessionID,
                dateOnly.string(from: r.night),
                r.inBedStart.map { offsetISO8601($0) } ?? "",
                r.inBedEnd.map { offsetISO8601($0) } ?? "",
                r.sleepOnset.map { offsetISO8601($0) } ?? "",
                r.sleepWake.map { offsetISO8601($0) } ?? "",
                "\(r.isManuallyEdited)",
                "\(r.summary.asleepMin)", "\(r.summary.deepMin)", "\(r.summary.lightMin)",
                "\(r.summary.remMin)", "\(r.summary.awakeMin)",
                String(format: "%.4f", r.summary.efficiency),
                "\(r.summary.sleepScore)", "\(r.summary.stressScore)",
                hypnogramSegmentCount(r),
                osa.map { String(format: "%.2f", $0.avgSpO2) } ?? "",
                osa.map { String(format: "%.2f", $0.minSpO2) } ?? "",
                osa.map { String(format: "%.1f", $0.timeBelow90Sec) } ?? "",
                osa.map { String(format: "%.2f", $0.odi) } ?? "",
                osa.map { "\($0.validWindows)" } ?? "",
                cov.map { String(format: "%.4f", $0.coverageFraction) } ?? "",
                cov.map { "\($0.expectedSamples)" } ?? "",
                cov.map { "\($0.observedSamples)" } ?? "",
                cov.map { String(format: "%.1f", $0.longestGapSeconds) } ?? "",
                // A `witnessed`/`unknown` edge has NO gap; the field stays empty rather than
                // printing 0, which would read as a measured zero-second silence.
                edge?.bedtimeVerdict ?? "",
                edge?.bedtimeGapSeconds.map { String(format: "%.1f", $0) } ?? "",
                edge?.wakeVerdict ?? "",
                edge?.wakeGapSeconds.map { String(format: "%.1f", $0) } ?? "",
                // Space-separated so the field needs no CSV quoting and stays greppable. Empty means
                // the CLASSIFIER found nothing to say — a real and common answer (12 of 21 corpus
                // nights) — and says nothing about any screen: no coverage caveat ships in this
                // build. See the ⚠️ on `SleepEdgeProvenanceRow`.
                edge?.reasons.joined(separator: " ") ?? ""
            ]))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV for the per-epoch hypnogram: one row PER SEGMENT across all sessions, keyed back to
    /// its session. Header: `sessionID,start,end,stage,durationSec`. Sessions with no recorded
    /// hypnogram contribute no rows (absence, not a zero-length night).
    ///
    /// The rows are a PARTITION: they never overlap, so `durationSec` may be summed per session.
    /// See `emittableHypnogram` for the envelope that is deliberately not emitted.
    public static func hypnogramCSV(_ rows: [SleepSessionRow]) -> String {
        var lines = ["sessionID,start,end,stage,durationSec"]
        for r in rows {
            for seg in emittableHypnogram(r) {
                lines.append(csvLine([
                    r.sessionID,
                    offsetISO8601(seg.start),
                    offsetISO8601(seg.end),
                    seg.stage.rawValue,
                    plainNumber(seg.duration)
                ]))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Schema v3 CSV: provenance / units / notes
    //
    // CSV is the DEFAULT format on the export screen, and it used to carry NONE of this: the three
    // honesty blocks were emitted only by `toJSON`. The file most people actually hand to a
    // clinician therefore showed `deepMin` / `osaODI` / `hrvSDNN` as bare columns with nothing in
    // it saying the stages are our own on-device estimate, that only `osaAvgSpO2` is validated, or
    // that `hrvSDNN` carries RMSSD — while the export screen told the user every section was
    // labelled. These render the SAME maps `toJSON` uses; there is no second source to drift from.
    // Sorted by key so the CSV rows and the JSON objects (serialized `.sortedKeys`) list in the
    // same order.

    /// CSV for the provenance map. Header: `section,provenance`.
    ///
    /// The value column is named after the JSON block it mirrors — as `field,unit` mirrors `units`
    /// and `topic,note` mirrors `notes` — so a reader who has only ever seen one of the two views
    /// can join them, and so the word a consumer searches for is in the file.
    public static func provenanceCSV(includesSleepSessions: Bool) -> String {
        keyValueCSV(header: "section,provenance",
                    map: provenance(includesSleepSessions: includesSleepSessions))
    }

    /// CSV for the units map. Header: `field,unit`.
    public static func unitsCSV() -> String {
        keyValueCSV(header: "field,unit", map: units)
    }

    /// CSV for the honest caveats. Header: `topic,note`. Free text with commas and quotes in it —
    /// `csvField` is what keeps a note from shifting the row.
    public static func notesCSV() -> String {
        keyValueCSV(header: "topic,note", map: notes)
    }

    private static func keyValueCSV(header: String, map: [String: String]) -> String {
        var lines = [header]
        for key in map.keys.sorted() {
            lines.append(csvLine([key, map[key] ?? ""]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON bundle

    /// The nightly-summary object. Shared by the v2 `sleep` section and the v3
    /// `sleepSessions[].summary` so the two can never drift apart in shape; only the timestamp
    /// policy differs, which is why the formatter is injected rather than captured.
    private static func sleepJSON(_ r: SleepRow, iso: (Date) -> String) -> [String: Any] {
        [
            "night": dateOnly.string(from: r.night),
            "asleepMin": r.asleepMin,
            "deepMin": r.deepMin,
            "lightMin": r.lightMin,
            "remMin": r.remMin,
            "awakeMin": r.awakeMin,
            "efficiency": r.efficiency,
            "inBedStart": jsonOrNull(r.inBedStart.map(iso)),
            "inBedEnd": jsonOrNull(r.inBedEnd.map(iso)),
            "skinTempC": r.skinTempC,
            "sleepScore": r.sleepScore,
            "stressScore": r.stressScore,
            "feelScore": r.feelScore,
            "hrDeep": r.hrDeep,
            "hrLight": r.hrLight,
            "hrRem": r.hrRem,
            "hrAwake": r.hrAwake,
            "movementLevels": r.movementLevels
        ]
    }

    /// All three tables as a single JSON blob with an `exportedAt` timestamp.
    /// Returns nil only if JSON serialization fails (should never happen in practice).
    ///
    /// `metadata` and `sleepSessions` are the schema-v3 additions; both are defaulted so every
    /// v2-era call site and test compiles and emits the same bytes it always did.
    public static func toJSON(samples: [SampleRow], sleep: [SleepRow],
                              daily: [DailyRow], stepSamples: [StepSampleRow] = [],
                              naps: [NapRow] = [],
                              daytimeTemperatures: [DaytimeTemperatureRow] = [],
                              historySyncEvidence: [HistorySyncEvidenceRow] = [],
                              now: Date = Date(),
                              metadata: ExportMetadata? = nil,
                              sleepSessions: [SleepSessionRow] = [],
                              epochArchives: [EpochArchiveRow] = []) -> String? {
        var root: [String: Any] = [
            "schemaVersion": schemaVersion,
            "exportedAt": iso8601.string(from: now),
            "samples": samples.map { [
                "kind": $0.kind,
                "start": iso8601.string(from: $0.start),
                "end": iso8601.string(from: $0.end),
                "value": $0.value
            ] as [String: Any] },
            "sleep": sleep.map { sleepJSON($0, iso: { iso8601.string(from: $0) }) },
            "daily": daily.map { [
                "day": dateOnly.string(from: $0.day),
                "steps": $0.steps
            ] as [String: Any] },
            "stepSamples": stepSamples.map { [
                "start": iso8601.string(from: $0.start),
                "end": iso8601.string(from: $0.end),
                "delta": $0.delta
            ] as [String: Any] },
            "naps": naps.map { [
                "start": iso8601.string(from: $0.start),
                "end": iso8601.string(from: $0.end),
                "asleepMin": $0.asleepMin,
                "isLongNap": $0.isLongNap
            ] as [String: Any] },
            "daytimeTemperatures": daytimeTemperatures.map { [
                "time": iso8601.string(from: $0.time),
                "celsius": $0.celsius
            ] as [String: Any] },
            "historySyncEvidence": historySyncEvidence.map { [
                "capturedAt": iso8601.string(from: $0.capturedAt),
                "ringID": $0.ringID,
                "trigger": $0.trigger,
                "sleepCommitted": $0.sleepCommitted,
                "nightRowOutcome": jsonOrNull($0.nightRowOutcome),
                "stagedSleepSegments": $0.stagedSleepSegments,
                "mergedRecordCount": $0.mergedRecordCount,
                "historySampleCount": $0.historySampleCount,
                "rawRecordBlobBase64": $0.rawRecordBlobBase64,
                "channels": $0.channels.map { channel in [
                    "label": channel.label,
                    "channel": channel.channel,
                    "startedAt": iso8601.string(from: channel.startedAt),
                    "finishedAt": jsonOrNull(channel.finishedAt.map { iso8601.string(from: $0) }),
                    "outcome": channel.outcome.rawValue,
                    "sawSyncAck": channel.sawSyncAck,
                    "syncAckFlag": jsonOrNull(channel.syncAckFlag),
                    "page4CCount": channel.page4CCount,
                    "page47Count": channel.page47Count,
                    "endMarkerCount": channel.endMarkerCount,
                    "recordsAtStart": channel.recordsAtStart,
                    "recordsAtEnd": channel.recordsAtEnd,
                    "recordsAdded": channel.recordsAdded,
                    "firstOpcode": jsonOrNull(channel.firstOpcode),
                    "lastOpcode": jsonOrNull(channel.lastOpcode),
                    "exitReason": jsonOrNull(channel.exitReason?.rawValue)
                ] as [String: Any] }
            ] as [String: Any] }
        ]

        // --- schema v3 additions (new keys only; nothing above is touched) ---
        if let metadata {
            root["meta"] = Dictionary(uniqueKeysWithValues: metadataFields(metadata))
        }
        if !sleepSessions.isEmpty {
            root["sleepSessions"] = sleepSessions.map { session -> [String: Any] in
                var obj: [String: Any] = [
                    "sessionID": session.sessionID,
                    "night": dateOnly.string(from: session.night),
                    "inBedStart": jsonOrNull(session.inBedStart.map { offsetISO8601($0) }),
                    "inBedEnd": jsonOrNull(session.inBedEnd.map { offsetISO8601($0) }),
                    "sleepOnset": jsonOrNull(session.sleepOnset.map { offsetISO8601($0) }),
                    "sleepWake": jsonOrNull(session.sleepWake.map { offsetISO8601($0) }),
                    "isManuallyEdited": session.isManuallyEdited,
                    "summary": sleepJSON(session.summary, iso: { offsetISO8601($0) })
                ]
                // Supervised LABEL for an edited night: what the detector said, alongside the
                // corrected values above. Key omitted entirely on an unedited night — absence means
                // "nothing was overridden", which is not the same as "the detector agreed".
                if session.isManuallyEdited {
                    var recorded: [String: Any] = [:]
                    if let v = session.recordedInBedStart { recorded["inBedStart"] = offsetISO8601(v) }
                    if let v = session.recordedInBedEnd { recorded["inBedEnd"] = offsetISO8601(v) }
                    if let v = session.recordedOnset { recorded["sleepOnset"] = offsetISO8601(v) }
                    if let v = session.recordedWake { recorded["sleepWake"] = offsetISO8601(v) }
                    if !recorded.isEmpty { obj["recorded"] = recorded }
                }
                // Omitted when no timeline was recorded, `[]` when one was recorded and holds no
                // stage blocks — the same absence-is-not-zero rule `hypnogramSegments` follows in
                // the CSV, and the same omit-the-key convention `osa`/`coverage` use below. An
                // empty array for both would have made a night staged before the hypnogram column
                // existed read identically to a night we staged and found no stages in.
                if !session.hypnogram.isEmpty {
                    obj["hypnogram"] = emittableHypnogram(session).map { seg in [
                        "start": offsetISO8601(seg.start),
                        "end": offsetISO8601(seg.end),
                        "stage": seg.stage.rawValue,
                        "durationSec": seg.duration
                    ] as [String: Any] }
                }
                // Omitted, not zero-filled: a night with no drained assessment and a night with
                // a genuinely quiet one must not read the same.
                if let osa = emittableOSA(session) {
                    obj["osa"] = [
                        "avgSpO2": osa.avgSpO2,
                        "minSpO2": osa.minSpO2,
                        "timeBelow90Sec": osa.timeBelow90Sec,
                        "odi": osa.odi,
                        "validWindows": osa.validWindows
                    ] as [String: Any]
                }
                if let cov = session.coverage {
                    obj["coverage"] = [
                        "windowStart": offsetISO8601(cov.windowStart),
                        "windowEnd": offsetISO8601(cov.windowEnd),
                        "expectedSamples": cov.expectedSamples,
                        "observedSamples": cov.observedSamples,
                        "coverageFraction": cov.coverageFraction,
                        "longestGapSeconds": cov.longestGapSeconds,
                        "gaps": cov.gaps.map { gap in [
                            "start": offsetISO8601(gap.start),
                            "end": offsetISO8601(gap.end),
                            "seconds": gap.seconds
                        ] as [String: Any] }
                    ] as [String: Any]
                }
                // Omitted, never zero-filled, for the same reason as `osa`/`coverage`: a night with
                // no clock times to measure is not a night whose edges we watched.
                if let edge = session.edgeProvenance {
                    var block: [String: Any] = [
                        "windowStart": offsetISO8601(edge.windowStart),
                        "windowEnd": offsetISO8601(edge.windowEnd),
                        "bedtimeVerdict": edge.bedtimeVerdict,
                        "wakeVerdict": edge.wakeVerdict,
                        "reasons": edge.reasons,
                        "materialGapSeconds": edge.materialGapSeconds
                    ]
                    // Present ONLY on a verdict that measured a silence. `witnessed` has none and
                    // `unknown` could not look — a 0 here would turn "we don't know" into "we
                    // watched, and the stream never stopped".
                    if let g = edge.bedtimeGapSeconds { block["bedtimeGapSeconds"] = g }
                    if let g = edge.wakeGapSeconds { block["wakeGapSeconds"] = g }
                    obj["edgeProvenance"] = block
                }
                return obj
            }
        }
        if !epochArchives.isEmpty {
            root["epochArchive"] = epochArchives.map { a in [
                "ringID": a.ringID,
                "recordCount": a.recordCount,
                "firstEpoch": jsonOrNull(a.firstEpoch.map { iso8601.string(from: $0) }),
                "lastEpoch": jsonOrNull(a.lastEpoch.map { iso8601.string(from: $0) }),
                "recordsBase64": a.recordsBase64,
                "evidenceBlobCoverage": [
                    "archiveRecordCount": a.coverage.archiveRecordCount,
                    "evidenceRecordCount": a.coverage.evidenceRecordCount,
                    "missingFromEvidenceCount": a.coverage.missingFromEvidence.count,
                    "longestMissingRunSeconds": a.coverage.longestMissingRunSeconds,
                    "isComplete": a.coverage.isComplete
                ] as [String: Any]
            ] as [String: Any] }
        }
        root["provenance"] = provenance(includesSleepSessions: !sleepSessions.isEmpty,
                                        includesEpochArchive: !epochArchives.isEmpty)
        root["units"] = units
        root["notes"] = notes

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - Provenance / units / notes

    /// Which sections are RAW and which are things we computed. This is the tester's "explicit
    /// separation of raw and derived": without it every number in the file looks equally
    /// authoritative, and the on-device staging estimate reads as if the ring reported it.
    ///   • measured   — values that came off the ring
    ///   • derived    — computed on-device from those values
    ///   • diagnostic — troubleshooting exhaust, not health data
    /// `ExportSchemaV3Tests` enumerates the emitted top-level keys against this map, so a new
    /// section added without a classification fails the suite rather than shipping unlabelled.
    private static func provenance(includesSleepSessions: Bool,
                                   includesEpochArchive: Bool = false) -> [String: String] {
        var map: [String: String] = [
            "samples": "measured",
            "stepSamples": "measured",
            "daytimeTemperatures": "measured",
            "sleep": "derived",
            "daily": "derived",
            "naps": "derived",
            "historySyncEvidence": "diagnostic"
        ]
        if includesEpochArchive {
            // MEASURED: these are the ring's own bytes, deduped — nothing is estimated.
            map["epochArchive"] = "measured"
            // DIAGNOSTIC: a statement about the FILE, not about the wearer.
            map["epochArchive.evidenceBlobCoverage"] = "diagnostic"
        }
        if includesSleepSessions {
            map["sleepSessions"] = "derived"
            map["sleepSessions.summary"] = "derived"
            map["sleepSessions.osa"] = "derived"
            // DERIVED, emphatically: the ring transmits no hypnogram — these stages are our own
            // per-epoch estimate, not a ring-reported label.
            map["sleepSessions.hypnogram"] = "derived"
            // MEASURED: coverage counts rows we actually hold, it estimates nothing.
            map["sleepSessions.coverage"] = "measured"
            // DERIVED, not measured. The two GAPS in it are measured (distances between stored
            // timestamps), but `bedtimeVerdict`/`wakeVerdict`/`reasons` are the output of a
            // classifier with a chosen threshold — and the reasons are literally the sentences the
            // app decided to show. Labelling that "measured" would dress a policy decision as an
            // observation, which is the one thing this block exists to prevent.
            map["sleepSessions.edgeProvenance"] = "derived"
        }
        return map
    }

    /// Units for every numeric field in the file that expresses a QUANTITY, so a consumer never has
    /// to infer one. Plain counts (`expectedSamples`, `validWindows`, `hypnogramSegments`,
    /// `mergedRecordCount`, …) and identifiers (`schemaVersion`, opcodes) carry no unit and are
    /// deliberately absent — `ExportSchemaV3Tests.testEveryNumericLeafInTheJSONHasAUnitOrIsAnExplicitCount`
    /// walks the emitted JSON and holds that allow-list, so a NEW quantity added without an entry
    /// here fails the suite rather than shipping a number whose unit a consumer has to guess.
    ///
    /// Sample units come from `MetricKind.unit` (Metrics.swift) rather than being restated here,
    /// so they cannot drift from what the HealthKit writer actually wrote.
    private static var units: [String: String] {
        var map: [String: String] = [:]
        for kind in MetricKind.allCases { map[kind.rawValue] = kind.unit }
        map["delta"] = "count"                     // stepSamples[].delta
        map["celsius"] = "degC"
        map["skinTempC"] = "degC"
        map["asleepMin"] = "min"
        map["deepMin"] = "min"
        map["lightMin"] = "min"
        map["remMin"] = "min"
        map["awakeMin"] = "min"
        map["efficiency"] = "fraction"
        map["hrDeep"] = "count/min"
        map["hrLight"] = "count/min"
        map["hrRem"] = "count/min"
        map["hrAwake"] = "count/min"
        // Scores are unitless composites, not physical quantities — say so rather than invent a
        // range the code doesn't enforce.
        map["sleepScore"] = "score (unitless)"
        map["stressScore"] = "score (unitless)"
        map["feelScore"] = "score (unitless)"
        // The ring's own motion index; no documented physical unit (PROTOCOL.md §5.3 [10:15]).
        map["movementLevels"] = "level (ring motion index, no physical unit)"
        // The OSA fields are named TWICE on purpose: `osa*` are the CSV column names, the bare names
        // are the keys the JSON `sleepSessions[].osa` object actually emits. A JSON consumer
        // resolving `units["odi"]` used to get nil — the exact "guess the unit" problem this block
        // exists to eliminate, live in the file. Same values, so the two views cannot disagree.
        for (csvColumn, jsonKey, unit) in [
            ("osaAvgSpO2", "avgSpO2", "percent"),  // OSA SpO₂ is percent, unlike samples' 0…1
            ("osaMinSpO2", "minSpO2", "percent"),
            ("osaTimeBelow90Sec", "timeBelow90Sec", "s"),
            ("osaODI", "odi", "events/hour")
        ] {
            map[csvColumn] = unit
            map[jsonKey] = unit
        }
        map["coverageFraction"] = "fraction"
        map["longestGapSeconds"] = "s"
        // `sleepSessions[].edgeProvenance` — the CSV column names and the JSON keys are the same
        // strings here, so there is nothing to keep in sync.
        map["bedtimeGapSeconds"] = "s"
        map["wakeGapSeconds"] = "s"
        map["materialGapSeconds"] = "s"
        map["durationSec"] = "s"
        map["seconds"] = "s"
        map["timeZoneOffsetSeconds"] = "s"
        return map
    }

    /// Honest caveats shipped inside the file. Every one of these is a claim we would otherwise
    /// be making silently by exporting the number at all.
    private static var notes: [String: String] { [
        "hrvSDNN":
            "The hrvSDNN sample kind carries RMSSD, not SDNN. The ring reports RMSSD and " +
            "HealthKit offers only an SDNN field; no fixed RMSSD→SDNN conversion exists, so the " +
            "RMSSD value is stored in the SDNN field and tagged in sample metadata rather than " +
            "converted (HealthKitWriter.swift:881-887, BulkSleep.swift:107).",
        "sleepStages":
            "Sleep stages are an ON-DEVICE ESTIMATE. The ring transmits no hypnogram; stages are " +
            "computed here from the same per-epoch vitals the RingConn app uses. Stage TOTALS " +
            "approximate the app's, but per-epoch cycle placement is NOT validated against any " +
            "reference (SleepStaging.swift header: \"APPROXIMATION, NOT GROUND TRUTH\").",
        "hypnogram":
            "The hypnogram rows for a session are a PARTITION of its sleep window: they never " +
            "overlap, so durationSec can be summed. The surrounding time in bed is carried by " +
            "inBedStart/inBedEnd on the session row, NOT as an extra all-night segment — a night " +
            "with no rows means no timeline was recorded, not a night with no stages. That " +
            "distinction is explicit: hypnogramSegments is EMPTY (and the JSON hypnogram key is " +
            "absent) when no timeline was recorded, and 0 only when one was recorded and contained " +
            "no stage blocks.",
        "exportRange":
            "meta.rangeStart and meta.rangeEnd are the window this file ACTUALLY covers, which can " +
            "be narrower than the one that was requested: the app caps how much it assembles in a " +
            "single pass and says so on screen. Trust these two fields over the filename or the " +
            "range you asked for.",
        "osa":
            "osaAvgSpO2 is validated to ±1% against the RingConn app. osaMinSpO2, " +
            "osaTimeBelow90Sec and osaODI are EXPERIMENTAL estimates — reproducing the app's " +
            "numbers needs its proprietary artifact rejection and event scoring (OSASpO2.swift " +
            "header, docs/RUNBOOK_OSA_APNEA.md).",
        "skinTemperature":
            "Skin temperature is LIVE-only: it is not part of the drainable 0x4c history, so a " +
            "window the app did not observe cannot be back-filled. Overnight temperature " +
            "coverage is expected to be sparse because the app deliberately stays quiet during " +
            "the sleep window.",
        "ringIdentity":
            "The meta.ring* fields describe the LAST RING THIS APP CONNECTED TO, which is not " +
            "necessarily the ring that produced every night in this file. Rings are used one at a " +
            "time and their data merges into a single shared timeline with no per-ring attribution " +
            "(RingScanner.swift:72-74), so on an install that has paired more than one ring an " +
            "older night may have come from a different ring than the one named here. " +
            "historySyncEvidence[].ringID is the only per-capture ring attribution in this file.",
        "coverage":
            "coverageFraction measures what THIS APP holds for the window, not what the ring " +
            "recorded. A low value can mean the ring was not worn, was not drained yet, or that " +
            "epochs were lost — the export cannot tell those apart. The coverage fields are left " +
            "EMPTY for a night older than the app's raw-sample retention window: those epochs " +
            "were deleted by local housekeeping, so a number there would report routine " +
            "housekeeping as missing data.",
        "edgeProvenance":
            "edgeProvenance says whether the record stream ran INTO the printed bedtime and " +
            "CONTINUED past the printed wake — the question coverageFraction structurally cannot " +
            "answer, because the detected window is defined by the records inside it (it measures " +
            "0.976-1.049 on all 21 nights of the development corpus, including two understated by " +
            "246 minutes, whose ~4 h hole starts exactly AT the in-bed end). The gaps are " +
            "measured; the verdicts and reasons are a classifier's output at " +
            "materialGapSeconds, a threshold the evidence does not pin down (gap sizes are " +
            "bimodal with an empty interval from 33 to 242 minutes, so every cut in there scores " +
            "identically). A gap BOUNDS the error in the reported duration, it does NOT estimate " +
            "it. 'unknown' means there was no measurement on that side at all — which is equally " +
            "consistent with the ring having stopped and with the app not having drained that far " +
            "yet, so it carries no claim. Measured against the RECORDED (detector) window, which " +
            "on an edited night is NOT the window inBedStart/inBedEnd report: the edit changes " +
            "what the app shows, not what was recorded. reasons[] is the classifier's own list, " +
            "NOT a record of what the app displayed: no coverage caveat is shown to the wearer in " +
            "this build, and any future card would apply its own render guards on top, so treat " +
            "reasons[] as an upper bound on what anyone actually saw."
    ] }
}
