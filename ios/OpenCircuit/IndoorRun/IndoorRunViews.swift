import SwiftUI
import OpenCircuitKit

// The indoor run or walk on screen (#339, decision 84d, 84e): cadence and the step-based distance while
// recording, then on the summary the cadence, the distance (marked "est." until corrected) and the
// "Treadmill distance?" / "Incline %" prompt. One call site each in the ring's `WorkoutView` and the
// strap's `StrapWorkoutView`.

/// Cadence and the estimated distance, live.
struct IndoorRunLiveStats: View {
    let cadence: Double?
    let estimatedMeters: Double?
    let distanceUnit: DistanceUnit

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(cadence.map { "\(Int($0.rounded()))" } ?? "--").font(.title2.weight(.semibold)).monospacedDigit()
                Text("Steps/min").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(estimatedMeters.map { String(format: "%.2f", distanceUnit.convert(fromMeters: $0)) } ?? "--")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text(distanceUnit.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Text("Distance (est.)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The summary's indoor section: what the steps gave, and the prompt that corrects it.
struct IndoorRunSummarySection: View {
    let finish: IndoorRunFinish
    let distanceUnit: DistanceUnit
    @State private var distanceText = ""
    @State private var inclineText = ""
    @FocusState private var focused: Bool

    private var metersPerUnit: Double { distanceUnit == .metric ? 1_000 : 1_609.344 }
    private var typed: Double? { IndoorRunEntry.distanceMeters(distanceText, metersPerUnit: metersPerUnit) }
    private var inclineIsValid: Bool { inclineText.trimmingCharacters(in: .whitespaces).isEmpty || IndoorRunEntry.incline(inclineText) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STEPS AND DISTANCE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                stat(finish.averageCadence.map { "\(Int($0.rounded())) spm" } ?? "--", "Avg cadence")
                stat("\(finish.inputs.activeSteps)", "Steps")
                stat(finish.distanceMeters.map { UnitsFormatter.distance($0, unit: distanceUnit, fractionDigits: 2) } ?? "--",
                     finish.distanceIsEstimate ? "Distance (est.)" : "Distance")
            }
            ForEach(Self.notes(finish), id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !finish.minuteCadence.isEmpty {
                DisclosureGroup("Cadence per minute") {
                    ForEach(Array(finish.minuteCadence.enumerated()), id: \.offset) { index, minute in
                        HStack {
                            Text("Minute \(index + 1)").font(.caption)
                            Spacer()
                            Text("\(minute.steps) spm").font(.caption).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
            if !finish.submitted {
                prompt
            }
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Treadmill distance?").font(.subheadline.weight(.semibold))
            Text("Optional. Type what the treadmill shows to replace the estimate. It also calibrates your stride for the next \(finish.inputs.sport.displayName.lowercased()).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Distance", text: $distanceText).keyboardType(.decimalPad).focused($focused)
                    .textFieldStyle(.roundedBorder)
                Text(distanceUnit.symbol).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Incline % (optional, 0-15)", text: $inclineText).keyboardType(.decimalPad).focused($focused)
                    .textFieldStyle(.roundedBorder)
                Text("%").foregroundStyle(.secondary)
            }
            if !inclineIsValid {
                Text("Incline must be between 0 and 15 %.").font(.caption).foregroundStyle(.orange)
            }
            Button("Save Distance") {
                guard let typed else { return }
                focused = false
                finish.submit(typedMeters: typed, inclinePercent: IndoorRunEntry.incline(inclineText))
            }
            .buttonStyle(.bordered)
            .disabled(typed == nil || !inclineIsValid)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// What the numbers are made of, in words (no fabricated precision): where the stride came from,
    /// what is missing, and what reached Apple Health.
    static func notes(_ finish: IndoorRunFinish) -> [String] {
        var notes: [String] = []
        let inputs = finish.inputs
        if inputs.activeSteps == 0, finish.distanceIsEstimate {
            notes.append("No steps were counted during this workout, so it has no distance estimate or cadence.")
        } else if inputs.activeSteps == 0 {
            notes.append("Distance as you typed it. No steps were counted, so there is no cadence and no stride to calibrate.")
        } else if finish.distanceIsEstimate {
            switch finish.stride?.source {
            case .height?: notes.append("The distance is an ESTIMATE: your steps times a stride from your height. Type the treadmill's distance to correct it.")
            case .calibrated?: notes.append("The distance is an ESTIMATE: your steps times the stride your last treadmill distance gave.")
            case .typed?, nil: notes.append("Set your height in Profile for a distance estimate from your steps.")
            }
        } else if inputs.stepsInterrupted {
            notes.append("Distance as you typed it. Steps stopped when the strap disconnected, so this run didn't calibrate your stride.")
        } else if finish.calibrationStored {
            notes.append("Distance as you typed it; your stride for the next one is calibrated from it.")
        } else {
            notes.append("Distance as you typed it. It doesn't fit your step count as a stride, so your stride wasn't changed.")
        }
        if inputs.stepsInterrupted, finish.distanceIsEstimate {
            notes.append("Steps stopped when the strap disconnected, so the steps and the estimate cover only the time before.")
        }
        if !inputs.savedToHealth {
            return notes
        }
        switch finish.distanceStatus {
        case .saved?: notes.append("Distance saved to Apple Health.")
        case .failed?: notes.append("Apple Health didn't accept the typed distance; the estimate stays there.")
        case .savedEstimateKept?: notes.append("The typed distance is in Apple Health, but the estimate couldn't be removed, so Health shows both for this workout.")
        case .notConnected?: notes.append("The distance isn't in Apple Health: Health isn't connected.")
        case .sharingOff?, nil: break
        }
        if IndoorStepWorkout.writesRunningMetrics(inputs.sport) {
            switch finish.runningMetricsStatus {
            case .saved?: notes.append("Running speed and stride length saved to Apple Health, minute by minute.")
            case .sharingOff?: notes.append("Running speed and stride length aren't saved: they're turned off for OpenCircuit in Apple Health.")
            case .failed?: notes.append("Apple Health didn't accept the running speed and stride length.")
            case .notConnected?, .savedEstimateKept?, nil: break
            }
        }
        notes.append("Cadence stays in OpenCircuit: Apple Health has no cadence type.")
        return notes
    }
}
