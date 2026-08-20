// Manual sleep-time-range edit — RingConn parity (#176).
//
// RE'd from the RingConn APK (EditSleepStagePage / SleepEditableTimeRange / SleepEditActionMixin /
// SleepEditViewModel; SleepSyncModel's separate `*Edit` override columns; and the verbatim limit
// copy). The app lets the user adjust a night's in-bed window, but bounds the edit to
//   "within 3 hours before your recorded sleep time and within 3 hours after your recorded wake
//    time"
// so an edit can only refine ring data, never invent an arbitrary night. The edit is stored as a
// SEPARATE overlay (the ring-derived original is never overwritten), so a later re-sync can't clobber
// it — that persistence lives in the store; THIS file is the pure, testable bounds + validation rule.

import Foundation

public enum SleepEdit {
    /// RingConn's editable margin: 3 h before the recorded sleep onset and 3 h after the recorded
    /// wake. (APK copy, see the sleep-edit spec.)
    public static let editMargin: TimeInterval = 3 * 3600

    /// The [earliest, latest] span the edited in-bed window may occupy, anchored on the RECORDED
    /// (ring-derived) onset + wake so the original data always bounds the edit.
    public struct Bounds: Equatable, Sendable {
        public let earliest: Date   // recorded onset − 3 h
        public let latest: Date     // recorded wake  + 3 h
        public init(earliest: Date, latest: Date) {
            self.earliest = earliest
            self.latest = latest
        }
    }

    /// Longest span the editor may ever offer. The EpochArchive retains ~30 h (two nights), so an
    /// unbounded widening could let an edit reach into the NEIGHBOURING night; this caps it to one
    /// plausible night, matching the `maxNightSpan` idea the all-day scoping fix already uses.
    public static let defaultMaxNightSpan: TimeInterval = 14 * 3600

    /// The span of epoch records that plausibly belong to the night anchored on
    /// `[recordedOnset, recordedWake]`. Pure so the EDITOR UI and the server-side validator can
    /// compute the identical value — if they diverge, the picker offers times `validate` then
    /// rejects. Pass the archive's record timestamps.
    public static func dataCoverage(recordDates: [Date],
                                    recordedOnset: Date, recordedWake: Date,
                                    maxNightSpan: TimeInterval = defaultMaxNightSpan) -> ClosedRange<Date>? {
        let lo = recordedWake.addingTimeInterval(-maxNightSpan)
        let hi = recordedOnset.addingTimeInterval(maxNightSpan)
        let inWindow = recordDates.filter { $0 >= lo && $0 <= hi }
        guard let first = inWindow.min(), let last = inWindow.max(), first <= last else { return nil }
        return first...last
    }

