import Foundation

// Every UserDefaults key for the headache-signals feature, in ONE place.
//
// These are shared constants rather than literals typed at each `@AppStorage` site on purpose:
// `userProfile.womensHealthEnabled` is currently hardcoded verbatim in BOTH ContentView.swift and
// UserProfile.swift, which is a live drift hazard (rename one, silently orphan the other's stored
// value). Not repeating that here.
//
// Mirrors the shape of `HealthAlertDefaults` in HealthNotificationCenter.swift.
enum HeadacheDefaults {

    /// Master opt-in for the whole feature. OFF by default — the card, the settings detail and the
    /// dashboard section are all invisible until the user turns it on.
    static let enabled = "headache.enabled"

    /// Whether the morning notification is LIVE for this user.
    ///
    /// The name is historical and the semantics inverted: it once meant "earned its way on by
    /// passing an evaluation gate against the user's own logged headaches". It no longer does. The
    /// notification unlocks after `HeadacheSignals.Tuning.minDaysForBanding` scored nights, because
    /// the alert reports a MEASUREMENT ("last night was unusual for you") rather than predicting a
    /// headache — a measurement is true whatever the detector's predictive skill turns out to be.
    /// The per-user statistics still run, but as an auto-retire MONITOR that can switch this back
    /// off for someone it demonstrably is not helping.
    ///
    /// Consequently the user MAY set this to false themselves (Settings), and the monitor may set it
    /// to false. Nothing but the 21-night unlock and an explicit user resume sets it to true.
    static let unlocked = "headache.alerts.unlocked"

    /// `yyyymmdd` of the day the unlock was granted, so post-unlock days can be excluded from the
    /// statistics that granted it.
    static let promotedOnDayKey = "headache.alerts.promotedOnDayKey"

    /// How many times the gate has been EVALUATED. Repeated looks at accumulating data inflate the
    /// false-promotion rate, so the count is persisted, surfaced in the UI, and used to keep the
    /// decision cadence honest.
    static let lookCount = "headache.alerts.lookCount"

    /// Timestamp of the last gate decision, enforcing the decision interval between looks.
    static let lastDecisionAt = "headache.alerts.lastDecisionAt"

    /// Consecutive passing decisions. The unlock requires more than one, so a single lucky window
    /// can't promote.
    static let consecutivePasses = "headache.alerts.consecutivePasses"

    /// Whether the one-time "import your headaches from Apple Health" prompt has been shown.
    static let importPromptShown = "headache.import.promptShown"

    /// UUID strings of Apple Health samples already consumed by an import, as a `[String]`.
    ///
    /// This duplicates `StoredHeadacheEntry.importedHKUUID` on purpose, because that column is not a
    /// sufficient tombstone: it is destroyed along with the row. Without a record that outlives the
    /// row, a user who imports a headache and then deletes it has it silently resurrected by the
    /// next import — the app would keep overruling a deliberate deletion.
    static let consumedImportUUIDs = "headache.import.consumedUUIDs"

    /// Whether the 90-day "still logging?" nudge has been shown.
    static let ninetyDayNudgeShown = "headache.nudge.ninetyDayShown"

    /// Legacy: whether the one-time explainer has been shown at all. Superseded by
    /// `onboardingVersion`, and read only to migrate an existing install to version 1.
    static let onboardingShown = "headache.onboarding.shown"

    /// Which VERSION of the explainer this user has seen. `0` = none.
    ///
    /// A version rather than a Bool, because the explainer can make promises that later become
    /// false — and it already did. Version 1 told users, at the moment they opted in, "it won't
    /// notify you" and "we won't turn on any alert until your own logged data shows it works for
    /// you". The design then changed: the notification now unlocks after 21 scored nights and the
    /// per-user statistics became an auto-retire monitor instead of a permission gate. A latched
    /// Bool would have left that promise standing forever, with nothing in the app ever retracting
    /// it — the user would simply start getting alerts they had been told in writing they would not
    /// get. Bumping the version re-presents the explainer so the correction actually reaches them.
    ///
    /// Bump this whenever the explainer's PROMISES change, not when its wording is merely polished.
    static let onboardingVersion = "headache.onboarding.version"

    /// The explainer version this build ships. 2 = the measurement-framed notification.
    static let currentOnboardingVersion = 2

    /// `yyyymmdd` of the day the morning-after prompt ASKED ABOUT, once the user has dismissed it
    /// for that day. `0` = never dismissed.
    ///
    /// The day asked about — not "the last day we showed it", and not a bare `Bool`:
    ///  - a `Bool` would silence the prompt permanently after one dismissal, and the prompt's whole
    ///    job is to recover a label the user would otherwise never enter;
    ///  - keying it to the ASKED-ABOUT day (rather than to today) means a dismissal can only ever
    ///    silence the question it answered. A card built just before midnight goes on asking about
    ///    the previous day for a few minutes, and dismissing that stale question must not swallow
    ///    tomorrow's fresh one.
    ///
    /// An Int `yyyymmdd` (`TempFeverNotifications.dayKey`) rather than an instant, for the same
    /// reason that ledger uses one: an instant shifts under travel, calendar day components do not.
    static let yesterdayPromptDismissedDay = "headache.prompt.yesterdayDismissedDay"

    /// Register defaults so a first read never returns a spurious `false`/`0` that differs from the
    /// documented default. Call alongside `HealthAlertDefaults.register`.
    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            enabled: false,
            unlocked: false,
            lookCount: 0,
            consecutivePasses: 0,
            importPromptShown: false,
            ninetyDayNudgeShown: false,
            yesterdayPromptDismissedDay: 0,
        ])
    }
}
