// WorkoutLiveActivity.swift — the Live Activity presentation for an in-progress workout.
//
// Renders three metrics the user asked for while a workout runs: TIME executed, CALORIES burned
// (estimate), and heart-rate BPM. Two surfaces:
//   • Lock Screen / banner — `ActivityConfiguration`'s content closure.
//   • Dynamic Island — compact (icon+timer / heart), minimal (heart), and expanded (all three).
//
// The elapsed clock uses `Text(timerInterval:)` seeded from the immutable `startDate`, so it ticks
// every second ON ITS OWN — no `Activity.update` needed just to advance the clock. Calories and BPM
// come from `ContentState`, refreshed by the app while the workout is alive.
//
// HONESTY (#45): when HR hasn't locked / has gone stale, `bpm == nil` or `hrIsStale == true`; the
// UI shows "--" / dims the number rather than freezing a held value as if it were live.
//
// TAP TARGET (tester report 2026-08-29, build 49): every surface below carries
// `WorkoutQuickLink.activeSession` as its `widgetURL`. Before that there was no `widgetURL`
// anywhere in `ios/`, so tapping this activity cold-opened the app onto its default screen and the
// tester "[didn't] know where the currently recording activity went". `widgetURL` is the ONLY
// supported tap target for a Live Activity — the lock-screen view and the compact/minimal Dynamic
// Island presentations cannot host a Button — so it is set on the lock-screen content, on the
// `DynamicIsland` itself (which covers compact + minimal), and on each expanded region.

import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock Screen / banner
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
                // Route the tap to the running session instead of a cold open (see the header).
                .widgetURL(WorkoutQuickLink.activeSession)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — the full three-metric view.
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.sportName)
                            .font(.caption).fontWeight(.semibold)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: context.attributes.sportSymbolName)
                            .foregroundStyle(.blue)
                    }
                    .widgetURL(WorkoutQuickLink.activeSession)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HeartRateLabel(bpm: context.state.bpm, isStale: context.state.hrIsStale || context.isStale)
                        .font(.caption).fontWeight(.semibold)
                        .widgetURL(WorkoutQuickLink.activeSession)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            ElapsedText(startDate: context.attributes.startDate, state: context.state)
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .monospacedDigit()
                            Spacer()
                            CaloriesLabel(kcal: context.state.activeKcal)
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                        }
                        // Only what exists: no distance/pace indoors or without a fix, no zone on a stale HR.
                        let live = !(context.state.hrIsStale || context.isStale)
                        if context.state.hasGPSMetrics || (live && context.state.hrZone != nil) {
                            HStack(spacing: 10) {
                                if let meters = context.state.distanceMeters {
                                    Text(LiveFormat.distance(meters, miles: context.state.usesMiles))
                                }
                                if let pace = context.state.currentPaceSecPerKm {
                                    Text("\(LiveFormat.pace(pace, miles: context.state.usesMiles)) GPS")
                                }
                                if let avg = context.state.avgPaceSecPerKm {
                                    Text("avg \(LiveFormat.pace(avg, miles: context.state.usesMiles))")
                                }
                                if live, let zone = context.state.hrZone {
                                    Text(WorkoutActivityAttributes.ContentState.zoneLabel(zone))
                                        .accessibilityLabel(WorkoutActivityAttributes.ContentState.zoneAccessibilityLabel(zone))
                                }
                            }
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                        if context.state.pausedElapsed != nil {
                            Text("Paused").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 2)
                    .widgetURL(WorkoutQuickLink.activeSession)
                }
            } compactLeading: {
                // Sport icon + ticking timer.
                HStack(spacing: 3) {
                    Image(systemName: context.attributes.sportSymbolName)
                        .foregroundStyle(.blue)
                    ElapsedText(startDate: context.attributes.startDate, state: context.state)
                        .monospacedDigit()
                }
            } compactTrailing: {
                // Heart rate (or -- when not locked).
                HeartRateLabel(bpm: context.state.bpm, isStale: context.state.hrIsStale || context.isStale)
            } minimal: {
                Image(systemName: "heart.fill")
                    .foregroundStyle((context.state.hrIsStale || context.isStale) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            // Tap target for the COMPACT and MINIMAL presentations — those closures render into a
            // system-owned container that cannot host a Button, so the URL must be set here on the
            // DynamicIsland itself. (The expanded regions each carry their own, above.)
            .widgetURL(WorkoutQuickLink.activeSession)
            .keylineTint(.red)
        }
    }
}

// MARK: - Lock Screen view