    /// The [earliest, latest] span the edited in-bed window may occupy.
    ///
    /// The ±3 h RingConn margin around the RECORDED onset/wake is a FLOOR that is always offered
    /// (parity, and it is what stops an edit inventing a night from nothing). But anchoring *only*
    /// on the recorded night assumes detection was roughly right — and it fails exactly when the
    /// user most needs to edit. 🟢 2026-08-04: a night that reached the phone as 07:30–08:55 (the
    /// #188 loss truncated an 8.6 h night to its tail) gave an "In bed" picker of 04:30–07:30, so
    /// the true 00:15 bedtime was 4 h 15 m outside the editable span and the previous calendar day
    /// was unreachable entirely — the user could not correct the night at all.
    ///
    /// So `dataCoverage` — the span of epochs we actually HOLD for this night — may widen the
    /// bounds outward, capped at `maxNightSpan`. The guarantee that survives: an edit may only
    /// reach where the ring has data or within the parity margin, never into open space.
    /// - Parameter existingEdit: the night's already-SAVED edited window, if any. Always inside the
    ///   returned bounds. `dataCoverage` can legitimately CONTRACT — `EpochArchive` prunes anything
    ///   older than 30 h behind its newest record — so without this, re-opening an edited night days
    ///   later could return bounds that no longer contain the user's own saved times, and
    ///   `EditSleepView.init`'s clamp would silently drag them inward (a Save then "corrects" a night
    ///   the user had already corrected). Applied AFTER the caps so it can never be trimmed away.
    public static func bounds(recordedOnset: Date, recordedWake: Date,
                              dataCoverage: ClosedRange<Date>? = nil,
                              existingEdit: ClosedRange<Date>? = nil,
                              maxNightSpan: TimeInterval = defaultMaxNightSpan) -> Bounds {
        let floorEarliest = recordedOnset.addingTimeInterval(-editMargin)
        let floorLatest = recordedWake.addingTimeInterval(editMargin)
        var earliest = floorEarliest
        var latest = floorLatest
        if let coverage = dataCoverage {
            earliest = min(earliest, coverage.lowerBound)
            latest = max(latest, coverage.upperBound)
        }
        // ⚠️ BOTH CAPS ARE ANCHORED ON THE *FLOOR*, NEVER ON THE COVERAGE-WIDENED EDGE. Do not
        // "simplify" either line to use `latest`/`earliest` after widening — in EITHER direction.
        //
        // The first draft capped the early edge with `latest.addingTimeInterval(-maxNightSpan)`,
        // where `latest` had already been widened to `coverage.upperBound`. On a worn ring the
        // all-day channel keeps feeding the archive, so `coverage.upperBound` tracks WALL-CLOCK NOW
        // — which made the editable window a 14 h span TRAILING the current time. Adversarial review
        // MEASURED the result on the exact night this fix exists for (recorded 07:30–08:55, true
        // bedtime 00:15): reachable if edited at 09:00, still reachable at 14:00, GONE by 15:00, and
        // by 19:00 `earliest` was back to 04:30 — bit-identical to the bug the user reported. The fix
        // silently expired a few hours after wake.
        //
        // The second draft then capped the late edge with `earliest.addingTimeInterval(maxNightSpan)`
        // — the WIDENED-AND-CAPPED `earliest`, which is the same mistake mirrored. 🟢 Device case
        // 2026-08-16: recorded 03:44→06:04, previous-EVENING coverage dragged `earliest` down to its
        // cap (`floorLatest` − 14 h = Sat 19:04), so the late cap collapsed to 19:04 + 14 h = 09:04 —
        // exactly `floorLatest` — and the tester's real ~10:15 wake was refused even though the
        // archive HELD epochs through 10:51. The 14 h budget was spent on eight useless evening
        // hours and denied on the side the user actually needed.
        //
        // So each cap anchors on the OPPOSITE FLOOR edge: an edge may reach at most `maxNightSpan`
        // beyond the recorded night's far margin, independent of how far coverage widened the other
        // side. Floor-anchoring keeps both edges time-invariant, and keeps `bounds` MONOTONE in
        // coverage: growing the archive can only ever widen, never contract. That monotonicity is
        // load-bearing for two more failures review found — a drain landing while the sheet is open
        // could otherwise make Save reject a time the picker had offered, and re-opening an edited
        // night could clamp the user's own stored edit inward.
        //
        // The caps alone no longer bound the PAIRED window to one night (the two edges can be up to
        // 28 h − floorSpan apart); "one plausible night" is enforced where it belongs, on the
        // proposed window itself — `validate`'s `.tooLong` duration rule.
        earliest = min(floorEarliest, max(earliest, floorLatest.addingTimeInterval(-maxNightSpan)))
        latest = max(floorLatest, min(latest, floorEarliest.addingTimeInterval(maxNightSpan)))
        // A night the user has ALREADY edited must always remain fully selectable. Deliberately
        // outside the caps above.
        if let existing = existingEdit {
            earliest = min(earliest, existing.lowerBound)
            latest = max(latest, existing.upperBound)
        }
        return Bounds(earliest: earliest, latest: latest)
    }

    /// Clamp a proposed edge into the editable bounds (for a live-dragging picker).
    public static func clamp(_ date: Date, to bounds: Bounds) -> Date {
        min(max(date, bounds.earliest), bounds.latest)
    }

    /// A night row's RECORDED (ring-derived) window — the four columns the edit sheet anchors on.
    /// `.distantPast` edges mean "unknown" (legacy rows / no asleep block), matching the store.
    public struct RecordedWindow: Equatable, Sendable {
        public var inBedStart: Date
        public var inBedEnd: Date
        public var sleepOnset: Date
        public var sleepWake: Date
        public init(inBedStart: Date, inBedEnd: Date, sleepOnset: Date, sleepWake: Date) {
            self.inBedStart = inBedStart
            self.inBedEnd = inBedEnd
            self.sleepOnset = sleepOnset
            self.sleepWake = sleepWake
        }
        var inBedKnown: Bool { inBedStart > .distantPast && inBedEnd > inBedStart }
        var sleepKnown: Bool { sleepOnset > .distantPast && sleepWake > sleepOnset }
    }

