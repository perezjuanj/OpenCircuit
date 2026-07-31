// HeadacheQuickLink.swift — the deep link that carries a one-tap headache log from OUTSIDE the app
// (the Control Centre / Lock Screen control) into it.
//
// SHARED SOURCE: compiled into BOTH the app target and the `WorkoutWidget` extension (project.yml
// lists `Shared/` under both), exactly like `WorkoutActivityAttributes`. The extension BUILDS one of
// these URLs; the app PARSES it and does the actual logging.
//
// WHY the control hands over a URL instead of just writing the row itself: there is no App Group
// (OpenCircuit.entitlements carries only the HealthKit entitlement), so the extension's process
// cannot see the app's SwiftData store. Anything it "saved" would land in a second, empty store
// inside the extension's own container and the label would be silently lost — and a lost label is
// the one failure this feature can never recover from (the ring's raw history can be re-drained; a
// headache nobody logged cannot). Adding an App Group to fix that would mean RELOCATING the
// SwiftData store into the group container, which is precisely the container-open failure path
// whose foreground recovery WIPES 30 days of un-resyncable raw history (#40/#131). So the extension
// is deliberately given no code that could write a label, and this file is kept free of SwiftData,
// UserDefaults and HealthKit so it stays correct in either process.

import Foundation

/// The `opencircuit://headache/log?when=…` deep link.
///
/// The scheme is registered on the APP target only (project.yml ▸ `CFBundleURLTypes`); the
/// extension never handles it, it only asks the system to open it.
enum HeadacheQuickLink {

    /// URL scheme, registered in project.yml. Kept here so the builder and the parser can never
    /// disagree about it.
    static let scheme = "opencircuit"
    static let host = "headache"
    static let path = "/log"
    /// Query item naming WHEN the headache happened, symbolically.
    static let whenQueryItem = "when"

    /// When the incoming link says the headache happened.
    ///
    /// SYMBOLIC, never an absolute timestamp. A control's `body` — and therefore the
    /// `OpenURLIntent` and URL baked into it — is evaluated by WidgetKit when the control is
    /// RENDERED, which can be hours before anybody taps it. A URL carrying `onset=<epoch>` built at
    /// render time would date the headache to whenever the Lock Screen last refreshed, which is a
    /// fabricated timestamp. The app resolves the clock time when the link actually arrives.
    enum When: String, CaseIterable, Sendable {
        /// The headache is happening now — the app stamps its own arrival time.
        case now
        /// The user is logging yesterday's headache from memory this morning.
        case yesterday

        /// The onset this link stands for, resolved against the CURRENT clock.
        ///
        /// `.yesterday` resolves to **yesterday at 12:00 local**, and that is a deliberate
        /// placeholder rather than a guess dressed up as data. Somebody logging yesterday's
        /// headache the next morning is not stating a time, so any minute-precision default would
        /// invent one; noon is transparently the middle of the waking day, it is unambiguously a
        /// round number a user reads as "we don't know", and it lands inside the correct calendar
        /// day — which is the only granularity anything downstream pairs a label against (a night's
        /// signals are indexed per day, not per minute). The app opens the log sheet on the entry
        /// straight afterwards so the user can move it, and the confirmation dialog names the time
        /// out loud rather than letting a placeholder pass as a measurement.
        func resolvedOnset(now: Date = Date(), calendar: Calendar = .current) -> Date {
            switch self {
            case .now:
                return now
            case .yesterday:
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                    return now.addingTimeInterval(-86_400)
                }
                // `bySettingHour` returns nil only if 12:00 doesn't exist on that date (no real
                // time zone skips noon), so the start-of-day fallback is belt-and-braces.
                return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday)
                    ?? calendar.startOfDay(for: yesterday).addingTimeInterval(12 * 3600)
            }
        }
    }

    /// Build the link the control opens.
    static func url(for when: When) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: whenQueryItem, value: when.rawValue)]
        // The components above are all literals, so this cannot fail; the fallback keeps the API
        // non-optional at the call site rather than forcing a `!` into the widget's body.
        return components.url ?? URL(string: "\(scheme)://\(host)\(path)?\(whenQueryItem)=\(when.rawValue)")!
    }

    /// Parse an incoming URL, returning `nil` for anything that isn't one of ours. Unknown `when`
    /// values return `nil` too rather than defaulting to `.now`: a link this build doesn't
    /// understand must not silently log a headache at a time nobody asked for.
    static func parse(_ url: URL) -> When? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              url.path == path,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == whenQueryItem })?.value
        else { return nil }
        return When(rawValue: raw)
    }
}
