// HeadacheLogIntent.swift — the fast paths from "I have a headache" to a stored row.
//
// This feature is only worth anything if the LABELS are complete. A logged headache is the only
// ground truth the overnight-signals index can ever be checked against, the labels come from
// TestFlight testers rather than from the developer, and a headache nobody logged is gone for good —
// unlike ring data, it cannot be back-filled a year later. Paid diary studies with dedicated tooling
// still only reach 70–85 % adherence, so "open the app, find the card, fill in a Form, save" is not
// a logging path, it is a way of losing labels. Hence these intents, which exist purely to shorten
// the distance between the symptom and the row:
//
//   • Siri / Shortcuts / the Action button:  "Log a headache in OpenCircuit"   → ZERO taps
//   • Control Centre / Lock Screen control:  one tap → the app opens on the entry, already stored
//   • The dashboard card's button:           the existing Form (unchanged)
//
// WHICH PROCESS RUNS THIS, AND WHY IT MATTERS
// -------------------------------------------
// These intents live in the APP target ONLY — deliberately NOT in `Shared/`, which is compiled into
// the `WorkoutWidget` extension as well. There is no App Group, so the extension's process cannot
// reach the app's SwiftData store; a copy of a store-writing intent compiled into the extension
// could therefore perform there and write the label into a second, empty store inside the
// extension's own container, where nobody would ever see it. Silently losing a label is strictly
// worse than an extra tap, so the extension is given no code that can write one (it opens a URL
// instead — see `Shared/HeadacheQuickLink.swift`), and these types are unreachable from it.
//
// With `openAppWhenRun == false` and the intent declared in the app binary, the system launches the
// APP (in the background, without showing UI) and performs it there, so `perform()` always runs
// against the real store. That is what makes the Siri path zero-tap: no app switch, no sheet.
//
// NO FABRICATION: severity is optional and an unsupplied severity is stored as UNSPECIFIED
// (severityRaw 0 — `HKCategoryValueSeverity.unspecified`), never quietly promoted to "moderate"
// because a number was convenient. Nothing here predicts or explains a headache; it records one.
//
// APPLE HEALTH is deliberately NOT written from here. The new row lands in `pendingHeadacheEntries`
// and the app's existing flush mirrors it on the next foreground activation / sync
// (`HealthKitWriter.flushHeadacheLog`). Writing it inside the intent would add a HealthKit failure
// surface to a background launch that may be running against a locked device, for a mirror that
// arrives minutes later anyway — and the row the labels are actually read from is the LOCAL one.

import AppIntents
import Foundation
import SwiftData

// MARK: - The shared write path

/// The one place a quick-logged headache is turned into a stored row.
///
/// Used by every fast path (`LogHeadacheIntent`, `LogHeadacheYesterdayIntent`, and the deep link the
/// Lock Screen control opens), so the near-duplicate rule below cannot differ between them.
enum HeadacheQuickLog {

    /// How close to an existing entry a quick log has to land before it is treated as the SAME
    /// headache rather than a new one.
    ///
    /// The store upserts on `onset`, so two quick logs a few minutes apart would otherwise become
    /// two rows for one headache — inflating every count the feature reports and turning one label
    /// into two. Two hours is deliberately conservative: ICHD-3 treats attacks separated by less
    /// than four hours of freedom from pain as a single attack, so half that window merges the
    /// obvious repeats (a double tap, re-opening the control, or logging again with a severity once
    /// it got worse) without swallowing a plausibly distinct evening attack. Merging is also the
    /// non-destructive direction: the merged row stays fully editable, and a user who really did
    /// have two can move the onset or add a second entry from the sheet.
    static let mergeWindow: TimeInterval = 2 * 3600

    /// What one quick log actually did, so the caller's confirmation can say it out loud instead of
    /// implying a new row was always created.
    enum Outcome: Equatable {
        /// A new entry was stored at this onset.
        case created(onset: Date)
        /// An existing entry at this onset was updated instead of a second row being created.
        case merged(onset: Date)

        /// The onset of the row that now holds this headache — the store key the caller needs to
        /// open the log sheet on it.
        var onset: Date {
            switch self {
            case .created(let onset), .merged(let onset): return onset
            }
        }
    }