    /// Outward-only widening of a MANUALLY-EDITED night's recorded anchors from a later, fuller
    /// staging of the same night.
    ///
    /// A manual edit freezes the row (`keptManualEdit`): the user's window/durations are
    /// authoritative and later re-syncs must not overwrite them. But freezing the RECORDED anchors
    /// with the minutes was its own defect — 🟢 device case 2026-08-16: the anchors froze at a
    /// truncated early staging (wake 06:04) while the archive grew through the real ~10:15 wake, so
    /// the ±3 h edit clamp (anchored on the recorded wake) pinned the sheet at 09:04 forever and
    /// the tester could never correct the night, edit after edit, morning after morning.
    ///
    /// The recorded anchors describe WHAT THE RING RECORDED, not what the user asserted — updating
    /// them from a fuller staging contradicts nothing the user edited. Widening is OUTWARD-ONLY
    /// (min start / max end), so the editable floor derived from them is monotone: re-opening the
    /// sheet can only ever offer MORE, never invalidate a previously offered time.
    ///
    /// Returns nil when there is nothing to do: the incoming staging has no known window, or
    /// widening changes nothing. The caller persists only on non-nil.
    public static func widenRecorded(stored: RecordedWindow,
                                     incoming: RecordedWindow) -> RecordedWindow? {
        guard incoming.inBedKnown else { return nil }
        var out = stored
        if stored.inBedKnown {
            out.inBedStart = min(stored.inBedStart, incoming.inBedStart)
            out.inBedEnd = max(stored.inBedEnd, incoming.inBedEnd)
        } else {
            out.inBedStart = incoming.inBedStart
            out.inBedEnd = incoming.inBedEnd
        }
        if incoming.sleepKnown {
            if stored.sleepKnown {
                out.sleepOnset = min(stored.sleepOnset, incoming.sleepOnset)
                out.sleepWake = max(stored.sleepWake, incoming.sleepWake)
            } else {
                out.sleepOnset = incoming.sleepOnset
                out.sleepWake = incoming.sleepWake
            }
        }
        return out == stored ? nil : out
    }

    /// The editor displays only date/hour/minute. Compare at that same granularity so changing a
    /// picker and returning to the visually unchanged minute cannot manufacture a manual edit due
    /// solely to hidden seconds in the ring-derived timestamp.
    public static func isSamePickerMinute(_ lhs: Date, _ rhs: Date,
                                          calendar: Calendar = .current) -> Bool {
        calendar.compare(lhs, to: rhs, toGranularity: .minute) == .orderedSame
    }

    /// A proposed edited in-bed window.
    public struct Window: Equatable, Sendable {
        public var inBedStart: Date
        public var inBedEnd: Date
        public init(inBedStart: Date, inBedEnd: Date) {
            self.inBedStart = inBedStart
            self.inBedEnd = inBedEnd
        }
        public var duration: TimeInterval { max(0, inBedEnd.timeIntervalSince(inBedStart)) }
    }

    /// The three clock times exposed by the sleep editor. Bedtime and sleep onset are deliberately
    /// separate: `[inBedStart, sleepOnset]` is awake-in-bed, while `[sleepOnset, sleepWake]` is the
    /// editable sleep window. The wake time is also the end of the in-bed envelope because the UI
    /// intentionally asks for the three user-observable anchors rather than a fourth "left bed" time.
    public struct Times: Equatable, Sendable {
        public var inBedStart: Date
        public var sleepOnset: Date
        public var sleepWake: Date

        public init(inBedStart: Date, sleepOnset: Date, sleepWake: Date) {
            self.inBedStart = inBedStart
            self.sleepOnset = sleepOnset
            self.sleepWake = sleepWake
        }

        public var inBedEnd: Date { sleepWake }
        public var inBedDuration: TimeInterval {
            max(0, sleepWake.timeIntervalSince(inBedStart))
        }
        public var asleepWindowDuration: TimeInterval {
            max(0, sleepWake.timeIntervalSince(sleepOnset))
        }
    }

    /// Why a proposed edit is rejected. nil (from `validate`) means the edit is allowed.
    public enum Invalid: Error, Equatable, Sendable {
        case endNotAfterStart
        case onsetBeforeBedtime
        case wakeNotAfterOnset
        case startBeforeEarliest    // pushed bedtime > 3 h before recorded onset
        case endAfterLatest         // pushed wake > 3 h after recorded wake
        case tooShort(minMinutes: Int)
        case tooLong(maxMinutes: Int) // in-bed window longer than one plausible night
    }

