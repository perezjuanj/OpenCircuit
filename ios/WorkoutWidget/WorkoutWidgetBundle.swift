// WorkoutWidgetBundle.swift — entry point of the WorkoutWidget app-extension.
//
// The extension exists ONLY to render the workout Live Activity (Lock Screen + Dynamic Island).
// There is no Home Screen / StandBy widget, so the bundle contains a single Live Activity widget.
// The app target starts/updates/ends the Activity via `WorkoutLiveActivityController`; the system
// hands each `ContentState` to this process to render.

import WidgetKit
import SwiftUI

@main
struct WorkoutWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}
