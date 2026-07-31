import SwiftUI
import SwiftData
import OpenCircuitKit

// The dashboard's headache-log card: the two-tap log, the morning-after prompt, the shared Apple
// Health import control, and (Phase 2, #183) last night's overnight signals.
//
// The LOG half is the point of the feature. The user's entries are the only ground-truth labels
// anything here could ever be validated against, and a headache that isn't logged can't be filled
// in later.
//
// The SIGNALS half is an ESTIMATE, and the framing is chosen against its real accuracy rather than
// its ambition. It sits under a neutral "Overnight signals" heading, it never shows the index, and
// the word "headache" appears only on the Log button. That is not squeamishness: the published
// ceiling for physiology-only headache forecasting is AUC ≈ 0.65, which at our operating point is
// roughly 26 % precision — about three in four unusual nights are followed by nothing at all. A
// headache-framed band on the dashboard would be a permanent ~10 %-of-days anxiety generator for a
// user for whom nothing has been validated and who may never get headaches
// (docs/HEADACHE_SIGNALS.md §6.1). Phase 2 also sends no notification, by design.
//
// Visibility is the CALLER's job (`HeadacheDefaults.enabled`), mirroring how the dashboard hides
// the cycle card behind `womensHealthEnabled`.

struct HeadacheCardView: View {
    /// Push the headache history/detail route. The dashboard SUPPLIES this — it does not wrap the
    /// card in its own `Button` the way `cycleCalendarCard` does.
    ///
    /// That difference is deliberate and load-bearing: unlike the passive cycle card, this card
    /// carries its own controls ("Log a headache", the Apple Health import prompt), and a `Button`
    /// nested inside another `Button`'s label does not receive its own taps — the outer hit area
    /// swallows them, which would break the feature's primary action. So the `NavigationStack` path
    /// still lives in ContentView, but it reaches this view as a closure and is fired from the
    /// card's own header button.
    ///
    /// `nil` means non-navigating (previews, or an embedded use with no route): the header is plain
    /// text and no chevron is drawn. Either way it is a `Button`, never a `NavigationLink` — a
    /// `NavigationLink` in the Today list draws the List's own disclosure chevron on top of ours.
    let onOpenDetail: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    /// This month's entries. Bounded: the card only ever renders a count, so it must not drag the
    /// whole table through the render path on every SwiftData invalidation.
    @Query private var monthEntries: [StoredHeadacheEntry]

    /// The last few FROZEN daily scores. Never rendered FROM here, and the index is never rendered
    /// at all — this exists so the signals `.task(id:)` re-runs when a sync freezes this morning's
    /// row, instead of the card holding last night's answer until some unrelated invalidation
    /// happens to arrive. The row's band is read inside that task, through the engine.
    @Query private var recentRisk: [StoredHeadacheRisk]

    /// Existence probe for the day the morning-after prompt asks about. `fetchLimit = 1` because the
    /// only question asked of it is "is this day empty?" — the rows themselves are never rendered.
    @Query private var yesterdayEntries: [StoredHeadacheEntry]

    @State private var showLogSheet = false

    /// The onset the log sheet should OPEN on, when it is being opened for a specific past day
    /// (the morning-after prompt). `nil` = the plain "Log a headache" path, which opens on now.
    @State private var pendingOnset: Date?

    /// The prompt follows the same switch the dashboard uses to show this card at all. Read here as
    /// well as by the caller so the prompt cannot outlive the feature being turned off mid-session.
    @AppStorage(HeadacheDefaults.enabled) private var headacheEnabled = false

    /// `yyyymmdd` of the day whose prompt the user has already dismissed. 0 = none.
    @AppStorage(HeadacheDefaults.yesterdayPromptDismissedDay) private var promptDismissedDay = 0

    /// Last night's verdict, computed OFF the render path (see the `.task(id:)` below). `nil` once
    /// `signalsLoaded` is true means the engine had nothing to say — which is rendered as "not
    /// assessed", never as a reassuring "nothing unusual".
    @State private var verdict: HeadacheSignals.Verdict?
    @State private var signalsLoaded = false