    /// Record a headache at `onset`, merging into a recent entry rather than creating a duplicate.
    ///
    /// `severityRaw` is `nil` when the user didn't rate it, which stores 0 (unspecified) on a new
    /// row and leaves an already-rated row alone — a quick log never DOWNGRADES a severity the user
    /// previously stated, and never invents one they didn't.
    ///
    /// `@MainActor` because `LocalStore` is (LocalStore.swift:466) — every caller here is already on
    /// the main actor, so this costs nothing and keeps the SwiftData context single-threaded.
    @MainActor
    @discardableResult
    static func record(onset: Date, severityRaw: Int?, store: LocalStore) throws -> Outcome {
        if let existing = mergeTarget(for: onset, store: store) {
            // Every field the store would otherwise overwrite is passed back verbatim.
            // `saveHeadacheEntry` assigns symptoms/customSymptoms/factors/notes/end unconditionally
            // on an upsert, so omitting them here would let a re-tap of the control ERASE a fully
            // filled-in entry — the exact opposite of what this feature is for.
            try store.saveHeadacheEntry(
                onset: existing.onset,
                end: existing.end,
                // Take a newly-stated severity (the user's latest word on it); otherwise keep what
                // is already recorded. `nil` here is "not stated", not "unspecified".
                severityRaw: severityRaw ?? existing.severityRaw,
                symptoms: existing.symptoms,
                customSymptoms: existing.customSymptoms,
                factors: existing.factors,
                notes: existing.notes)
            revealLog()
            return .merged(onset: existing.onset)
        }
        try store.saveHeadacheEntry(
            onset: onset,
            end: nil,
            // Unrated stays UNSPECIFIED. This is the fabrication guard: the fast path must never
            // buy its speed by asserting a pain level the user never gave.
            severityRaw: severityRaw ?? 0,
            symptoms: [],
            // A quick log IS the user stating a fact about themselves, so it is `.user` like any
            // sheet entry — never an inferred or imported row.
            source: .user)
        revealLog()
        return .created(onset: onset)
    }

    /// Turn the headache feature's master opt-in ON, after a quick log has actually been stored.
    ///
    /// With the gate off, the dashboard card and its history screen aren't drawn at all — so the row
    /// would be stored somewhere the user cannot see, edit or delete it, which is a trap rather than
    /// a feature. Flipping the gate is the direct consequence of the user's own explicit request to
    /// log a headache, and it only REVEALS a log: it enables no notification (that has its own
    /// earned unlock) and asserts nothing about their health.
    ///
    /// Lives here rather than at each call site so Siri, the control and any future entry point
    /// cannot disagree about it. `@AppStorage(HeadacheDefaults.enabled)` observes `UserDefaults`, so
    /// a live dashboard picks this up without extra plumbing.
    private static func revealLog() {
        UserDefaults.standard.set(true, forKey: HeadacheDefaults.enabled)
    }

    /// The existing entry a log at `onset` should fold into, if any: the nearest OPEN, user-entered
    /// headache whose onset is within `mergeWindow`.
    ///
    /// Three exclusions, each for its own reason:
    ///  - `source != .user` — an imported Apple Health row is somebody else's record of the same
    ///    fact; upserting it would rewrite fields on a sample we don't own and muddy the provenance
    ///    the label series depends on.
    ///  - `end != nil` — the user explicitly said that headache was over, so a later log is a new
    ///    episode, not an update to a finished one.
    ///  - nothing at all in range — the ordinary case, a new row.
    ///
    /// The MERGED row keeps its own `onset`. A quick log's timestamp is the weaker of the two
    /// claims (it is "when I got round to tapping", and for the yesterday path it is an admitted
    /// placeholder), and moving the key would relocate the row and churn a delete-then-rewrite
    /// through the user's Apple Health store for nothing.
    @MainActor
    private static func mergeTarget(for onset: Date, store: LocalStore) -> StoredHeadacheEntry? {
        let nearby = (try? store.headacheEntries(from: onset.addingTimeInterval(-mergeWindow),
                                                 to: onset.addingTimeInterval(mergeWindow))) ?? []
        return nearby
            .filter { $0.source == .user && $0.end == nil }
            .min { abs($0.onset.timeIntervalSince(onset)) < abs($1.onset.timeIntervalSince(onset)) }
    }
}

// MARK: - Intent plumbing

