// "How sleep need is worked out": every term behind the Sleep card's need line, with its value, which
// parts are published research and which are OpenCircuit's own estimates. Opened from the Sleep card.

import SwiftUI
import OpenCircuitKit

struct SleepNeedView: View {
    let result: SleepNeed.Result
    /// When `result` was worked out; a bedtime before this is already past.
    let computedAt: Date
    @Environment(\.dismiss) private var dismiss

    private var bedtime: Date? { SleepNeedText.upcomingBedtime(result, now: computedAt) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Sleep goal", SleepNeedText.duration(result.goalMin),
                        "Your goal for the day tonight's sleep ends on, weekday or weekend. Change it in Profile.")
                    row("Sleep debt", result.hasEnoughNights ? SleepNeedText.duration(result.debtMin) : "none yet",
                        result.hasEnoughNights
                            ? "Worked out over your last \(result.nightsUsed) recorded nights. A night with no recording is left out, not counted as no sleep."
                            : "Debt needs at least 3 recorded nights; you have \(result.knownNights). Until then it adds nothing.")
                    row("Naps today", result.napMin > 0 ? "−\(SleepNeedText.duration(result.napMin))" : "none",
                        "Sleep from naps since you woke, taken off tonight's need.")
                    row("Need tonight", SleepNeedText.duration(result.needMin), needNote)
                } header: {
                    Text("Tonight")
                }

                Section {
                    row("Wake time", result.nextWake.map(SleepNeedText.clock) ?? "not set",
                        result.nextWake == nil
                            ? "No sleep schedule is set, so there is no bedtime to suggest. Turn on a sleep schedule in Profile to get one."
                            : "From your sleep schedule.")
                    row("Time to fall asleep", SleepNeedText.duration(result.latencyMin),
                        result.latencyIsDefault
                            ? "Assumed until 3 nights record when you fell asleep."
                            : "The median of your recent nights, between 0 and 60 minutes.")
                    if result.nextWake != nil {
                        row("In bed by", bedtime.map(SleepNeedText.clock) ?? "now",
                            bedtime == nil
                                ? "Past the time to be in bed for your wake time. Sooner is better."
                                : "Wake time, minus need, minus time to fall asleep.")
                    }
                } header: {
                    Text("Bedtime")
                }

                Section {
                    Text("Each night's debt is 55% of what is left after your goal plus the debt carried in, minus "
                         + "the sleep you got (naps that day included). Debt under 10 minutes counts as none, and "
                         + "extra sleep never builds a credit. Need is held between 1 hour under and 2 hours over "
                         + "your goal.")
                        .font(.footnote)
                    Text("The 55% carry, the 14-night window, the 10-minute floor, the limits on need and the "
                         + "15-minute default for falling asleep are OpenCircuit estimates, not published figures. "
                         + "This is an estimate to plan around, not medical advice.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("How it is worked out")
                }

                Section {
                    ForEach(HealthSources.source(.sleepNeed).citations, id: \.self) { citation in
                        Link(destination: citation.url) {
                            Label {
                                Text(citation.text).font(.footnote).multilineTextAlignment(.leading)
                            } icon: {
                                Image(systemName: "book.closed")
                            }
                        }
                        .accessibilityHint("Opens the source in Safari")
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Research shows that restricted sleep accumulates and takes several nights to repay. "
                         + "The goal itself follows the published adult sleep-duration advice.")
                }
            }
            .navigationTitle("How sleep need is worked out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private var needNote: String {
        if result.needMin < result.unclampedNeedMin {
            return "Goal plus debt less naps is \(SleepNeedText.duration(result.unclampedNeedMin)); held to 2 hours over your goal."
        }
        if result.needMin > result.unclampedNeedMin {
            return "Goal plus debt less naps is \(SleepNeedText.duration(max(result.unclampedNeedMin, 0))); held to 1 hour under your goal."
        }
        return "Goal, plus debt, less naps."
    }

    private func row(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value). \(note)")
    }
}
