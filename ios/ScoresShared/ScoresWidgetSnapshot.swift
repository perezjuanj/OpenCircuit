// The Today scores widget's snapshot (#398, decision 95c): what the app hands the widget.
//
// SHARED SOURCE: compiled into BOTH the app target and the `ScoresWidget` extension (project.yml lists
// `ScoresShared/` under both). The app WRITES the snapshot right after Today's scores are built
// (`ScoresWidgetPublisher`); the extension only READS it and draws it. Nothing in this folder computes a
// score: every number and word in a snapshot was produced by `TodayScores` and `TodayScoresCopy` in the
// app, so the widget can never disagree with the card. A test greps this folder and the extension to
// keep it that way.
//
// The snapshot is three dials (Sleep, Recovery, Strain), each a value and its state, and the time it
// was written. A missing value is ABSENT, never 0, and is drawn as the card's dash.

import Foundation

/// The one name for the App Group both targets share. Its value is the `OC_APP_GROUP_ID` build setting
/// (project.yml), which also fills both targets' `com.apple.security.application-groups` entitlement and
/// the `OCAppGroupIdentifier` Info.plist key read here. Change it in project.yml only.
enum ScoresWidgetAppGroup {
    static let infoPlistKey = "OCAppGroupIdentifier"

    /// The group id from this bundle's Info.plist, or nil when the build carries none.
    static var identifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }

    /// The snapshot file inside the group container. Nil when the group isn't provisioned (an unsigned
    /// build): the app then writes nothing and the widget shows its "open the app" state.
    static var snapshotURL: URL? {
        guard let id = identifier,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return dir.appendingPathComponent("today-scores-widget.json")
    }
}

/// The widget kinds, shared so the app can ask WidgetKit to reload exactly these.
enum ScoresWidgetKind {
    static let today = "OpenCircuitTodayScores"
    static let sleep = "OpenCircuitSleepDial"
    static let recovery = "OpenCircuitRecoveryDial"
    static let strain = "OpenCircuitStrainDial"
    static let all = [today, sleep, recovery, strain]
}

/// The card's fixed words that the widget draws too. `TodayScoresCopy` reads them from here, so the
/// card and the widget say the same thing.
enum TodayScoresWords {
    /// A missing value's centre: a dash, never a 0.
    static let missing = "—"
    static let sleepLabel = "SLEEP"
    static let recoveryLabel = "RECOVERY"
    static let strainLabel = "STRAIN"
    static let footer = "On-device estimates · not medical advice"
}

struct ScoresWidgetSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var writtenAt: Date
    var sleep: Dial
    var recovery: Dial
    var strain: Dial

    /// One dial as the card draws it.
    struct Dial: Codable, Equatable {
        /// The centre text as the card shows it ("81", "12.4"); nil when there is no value.
        var value: String?
        /// The ring's fill, 0…1; nil for the empty track.
        var fill: Double?
        /// The line under the dial: the value's state or the reason there is none.
        var status: String
        var tint: Tint
        /// Dashed track: the value rests on fewer inputs than usual.
        var dashed: Bool
        /// What VoiceOver says for the dial (the card's own label).
        var spoken: String

        enum CodingKeys: String, CodingKey {
            case value, fill, status, tint, dashed, spoken
        }
    }

    /// Which of the card's colours the dial uses.
    enum Tint: String, Codable, CaseIterable {
        case sleep, recoveryExcellent, recoveryGood, recoveryNeedsImprovement, recoveryNone, strain
    }

    enum CodingKeys: String, CodingKey {
        case version = "v", writtenAt = "at", sleep, recovery, strain
    }

    /// Same values and states, whenever written.
    func sameContent(as other: ScoresWidgetSnapshot) -> Bool {
        sleep == other.sleep && recovery == other.recovery && strain == other.strain
    }
}

// MARK: - Codec

