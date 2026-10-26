// AutoLiveHeartRate: the pure decision behind "Live heart rate when the app opens" (decision 81,
// #336). Given what the app knows at one instant, it says whether the active device's own Measure
// stream should start now, wait for something to finish, or not start at all for this foreground
// activation. It starts nothing itself: `AutoLiveHeartRateCoordinator` (app side) asks, then drives
// the device through the same entry points a manual Measure uses.
//
// Decision 81, quoted:
//   81a. Trigger: the scene becomes `.active`. If the ACTIVE device's descriptor capability
//        `autoLiveHeartRateOnOpen` is true AND the per-device setting is on, start that device's
//        existing Measure stream once the session is ready and not syncing and no workout owns the
//        stream. If a sync is running, start when it ends, only if the app is still in front and no
//        more than 2 min passed since activation.
//   81b. Never preempt: not while a workout owns the stream, not while a Measure already runs, not
//        while a history sync holds the link. Never delay or defer the foreground sync for it.
//   81c. At most one automatic start per foreground activation; a manual stop by the person is
//        respected until the next activation.
//   81d. Leaving the foreground stops an automatically started stream at once (a manual Measure
//        keeps today's behaviour).

import Foundation

public enum AutoLiveHeartRate {
    /// 81a: a start that follows a sync is allowed only this long after the activation.
    public static let afterSyncWindow: TimeInterval = 120

    /// Who holds the device's live heart-rate stream right now.
    public enum Owner: Equatable, Sendable {
        case none
        /// A Measure (the person's, or an automatic one) is running.
        case measure
        /// A workout owns it.
        case workout
    }

    public enum Decision: Equatable, Sendable {
        /// Start the device's Measure stream now.
        case startNow
        /// Not yet; ask again when something changes.
        case wait
        /// Not for this activation (the next one asks afresh).
        case never
    }

    public struct Inputs: Equatable, Sendable {
        /// The active device's descriptor capability (`ActiveDeviceChoice.autoLiveHeartRateOnOpen`).
        public var supported: Bool
        /// The person's per-device setting.
        public var settingOn: Bool
        /// The app is still in front.
        public var inFront: Bool
        public var activatedAt: Date
        public var now: Date
        /// The session is connected and can start a stream (ready).
        public var sessionReady: Bool
        /// A history sync is running.
        public var syncing: Bool
        /// A history sync ran at any point since this activation (it may have ended).
        public var syncRanSinceActivation: Bool
        /// The foreground sync's own start has not been decided yet, so a start now could take the
        /// link ahead of it (81b: never delay the sync).
        public var syncStillToDecide: Bool
        public var owner: Owner
        /// This activation already started a stream by itself (81c).
        public var alreadyAutoStarted: Bool
        /// The person stopped the automatic stream during this activation (81c).
        public var stoppedByPerson: Bool

        public init(supported: Bool, settingOn: Bool, inFront: Bool, activatedAt: Date, now: Date,
                    sessionReady: Bool, syncing: Bool, syncRanSinceActivation: Bool,
                    syncStillToDecide: Bool, owner: Owner, alreadyAutoStarted: Bool, stoppedByPerson: Bool) {
            self.supported = supported
            self.settingOn = settingOn
            self.inFront = inFront
            self.activatedAt = activatedAt
            self.now = now
            self.sessionReady = sessionReady
            self.syncing = syncing
            self.syncRanSinceActivation = syncRanSinceActivation
            self.syncStillToDecide = syncStillToDecide
            self.owner = owner
            self.alreadyAutoStarted = alreadyAutoStarted
            self.stoppedByPerson = stoppedByPerson
        }
    }

    public static func decide(_ i: Inputs) -> Decision {
        // 81a: the capability and the setting.
        guard i.supported, i.settingOn else { return .never }
        // 81a: only while the app is in front.
        guard i.inFront else { return .never }
        // 81c: one automatic start per activation, and a manual stop sticks.
        guard !i.alreadyAutoStarted, !i.stoppedByPerson else { return .never }
        // 81b: never preempt a workout's stream or a Measure that already runs.
        guard i.owner == .none else { return .never }
        // 81a: a start that follows a sync is allowed within 2 min of the activation.
        if i.syncing || i.syncRanSinceActivation,
           i.now.timeIntervalSince(i.activatedAt) > afterSyncWindow { return .never }
        // 81a, 81b: wait for the link, the sync, and the sync's own start decision.
        if i.syncing || i.syncStillToDecide || !i.sessionReady { return .wait }
        return .startNow
    }
}
