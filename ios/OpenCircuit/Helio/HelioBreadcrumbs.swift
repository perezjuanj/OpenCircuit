import Foundation
import ZeppKit

// Breadcrumbs for the strap's link and wakes (#233). Build 59's first night synced only when the app
// was opened, and nothing recorded whether the link was up, dropped or restored overnight. These lines
// go to the metric log under one source tag (`source`), which the Diagnostics export prints in its own
// section, so the next night can explain itself.
//
// Only state and control bytes: never an identifier, never a payload (which can hold health data).
// Bounded, because the metric log keeps 400 entries for every source and one night must not evict the
// rest: see `HelioBreadcrumbBudget`.

/// Why a strap sync ran (decision 33's wake sources, plus the BGTask kinds and the app in front).
enum HelioWake: String, Equatable, Sendable {
    case appRefresh
    case processing
    case sleepFocus
    /// CoreBluetooth relaunched the app and handed the strap's link back (state restoration).
    case restoration
    /// The strap sent its woke-up event (`06 00` on `0x001D`).
    case strapEvent
    /// The link came back (out of range, Bluetooth toggled) while the app was in the background.
    case reconnect
    /// The strap sent something on its own over the idle link (decision 35): a ping, a sleep event,
    /// any §16.2 message. Gated exactly like `reconnect`.
    case idleTraffic
    /// HealthKit delivered new iPhone steps in the background.
    case healthDelivery
    case foreground

    /// The BGTask kinds' wakes; nil for a kind that isn't a BGTask.
    init?(task kind: TaskRecord.Kind) {
        switch kind {
        case .appRefresh: self = .appRefresh
        case .processing: self = .processing
        case .sleepFocus: self = .sleepFocus
        case .foreground, .cbWake, .backgroundSync: return nil
        }
    }

    /// For a log line: "the processing run".
    var runName: String {
        switch self {
        case .appRefresh: return "app-refresh"
        case .processing: return "processing"
        case .sleepFocus: return "Sleep Focus"
        case .restoration: return "restoration"
        case .strapEvent: return "strap-event"
        case .reconnect: return "reconnect"
        case .idleTraffic: return "idle-link traffic"
        case .healthDelivery: return "Health-delivery"
        case .foreground: return "foreground"
        }
    }
}

/// The breadcrumbs' volume rules, pure so they test without UserDefaults. Persisted between calls (and
/// across relaunches: a restoration relaunch is a new process) by `HelioBreadcrumbs`.
///
/// - Lines are counted per 12-hour window (a night is one window) in three categories, each with its
///   own budget, so no kind of line can starve another: link lines (up, down, Bluetooth, restoration)
///   20, sync lines (why each sync ran) 16, strap messages 12. One window therefore uses at most 48 of
///   the metric log's 400 entries. Lines over budget are counted, and the count is reported on the
///   first line of the next window.
/// - Keyed lines (each link event, each strap endpoint) are rate-limited: at most one line per key per
///   10 minutes, carrying how many happened since that key's last line. A flapping link or a chatty
///   endpoint costs one line per 10 minutes, not one per event. A strap endpoint also gets at most 4
///   lines per window, so one endpoint can't spend the others' budget.
struct HelioBreadcrumbBudget: Codable, Equatable {
    static let window: TimeInterval = 12 * 3600
    static let keyInterval: TimeInterval = 10 * 60
    static let messageLinesPerKey = 4

    enum Kind: String, Codable, CaseIterable {
        case link, sync, message

        var linesPerWindow: Int {
            switch self {
            case .link: return 20
            case .sync: return 16
            case .message: return 12
            }
        }
    }

    static var linesPerWindow: Int { Kind.allCases.map(\.linesPerWindow).reduce(0, +) }

    var windowStart: Date?
    var used: [String: Int] = [:]
    /// Lines dropped in this window, reported on the next window's first line.
    var suppressed = 0
    var carriedSuppressed = 0
    var keyLines: [String: Int] = [:]
    var lastKeyLine: [String: Date] = [:]
    var sinceKeyLine: [String: Int] = [:]

    /// The line to record, or nil when this window's budget for `kind` is spent. The line that spends
    /// the budget says so.
    mutating func admit(_ text: String, kind: Kind, now: Date) -> String? {
        roll(now)
        let used = self.used[kind.rawValue, default: 0]
        guard used < kind.linesPerWindow else {
            suppressed += 1
            return nil
        }
        self.used[kind.rawValue] = used + 1
        var line = text
        if carriedSuppressed > 0 {
            line += " [\(carriedSuppressed) line(s) over budget in the previous 12 h]"
            carriedSuppressed = 0
        }
        if used + 1 == kind.linesPerWindow {
            line += " [\(kind.rawValue) line budget spent; the rest of this 12 h window is counted, not logged]"
        }
        return line
    }