/// Strict on the way in: anything that isn't exactly a current-version snapshot is no snapshot at all,
/// so the widget falls back to its empty state rather than drawing a half-read file.
enum ScoresWidgetCodec {
    static let topLevelKeys: Set<String> = ["v", "at", "sleep", "recovery", "strain"]
    static let requiredDialKeys: Set<String> = ["status", "tint", "dashed", "spoken"]
    static let optionalDialKeys: Set<String> = ["value", "fill"]

    static func encode(_ snapshot: ScoresWidgetSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data) -> ScoresWidgetSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == topLevelKeys,
              (object["v"] as? Int) == ScoresWidgetSnapshot.currentVersion else { return nil }
        for key in ["sleep", "recovery", "strain"] {
            guard let dial = object[key] as? [String: Any] else { return nil }
            let keys = Set(dial.keys)
            guard requiredDialKeys.isSubset(of: keys),
                  keys.isSubset(of: requiredDialKeys.union(optionalDialKeys)) else { return nil }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(ScoresWidgetSnapshot.self, from: data),
              snapshot.writtenAt.timeIntervalSince1970.isFinite,
              [snapshot.sleep, snapshot.recovery, snapshot.strain].allSatisfy(isValid) else { return nil }
        return snapshot
    }

    private static func isValid(_ dial: ScoresWidgetSnapshot.Dial) -> Bool {
        if let fill = dial.fill, !(fill.isFinite && (0...1).contains(fill)) { return false }
        if let value = dial.value {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == TodayScoresWords.missing { return false }
        }
        return !dial.status.trimmingCharacters(in: .whitespaces).isEmpty
            && !dial.spoken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Freshness

enum ScoresWidgetFreshness: Equatable {
    /// Written in the last `staleAfter`: drawn as it is.
    case current
    /// Written earlier today: drawn dimmed, with the time it was written.
    case stale
    /// Written on another day (or in the future, after a clock change): today's scores aren't known,
    /// so every dial is drawn empty. Yesterday's numbers are never shown as today's.
    case expired
    /// No readable snapshot.
    case none

    /// Strain counts "so far" and Recovery can change after a late sync: a few hours is as long as a
    /// value reads as current.
    static let staleAfter: TimeInterval = 3 * 3600

    static func of(writtenAt: Date?, now: Date, calendar: Calendar = .current) -> ScoresWidgetFreshness {
        guard let writtenAt else { return .none }
        if writtenAt.timeIntervalSince(now) > 5 * 60 || !calendar.isDate(writtenAt, inSameDayAs: now) {
            return .expired
        }
        return now.timeIntervalSince(writtenAt) > staleAfter ? .stale : .current
    }

    /// When the widget must redraw on its own: as the snapshot turns stale, and at midnight.
    static func changeDates(writtenAt: Date, after now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [writtenAt.addingTimeInterval(staleAfter)]
        if let midnight = calendar.nextDate(after: writtenAt, matching: DateComponents(hour: 0, minute: 0),
                                            matchingPolicy: .nextTime) {
            dates.append(midnight)
        }
        return dates.filter { $0 > now }.sorted()
    }
}

// MARK: - Deep links

/// `opencircuit://today[/sleep|/recovery|/strain|/sources]`: where a widget tap lands. Shares the app's
/// one URL scheme with `WorkoutQuickLink` and `HeadacheQuickLink`; told apart by host.
enum ScoresQuickLink {
    enum Route: String, CaseIterable, Equatable {
        /// The Today tab.
        case today
        /// The Sleep tab.
        case sleep
        /// The Recovery detail, pushed on Today.
        case recovery
        /// The Strain detail, pushed on Today.
        case strain
        /// How these numbers are worked out, pushed on Today.
        case sources
    }

    static let scheme = "opencircuit"
    static let host = "today"

    static func url(_ route: Route) -> URL {
        let path = route == .today ? "" : "/\(route.rawValue)"
        return URL(string: "\(scheme)://\(host)\(path)")!
    }

    /// The route for a Today link, or nil for anything else so the other handlers still get it.
    static func parse(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        switch parts.count {
        case 0:  return .today
        case 1:
            guard let route = Route(rawValue: String(parts[0]).lowercased()), route != .today else { return nil }
            return route
        default: return nil
        }
    }
}
