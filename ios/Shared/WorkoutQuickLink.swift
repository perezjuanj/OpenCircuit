// WorkoutQuickLink.swift — the deep link that carries a tap on the workout Live Activity back into
// the RUNNING session.
//
// SHARED SOURCE: compiled into BOTH the app target and the `WorkoutWidget` extension (project.yml
// lists `Shared/` under both), exactly like `HeadacheQuickLink` and `WorkoutActivityAttributes`.
// The extension BUILDS this URL (as the Live Activity's `widgetURL`); the app PARSES it and routes
// to the live session.
//
// WHY (tester report 2026-08-29, build 49): "I tapped the live activity on my lock screen and it
// opened the app but with the record a new activity screen open and I don't know where the
// currently recording activity went." There was NO `widgetURL` anywhere in `ios/`, so the tap was a
// plain cold open onto whatever screen the app defaulted to. `widgetURL` is the only supported tap
// target for a Live Activity (its lock-screen view and its compact/minimal Dynamic Island
// presentations cannot host a Button), so a link is the only way to make that tap mean anything.
//
// The URL is deliberately CONSTANT — no session id, no start timestamp. A control/activity's view
// is rendered by the system well before anybody taps it, so anything baked into the URL at render
// time is stale by definition (the same trap `HeadacheQuickLink.When` documents). "Show me the
// workout that is running" needs no parameters: the app already owns the one live session.

import Foundation

/// The `opencircuit://workout/active` deep link.
///
/// Shares the app's single registered URL scheme (project.yml ▸ `CFBundleURLTypes`) with
/// `HeadacheQuickLink`; the two are told apart by host, and `ContentView.onOpenURL` routes on that.
enum WorkoutQuickLink {

    /// Same scheme as `HeadacheQuickLink` — the app registers exactly one.
    static let scheme = "opencircuit"
    static let host = "workout"
    static let path = "/active"

    /// The link the Live Activity opens: "take me to the workout that is recording right now".
    static var activeSession: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        // All literals, so this cannot fail; the fallback keeps the API non-optional at the call
        // site rather than forcing a `!` into the widget's body.
        return components.url ?? URL(string: "\(scheme)://\(host)\(path)")!
    }

    /// True for the active-session link and nothing else. Anything unrecognised returns false so
    /// `onOpenURL` can fall through to the other handler rather than swallowing the URL.
    static func isActiveSession(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == host
            && url.path == path
    }
}
