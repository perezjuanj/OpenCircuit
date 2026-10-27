// WorkoutActivityAttributes.swift — the ActivityKit contract for the workout Live Activity.
//
// SHARED SOURCE: this one file is compiled into BOTH the app target (which starts/updates/ends
// the Activity via `WorkoutLiveActivityController`) and the `WorkoutWidget` extension (which
// RENDERS it on the Lock Screen and in the Dynamic Island). It is the only type the two targets
// must agree on, so it is kept deliberately small and dependency-free.
//
// WHY it lives here and NOT in OpenCircuitKit: conforming to `ActivityAttributes` requires
// `import ActivityKit`, and the Kit is Foundation-only by contract (Package.swift) so it can build
// and test on the command line without Xcode. Importing ActivityKit there would break that. So the
// attributes are a plain shared file, and every value is a primitive (String/Int/Bool/Date/
// TimeInterval) — no Kit types — so the widget extension needs no OpenCircuitKit dependency.
//
// NO-FABRICATION (CLAUDE.md / #45): `bpm` is optional and `hrIsStale` is honest. When the ring's
// best-effort live-HR poll can't lock (the common in-motion case), the app sends `bpm = nil` /
// `hrIsStale = true` and the widget shows "--" / "measuring…" rather than freezing a held value
// and pretending it is live. `activeKcal` is an ESTIMATE (Keytel HR→energy); the widget labels it.
// The same holds for `distanceMeters`, the two paces and `hrZone` (#283): nil unless genuinely measured,
// and the widget HIDES them (indoor / no GPS) instead of showing 0 or a held value. Pace is GPS-derived.

import Foundation
import ActivityKit

/// Attributes + dynamic content for the in-progress-workout Live Activity.
///
/// Availability: `ActivityAttributes` is iOS 16.1+. The app deploys to iOS 17, and this file is
/// only ever referenced from ActivityKit code paths, so no per-symbol availability gate is needed.
@available(iOS 16.1, *)
struct WorkoutActivityAttributes: ActivityAttributes {

    /// Dynamic state, refreshed by `Activity.update(...)` as the workout runs.
    public struct ContentState: Codable, Hashable {
        /// Elapsed seconds at the moment this state was published. The widget prefers a self-ticking
        /// `Text(timerInterval:)` seeded from `startDate` (below) so the clock advances every second
        /// WITHOUT an update; this numeric value is the fallback for the minimal/compact presentations
        /// and any place a live-ticking timer doesn't fit.
        public var elapsedSeconds: TimeInterval
        /// Estimated active calories so far (ESTIMATE — Keytel HR→energy; labeled in the UI). Whole
        /// kcal, monotonically growing while HR is present.
        public var activeKcal: Int
        /// Most recent GENUINE heart-rate reading in bpm, or nil when none has locked yet / the last
        /// reading has aged out. Never a held/fabricated value.
        public var bpm: Int?
        /// True when `bpm` is older than the freshness window — the widget dims it and shows
        /// "measuring…" instead of implying the number is live (#45 honesty).
        public var hrIsStale: Bool
        /// A workout with pauses (either device, #227 / #283): the instant the clock counts up from,
        /// so it shows running time only. nil (a workout never paused) counts from `startDate`,
        /// exactly as before.
        public var clockStart: Date? = nil
        /// Set while paused: the clock stands still at this many seconds. nil while running.
        public var pausedElapsed: TimeInterval? = nil
        /// GPS distance so far in metres (phone location; the same figure both devices' workouts use).
        /// nil for indoor sports, with location off, or before the first fix — the widget then shows
        /// no distance at all rather than 0 or a held value.
        public var distanceMeters: Double? = nil
        /// Pace over the last ~30 s of GPS, seconds per km. nil when the fixes are stale or too few.
        /// GPS-derived; the widget labels it so.
        public var currentPaceSecPerKm: Double? = nil
        /// Pace over the whole running time (pauses excluded), seconds per km. nil without enough GPS.
        public var avgPaceSecPerKm: Double? = nil
        /// Live HR zone 1...5 from the last FRESH reading; nil when HR is stale/absent or below zone 1.
        public var hrZone: Int? = nil
        /// Show distance in miles and pace per mile (the app's distance-unit setting, which the
        /// widget extension cannot read itself). false = km.
        public var usesMiles: Bool = false

        /// "Zone 3": how the Live Activity names a zone (decision 83a), the same name the app uses.
        public static func zoneLabel(_ zone: Int) -> String { "Zone \(zone)" }
        /// What VoiceOver says for the zone: "Heart rate zone 3".
        public static func zoneAccessibilityLabel(_ zone: Int) -> String { "Heart rate zone \(zone)" }
    }

    // MARK: Fixed attributes (set once at start, immutable for the Activity's life)

    /// Human-readable sport name, e.g. "Outdoor Running" (`WorkoutSportType.displayName`).
    public var sportName: String
    /// SF Symbol name for the sport, e.g. "figure.run" (`WorkoutSportType.systemImageName`).
    public var sportSymbolName: String
    /// Session start (wall clock). Seeds the widget's self-ticking `Text(timerInterval:)` so the
    /// elapsed clock advances on its own between content updates.
    public var startDate: Date
}
