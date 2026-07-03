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

    func schedule() {
        do {
            scheduler.cancel(taskRequestWithIdentifier: Self.identifier)
            try scheduler.submit(makeRequest())
        } catch {
            #if DEBUG
            print("Unable to schedule background refresh: \(error)")
            #endif
        }
    }

    func scheduleProcessing() {
        do {
            scheduler.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
            try scheduler.submit(makeProcessingRequest())
        } catch {
            #if DEBUG
            print("Unable to schedule background processing: \(error)")
            #endif
        }
    }
}