    /// Today's FROZEN band — the one OF RECORD — and the coverage recorded with it.
    ///
    /// The card shows THIS band whenever there is one, and only falls back to `verdict` before a
    /// day is frozen. `todaysVerdict` re-assesses as of the freeze instant so the two normally
    /// agree, but a night that re-stages after the freeze (1–22 h after wake in this app) moves the
    /// live reproduction and NOT the row: the frozen row is what the history rows, the Diagnostics
    /// export and any later accuracy check use, so a dashboard rendering the fresher number can
    /// announce "last night was unusual for you" on a morning whose record says otherwise.
    ///
    /// `nil` band means nothing is frozen for today yet OR the stored `bandRaw` isn't one this
    /// build knows — both fall back to the live reproduction rather than guessing.
    @State private var recordedBand: HeadacheSignals.Band?
    @State private var recordedFeatureCount: Int?

    /// So a skin-temperature reason reads in the unit the rest of the app uses (#83).
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    /// The day the morning-after prompt asks about, fixed at INIT and shared by the emptiness query,
    /// the sheet's prefill and the dismissal key so all three always mean the same day.
    ///
    /// A card that survives midnight therefore asks a slightly STALE question rather than an
    /// inconsistent one: it prefills, and remembers the dismissal for, the day it actually asked
    /// about. (Any dashboard invalidation rebuilds the view and moves the window on.)
    private let promptDayStart: Date

    private static let monthFetchLimit = 100
    /// Three days of frozen rows: enough to see this morning's appear, small enough that the
    /// dashboard never carries a growing fetch on its render path.
    private static let riskWindowDays = 3
    private static let riskFetchLimit = 4

