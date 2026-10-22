import AppIntents
import Foundation
import Observation
import OpenCircuitKit

// "Start Workout" for Shortcuts, Siri, the Action button and automations. The person picks the
// workout type when they set the shortcut up (or Shortcuts asks when it runs, if left blank); the
// rules for what happens next live in `WorkoutShortcutStart` (Kit, unit-tested).
//
// It OPENS THE APP (`supportedModes = .foreground`, `openAppWhenRun = true`), unlike the wearable
// actions in WearableShortcutIntents.swift: a workout is something you watch start (its Live
// Activity can only be requested by a foreground app, an outdoor route may need the location prompt,
// and the workout sheet is where you see it is recording). It lives in the APP target only, like
// every intent here, so it performs in the app's process against the app-lifetime recorders.
//
// Listed in `OpenCircuitAppShortcuts` (HeadacheLogIntent.swift), the app's only provider.

/// The workout types, as Shortcuts and Siri show them. Mirrors `WorkoutSportType` one to one; the
/// titles are literals because the App Intents metadata is extracted at build time, and
/// `WorkoutShortcutIntentTests` pins them to `WorkoutSportType.displayName` so the shortcut and the
/// in-app picker can never name a type differently.
enum WorkoutTypeChoice: String, AppEnum, CaseIterable {
    case walkingOutdoor, walkingIndoor, runningOutdoor, runningIndoor, cyclingOutdoor, cyclingIndoor
    case rowing, hiking, strengthTraining, yoga, other

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workout Type"
    static let caseDisplayRepresentations: [WorkoutTypeChoice: DisplayRepresentation] = [
        .walkingOutdoor: DisplayRepresentation(title: "Outdoor Walking", synonyms: ["Outdoor Walk", "Walk"]),
        .walkingIndoor: DisplayRepresentation(title: "Indoor Walking", synonyms: ["Indoor Walk", "Treadmill Walk"]),
        .runningOutdoor: DisplayRepresentation(title: "Outdoor Running", synonyms: ["Outdoor Run", "Run"]),
        .runningIndoor: DisplayRepresentation(title: "Indoor Running", synonyms: ["Indoor Run", "Treadmill Run"]),
        .cyclingOutdoor: DisplayRepresentation(title: "Outdoor Cycling", synonyms: ["Outdoor Ride", "Bike Ride"]),
        .cyclingIndoor: DisplayRepresentation(title: "Indoor Cycling", synonyms: ["Indoor Ride", "Spin"]),
        .rowing: DisplayRepresentation(title: "Indoor Rowing", synonyms: ["Rowing", "Row"]),
        .hiking: DisplayRepresentation(title: "Hiking", synonyms: ["Hike"]),
        .strengthTraining: DisplayRepresentation(title: "Strength", synonyms: ["Strength Training", "Weights"]),
        .yoga: DisplayRepresentation(title: "Yoga"),
        .other: DisplayRepresentation(title: "Other"),
    ]

    var sport: WorkoutSportType {
        switch self {
        case .walkingOutdoor: return .walkingOutdoor
        case .walkingIndoor: return .walkingIndoor
        case .runningOutdoor: return .runningOutdoor
        case .runningIndoor: return .runningIndoor
        case .cyclingOutdoor: return .cyclingOutdoor
        case .cyclingIndoor: return .cyclingIndoor
        case .rowing: return .rowing
        case .hiking: return .hiking
        case .strengthTraining: return .strengthTraining
        case .yoga: return .yoga
        case .other: return .other
        }
    }
}

struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Workout"
    static let description = IntentDescription(
        "Opens OpenCircuit and starts recording a workout of the type you choose with your ring or strap. If the wearable is still connecting or syncing, the workout starts as soon as it's ready. If a workout is already recording, it opens that one instead.",
        categoryName: "Workouts",
        searchKeywords: ["workout", "exercise", "start", "run", "walk", "ride", "training"])

    /// A workout is watched as it starts; see the file comment.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    /// iOS 17...25. On iOS 26+ `supportedModes` above is authoritative.
    static let openAppWhenRun = true

    /// No default on purpose: Shortcuts asks for the type when the shortcut is set up, and asks again
    /// at run time if it was left blank.
    @Parameter(title: "Workout Type", description: "The kind of workout to record.")
    var workoutType: WorkoutTypeChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$workoutType) workout")
    }

    init() {}

    init(workoutType: WorkoutTypeChoice) {
        self.workoutType = workoutType
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutShortcutInbox.shared.submit(workoutType.sport)
        return .result()
    }
}

/// The shortcut's hand-off to `ContentView`, which owns both workout recorders and their sheets. One
/// request at a time: a second run before the first was applied replaces it (the newer choice wins).
@Observable
@MainActor
final class WorkoutShortcutInbox {
    static let shared = WorkoutShortcutInbox()

    /// The request waiting to be applied, or nil.
    private(set) var pending: WorkoutShortcutStart.Request?

    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    func submit(_ sport: WorkoutSportType) {
        pending = WorkoutShortcutStart.Request(sport: sport, requestedAt: clock())
    }

    /// Drop the request: applied, timed out, or the person closed the sheet while it waited.
    func clear() {
        pending = nil
    }
}
