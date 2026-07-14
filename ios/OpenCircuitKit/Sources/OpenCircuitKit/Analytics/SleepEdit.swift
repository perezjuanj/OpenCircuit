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

    public static func bounds(recordedOnset: Date, recordedWake: Date) -> Bounds {
        Bounds(earliest: recordedOnset.addingTimeInterval(-editMargin),
               latest: recordedWake.addingTimeInterval(editMargin))
    }

    /// Clamp a proposed edge into the editable bounds (for a live-dragging picker).
    public static func clamp(_ date: Date, to bounds: Bounds) -> Date {
        min(max(date, bounds.earliest), bounds.latest)
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

    /// Why a proposed edit is rejected. nil (from `validate`) means the edit is allowed.
    public enum Invalid: Error, Equatable, Sendable {
        case endNotAfterStart
        case startBeforeEarliest    // pushed bedtime > 3 h before recorded onset
        case endAfterLatest         // pushed wake > 3 h after recorded wake
        case tooShort(minMinutes: Int)
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
    public static func recompute(baseSegments: [SleepSegment], window: Window,
                                 fillStage: SleepStage = .asleepCore) -> [SleepSegment] {
        let start = window.inBedStart, end = window.inBedEnd
        guard end > start else { return [] }

        // Clip each base segment to the window; drop any that fall entirely outside.
        let sortedBase = baseSegments.sorted { $0.start < $1.start }
        let clipped: [SleepSegment] = sortedBase.compactMap { seg in
            let s = max(seg.start, start), e = min(seg.end, end)
            return e > s ? SleepSegment(start: s, end: e, stage: seg.stage) : nil
        }

        // With no recording at all, the user's whole window is synthetic asleep time. With a
        // non-empty recording, however, an empty `clipped` array can mean the proposed window sits
        // wholly inside an INTERIOR recording gap; that gap must remain empty rather than becoming
        // invented sleep. Extension fill is therefore keyed to the original recording envelope,
        // never to the first/last clipped segment.
        guard let recordedStart = sortedBase.map(\.start).min(),
              let recordedEnd = sortedBase.map(\.end).max() else {
            return [SleepSegment(start: start, end: end, stage: fillStage)]
        }

        let hasInBedLayer = sortedBase.contains { $0.stage == .inBed }
        var out: [SleepSegment] = []
        let leadingEnd = min(end, recordedStart)
        if start < leadingEnd {
            // Match the classifier's two-layer representation: the extension is both in bed and
            // asleep. For synthetic stage-only input, keep it stage-only so Summary's fallback
            // remains valid instead of introducing a partial in-bed layer.
            if hasInBedLayer { out.append(SleepSegment(start: start, end: leadingEnd, stage: .inBed)) }
            out.append(SleepSegment(start: start, end: leadingEnd, stage: fillStage))
        }
        out.append(contentsOf: clipped)
        let trailingStart = max(start, recordedEnd)
        if trailingStart < end {
            if hasInBedLayer { out.append(SleepSegment(start: trailingStart, end: end, stage: .inBed)) }
            out.append(SleepSegment(start: trailingStart, end: end, stage: fillStage))
        }
        return out
    }
}