    /// The longest in-bed window `validate` accepts — the "one plausible night" rule, enforced on
    /// the PROPOSED window itself rather than by capping the bounds' edges against each other
    /// (capping the edges is what produced the 2026-08-16 seesaw — see `bounds`). Never below the
    /// FLOOR span, so a genuinely long recorded night plus its ±3 h parity margins always remains
    /// fully selectable, and never below an already-saved edit — the same "the user's own saved
    /// times stay valid" guarantee `bounds` makes for its edges.
    public static func maxWindowDuration(recordedOnset: Date, recordedWake: Date,
                                         existingEdit: ClosedRange<Date>? = nil,
                                         maxNightSpan: TimeInterval = defaultMaxNightSpan) -> TimeInterval {
        let floorSpan = recordedWake.timeIntervalSince(recordedOnset) + 2 * editMargin
        let existingSpan = existingEdit.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? 0
        return max(maxNightSpan, max(floorSpan, existingSpan))
    }

    /// Validate the three independent editor anchors. The minimum applies to the asserted sleep
    /// window, not to the longer in-bed envelope.
    public static func validate(_ times: Times, recordedOnset: Date, recordedWake: Date,
                                minDuration: TimeInterval = 0,
                                dataCoverage: ClosedRange<Date>? = nil,
                                existingEdit: ClosedRange<Date>? = nil) -> Invalid? {
        let b = bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                       dataCoverage: dataCoverage, existingEdit: existingEdit)
        if times.sleepOnset < times.inBedStart { return .onsetBeforeBedtime }
        if times.sleepWake <= times.sleepOnset { return .wakeNotAfterOnset }
        if times.inBedStart < b.earliest { return .startBeforeEarliest }
        if times.sleepWake > b.latest { return .endAfterLatest }
        // "One plausible night" — the bounds' edges no longer pairwise-cap each other (see
        // `bounds`), so the window's own duration carries the rule.
        let maxDuration = maxWindowDuration(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                            existingEdit: existingEdit)
        if times.inBedDuration > maxDuration {
            return .tooLong(maxMinutes: Int(maxDuration / 60))
        }
        if times.asleepWindowDuration < minDuration {
            return .tooShort(minMinutes: Int(minDuration / 60))
        }
        return nil
    }

    public static func isValid(_ times: Times, recordedOnset: Date, recordedWake: Date,
                               minDuration: TimeInterval = 0,
                               dataCoverage: ClosedRange<Date>? = nil,
                               existingEdit: ClosedRange<Date>? = nil) -> Bool {
        validate(times, recordedOnset: recordedOnset, recordedWake: recordedWake,
                 minDuration: minDuration, dataCoverage: dataCoverage,
                 existingEdit: existingEdit) == nil
    }

    /// Validate a proposed window against the recorded onset/wake bounds. Returns nil when valid.
    /// `minDuration` guards against a degenerate near-zero night.
    public static func validate(_ w: Window, recordedOnset: Date, recordedWake: Date,
                                minDuration: TimeInterval = 0) -> Invalid? {
        let b = bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        if w.inBedEnd <= w.inBedStart { return .endNotAfterStart }
        if w.inBedStart < b.earliest { return .startBeforeEarliest }
        if w.inBedEnd > b.latest { return .endAfterLatest }
        if w.duration < minDuration { return .tooShort(minMinutes: Int(minDuration / 60)) }
        return nil
    }

    public static func isValid(_ w: Window, recordedOnset: Date, recordedWake: Date,
                               minDuration: TimeInterval = 0) -> Bool {
        validate(w, recordedOnset: recordedOnset, recordedWake: recordedWake, minDuration: minDuration) == nil
    }

    /// Recompute a night's stage segments for an edited in-bed window, NON-DESTRUCTIVELY:
    /// - base segments are clipped to the window (a trim just drops out-of-window time);
    /// - the EXTENSION region — window time BEFORE the first / AFTER the last recorded segment — is
    ///   credited as asleep (`fillStage`, default core/light): the user extended the window because
    ///   they were asleep there and the ring simply stopped recording. INTERIOR gaps between recorded
    ///   segments are left as-is (a real mid-night awake gap is never overwritten).
    ///
    /// The result drives both the app display and the append-only HealthKit write: extension-tail
    /// segments fall past the sleep write-watermark, so Health GAINS the added sleep and nothing is
    /// ever deleted. (A trim shrinks the in-app view only; already-written Health samples are left
    /// untouched — non-destructive by design.)
    /// - Parameter coverage: which instants the ring actually recorded. **`nil` is the kill switch**
    ///   — it reproduces the pre-provenance behaviour byte-for-byte, every emitted segment carrying
    ///   the default `.measured`. Non-nil splits every FILL span against the coverage so invented
    ///   time is tagged `.asserted` and can be excluded from derived numbers and from Health.
    public static func recompute(baseSegments: [SleepSegment], window: Window,
                                 fillStage: SleepStage = .asleepCore,
                                 coverage: MeasuredCoverage? = nil) -> [SleepSegment] {
        let start = window.inBedStart, end = window.inBedEnd
        guard end > start else { return [] }

        // Clip each base segment to the window; drop any that fall entirely outside.
        let sortedBase = baseSegments.sorted { $0.start < $1.start }
        let clipped: [SleepSegment] = sortedBase.compactMap { seg in
            let s = max(seg.start, start), e = min(seg.end, end)
            return e > s ? SleepSegment(start: s, end: e, stage: seg.stage,
                                        provenance: seg.provenance) : nil
        }

        // With no recording at all, the user's whole window is synthetic asleep time. With a
        // non-empty recording, however, an empty `clipped` array can mean the proposed window sits
        // wholly inside an INTERIOR recording gap; that gap must remain empty rather than becoming
        // invented sleep. Extension fill is therefore keyed to the original recording envelope,
        // never to the first/last clipped segment.
        guard let recordedStart = sortedBase.map(\.start).min(),
              let recordedEnd = sortedBase.map(\.end).max() else {
            return fill(start ..< end, stage: fillStage, coverage: coverage)
        }

        let hasInBedLayer = sortedBase.contains { $0.stage == .inBed }
        var out: [SleepSegment] = []
        let leadingEnd = min(end, recordedStart)
        if start < leadingEnd {
            // Match the classifier's two-layer representation: the extension is both in bed and
            // asleep. For synthetic stage-only input, keep it stage-only so Summary's fallback
            // remains valid instead of introducing a partial in-bed layer.
            if hasInBedLayer {
                out.append(contentsOf: fill(start ..< leadingEnd, stage: .inBed, coverage: coverage))
            }
            out.append(contentsOf: fill(start ..< leadingEnd, stage: fillStage, coverage: coverage))
        }
        out.append(contentsOf: clipped)
        let trailingStart = max(start, recordedEnd)
        if trailingStart < end {
            if hasInBedLayer {
                out.append(contentsOf: fill(trailingStart ..< end, stage: .inBed, coverage: coverage))
            }
            out.append(contentsOf: fill(trailingStart ..< end, stage: fillStage, coverage: coverage))
        }
        return out
    }

    /// Emit a USER-ASSERTED span as one or more segments, split at the coverage boundaries.
    ///
    /// This is the single choke point through which every invented minute in this file passes —
    /// `recompute`'s leading fill, trailing fill, empty-base fill, and the bedtime-to-onset `.awake`
    /// paint. Centralising it is deliberate: the audit found five separate fill sites and a fix
    /// applied to only some of them is a false sense of safety.
    ///
    /// `coverage == nil` returns exactly one `.measured` segment — bit-for-bit what the pre-
    /// provenance code emitted, which is what makes the kill switch a true no-op.
    private static func fill(_ range: Range<Date>, stage: SleepStage,
                             coverage: MeasuredCoverage?) -> [SleepSegment] {
        guard range.upperBound > range.lowerBound else { return [] }
        guard let coverage else {
            return [SleepSegment(start: range.lowerBound, end: range.upperBound, stage: stage)]
        }
        return coverage.partition(range).map { piece in
            SleepSegment(start: piece.range.lowerBound, end: piece.range.upperBound, stage: stage,
                         provenance: piece.measured ? .assertedOverMeasured : .asserted)
        }
    }

    /// Recompute using independent bedtime, sleep-onset, and wake anchors.
    ///
    /// The result always has one in-bed envelope. The bedtime-to-onset interval is explicitly
    /// `.awake`; recorded stages inside the original sleep window are preserved; only a user-added
    /// extension of the *sleep* window is synthetic core sleep. Thus moving bedtime earlier no
    /// longer inflates time asleep or produces 100% efficiency.
    /// - Parameter coverage: which instants the ring actually recorded. **`nil` is the kill switch**
    ///   and reproduces master byte-for-byte (proved by regenerating the corpus baseline TSV and
    ///   matching its sha256).
    ///
    /// 🟢 WHAT COVERAGE FIXES, MEASURED. On the tester night `R2_2026-08-18` this function emitted
    /// `{asleepCore, 02:37:02 → 06:43:00}` — 246 minutes — over a raw hole `02:35:02 → 06:38:57`
    /// holding 2 of ~98 expected epochs. The card read 403 min asleep at 0.918 efficiency on a night
    /// whose own coverage is 0.377, and the block reached Apple Health 1:1 as `.asleepCore`. With
    /// coverage supplied, the same call still emits the same 246 minutes — the user asserted them and
    /// clause 1 says an assertion wins for display — but ~243 of them now carry `.asserted`, which
    /// keeps them out of every stage minute, out of efficiency, out of the score, and out of Health.
    ///
    /// ⚠️ THE SIBLING DEFECT IS DELIBERATELY NOT "FIXED" HERE. `preservedStart` still discards
    /// recorded stages before the asserted onset, and the `.awake` paint below is still
    /// unconditional. Vetoing either would make the onset picker a no-op against OVER-detected sleep
    /// (`SleepEditTests.swift:19-40` is a real tester whose ring called onset 86 min early), and on
    /// `R2_2026-08-17` it would leave 14 SECONDS of preserved sleep — a card reading 0 min asleep
    /// across an 8 h 11 m in-bed window, which is a worse number than the bug. The answer is
    /// provenance plus reversibility: the paint is TAGGED (`.assertedOverMeasured` where the ring
    /// recorded), and the ring's own hypnogram is persisted separately so the disagreement is
    /// visible and undoable rather than silently resolved by deletion.
    public static func recompute(baseSegments: [SleepSegment], times: Times,
                                 fillStage: SleepStage = .asleepCore,
                                 coverage: MeasuredCoverage? = nil) -> [SleepSegment] {
        guard times.sleepWake > times.sleepOnset,
              times.sleepOnset >= times.inBedStart else { return [] }

        let stageBase = baseSegments
            .filter { $0.stage != .inBed }
            .sorted { $0.start < $1.start }
        let recordedSleep = SleepStaging.sleepWindow(stageBase)

        var stages: [SleepSegment] = []
        if let recordedSleep {
            let preservedStart = max(times.sleepOnset, recordedSleep.onset)
            let preservedEnd = min(times.sleepWake, recordedSleep.wake)

            // LEADING fill — the mirror of the trailing one below, and just as capable of inventing
            // sleep over a front-edge hole.
            if times.sleepOnset < min(times.sleepWake, recordedSleep.onset) {
                stages.append(contentsOf: fill(times.sleepOnset ..< min(times.sleepWake, recordedSleep.onset),
                                               stage: fillStage, coverage: coverage))
            }
            if preservedEnd > preservedStart {
                // The ring's own stages, kept verbatim — including their provenance, which is
                // `.measured` for anything staging produced.
                stages.append(contentsOf: stageBase.compactMap { segment in
                    let start = max(segment.start, preservedStart)
                    let end = min(segment.end, preservedEnd)
                    return end > start
                        ? SleepSegment(start: start, end: end, stage: segment.stage,
                                       provenance: segment.provenance) : nil
                })
            }
            // TRAILING fill — the 246-minute block on R2_2026-08-18.
            if max(times.sleepOnset, recordedSleep.wake) < times.sleepWake {
                stages.append(contentsOf: fill(max(times.sleepOnset, recordedSleep.wake) ..< times.sleepWake,
                                               stage: fillStage, coverage: coverage))
            }
        } else {
            // No staged base at all — 100 % of this night's "sleep" is the user's assertion.
            stages.append(contentsOf: fill(times.sleepOnset ..< times.sleepWake,
                                           stage: fillStage, coverage: coverage))
        }

        // The in-bed envelope is entirely a user claim, and we honour it (clause 1: in-bed is a
        // statement about where the body was, and we hold no competing measurement). Splitting it by
        // coverage is what lets a consumer compute efficiency over COVERED ground without re-deriving
        // anything: covered in-bed is just the non-`.asserted` part of this layer.
        var result = fill(times.inBedStart ..< times.inBedEnd, stage: .inBed, coverage: coverage)
        if times.inBedStart < times.sleepOnset {
            result.append(contentsOf: fill(times.inBedStart ..< times.sleepOnset,
                                           stage: .awake, coverage: coverage))
        }
        result.append(contentsOf: stages)
        return result
    }
}
