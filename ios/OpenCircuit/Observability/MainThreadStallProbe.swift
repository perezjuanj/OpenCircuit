import Foundation

/// How long the main thread stays busy between two waits of its run loop (decision 75d).
///
/// A run-loop observer stamps every wake (`afterWaiting`) and every return to sleep
/// (`beforeWaiting`); the stretch in between is one uninterrupted piece of main-thread work, so the
/// longest stretch is the longest stall the user could feel. Cheap enough to leave on for a whole
/// sync (two `CFAbsoluteTimeGetCurrent()` calls per run-loop pass), and it runs only between
/// `start()` and `stop()`.
@MainActor
final class MainThreadStallProbe {

    /// Counts and milliseconds only.
    struct Report: Equatable, Sendable {
        /// The longest single busy stretch.
        var longestMS: Int
        /// The sum of every busy stretch.
        var busyMS: Int
        /// How many busy stretches there were.
        var stretches: Int
    }

    private var observer: CFRunLoopObserver?
    private var wokeAt: CFAbsoluteTime?
    private var longest: CFTimeInterval = 0
    private var busy: CFTimeInterval = 0
    private var stretches = 0

    var isRunning: Bool { observer != nil }

    /// Starts measuring. The main thread is busy right now (it is running this), so the first
    /// stretch starts here.
    func start() {
        guard observer == nil else { return }
        clear()
        wokeAt = CFAbsoluteTimeGetCurrent()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// What was measured since `start()` (or the last `take()`), counting the stretch in progress
    /// up to now, and then measuring again from zero. Keeps running.
    func take() -> Report {
        let now = CFAbsoluteTimeGetCurrent()
        if let wokeAt { add(now - wokeAt) }
        let report = Report(longestMS: Self.ms(longest), busyMS: Self.ms(busy), stretches: stretches)
        clear()
        if observer != nil, wokeAt != nil { wokeAt = now }
        return report
    }

    /// Stops measuring and returns what was measured since the last `start()` or `take()`.
    @discardableResult
    func stop() -> Report {
        let report = take()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        wokeAt = nil
        return report
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting {
            wokeAt = now
        } else if let wokeAt {
            add(now - wokeAt)
            self.wokeAt = nil
        }
    }

    private func add(_ stretch: CFTimeInterval) {
        busy += stretch
        longest = max(longest, stretch)
        stretches += 1
    }

    private func clear() {
        longest = 0
        busy = 0
        stretches = 0
    }

    private static func ms(_ t: CFTimeInterval) -> Int { Int((t * 1000).rounded()) }
}