/// The severity choices an intent can carry.
///
/// Mirrors `HeadacheLogSheet.Severity` minus "Unspecified": leaving the parameter EMPTY is how a
/// caller says "unspecified", so offering it as a choice as well would just be two ways to say the
/// same thing in a voice prompt. Raw values are `HKCategoryValueSeverity`'s, matching the sheet, so
/// there is still no mapping table to drift.
enum HeadacheSeverityChoice: String, AppEnum {
    case mild
    case moderate
    case severe

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Headache Severity"
    static let caseDisplayRepresentations: [HeadacheSeverityChoice: DisplayRepresentation] = [
        .mild: "Mild",
        .moderate: "Moderate",
        .severe: "Severe",
    ]

    /// `HKCategoryValueSeverity` raw value: 2 mild, 3 moderate, 4 severe.
    var severityRaw: Int {
        switch self {
        case .mild:     return 2
        case .moderate: return 3
        case .severe:   return 4
        }
    }

    /// Lower-case wording for mid-sentence use in a spoken confirmation ("Logged a severe
    /// headache…"). The capitalised forms are the picker labels above.
    var spokenAdjective: String {
        switch self {
        case .mild:     return "mild"
        case .moderate: return "moderate"
        case .severe:   return "severe"
        }
    }
}

/// Errors an intent can report back to Siri/Shortcuts in words a user can act on.
enum HeadacheQuickLogError: Error, CustomLocalizedStringResourceConvertible {
    /// The SwiftData store could not be opened — in practice a background launch before the first
    /// unlock after a restart, when Data Protection still has the store file sealed (#131). Saying
    /// so is the honest outcome; the alternative (a throwaway in-memory container) would report
    /// success and drop the label.
    case storeUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable:
            return "OpenCircuit couldn’t open your log just now — if your iPhone restarted recently, unlock it and try again."
        }
    }
}

/// Resolve the store the intents write to.
///
/// Reuses the process-wide container the `App` published at launch, exactly as the BGTask handler
/// does (AppDelegate.swift:127), and falls back to the NON-destructive `makeContainerOrThrow()`.
/// `makeContainer()` is never called here: its wipe-and-recover path would delete un-resyncable
/// history on a transient open failure, with no UI present to tell the user (#40/#131).
@MainActor
private func quickLogStore() throws -> LocalStore {
    guard let container = try? (OpenCircuitApp.sharedContainer ?? OpenCircuitApp.makeContainerOrThrow()) else {
        throw HeadacheQuickLogError.storeUnavailable
    }
    return LocalStore(container.mainContext)
}

/// Shared confirmation wording, so every entry point says the same thing about what was stored.
///
/// The dialog always names the TIME the row was filed under. That is the honest half of the
/// yesterday path: the noon onset is a placeholder, and a confirmation that hid it would let the
/// placeholder pass as something the user said.
private func quickLogDialog(_ outcome: HeadacheQuickLog.Outcome,
                            severity: HeadacheSeverityChoice?,
                            placeholderTime: Bool) -> IntentDialog {
    let when = outcome.onset.formatted(date: .abbreviated, time: .shortened)
    let rated = severity.map { "\($0.spokenAdjective) headache" } ?? "headache"
    switch outcome {
    case .created:
        return IntentDialog(placeholderTime
            ? "Logged a \(rated) for \(when). Open OpenCircuit if you'd like to correct the time."
            : "Logged a \(rated) at \(when).")
    case .merged:
        // Naming the merge is what keeps it from reading as a dropped tap — and it tells the user
        // the count didn't go up, which matters when the count is the whole point.
        if let severity {
            return IntentDialog("Updated the headache you logged at \(when) to \(severity.spokenAdjective).")
        }
        return IntentDialog("You'd already logged a headache at \(when) — updated that one instead of adding a second.")
    }
}

// MARK: - Log a headache now