    init(onOpenDetail: (() -> Void)? = nil) {
        self.onOpenDetail = onOpenDetail
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))
            ?? cal.startOfDay(for: Date())
        var desc = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset >= monthStart },
            sortBy: [SortDescriptor(\.onset, order: .reverse)])
        desc.fetchLimit = Self.monthFetchLimit
        _monthEntries = Query(desc)

        let riskSince = cal.startOfDay(for: Date())
            .addingTimeInterval(-Double(Self.riskWindowDays) * 86_400)
        var riskDesc = FetchDescriptor<StoredHeadacheRisk>(
            predicate: #Predicate { $0.day >= riskSince },
            sortBy: [SortDescriptor(\.day, order: .reverse)])
        riskDesc.fetchLimit = Self.riskFetchLimit
        _recentRisk = Query(riskDesc)

        // Yesterday, as its own bounded query rather than a filter over `monthEntries`: on the 1st
        // of a month yesterday is in the PREVIOUS month, so the month query would report it empty
        // and the card would ask about a day the user had already logged.
        let dayStart = cal.startOfDay(for: Date())
        let prevStart = cal.date(byAdding: .day, value: -1, to: dayStart)
            ?? dayStart.addingTimeInterval(-86_400)
        promptDayStart = prevStart
        var yesterdayDesc = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset >= prevStart && $0.onset < dayStart },
            sortBy: [SortDescriptor(\.onset, order: .forward)])
        yesterdayDesc.fetchLimit = 1
        _yesterdayEntries = Query(yesterdayDesc)
    }

    var body: some View {
        OCCard {
            if let onOpenDetail {
                Button(action: onOpenDetail) {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Headache log. \(monthCountLine)")
                .accessibilityHint("Shows your logged headaches")
            } else {
                header
            }

            // Above the signals divider, in the LOG half of the card. Deliberately not adjacent to
            // "Overnight signals": a question sitting under a band reads as being asked BECAUSE of
            // the band, which is the one thing this prompt must never imply.
            yesterdayPrompt

            signalsSection

            Button {
                pendingOnset = nil          // a plain log opens on NOW, never on the prompt's day
                showLogSheet = true
            } label: {
                Label("Log a headache", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HeadacheImportControl(oneTimePrompt: true)
        }
        .sheet(isPresented: $showLogSheet, onDismiss: { pendingOnset = nil }) {
            // `editing:` is doing PREFILL duty here, not edit duty. `HeadacheLogSheet` takes its
            // opening onset from the entry it is handed, and the morning-after prompt has to open on
            // yesterday — opening on `now` would file yesterday's headache under today unless the
            // user noticed and corrected the picker, which is a corrupted label, not a missing one.
            //
            // The carrier is never inserted into the context, and holding an un-inserted `@Model` is
            // already how this feature works elsewhere: `HeadacheEngine` builds a `StoredHeadacheRisk`
            // and hands it to `insertRiskDayIfAbsent`, which drops it unused when the day is already
            // frozen (HeadacheStore.swift:342).
            HeadacheLogSheet(editing: pendingOnset.map { StoredHeadacheEntry(onset: $0) }) { draft in
                try LocalStore(modelContext).saveHeadacheEntry(
                    onset: draft.onset, end: draft.end, severityRaw: draft.severityRaw,
                    symptoms: draft.symptoms, customSymptoms: draft.customSymptoms,
                    factors: draft.factors, notes: draft.notes,
                    // Always a plain upsert. This card never opens on a STORED row — `editing:` is
                    // either nil or the prefill carrier above — so there is no original row to
                    // relocate, and handing the carrier's onset over as `originalOnset` would send
                    // the store down its relocate path: moving the picker would then DELETE whatever
                    // real entry occupies the new onset (HeadacheStore.swift:218-227). Editing an
                    // existing entry belongs to the history screen (HeadacheSignalsView.swift:127).
                    originalOnset: nil)
            }
        }
        // Last night's verdict, OFF the render path. `HeadacheEngine` owns the other half of the
        // 0x8BADF00D discipline (VitalsStatusCardView.swift:101-122): it snapshots the SwiftData
        // rows on the main actor and runs the Kit math on `Task.detached`. Doing any of it inline
        // in `body` has already cost this app one shipped watchdog crash.
        .task(id: signalsKey) {
            let store = LocalStore(modelContext)
            let engine = HeadacheEngine()
            verdict = await engine.todaysVerdict(store: store)
            // The row of record, fetched AFTER the assessment and flattened to values immediately:
            // a `@Model` reference must not be carried across a suspension point (the row can be
            // re-staged or deleted under us), and only these two values reach the render path.
            // Reassigned unconditionally so the band clears again after midnight.
            let recorded = engine.frozenToday(store: store)
            recordedBand = recorded.flatMap { HeadacheSignals.Band(rawValue: $0.bandRaw) }
            recordedFeatureCount = recorded?.ringFeatureCount
            signalsLoaded = true
        }
    }

    // MARK: - Morning-after prompt

    /// Whether to ask about yesterday: the feature is on, the day is EMPTY, and the user hasn't
    /// already waved this day away.
    ///
    /// The trigger is emptiness and nothing else. It is deliberately NOT conditioned on the signals
    /// score, the band, or anything the detector produced: asking "did you have a headache?" because
    /// we flagged the night would pull the answer toward our own output, and these labels are the
    /// only ground truth the detector can ever be measured against — a biased label set can't be
    /// spotted later and can't be repaired.
    ///
    /// "Empty" counts ANY row for the day, including a `notPresent` (severity 1) one. That is a
    /// looser test than the engine's own suppression check, which excludes `notPresent` because an
    /// absence isn't a headache (HeadacheEngine.swift:511-514) — but here the question is "do we
    /// have the user's answer for this day?", and "no headache" is an answer. Re-asking it would be
    /// nagging someone who already told us.
    private var showsYesterdayPrompt: Bool {
        headacheEnabled && yesterdayEntries.isEmpty && promptDismissedDay != promptDayKey
    }

    /// Timezone-stable `yyyymmdd` key for the day being asked about — the house form for a per-day
    /// ledger (HealthAlerts.swift:296-303). An instant would shift under travel and could re-arm a
    /// prompt the user already dismissed.
    private var promptDayKey: Int { TempFeverNotifications.dayKey(for: promptDayStart) }

    /// The onset the prefilled sheet OPENS on: midday of the day being asked about.
    ///
    /// A placeholder, and deliberately an obvious one. The user is answering a DAY-level question
    /// and has stated no clock time, so any time we choose is ours, not theirs; midday is round
    /// enough to read as a default and the picker shows it before anything is saved. This is the
    /// sheet's own rule for its end-time default — "a wrong 'now' is at least visible and
    /// correctable" (HeadacheLogSheet.swift:96-101) — rather than an invented plausible-looking
    /// time. Severity stays Unspecified: the quick path records no rating the user didn't give.
    ///
    /// It cannot collide with the store's unique `onset` key either: the prompt only appears when
    /// the day holds no rows at all.
    private var yesterdayPrefillOnset: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: promptDayStart)
            ?? promptDayStart
    }

    /// Most headaches are remembered the NEXT morning rather than logged during, and the card is
    /// already on screen at exactly the moment that memory is still recoverable. Unlike ring data a
    /// missed label cannot be back-filled from anywhere — if the user doesn't type it, it never
    /// existed — so the card asks instead of waiting to be found.
    ///
    /// It asks; it never asserts. Nothing here says a headache was likely, nothing references the
    /// signals section, and a dismissal records NOTHING: "no" is not filed as a `notPresent` label,
    /// because a tap that may well have meant "not now" would then become a health fact the user
    /// never stated.
    @ViewBuilder
    private var yesterdayPrompt: some View {
        if showsYesterdayPrompt {
            VStack(alignment: .leading, spacing: 6) {
                Text("Did you have a headache yesterday?")
                    .font(.subheadline.weight(.medium))
                // Names the actual reason it is being asked — the day is blank — so the question
                // can't be read as the app having noticed something.
                Text("Nothing is logged for \(promptDayName). You can add it now and set the time yourself.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Log it") {
                        pendingOnset = yesterdayPrefillOnset
                        showLogSheet = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Log a headache for \(promptDayName)")

                    Button("Nothing to log") {
                        promptDismissedDay = promptDayKey
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Stops asking about \(promptDayName). Nothing is recorded.")
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            // The NEUTRAL house surface (ContentView.swift:1011), never the orange one warnings use
            // (ContentView.swift:1052): this is a question about a blank day, not an alert.
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
    }

    /// Weekday name of the day being asked about. Spelled out rather than left as "yesterday" so a
    /// card that has been on screen since before midnight still names the day it actually queried.
    private var promptDayName: String {
        promptDayStart.formatted(.dateTime.weekday(.wide))
    }

    // MARK: - Overnight signals (#183, Phase 2)

    /// Identity for the verdict recompute: today's date (so the card doesn't hold last night's
    /// answer across midnight), the frozen rows (this morning's row appearing must show up), and
    /// the log (logging today changes the suppression state).
    private var signalsKey: String {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return "\(day)|\(recentRisk.count)|\(recentRisk.first?.updatedAt.timeIntervalSince1970 ?? 0)|\(monthEntries.count)"
    }

    /// Whether the engine reported the feature switched off. The dashboard already gates the whole
    /// card on `HeadacheDefaults.enabled`; this is the belt-and-braces case where the engine and
    /// the caller disagree, and it renders nothing rather than an empty heading.
    private var isNotEnabled: Bool {
        guard let verdict else { return false }
        if case .notEnabled = verdict { return true }
        return false
    }

    /// The band this card is willing to show: the FROZEN row's when today is frozen, the live
    /// reproduction's until it is, and nothing at all when neither can speak.
    private var shownBand: HeadacheSignals.Band? {
        if let recordedBand { return recordedBand }
        if let verdict, case .scored(let assessment) = verdict {
            return HeadacheSignalCopy.displayBand(assessment)
        }
        return nil
    }

    /// The live reproduction's assessment, when there is one. It supplies the DETAIL under the band
    /// — the driver lines and the fever note — which the frozen row cannot: it stores contributions
    /// as JSON, and the Kit's `Assessment` has no public initialiser to rebuild one from.
    private var liveAssessment: HeadacheSignals.Assessment? {
        if let verdict, case .scored(let assessment) = verdict { return assessment }
        return nil
    }

    /// Last night's verdict under a NEUTRAL heading. Every branch states what we actually know:
    /// there is deliberately no branch that renders a comfortable silence.
    @ViewBuilder
    private var signalsSection: some View {
        if signalsLoaded && !isNotEnabled {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Overnight signals")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let shownBand {
                        HeadacheBandChip(band: shownBand)
                    }
                }
                if let verdict {
                    signalsBody(verdict)
                } else {
                    Text("Not assessed yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func signalsBody(_ verdict: HeadacheSignals.Verdict) -> some View {
        // The headline follows the band actually on screen. Deriving it from the live verdict while
        // the chip came from the frozen row is how the card ends up saying one thing beside another.
        let head = recordedBand.map(HeadacheSignalCopy.headline(recordedBand:))
            ?? HeadacheSignalCopy.headline(verdict)
        Text(head.title)
            .font(.subheadline)
        if let detail = head.detail {
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
        }

        // The two biggest REASONS, with what they actually read. A band with nothing under it is an
        // assertion; naming the inputs is what makes it checkable. Only the live reproduction can
        // supply them, so on a re-staged morning the recorded band stands with no drivers under it
        // rather than borrowing reasons that produced a different number.
        if let live = liveAssessment, shownBand != .typical {
            ForEach(Array(HeadacheSignalCopy.drivers(live.contributions).prefix(2)),
                    id: \.feature) { driver in
                driverLine(driver)
            }
        }

        // Coverage on EVERY scored night, not just the thin ones. A confident "nothing unusual"
        // derived from two working sensors is the dangerous failure mode here — a lie of omission —
        // so how much was actually measured is never left off. Recorded coverage first, for the same
        // reason as the band.
        if let measured = recordedFeatureCount ?? liveAssessment?.ringFeatureCount {
            Text("Measured \(measured) of \(HeadacheSignalCopy.ringFeatureTotal) signals.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if liveAssessment?.suppressedBy == .fever {
            // Raised HR + raised temperature IS a scored night's signature, so it is named
            // rather than left to be misread. `.headacheAlreadyLogged` is deliberately NOT
            // surfaced: it only withholds a Phase-3 notification, and saying it here would put
            // the word "headache" into signals copy for no gain.
            Text("Your resting heart rate and skin temperature both look raised, which on its own can produce these signals.")
                .font(.caption).foregroundStyle(.secondary)
        }

        // Attached to the BAND, not to the live verdict: whenever a band is on screen, so is the
        // sentence saying what it is and is not.
        if shownBand != nil {
            Text("How unusual last night was for you — in either direction, not how bad it was. Not a prediction.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// One reason, with its real reading attached in the user's own units.
    private func driverLine(_ contribution: HeadacheSignals.Contribution) -> some View {
        let unit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
        let name = HeadacheSignalCopy.name(contribution.feature)
        let phrase = HeadacheSignalCopy.deviation(contribution, tempUnit: unit)
        return Text(phrase.map { "\(name) — \($0)" } ?? name)
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Title + this month's count. The chevron is drawn in both modes because the card pushes the
    /// history either way — from our own button or from the dashboard's wrapper.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            OCSectionHeader("Headache log", systemImage: "brain.head.profile",
                            tint: Theme.accent) {
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Text(monthCountLine)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Count line. Reports the fetch cap as "100+" rather than a flat "100" — the card would
    /// otherwise understate a month it only partly fetched.
    private var monthCountLine: String {
        let count = monthEntries.count
        switch count {
        case 0:                     return "No headaches logged this month"
        case 1:                     return "1 headache logged this month"
        case Self.monthFetchLimit:  return "\(Self.monthFetchLimit)+ headaches logged this month"
        default:                    return "\(count) headaches logged this month"
        }
    }
}

// MARK: - Apple Health import

/// The "import the headaches you already log in Apple Health" control.
///
/// ONE component in two modes so the card's one-time prompt and the history screen's permanent
/// button can never disagree about what was imported or about what "none" means:
///  - `oneTimePrompt: true` — the card's first-run offer. Disappears once answered
///    (`HeadacheDefaults.importPromptShown`), either by importing or by "Not now".
///  - `oneTimePrompt: false` — the history screen's always-available button.
///
/// The result copy is deliberately careful. HealthKit does NOT tell an app when a read is denied:
/// a denied read and a genuinely empty Health store return the exact same empty set. So "none" may
/// never be phrased as "you have no headaches in Health" — it says nothing was FOUND, and names
/// permissions as a possible reason.
struct HeadacheImportControl: View {
    var oneTimePrompt: Bool = false

    @Environment(\.modelContext) private var modelContext
    @AppStorage(HeadacheDefaults.importPromptShown) private var importPromptShown = false

    @State private var running = false
    @State private var outcome: Outcome? = nil

    /// Bounded lookback. Labels older than this have no ring data to be paired with — the user
    /// didn't own the ring yet — so an unbounded scan of the Health store buys nothing.
    private static let lookbackDays = 730

    /// What one import run actually did. `nothingNew` and `nothingFound` are DIFFERENT facts and
    /// must not share copy: the first read real samples and added none of them, the second read an
    /// empty set — which is also exactly what a denied read looks like.
    private enum Outcome: Equatable {
        case imported(Int)
        case nothingNew
        case nothingFound
    }

    /// The card's one-time prompt hides once answered — but NOT while it is showing the result of a
    /// run the user just kicked off, or the count they asked for would vanish as they read it.
    private var visible: Bool {
        guard HealthKitWriter.isAvailable else { return false }
        return !oneTimePrompt || !importPromptShown || outcome != nil
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 6) {
                if let outcome {
                    Text(resultLine(outcome))
                        .font(.caption).foregroundStyle(.secondary)
                    if outcome == .nothingFound {
                        Text("Apple Health doesn't tell apps when a read is blocked, so this can also mean OpenCircuit isn't allowed to read headaches yet — check its permissions in the Health app.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(oneTimePrompt
                         ? "Already log headaches in Apple Health? Bring them across so they're all in one place."
                         : "Bring headaches you logged in Apple Health into this log.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await runImport() }
                    } label: {
                        if running {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(outcome == nil ? "Import from Apple Health" : "Check again")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(running)

                    if oneTimePrompt, outcome == nil {
                        Button("Not now") { importPromptShown = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultLine(_ outcome: Outcome) -> String {
        switch outcome {
        case .imported(1):          return "Imported 1 headache from Apple Health."
        case .imported(let count):  return "Imported \(count) headaches from Apple Health."
        case .nothingNew:           return "Nothing new to import from Apple Health."
        case .nothingFound:         return "Found no headaches in Apple Health."
        }
    }

    /// Read headache samples out of Apple Health and add the ones we don't already hold.
    ///
    /// Three things this deliberately does NOT do:
    ///  - re-import a sample already imported (`importedHKUUID`, so repeat runs are idempotent);
    ///  - overwrite an entry the user typed themselves — `saveHeadacheEntry` UPSERTS on `onset`, so
    ///    an exact onset collision would silently wipe their symptoms and notes;
    ///  - import a `notPresent` (severity 1) sample. That records the ABSENCE of a headache; filing
    ///    it as a logged headache would fabricate a label for something that didn't happen and
    ///    inflate every count this feature reports.
    @MainActor
    private func runImport() async {
        running = true
        let store = LocalStore(modelContext)
        let since = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86_400)
        let result = await HealthKitWriter().readHeadacheSamples(since: since)
        // The row's own `importedHKUUID` is not a sufficient tombstone: it dies WITH the row, so a
        // user who imports a sample and then deletes it gets it resurrected by the very next import.
        // The consumed set outlives the row, so a deletion stays a deletion.
        let consumed = Set(UserDefaults.standard.stringArray(forKey: HeadacheDefaults.consumedImportUUIDs) ?? [])
        let alreadyImported = ((try? store.importedHeadacheHKUUIDs()) ?? []).union(consumed)
        let existingOnsets = Set(((try? store.allHeadacheEntries()) ?? []).map(\.onset))

        var imported = 0
        var newlyConsumed: [String] = []
        for sample in result.external {
            guard !alreadyImported.contains(sample.uuid),
                  !existingOnsets.contains(sample.onset),
                  sample.severityRaw != 1 else { continue }
            do {
                try store.saveHeadacheEntry(
                    onset: sample.onset, end: sample.end, severityRaw: sample.severityRaw,
                    symptoms: [], source: .healthImport, importedHKUUID: sample.uuid)
                imported += 1
                newlyConsumed.append(sample.uuid)
            } catch {
                break   // stop on the first store failure; the rest retry on the next run
            }
        }
        if !newlyConsumed.isEmpty {
            UserDefaults.standard.set(Array(consumed) + newlyConsumed,
                                      forKey: HeadacheDefaults.consumedImportUUIDs)
        }

        // Only a query that returned NOTHING AT ALL may say "found none" and mention permissions —
        // that is the one case indistinguishable from a denied read. A store holding only our OWN
        // headaches proves the read worked, so it reports "nothing new" instead; saying "none found,
        // check permissions" to someone whose Health app is full of their headaches is simply false.
        outcome = imported > 0
            ? .imported(imported)
            : (result.returnedNothingAtAll ? .nothingFound : .nothingNew)
        importPromptShown = true
        running = false
    }
}