    /// One event on `key`: how many happened since the key's last line when a line is due now, else
    /// nil (it is counted for the next one). `perWindow` caps the key's lines in a window.
    mutating func due(key: String, perWindow: Int? = nil, now: Date) -> Int? {
        roll(now)
        sinceKeyLine[key, default: 0] += 1
        if let last = lastKeyLine[key], now >= last, now.timeIntervalSince(last) < Self.keyInterval { return nil }
        if let perWindow, keyLines[key, default: 0] >= perWindow { return nil }
        let count = sinceKeyLine[key] ?? 1
        sinceKeyLine[key] = 0
        lastKeyLine[key] = now
        keyLines[key, default: 0] += 1
        return count
    }

    private mutating func roll(_ now: Date) {
        if let start = windowStart, now >= start, now.timeIntervalSince(start) < Self.window { return }
        carriedSuppressed += suppressed
        suppressed = 0
        used = [:]
        keyLines = [:]
        windowStart = now
    }
}

/// Writes the strap's breadcrumbs to the metric log (`ObservabilityStore`), within `HelioBreadcrumbBudget`.
@MainActor
final class HelioBreadcrumbs {
    /// The metric-log source tag. The Diagnostics export prints it in its own section.
    nonisolated static let source = "helio-link"
    nonisolated static let budgetKey = "helio.breadcrumbBudget.v1"

    static let shared = HelioBreadcrumbs()

    private let observability: ObservabilityStore
    private let defaults: UserDefaults
    private let clock: () -> Date

    init(observability: ObservabilityStore = ObservabilityStore(), defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init) {
        self.observability = observability
        self.defaults = defaults
        self.clock = clock
    }

    // MARK: Link

    /// The link came up. `how` says why: a first connect, a reconnect, a restored link.
    func linkUp(_ how: String, appActive: Bool) {
        keyed("link-up", .link) { "link up (\(how); app \(appActive ? "in front" : "in background"))" }
    }

    /// The link went down. `errorCode` is CoreBluetooth's (`CBError.Code`), nil without an error;
    /// `upFor` is how long the link had been up (does the strap drop a silent link? §16.3).
    func linkDown(errorCode: Int?, expected: Bool, standingConnectArmed: Bool, upFor: TimeInterval? = nil) {
        let error = errorCode.map { "CBError \($0)" } ?? "no error"
        // Separate keys: a drop we made can't hide an unexpected one inside the same 10 minutes.
        keyed(expected ? "link-down-expected" : "link-down-unexpected", .link) {
            "link down (\(expected ? "we dropped it" : "unexpected"), \(error)\(Self.upFor(upFor))); standing connect \(standingConnectArmed ? "armed" : "NOT armed")"
        }
    }

    func bluetoothOff(standingConnectArmed: Bool, upFor: TimeInterval? = nil) {
        keyed("bluetooth-off", .link) {
            "Bluetooth off; the link is gone\(Self.upFor(upFor)); reconnect \(standingConnectArmed ? "armed for when it is back on" : "NOT armed")"
        }
    }

    /// ", after 3h12m up", or nothing.
    nonisolated static func upFor(_ interval: TimeInterval?) -> String {
        guard let interval, interval >= 0 else { return "" }
        let minutes = Int(interval / 60)
        return ", after \(minutes / 60)h\(String(format: "%02d", minutes % 60))m up"
    }

    /// A state-restoration relaunch: what came back, as states only (never an identifier).
    func restored(peripheralStates: [String], savedStrapState: String?) {
        let states = peripheralStates.isEmpty ? "none" : peripheralStates.joined(separator: ",")
        keyed("restored", .link) {
            "restoration relaunch: \(peripheralStates.count) peripheral(s) [\(states)]; saved strap \(savedStrapState ?? "not among them")"
        }
    }

    // MARK: Syncs

    /// A strap sync started, and why.
    func syncStarted(wake: HelioWake, detail: String? = nil) {
        record("sync start wake=\(wake.rawValue)" + (detail.map { " (\($0))" } ?? ""), .sync)
    }

    /// One line for a background wake that decided not to sync, or ran into another run.
    func wakeNote(_ wake: HelioWake, _ text: String) {
        record("wake=\(wake.rawValue): \(text)", .sync)
    }

    /// Review-224e S-2: a strap sleep more than 60 min from the rest of its night was kept out (the
    /// night's longer part holds the key). Since decision 71b (#278), only a sleep the overnight join
    /// can't reach (it would make the night longer than 20 h). Since #231 such a sleep is judged as a
    /// nap: `storedAsNap` says whether it was stored as one (it isn't while it is under 20 min, still settling, or not
    /// wholly in the strap's time). No time, no length. At most one line of each kind per night per
    /// 12 h window: every sync re-delivers the sessions.
    func strapSleepKeptOut(nightKey: Date, storedAsNap: Bool) {
        let night = Int(nightKey.timeIntervalSince1970)
        if storedAsNap {
            keyed("sleep-kept-out-nap-\(night)", .sync, perWindow: 1) {
                "a strap sleep was kept out of its night (over 60 min from the night's longer part); stored as a nap (#231)"
            }
        } else {
            keyed("sleep-kept-out-\(night)", .sync, perWindow: 1) {
                "a strap sleep was kept out of its night (over 60 min from the night's longer part); not stored as a nap yet (#231)"
            }
        }
    }

