// HeadacheLogControl.swift — a Control Centre / Lock Screen button that logs a headache.
//
// This is the shortest path the platform offers: from a locked phone it is one press to reveal
// Control Centre (or a swipe to the customisable Lock Screen control) and ONE tap on this button.
// That matters more here than anywhere else in the app — a headache label that isn't captured in
// the moment is usually never captured at all, and somebody with a headache is not going to unlock,
// find the app, scroll to a card and fill in a Form.
//
// AVAILABILITY: `ControlWidget` is iOS 18+, and this app deploys to iOS 17 (project.yml). The whole
// type is `@available(iOS 18.0, *)` and the bundle registers it behind an `if #available`, so an
// iOS 17 device simply builds and runs without the control — the Siri phrases and the in-app button
// still work there.
//
// WHY THE BUTTON OPENS A URL INSTEAD OF WRITING THE ROW ITSELF: this extension's process cannot
// reach the app's SwiftData store (there is no App Group, and adding one would mean relocating the
// store — the #40/#131 wipe path). An intent performing HERE would write the label into an empty
// store inside the extension's container and lose it silently. So the button hands the system a
// deep link (`Shared/HeadacheQuickLink.swift`); the app resolves the time on arrival, stores the
// row IMMEDIATELY, and then opens the log sheet on it for optional correction. The label is banked
// before the user has to decide anything.

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct HeadacheLogControl: ControlWidget {

    /// Stable identity for this control. Changing it would orphan the control users have already
    /// placed in Control Centre / on their Lock Screen, so it is fixed for good.
    static let kind = "com.standardsoftwaresolutions.opencircuit.HeadacheLogControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            // `OpenURLIntent` (iOS 18+) is a system intent: the system opens the URL, our app
            // handles it. The URL is built with a SYMBOLIC time (`when=now`), never a baked-in
            // timestamp — this body is evaluated when WidgetKit renders the control, which can be
            // hours before the tap, so an absolute onset here would be a fabricated one.
            ControlWidgetButton(action: OpenURLIntent(HeadacheQuickLink.url(for: .now))) {
                Label("Log Headache", systemImage: "brain.head.profile")
            }
        }
        .displayName("Log a Headache")
        // Says plainly that it records rather than predicts, and that the entry lands in the app —
        // this is a log, not a medical device.
        .description("Records a headache in OpenCircuit, starting now.")
    }
}
