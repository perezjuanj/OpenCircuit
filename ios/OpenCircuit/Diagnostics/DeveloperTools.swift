import Foundation

/// Whether the ring reverse-engineering surfaces (the "Ring Debug" section at the bottom of
/// Background Activity: last sync & frame and the
/// activity-channel probe) are shown.
///
/// App Store readiness: a store build must not greet every user, or App Review, with raw hex frames
/// and an "RE tool" probe. A compile-time `#if DEBUG` gate would also take them from TestFlight
/// testers, who still use the probe, and a runtime "is this TestFlight?" check can't work because
/// App Review runs the build with the same sandbox receipt TestFlight does. So: always on in DEBUG,
/// and in Release off until unlocked by tapping the version line in Profile's footer
/// `unlockTapCount` times (the same taps lock it again). Unlocking reveals tools only; it changes no
/// sync, storage or Health behaviour.
enum DeveloperTools {
    static let unlockedKey = "developerTools.unlocked"
    static let unlockTapCount = 7

    static func isVisible(unlocked: Bool) -> Bool {
        #if DEBUG
        return true
        #else
        return unlocked
        #endif
    }
}
