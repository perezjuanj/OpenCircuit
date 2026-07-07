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
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HeartRateLabel(bpm: context.state.bpm, isStale: context.state.hrIsStale || context.isStale)
                        .font(.caption).fontWeight(.semibold)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .firstTextBaseline) {
                        ElapsedText(startDate: context.attributes.startDate)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Spacer()
                        CaloriesLabel(kcal: context.state.activeKcal)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                // Sport icon + ticking timer.
                HStack(spacing: 3) {
                    Image(systemName: context.attributes.sportSymbolName)
                        .foregroundStyle(.blue)
                    ElapsedText(startDate: context.attributes.startDate)
                        .monospacedDigit()
                }
            } compactTrailing: {
                // Heart rate (or -- when not locked).
                HeartRateLabel(bpm: context.state.bpm, isStale: context.state.hrIsStale || context.isStale)
            } minimal: {
                Image(systemName: "heart.fill")
                    .foregroundStyle((context.state.hrIsStale || context.isStale) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
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
                    ElapsedText(startDate: context.attributes.startDate)
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
        }
        .padding()
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

// MARK: - Shared metric labels

/// Self-ticking elapsed-time text seeded from the immutable start date; the OS advances it every
/// second on its own, so no content update is needed just to move the clock.
@available(iOS 16.1, *)
private struct ElapsedText: View {
    let startDate: Date

    var body: some View {
        // countsDown:false ⇒ counts UP from startDate; the OS advances it every second with no update.
        // multilineTextAlignment(.center): Text(timerInterval:) reserves a wider frame (room for the
        // widest H:MM:SS) and LEFT-aligns the digits inside it by default, so "0:22" drifted to the
        // left of the centered "TIME" label. Centering the digits within that reserved frame lines the
        // value up under its label, matching the calories/heart columns.
        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
            .lineLimit(1)
            .multilineTextAlignment(.center)
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
