// WorkoutWidgetBundle.swift — entry point of the WorkoutWidget app-extension.
//
// The extension renders the workout Live Activity (Lock Screen + Dynamic Island) and hosts the
// Control Centre / Lock Screen "Log a Headache" control. There is still no Home Screen / StandBy
// widget. The app target starts/updates/ends the Activity via `WorkoutLiveActivityController`; the
// system hands each `ContentState` to this process to render.
//
// (The extension's name is now narrower than its contents. It is deliberately NOT renamed: the
// bundle id com.standardsoftwaresolutions.opencircuit.WorkoutWidget is a registered App ID under
// the paid team and is embedded in shipped builds, so renaming it costs a provisioning round-trip
// and buys nothing.)

import WidgetKit
import SwiftUI

@main
struct WorkoutWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        // `ControlWidget` is iOS 18+ while this extension deploys to iOS 17 alongside the app, so
        // the control is registered behind an availability check. On iOS 17 the bundle contains
        // just the Live Activity, exactly as it shipped — the control's absence changes nothing
        // about it. (`WidgetBundleBuilder.buildOptional` accepts the limited-availability widget
        // this produces.)
        if #available(iOS 18.0, *) {
            HeadacheLogControl()
        }
    }
}