    /// #231 (ZEPP_PROTOCOL.md §21.5 step 4): the strap sent a sleep under 20 minutes. Amazfit says it
    /// doesn't record these, so one arriving says the phone-side nap rule is wrong. No time, no length.
    /// At most one line per day per 12 h window.
    func strapSleepTooShort(day: Date) {
        keyed("sleep-too-short-\(Int(day.timeIntervalSince1970))", .sync, perWindow: 1) {
            "the strap sent a sleep under 20 min; not a nap (§21.5: Amazfit doesn't record these)"
        }
    }

    /// Decision 72 (#278): one line per sync that fetched a sleep-session round, counts only (see
    /// `StrapSleepRoundSummary`). Its own key, at most 4 per 12 h window, so it can't take more than a
    /// quarter of the sync lines' budget; the 10-minute key interval keeps a burst of re-syncs to one.
    func strapSleepRound(_ summary: StrapSleepRoundSummary) {
        keyed("sleep-round", .sync, perWindow: 4) { summary.text }
    }

    // MARK: Strap messages

    /// A message the strap sent on its own, outside a request this app started: the endpoint, the
    /// opcode bytes and the length only (§16.5), rate-limited per endpoint. Its time is when it arrived.
    func strapMessage(endpoint: UInt16, opcode: [UInt8], length: Int) {
        let key = String(format: "0x%04x", endpoint)
        let bytes = opcode.map { String(format: "%02x", $0) }.joined(separator: " ")
        keyed(key, .message, perWindow: HelioBreadcrumbBudget.messageLinesPerKey, since: "this endpoint's") {
            "strap sent \(key) \(bytes) (\(length) B)"
        }
    }

    /// Decision 84c: what an indoor workout's realtime step stream did on one connection, counts and
    /// control bytes only (never a step count): whether frames came, how soon after `05 01`, and the
    /// ack's bytes. At most 4 lines per 12 h window.
    func stepStream(_ report: StrapStepStreamReport) {
        keyed("step-stream", .message, perWindow: HelioBreadcrumbBudget.messageLinesPerKey) {
            Self.stepStreamText(report)
        }
    }

    nonisolated static func stepStreamText(_ report: StrapStepStreamReport) -> String {
        var parts = ["realtime steps: \(report.frames) frame(s)"]
        if let delay = report.firstFrameDelay { parts.append(String(format: "first after %.0f s", delay)) }
        if report.unreadable > 0 { parts.append("\(report.unreadable) unreadable") }
        if let status = report.ackStatus {
            parts.append("ack 06 " + ([status] + (report.ackEnabled.map { [$0] } ?? [])).map { String(format: "%02x", $0) }.joined(separator: " "))
        } else {
            parts.append("no ack")
        }
        return parts.joined(separator: ", ")
    }

    /// A notification on a standard characteristic nothing asked for (no bytes at all: it can be a
    /// heart-rate value).
    func strapNotification(characteristic: String) {
        let key = "char-\(characteristic.lowercased())"
        keyed(key, .message, perWindow: HelioBreadcrumbBudget.messageLinesPerKey, since: "this endpoint's") {
            "strap sent a \(characteristic) notification"
        }
    }

    // MARK: Plumbing

    /// A rate-limited line: at most one per `key` per 10 minutes, with the count since the key's last
    /// line (only shown when it's more than this one).
    private func keyed(_ key: String, _ kind: HelioBreadcrumbBudget.Kind, perWindow: Int? = nil,
                       since: String = "the last such line", text: () -> String) {
        let now = clock()
        var budget = load()
        if let count = budget.due(key: key, perWindow: perWindow, now: now) {
            let suffix = kind == .message || count > 1 ? " (\(count) since \(since) last line)" : ""
            if let line = budget.admit(text() + suffix, kind: kind, now: now) {
                observability.recordMetricEvent(source: Self.source, detail: line, at: now)
            }
        }
        save(budget)
    }

    private func record(_ text: String, _ kind: HelioBreadcrumbBudget.Kind) {
        let now = clock()
        var budget = load()
        if let line = budget.admit(text, kind: kind, now: now) {
            observability.recordMetricEvent(source: Self.source, detail: line, at: now)
        }
        save(budget)
    }

    private func load() -> HelioBreadcrumbBudget {
        guard let data = defaults.data(forKey: Self.budgetKey),
              let budget = try? JSONDecoder().decode(HelioBreadcrumbBudget.self, from: data) else { return HelioBreadcrumbBudget() }
        return budget
    }

    private func save(_ budget: HelioBreadcrumbBudget) {
        if let data = try? JSONEncoder().encode(budget) { defaults.set(data, forKey: Self.budgetKey) }
    }
}
