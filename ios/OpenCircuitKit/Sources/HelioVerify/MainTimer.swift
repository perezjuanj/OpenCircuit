import Foundation

/// HelioVerify parks the main thread in dispatchMain(), which never runs RunLoop.main, so
/// Foundation Timers never fire there. Dispatch timers on the main queue do.
func mainTimer(every interval: Double?, after delay: Double, _ body: @escaping () -> Void) -> DispatchSourceTimer {
    let t = DispatchSource.makeTimerSource(queue: .main)
    if let interval { t.schedule(deadline: .now() + delay, repeating: interval) } else { t.schedule(deadline: .now() + delay) }
    t.setEventHandler(handler: body)
    t.resume()
    return t
}
