import SwiftUI
import OpenCircuitKit

// The strap's "DETECTED BY STRAP" section and its review (#226, decision 91d): the ring's "DETECTED BY
// RING" row and review layout in `WorkoutView`, copied for the strap's records (the ring's view is not
// changed). The record supplies the time, duration, energy and heart rate; the person picks the sport.

enum StrapDetectedWorkoutCopy {
    static let sectionTitle = "DETECTED BY STRAP"
    static let sectionNote = "Review within two days. The strap supplies the time, heart rate, and calories; confirm the activity type before saving."
    static let reviewNote = "The strap recorded this workout on its own, so check the activity type before saving. No GPS route is available for it."

    /// "Possible Workout" for the strap's auto-detected activity (it names no sport), else the sport.
    static func title(_ item: StrapDetectedWorkout) -> String {
        item.suggestedSport == .other ? "Possible Workout" : item.suggestedSport.displayName
    }

    /// The row's start time, duration and average heart rate (91d), the ring's date rule.
    static func subtitle(_ item: StrapDetectedWorkout, calendar: Calendar = .current, now: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateStyle = calendar.isDate(item.start, inSameDayAs: now) ? .none : .medium
        df.timeStyle = .short
        var parts = [df.string(from: item.start), duration(item.duration)]
        if let bpm = item.averageHeartRate { parts.append("avg \(bpm) bpm") }
        return parts.joined(separator: " · ")
    }

    /// The ring's review format ("25m 00s", "1h 05m").
    static func duration(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, s)
    }
}

struct StrapDetectedWorkoutSection: View {
    let items: [StrapDetectedWorkout]
    let onReview: (StrapDetectedWorkout) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(StrapDetectedWorkoutCopy.sectionTitle)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(items) { item in
                    Button { onReview(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.suggestedSport == .other ? "figure.mixed.cardio" : item.suggestedSport.systemImageName)
                                .font(.title2).foregroundStyle(.blue).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(StrapDetectedWorkoutCopy.title(item)).font(.subheadline.weight(.semibold))
                                Text(StrapDetectedWorkoutCopy.subtitle(item))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
                Text(StrapDetectedWorkoutCopy.sectionNote)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct StrapDetectedWorkoutReview: View {
    let item: StrapDetectedWorkout
    let detected: StrapDetectedWorkouts
    let onDone: () -> Void
    @State private var sport: WorkoutSportType

    init(item: StrapDetectedWorkout, detected: StrapDetectedWorkouts, onDone: @escaping () -> Void) {
        self.item = item
        self.detected = detected
        self.onDone = onDone
        _sport = State(initialValue: item.suggestedSport)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 38)).foregroundStyle(.blue)
                    Text("Detected Workout").font(.title2.weight(.bold))
                    Text(StrapDetectedWorkoutCopy.subtitle(item))
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCell("Duration", StrapDetectedWorkoutCopy.duration(item.duration))
                    statCell("Calories", item.kilocalories.map { "\($0) kcal" } ?? "--")
                    statCell("Avg HR", item.averageHeartRate.map { "\($0) bpm" } ?? "--")
                    statCell("Max HR", item.maximumHeartRate.map { "\($0) bpm" } ?? "--")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("CONFIRM ACTIVITY")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                        ForEach(WorkoutSportType.allCases, id: \.rawValue) { option in
                            SportButton(sport: option, selected: sport == option) { sport = option }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(StrapDetectedWorkoutCopy.reviewNote)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error = detected.saveError {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        if await detected.save(item, as: sport) { onDone() }
                    }
                } label: {
                    Label("Add to Apple Health", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(detected.saving)

                HStack {
                    Button("Back") { detected.clearSaveError(); onDone() }
                    Spacer()
                    Button("Not a Workout", role: .destructive) {
                        detected.discard(item)
                        onDone()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(detected.saving)
            }
            .padding()
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}