/// Record a headache starting NOW.
struct LogHeadacheIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Headache"
    static let description = IntentDescription(
        "Records a headache starting now in your OpenCircuit headache log.",
        categoryName: "Headache Log",
        searchKeywords: ["headache", "migraine", "log", "pain"])

    /// FALSE on purpose. The intent is declared in the app target, so the system launches the app
    /// (in the background, no UI) and performs it there against the real SwiftData store — which is
    /// what makes this a zero-tap path. Opening the app would cost the user a screen they did not
    /// ask for, and — for someone with a headache — a bright screen is an actively hostile thing to
    /// put in front of them.
    static let openAppWhenRun = false

    /// Runnable from a LOCKED device. The default policy (`.requiresAuthentication`) would put a
    /// Face ID prompt between "Hey Siri, log a headache" and the row, at 3 a.m., for someone in
    /// pain — which is precisely the friction that loses labels.
    ///
    /// It is safe to relax here because this intent DISCLOSES nothing: it reads no stored health
    /// data back, and its dialog only repeats what the speaker just said. Its entire effect is
    /// appending one row that says a headache happened, which the owner can see and delete. The
    /// residual risk — somebody with physical access to a locked phone adding a bogus entry — is
    /// visible and reversible, and is a far smaller cost to the label series than a real headache
    /// that never got logged. (Anything that READS the log stays behind the app's normal
    /// unlock-and-open path.)
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Severity",
               description: "Optional. Leave this empty to log the headache without rating it.")
    var severity: HeadacheSeverityChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try quickLogStore()
        let outcome = try HeadacheQuickLog.record(onset: Date(),
                                                  severityRaw: severity?.severityRaw,
                                                  store: store)
        return .result(dialog: quickLogDialog(outcome, severity: severity, placeholderTime: false))
    }
}

// MARK: - Log yesterday's headache

/// Record a headache for YESTERDAY.
///
/// This exists because people remember a headache the next morning — often only when the phone asks
/// them something else. Without a yesterday path those labels are simply never logged, and a label
/// that is never logged cannot be recovered.
struct LogHeadacheYesterdayIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Yesterday’s Headache"
    static let description = IntentDescription(
        "Records a headache for yesterday in your OpenCircuit headache log. You can correct the time in the app.",
        categoryName: "Headache Log",
        searchKeywords: ["headache", "migraine", "yesterday", "log"])

    static let openAppWhenRun = false
    /// Same reasoning as `LogHeadacheIntent.authenticationPolicy` — write-only, disclosing nothing,
    /// and reversible.
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Severity",
               description: "Optional. Leave this empty to log the headache without rating it.")
    var severity: HeadacheSeverityChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try quickLogStore()
        // Yesterday at 12:00 local — an admitted placeholder, defined once in
        // `HeadacheQuickLink.When.yesterday` (see the reasoning there) and shared with the deep
        // link so the two paths can't disagree about it. The dialog below names the time, and the
        // log sheet lets the user move it.
        let onset = HeadacheQuickLink.When.yesterday.resolvedOnset()
        let outcome = try HeadacheQuickLog.record(onset: onset,
                                                  severityRaw: severity?.severityRaw,
                                                  store: store)
        return .result(dialog: quickLogDialog(outcome, severity: severity, placeholderTime: true))
    }
}

// MARK: - Siri phrases

/// Siri / Spotlight / Action-button phrases for the two logging intents.
///
/// Every phrase carries `\(.applicationName)` because App Intents REQUIRES the app-name token in
/// each one; without it the phrase is rejected at build time. The wording covers both how a person
/// describes the act ("log a headache") and how they describe the state ("I have a headache"),
/// since the second is what someone actually says when they have one.
struct OpenCircuitAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogHeadacheIntent(),
            phrases: [
                "Log a headache in \(.applicationName)",
                "Log a headache with \(.applicationName)",
                "Record a headache in \(.applicationName)",
                "I have a headache, \(.applicationName)",
            ],
            shortTitle: "Log a Headache",
            systemImageName: "brain.head.profile")

        AppShortcut(
            intent: LogHeadacheYesterdayIntent(),
            phrases: [
                "Log yesterday’s headache in \(.applicationName)",
                "Log a headache for yesterday in \(.applicationName)",
                "I had a headache yesterday, \(.applicationName)",
            ],
            shortTitle: "Log Yesterday’s Headache",
            systemImageName: "brain.head.profile")

        // Data export (#80). It lives in THIS provider, not a second one: an app may declare only a
        // single `AppShortcutsProvider`, and a second declaration makes every shortcut — including
        // the headache ones above — silently disappear from Shortcuts. The intent itself is in
        // Export/ExportDataIntent.swift.
        AppShortcut(
            intent: ExportRingDataIntent(),
            phrases: [
                "Export my \(.applicationName) data",
                "Export my ring data with \(.applicationName)",
                "Export health data from \(.applicationName)",
            ],
            shortTitle: "Export Ring Data",
            systemImageName: "square.and.arrow.up")
    }
}