@available(iOS 16.1, *)
private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(spacing: 12) {
            // Header: sport icon + name.
            HStack(spacing: 8) {
                Image(systemName: context.attributes.sportSymbolName)
                    .foregroundStyle(.blue)
                Text(context.attributes.sportName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Workout")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Three metrics: time, calories, BPM.
            HStack(alignment: .top) {
                metric(title: "TIME") {
                    ElapsedText(startDate: context.attributes.startDate, state: context.state)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                Spacer()
                metric(title: "CALORIES") {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Text("\(context.state.activeKcal)")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                    }
                }
                Spacer()
                metric(title: "HEART") {
                    HeartRateLabel(bpm: context.state.bpm, isStale: context.state.hrIsStale || context.isStale)
                        .font(.system(.title, design: .rounded).weight(.bold))
                }
            }

            // GPS row — only what exists. Indoor / no-fix workouts have no distance or pace and show
            // no row at all (NO-FABRICATION); the zone appears only for a fresh reading.
            if context.state.hasGPSMetrics || zoneText != nil {
                HStack(alignment: .top) {
                    if let meters = context.state.distanceMeters {
                        metric(title: "DISTANCE") {
                            Text(LiveFormat.distance(meters, miles: context.state.usesMiles))
                                .font(.system(.headline, design: .rounded).weight(.bold)).monospacedDigit()
                        }
                    }
                    if let pace = context.state.currentPaceSecPerKm {
                        Spacer()
                        metric(title: "PACE (GPS)") {
                            Text(LiveFormat.pace(pace, miles: context.state.usesMiles))
                                .font(.system(.headline, design: .rounded).weight(.bold)).monospacedDigit()
                        }
                    }
                    if let avg = context.state.avgPaceSecPerKm {
                        Spacer()
                        metric(title: "AVG PACE") {
                            Text(LiveFormat.pace(avg, miles: context.state.usesMiles))
                                .font(.system(.headline, design: .rounded).weight(.bold)).monospacedDigit()
                        }
                    }
                    if let zoneText {
                        Spacer()
                        metric(title: "HEART RATE") {
                            Text(zoneText)
                                .font(.system(.headline, design: .rounded).weight(.bold))
                                .accessibilityLabel(zoneAccessibilityText ?? zoneText)
                        }
                    }
                }
            }
            if context.state.pausedElapsed != nil {
                Text("Paused").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .padding()
    }

    private var zoneText: String? {
        guard !(context.state.hrIsStale || context.isStale), let zone = context.state.hrZone else { return nil }
        return WorkoutActivityAttributes.ContentState.zoneLabel(zone)
    }

    private var zoneAccessibilityText: String? {
        guard !(context.state.hrIsStale || context.isStale), let zone = context.state.hrZone else { return nil }
        return WorkoutActivityAttributes.ContentState.zoneAccessibilityLabel(zone)
    }

    @ViewBuilder
    private func metric<Content: View>(title: String,
                                       @ViewBuilder _ value: () -> Content) -> some View {
        VStack(spacing: 2) {
            value()
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formatting

private extension WorkoutActivityAttributes.ContentState {
    /// Any GPS-derived figure is present.
    var hasGPSMetrics: Bool { distanceMeters != nil || currentPaceSecPerKm != nil || avgPaceSecPerKm != nil }
}

/// Distance and pace text, in the unit the app chose (`usesMiles`; the widget cannot read the setting).
private enum LiveFormat {
    static func distance(_ meters: Double, miles: Bool) -> String {
        miles ? String(format: "%.2f mi", meters / 1609.344) : String(format: "%.2f km", meters / 1000)
    }

    /// m:ss per km (or per mi).
    static func pace(_ secPerKm: Double, miles: Bool) -> String {
        let t = Int((miles ? secPerKm * 1.609344 : secPerKm).rounded())
        return String(format: "%d:%02d/%@", t / 60, t % 60, miles ? "mi" : "km")
    }
}

// MARK: - Shared metric labels

/// Self-ticking elapsed-time text seeded from the immutable start date; the OS advances it every
/// second on its own, so no content update is needed just to move the clock.
@available(iOS 16.1, *)
private struct ElapsedText: View {
    let startDate: Date
    /// The strap's workout can pause (#227): `clockStart`/`pausedElapsed` are nil for the ring's, so
    /// its clock is exactly the `startDate` timer it always was.
    var state: WorkoutActivityAttributes.ContentState? = nil

    var body: some View {
        if let paused = state?.pausedElapsed {
            // Paused: the clock stands still at the running time, in the timer's own H:MM:SS / M:SS shape.
            Text(Self.clockText(paused))
                .lineLimit(1)
                .multilineTextAlignment(.center)
        } else {
            // countsDown:false ⇒ counts UP from startDate; the OS advances it every second with no update.
            // multilineTextAlignment(.center): Text(timerInterval:) reserves a wider frame (room for the
            // widest H:MM:SS) and LEFT-aligns the digits inside it by default, so "0:22" drifted to the
            // left of the centered "TIME" label. Centering the digits within that reserved frame lines the
            // value up under its label, matching the calories/heart columns.
            Text(timerInterval: (state?.clockStart ?? startDate)...Date.distantFuture, countsDown: false)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
    }

    static func clockText(_ seconds: TimeInterval) -> String {
        let t = max(Int(seconds), 0)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Heart-rate label: the reading in bold red, dimmed to secondary when stale, or "--" when no
/// genuine reading has locked yet. Never shows a fabricated/held value (#45).
@available(iOS 16.1, *)
private struct HeartRateLabel: View {
    let bpm: Int?
    let isStale: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.caption)
                .foregroundStyle(bpm == nil || isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            if let bpm {
                Text("\(bpm)")
                    .monospacedDigit()
                    .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            } else {
                Text("--")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Calories label with a flame glyph. Whole kcal; labeled elsewhere as an estimate.
@available(iOS 16.1, *)
private struct CaloriesLabel: View {
    let kcal: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.caption).foregroundStyle(.orange)
            Text("\(kcal)")
                .monospacedDigit()
            Text("cal")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
