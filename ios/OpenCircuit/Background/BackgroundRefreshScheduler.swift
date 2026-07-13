import BackgroundTasks
import Foundation
import OpenCircuitKit

protocol BGTaskScheduling {
    func register(forTaskWithIdentifier identifier: String,
                  using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool
    func cancel(taskRequestWithIdentifier identifier: String)
    func submit(_ taskRequest: BGTaskRequest) throws
}

extension BGTaskScheduler: BGTaskScheduling {}

struct BackgroundRefreshScheduler {
    static let identifier = "com.standardsoftwaresolutions.opencircuit.bgrefresh"
    static let refreshInterval: TimeInterval = 15 * 60

    /// Separate BGProcessingTask (#45). A processing task gets a much longer runtime window than
    /// the ~30 s BGAppRefreshTask ceiling, so the optical-HR poll can finally clear its ~60 s
    /// warm-up in the background. HONEST: iOS schedules processing tasks at its own discretion
    /// (commonly overnight while charging), so this improves the odds of a real background HR
    /// lock but does NOT guarantee a daytime one.
    static let processingIdentifier = "com.standardsoftwaresolutions.opencircuit.bgprocessing"
    /// Ask for the processing task less often than the app refresh — it's the heavier, longer
    /// run, and iOS coalesces/throttles these regardless.
    static let processingInterval: TimeInterval = 60 * 60

    private let scheduler: BGTaskScheduling
    private let now: () -> Date
    private let window: (Date) -> DateInterval?

    init(scheduler: BGTaskScheduling = BGTaskScheduler.shared,
         now: @escaping () -> Date = Date.init,
         window: @escaping (Date) -> DateInterval? = BackgroundRefreshScheduler.defaultWindow) {
        self.scheduler = scheduler
        self.now = now
        self.window = window
    }

    /// Tonight's (or the in-progress) sleep window from the manual/default schedule
    /// (`SleepScheduleDefaults`) — the same fallback `RingSession.isInSleepWindow` uses before
    /// its async learned-window resolution. A rough window is fine: `earliestBeginDate` is only
    /// a lower bound. Injectable so tests stay deterministic.
    static func defaultWindow(now: Date) -> DateInterval? {
        let defaults = UserDefaults.standard
        SleepScheduleDefaults.register(defaults)
        return BackgroundSyncPolicy.relevantWindow(
            now: now,
            bedMinutes: defaults.integer(forKey: SleepScheduleDefaults.bedMinutes),
            wakeMinutes: defaults.integer(forKey: SleepScheduleDefaults.wakeMinutes))
    }

    @discardableResult
    func register(launchHandler: @escaping (BGTask) -> Void) -> Bool {
        scheduler.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil,
            launchHandler: launchHandler
        )
    }

    @discardableResult
    func registerProcessing(launchHandler: @escaping (BGTask) -> Void) -> Bool {
        scheduler.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil,
            launchHandler: launchHandler
        )
    }

    func makeRequest() -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = aimedDate(fallbackInterval: Self.refreshInterval)
        return request
    }

    func makeProcessingRequest() -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.earliestBeginDate = aimedDate(fallbackInterval: Self.processingInterval)
        // It needs the longer WINDOW, not the charger — a daytime HR read shouldn't require power.
        // (iOS still tends to defer processing tasks to charging/idle, but we don't mandate it.)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        return request
    }

    /// Aim the request at the moment it's worth granting (#119): the normal interval by day, but
    /// once bedtime is near (or in progress) the coming morning instead — an in-window grant does
    /// no drain (overnight-quiet gate) and a wasted run deprioritizes the next.
    private func aimedDate(fallbackInterval: TimeInterval) -> Date {
        BackgroundSyncPolicy.aimedFireDate(now: now(), sleepWindow: window(now()),
                                           fallbackInterval: fallbackInterval)
    }

    @discardableResult
    func schedule() -> Bool {
        submit(makeRequest(), cancelIdentifier: Self.identifier, label: "refresh")
    }

    @discardableResult
    func scheduleProcessing() -> Bool {
        submit(makeProcessingRequest(), cancelIdentifier: Self.processingIdentifier, label: "processing")
    }

    /// Cancel any duplicate then submit, recording the REAL outcome into the Diagnostics metric log
    /// (#bg-observability). The old `#if DEBUG print` swallowed submit failures, so on a
    /// device/TestFlight build a request iOS rejected on EVERY call (Background App Refresh
    /// unavailable, or the identifier missing from `BGTaskSchedulerPermittedIdentifiers`) was
    /// indistinguishable from a healthy schedule — `recordScheduled` fired regardless. That is
    /// exactly how "no background sync ever runs" hides. We now persist success/failure (+ the
    /// named reason) so the export can trace it.
    @discardableResult
    private func submit(_ request: BGTaskRequest, cancelIdentifier: String, label: String) -> Bool {
        scheduler.cancel(taskRequestWithIdentifier: cancelIdentifier)
        do {
            try scheduler.submit(request)
            ObservabilityStore().recordMetricEvent(
                source: "bgschedule", detail: "\(label): submitted ok (earliest \(Self.stamp(request)))")
            return true
        } catch {
            ObservabilityStore().recordMetricEvent(
                source: "bgschedule", detail: "\(label): SUBMIT FAILED — \(Self.describe(error))")
            #if DEBUG
            print("Unable to schedule background \(label): \(error)")
            #endif
            return false
        }
    }

    /// Snapshot what iOS actually has QUEUED for us, into the Diagnostics metric log. The decisive
    /// triage signal: if this shows zero pending right after `schedule()`, the submit is silently
    /// failing; if it shows our two identifiers yet the handler never runs, iOS simply isn't
    /// granting (throttle/conditions), not a wiring bug. Uses the real scheduler singleton (a
    /// device-only diagnostic), so it reflects true system state, not an injected test mock.
    func probePendingRequests() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let summary = requests.isEmpty
                ? "NONE queued (submit is failing, or iOS dropped them)"
                : requests.map { req in
                    "\(req.identifier)@\(req.earliestBeginDate.map(Self.iso) ?? "asap")"
                }.joined(separator: ", ")
            ObservabilityStore().recordMetricEvent(source: "bgpending", detail: summary)
        }
    }

    /// Human-readable reason for a `BGTaskScheduler` submit failure so the log names the actual
    /// cause. The top suspects for "no background run ever" are `unavailable` (refresh off) and
    /// `notPermitted` (identifier not declared in Info.plist).
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == "BGTaskSchedulerErrorDomain" else {
            return "\(ns.domain) code \(ns.code): \(ns.localizedDescription)"
        }
        switch ns.code {
        case 1:  return "unavailable — Background App Refresh is off/restricted for this app or device"
        case 2:  return "tooManyPendingTaskRequests"
        case 3:  return "notPermitted — identifier missing from BGTaskSchedulerPermittedIdentifiers, or submitted after launch"
        default: return "BGTaskScheduler code \(ns.code): \(ns.localizedDescription)"
        }
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func stamp(_ request: BGTaskRequest) -> String {
        request.earliestBeginDate.map(iso) ?? "asap"
    }
}
