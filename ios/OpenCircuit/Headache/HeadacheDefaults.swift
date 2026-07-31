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

    /// Whether the morning notification has EARNED its way on for this user, by passing the
    /// evaluation gate against their own logged headaches. Never user-settable to ON: the only
    /// route to `true` is the evaluated unlock. The user may always turn it back OFF.
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

    /// Whether the one-time explainer has been shown (on first enable).
    ///
    /// Shown ONCE, at the moment the user opts in, because the ask this feature makes is unusual and
    /// entirely front-loaded: log every headache for months, for something that may never tell you
    /// anything. A user who never learns that is a user whose labels quietly go incomplete, and
    /// incomplete labels cannot be repaired later.
    static let onboardingShown = "headache.onboarding.shown"

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
