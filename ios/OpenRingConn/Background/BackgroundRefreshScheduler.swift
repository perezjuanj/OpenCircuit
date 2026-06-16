import BackgroundTasks
import Foundation

protocol BGTaskScheduling {
    func register(forTaskWithIdentifier identifier: String,
                  using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool
    func cancel(taskRequestWithIdentifier identifier: String)
    func submit(_ taskRequest: BGTaskRequest) throws
}

extension BGTaskScheduler: BGTaskScheduling {}

struct BackgroundRefreshScheduler {
    static let identifier = "com.dreamality.openringconn.bgrefresh"
    static let refreshInterval: TimeInterval = 15 * 60

    /// Separate BGProcessingTask (#45). A processing task gets a much longer runtime window than
    /// the ~30 s BGAppRefreshTask ceiling, so the optical-HR poll can finally clear its ~60 s
    /// warm-up in the background. HONEST: iOS schedules processing tasks at its own discretion
    /// (commonly overnight while charging), so this improves the odds of a real background HR
    /// lock but does NOT guarantee a daytime one.
    static let processingIdentifier = "com.dreamality.openringconn.bgprocessing"
    /// Ask for the processing task less often than the app refresh — it's the heavier, longer
    /// run, and iOS coalesces/throttles these regardless.
    static let processingInterval: TimeInterval = 60 * 60

    private let scheduler: BGTaskScheduling
    private let now: () -> Date

    init(scheduler: BGTaskScheduling = BGTaskScheduler.shared,
         now: @escaping () -> Date = Date.init) {
        self.scheduler = scheduler
        self.now = now
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
        request.earliestBeginDate = now().addingTimeInterval(Self.refreshInterval)
        return request
    }

    func makeProcessingRequest() -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.earliestBeginDate = now().addingTimeInterval(Self.processingInterval)
        // It needs the longer WINDOW, not the charger — a daytime HR read shouldn't require power.
        // (iOS still tends to defer processing tasks to charging/idle, but we don't mandate it.)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        return request
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
