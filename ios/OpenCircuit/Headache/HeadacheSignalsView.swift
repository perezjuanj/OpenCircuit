import SwiftUI
import SwiftData
import OpenCircuitKit

// Headache history + last night's overnight signals — the detail screen behind the dashboard card.
//
// TWO THINGS LIVE HERE, and keeping them apart is the point.
//
// 1. THE LOG (Phase 1) is the ground-truth LABEL series. A detector can only ever be validated
//    against it, and a label that was never logged cannot be recovered afterwards. Every affordance
//    in the history section is about getting entries IN and keeping them accurate.
//
// 2. THE SIGNALS (Phase 2, #183) are an ESTIMATE of how unusual last night was FOR THIS PERSON, in
//    either direction. This is the ONLY screen in the app that shows the numeric index, and it is
//    shown with its limits attached rather than in spite of them:
//      · the published ceiling for physiology-only headache forecasting is AUC ≈ 0.65; at our
//        operating point that is roughly 26 % precision — about three in four flagged nights are
//        followed by nothing;
//      · the index is a RELATIVE position on one person's own scale. Never a probability, never a
//        percentage chance, never comparable between people;
//      · a hangover, a late night out and a hard training day are indistinguishable from a
//        prodrome, by construction.
//    All of that is in the shipped footer, not just in this comment.
//
// The signals section is headed "Overnight signals" and never says "headache". Phase 2 has no
// notification and nothing has been validated for this user, so a headache-framed band would be a
// permanent ~10 %-of-days anxiety generator with a 100 % false-positive rate for the many people
// who simply don't get headaches (docs/HEADACHE_SIGNALS.md §6.1). The word stays on the log.

struct HeadacheSignalsView: View {
    @Environment(\.modelContext) private var modelContext

    /// The whole log, newest first. Unbounded on purpose — this IS the history screen, and the
    /// table is user-entered and sparse (a heavy sufferer logs a few hundred rows a year).
    @Query(sort: \StoredHeadacheEntry.onset, order: .reverse)
    private var entries: [StoredHeadacheEntry]

    /// Frozen daily scores, newest first, used to annotate the history rows. BOUNDED, unlike
    /// `entries`: this table gains a row every day and is deliberately never pruned (the score is
    /// not re-derivable — HeadacheStore.swift:113-124), so it is the one table here that grows
    /// without a user in the loop.
    @Query private var riskRows: [StoredHeadacheRisk]

    @State private var showLogSheet = false
    @State private var editingEntry: StoredHeadacheEntry? = nil

    /// Last night's verdict, computed OFF the render path (see the `.task(id:)` below). `nil` once
    /// `signalsLoaded` is true means the engine had nothing to say — rendered as "not assessed",
    /// never as a reassuring "nothing unusual".
    @State private var verdict: HeadacheSignals.Verdict?
    @State private var signalsLoaded = false

    /// Local-start-of-day → that morning's frozen score, for the history rows. Built off the main
    /// actor from a value snapshot.
    @State private var frozen: [Date: FrozenDay] = [:]

    /// The quality monitor's current reading (Phase 3). `nil` until loaded, or when the feature is
    /// off — the panel is simply absent rather than showing a reassuring placeholder.
    @State private var monitor: HeadacheMonitorReport?

    /// Whether the morning notification is live right now. Read from the defaults rather than from
    /// `monitor`, so the "turn it back on" button below changes the panel the instant it is tapped.
    @AppStorage(HeadacheDefaults.unlocked) private var alertsLive = false

    /// `yyyymmdd` of the day the notification first went live, or 0 if it never has. The panel needs
    /// the distinction: "alerts are off because they were never switched on" and "alerts are off
    /// because something switched them off" are different sentences, and only one of them may
    /// mention this check as the reason.
    @AppStorage(HeadacheDefaults.promotedOnDayKey) private var promotedOnDayKey = 0

    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    /// Two years of frozen rows — the same window the Apple Health import uses, and far more than
    /// either the 60-day banding window or the 365-day evaluation window needs.
    private static let riskLookbackDays = 730
    private static let riskFetchLimit = 800

    init() {
        let since = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(-Double(Self.riskLookbackDays) * 86_400)
        var desc = FetchDescriptor<StoredHeadacheRisk>(
            predicate: #Predicate { $0.day >= since },
            sortBy: [SortDescriptor(\.day, order: .reverse)])
        desc.fetchLimit = Self.riskFetchLimit
        _riskRows = Query(desc)
    }

    /// One frozen day, snapshotted out of SwiftData so the history join can run off the main actor.
    struct FrozenDay: Sendable, Equatable {
        let index: Int
        /// `nil` when the stored raw value isn't one this build knows. Shown as a bare index rather
        /// than guessed at — a forward-compatibility case, not a normal one.
        let band: HeadacheSignals.Band?
        let computedAt: Date
        let restaged: Bool
    }

    var body: some View {
        List {
            todaySignalsSection

            monitorSection

            if entries.isEmpty {
                emptySection
            } else {
                ForEach(months) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }

            Section {
                HeadacheImportControl()
            } header: {
                Text("Apple Health")
            } footer: {
                Text("OpenCircuit is not a medical device. This log is your own record — nothing here diagnoses or explains a headache.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.pageBackground)
        .navigationTitle("Headache Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingEntry = nil
                    showLogSheet = true
                } label: {
                    Label("Log a headache", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            // The sheet keeps this entry's onset as its `originalOnset`, so a moved onset RELOCATES
            // the row instead of leaving the original behind as a duplicate. `onDelete` is always
            // supplied — the sheet itself only surfaces the affordance when it has an entry to
            // delete, so a new entry can't offer one.
            HeadacheLogSheet(editing: editingEntry, onDelete: { onset in delete(onset: onset) }) { draft in
                try LocalStore(modelContext).saveHeadacheEntry(
                    onset: draft.onset, end: draft.end, severityRaw: draft.severityRaw,
                    symptoms: draft.symptoms, customSymptoms: draft.customSymptoms,
                    factors: draft.factors, notes: draft.notes,
                    originalOnset: draft.originalOnset)
            }
        }
        // Last night's verdict, OFF the render path. `HeadacheEngine` owns the other half of the
        // 0x8BADF00D discipline (VitalsStatusCardView.swift:101-122): it snapshots the SwiftData
        // rows on the main actor and runs the Kit math on `Task.detached`. This view must never
        // assemble or assess anything inside `body`.
        .task(id: signalsKey) {
            verdict = await HeadacheEngine().todaysVerdict(store: LocalStore(modelContext))
            signalsLoaded = true
        }
        // The quality monitor's reading. Same discipline again, and this one WRITES NOTHING: opening
        // a screen must never be able to spend one of the monitor's rationed decisions.
        .task(id: monitorKey) {
            monitor = await HeadacheEngine().monitorReport(store: LocalStore(modelContext))
        }
        // Same discipline for the history join: snapshot to Sendable values on the main actor,
        // build the lookup on `Task.detached`.
        .task(id: frozenKey) {
            let snapshot = riskRows.map {
                (day: $0.day, index: $0.index, bandRaw: $0.bandRaw,
                 computedAt: $0.computedAt, restaged: $0.sleepRestaged)
            }
            frozen = await Task.detached { Self.frozenLookup(snapshot) }.value
        }
    }

    /// Identity for the verdict recompute: today's date (so the screen doesn't hold last night's
    /// answer across midnight), the frozen rows (a sync freezing this morning's row must show up),
    /// and the log (logging today changes the suppression state).
    private var signalsKey: String {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return "\(day)|\(riskRows.count)|\(riskRows.first?.updatedAt.timeIntervalSince1970 ?? 0)|\(entries.count)"
    }

    private var frozenKey: String {
        "\(riskRows.count)|\(riskRows.first?.updatedAt.timeIntervalSince1970 ?? 0)"
    }

    /// Identity for the monitor recompute. Deliberately NOT `alertsLive`: the alert state is read
    /// live from `@AppStorage` and re-runs nothing, so tapping the resume button updates the panel
    /// without paying for a whole re-evaluation of the year.
    private var monitorKey: String {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return "\(day)|\(riskRows.count)|\(entries.count)|\(entries.first?.updatedAt.timeIntervalSince1970 ?? 0)"
    }

    /// Join key is the LOCAL start of day, matching `StoredHeadacheRisk.day` (the start of the day
    /// the night ENDED on).
    nonisolated static func frozenLookup(
        _ rows: [(day: Date, index: Double, bandRaw: Int, computedAt: Date, restaged: Bool)]
    ) -> [Date: FrozenDay] {
        let cal = Calendar.current
        var out: [Date: FrozenDay] = [:]
        for row in rows {
            out[cal.startOfDay(for: row.day)] = FrozenDay(
                index: Int(row.index.rounded()),
                band: HeadacheSignals.Band(rawValue: row.bandRaw),
                computedAt: row.computedAt,
                restaged: row.restaged)
        }
        return out
    }

    // MARK: Today's signals

    /// Whether the engine reported the feature switched off. Visibility is otherwise the caller's
    /// job, exactly as for the card.
    private var isNotEnabled: Bool {
        guard let verdict else { return false }
        if case .notEnabled = verdict { return true }
        return false
    }

    /// Last night's assessment, under a NEUTRAL heading. Every branch says what we actually know:
    /// there is no branch that renders a reassuring silence.
    @ViewBuilder
    private var todaySignalsSection: some View {
        if signalsLoaded && !isNotEnabled {
            Section {
                if let verdict {
                    let head = HeadacheSignalCopy.headline(verdict)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(head.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            if case .scored(let assessment) = verdict {
                                HeadacheBandChip(band: HeadacheSignalCopy.displayBand(assessment))
                            }
                        }
                        if let detail = head.detail {
                            Text(detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    recordDisclosure(verdict)

                    if case .scored(let assessment) = verdict {
                        scoredRows(assessment)
                    } else if case .insufficientData(let missing) = verdict {
                        // Still list all nine, so "what did we actually measure?" is answerable on
                        // a night we couldn't score — that is exactly the night it matters on.
                        ForEach(HeadacheSignals.Feature.allCases, id: \.self) { feature in
                            featureRow(feature, contribution: nil, absent: missing[feature], all: [])
                        }
                    }
                } else {
                    Text("Not assessed yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                // The plan's name for this section (§6.2). Neutral, like the card's "Overnight
                // signals" heading it hangs off — the word "headache" belongs to the log below.
                Text("Today's signals")
            } footer: {
                disclaimerFooter
            }
        }
    }

    /// Says so when what this section shows is NOT the number of record.
    ///
    /// `todaysVerdict` REPRODUCES the assessment as of the freeze instant, so it normally equals
    /// the frozen row exactly. It can't when the night re-staged after the freeze — nights in this
    /// app re-stage 1–22 h after wake — and the frozen row is the one of record: it is what every
    /// history row, the Diagnostics export and any later accuracy check use.
    ///
    /// SECTION level, not inside `indexRow`. The states where the reproduction has drifted FURTHEST
    /// are exactly the ones with no index row to hang a disclosure off — a night that re-staged
    /// thin now reproduces as `.insufficientData`, and a frozen score would then sit unmentioned
    /// behind a screen saying nothing was measured. That is the morning the disclosure matters most.
    @ViewBuilder
    private func recordDisclosure(_ verdict: HeadacheSignals.Verdict) -> some View {
        if let recorded = frozen[Calendar.current.startOfDay(for: Date())] {
            let reproduced: Int? = {
                if case .scored(let assessment) = verdict { return assessment.index }
                return nil
            }()
            if reproduced != recorded.index {
                Text(driftLine(recorded, reproduced: reproduced))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            }
        }
    }

    /// Three different facts, three different sentences: the night re-staged under the score, the
    /// score can no longer be reproduced at all, or it reproduces to a different number.
    private func driftLine(_ recorded: FrozenDay, reproduced: Int?) -> String {
        let lead = "Recorded for today: index \(recorded.index). That frozen number is the one of record"
        if recorded.restaged {
            return "\(lead) — last night re-staged after it was taken, so everything else here is a fresh reading that no longer reproduces it."
        }
        if reproduced == nil {
            return "\(lead); it can no longer be reproduced from what is stored today, so the rest of this section describes today's data instead of that score."
        }
        return "\(lead); everything else here is a fresh reproduction and no longer matches it."
    }

    /// The scored night: the index (shown HERE and nowhere else), what we measured, and every
    /// feature's own contribution so the number can be audited rather than believed.
    @ViewBuilder
    private func scoredRows(_ assessment: HeadacheSignals.Assessment) -> some View {
        indexRow(assessment)
        coverageRow(assessment)
        if assessment.suppressedBy == .fever {
            // The fever pattern (HRV down, resting HR up, temperature up) IS what a scored night
            // looks like, so it is named rather than left for the user to mistake for something
            // else. `.headacheAlreadyLogged` is deliberately NOT surfaced: it only withholds a
            // Phase-3 notification, and saying it here would put the word "headache" into signals
            // copy for no gain.
            Text("Your resting heart rate and skin temperature both look raised. That pattern on its own can produce these signals — see the vitals card.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, 2)
        }
        // Declaration order is the evidence order the weights were set in
        // (docs/HEADACHE_SIGNALS.md §3.4), so it is also the right reading order.
        ForEach(HeadacheSignals.Feature.allCases, id: \.self) { feature in
            featureRow(feature,
                       contribution: assessment.contributions.first { $0.feature == feature },
                       absent: nil,
                       all: assessment.contributions)
        }
    }

    /// The ONLY place the index is rendered, and it never appears without the sentence that says
    /// what it is not. Whether this number is the one OF RECORD is answered above it, at section
    /// level (`recordDisclosure`) — a drift disclosure nested here would be missing on the mornings
    /// that have no index row at all.
    private func indexRow(_ assessment: HeadacheSignals.Assessment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Index")
                    .font(.subheadline.weight(.medium))
                Text("a relative index on your own scale (0–100) — not a probability")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text("\(assessment.index)")
                .font(.title3.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Index \(assessment.index) out of 100, a relative index on your own scale, not a probability")
        .padding(.vertical, 2)
    }

    /// Coverage, on every scored night. A confident-looking verdict derived from two working
    /// sensors is the dangerous failure here, so how much was actually measured is never optional.
    private func coverageRow(_ assessment: HeadacheSignals.Assessment) -> some View {
        let pct = Int((assessment.coverageFraction * 100).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            Text("Measured \(assessment.ringFeatureCount) of \(HeadacheSignalCopy.ringFeatureTotal) signals")
                .font(.subheadline.weight(.medium))
            Text("That is \(pct)% of the signal weight a complete night would carry.")
                .font(.caption2).foregroundStyle(.tertiary)
            // Without this the two percentages below read as the same kind of number. They are
            // not: the trailing one is the DESIGNED weight, the line under each row is the share
            // of last night's index that signal actually produced after renormalising over the
            // signals that were present.
            Text("The percentage beside each signal below is the weight it was designed to carry. Only measured signals count, so a missing one raises every other signal's real share.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// One feature: what it read last night in the user's own units, or why it is missing — plus
    /// the weight it was designed to carry and the share of the index it actually drove.
    private func featureRow(_ feature: HeadacheSignals.Feature,
                            contribution: HeadacheSignals.Contribution?,
                            absent: HeadacheSignals.AbsentReason?,
                            all: [HeadacheSignals.Contribution]) -> some View {
        let unit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
        let reason = absent ?? contribution?.absentReason
        let weightPct = Int((feature.weight * 100).rounded())

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HeadacheSignalCopy.name(feature))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("\(weightPct)%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .accessibilityLabel("weight \(weightPct) percent")
            }

            if let contribution, let ramp = contribution.contribution {
                if let phrase = HeadacheSignalCopy.deviation(contribution, tempUnit: unit) {
                    Text(phrase)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if ramp <= 0 {
                    Text("Within your usual range — it added nothing to last night's index.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if let share = HeadacheSignalCopy.indexShare(contribution, in: all) {
                    Text("\(Int((share * 100).rounded()))% of last night's index came from this.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                // Only two things can shrink a weight — the truncated-night quality rule and the
                // single-signal cap (HeadacheSignals.swift:350-355, :487-504) — and nothing can
                // grow one. We can't tell which applied, so we don't claim.
                if abs(contribution.effectiveWeight - feature.weight) > 0.005 {
                    Text("Counted at \(Int((contribution.effectiveWeight * 100).rounded()))% — reduced because the ring may have cut this night short, or by the cap that stops any one signal dominating.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if feature == .perimenstrual {
                    Text("Context, not a measurement: its weight is added on top of the eight ring signals rather than taken from them, it never counts toward the minimum number of ring signals, and no single signal may supply more than 35 % of a night's score.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else if let reason {
                Text(HeadacheSignalCopy.absence(reason, feature: feature))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Measured last night.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// House-style disclaimer footer (cf. CycleCalendarView.swift:452-457). Every limitation here is
    /// structural rather than incidental: the unsigned scoring, the confusable false-positive class
    /// and the accuracy ceiling are properties of the design, not bugs waiting to be fixed.
    private var disclaimerFooter: some View {
        Text("These signals are a statistical estimate computed on your device from your own 7–60 night baseline. They measure how unusual a night was for you, in either direction — not how bad it was, so an unusually restful night scores like a rough one. A hangover, a late night out and a hard training day look exactly the same to a ring. OpenCircuit is not a medical device, this is not a diagnosis, and it does not predict headaches. If your headaches are new, worsening or severe, consult a qualified healthcare professional.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: Is this working for you?

    /// The panel no vendor ships: what this feature has actually done for THIS user, in words they
    /// can check against their own log.
    ///
    /// Three rules shape everything below.
    ///
    /// 1. NO RAW STATISTIC IS EVER THE HEADLINE. The evaluation produces an AUC, a 95 % interval and
    ///    an exact p-value, and none of them appear as such. A number the reader cannot interpret is
    ///    not honesty, it is decoration — and worse, it is decoration that looks like rigour. The
    ///    AUC and its interval are stated as what they literally mean (how often a headache morning
    ///    outscored an ordinary one, and how tightly that is pinned down); the p-value is not shown
    ///    at all, because there is no plain-language rendering of it that is both short and true.
    /// 2. `.monitoring` MUST NOT READ AS A FAILURE. It is the default and most users live there for
    ///    months or forever — §1.1's own arithmetic says a year of a WORKING detector often still
    ///    cannot settle the question. Copy that reads as an error would be telling most users their
    ///    feature is broken when nothing is.
    /// 3. THE EXCLUSIONS ARE SHOWN. A user who logged 20 headaches and is told 12 were usable is
    ///    owed the other 8, itemised. Hiding the gap is how a denominator quietly becomes a lie.
    @ViewBuilder
    private var monitorSection: some View {
        if let monitor {
            let head = HeadacheMonitorCopy.headline(monitor, alertsLive: alertsLive)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(head.title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(head.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                if let metrics = monitor.metrics {
                    exclusionRow(monitor, metrics)
                }
                lookRow(monitor)
                alertStateRow(monitor)
            } header: {
                Text("Is this working for you?")
            } footer: {
                Text("These numbers come from your own log and only from days OpenCircuit was able to score. They describe whether flagged mornings have actually been different for you — never whether a headache is coming.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// What was logged, what was usable, and — itemised — where the difference went.
    @ViewBuilder
    private func exclusionRow(_ report: HeadacheMonitorReport,
                              _ metrics: HeadacheEvaluation.Metrics) -> some View {
        let reasons = HeadacheMonitorCopy.exclusions(report, metrics)
        VStack(alignment: .leading, spacing: 3) {
            Text(HeadacheMonitorCopy.usableLine(report, metrics))
                .font(.subheadline.weight(.medium))
            if reasons.isEmpty {
                Text("Nothing was left out.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    Text("· \(reason)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// How many times this check has been run. Shown because repeated looks at accumulating data are
    /// what make a rare result likely by chance alone: a reader who can see the count can judge the
    /// verdict for themselves, and it keeps us honest about a decision cadence nobody can audit.
    @ViewBuilder
    private func lookRow(_ report: HeadacheMonitorReport) -> some View {
        if let line = HeadacheMonitorCopy.lookLine(report) {
            Text(line)
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.vertical, 2)
        }
    }

    /// The alert state, stated separately from the finding above it.
    ///
    /// They are genuinely two different facts and can point opposite ways — the check can say "still
    /// too early to tell" on a phone whose alerts are off, and can say "not tracking anything" on
    /// one where the user has switched them back on. A single merged sentence would have to guess
    /// which of those it was looking at, and would be wrong some of the time.
    @ViewBuilder
    private func alertStateRow(_ report: HeadacheMonitorReport) -> some View {
        let retired = HeadacheMonitorCopy.isRetired(report.status)
        VStack(alignment: .leading, spacing: 4) {
            Text(HeadacheMonitorCopy.alertStateLine(report,
                                                    alertsLive: alertsLive,
                                                    everLive: promotedOnDayKey != 0,
                                                    retired: retired))
                .font(.caption).foregroundStyle(.secondary)

            // Offered only once the notification HAS been live: before that there is nothing to turn
            // back on, and a button that pre-empts the 21-night floor would switch on an alert that
            // structurally cannot fire (`HeadacheSignals.band` has no percentile window yet).
            if !alertsLive, promotedOnDayKey != 0 {
                Button("Turn morning alerts back on") {
                    HeadacheEngine().resumeAlerts()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))

                // Shown with the button rather than gated on the CURRENT reading. The button only
                // appears for someone the monitor has already switched off once, and what happens
                // next is the same for them whether today's reading still says "retire" or has
                // since drifted back to "too close to call" — it looks again in a month either way.
                // Gating it on the reading hid the consequence from exactly the user whose alerts
                // had recovered, leaving them a button with no explanation of what tapping it buys.
                Text("We'll look again in about a month, and switch them off again if they still aren't tracking anything for you.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Empty state

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing logged yet")
                    .font(.headline)
                Text("Log every headache you get — including the mild ones, and the ones that pass in an hour. This log is the only record of what actually happened to you, and it's what would let this feature ever tell you anything. A headache you don't log can't be filled in later.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    editingEntry = nil
                    showLogSheet = true
                } label: {
                    Label("Log a headache", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Rows

    private func entryRow(_ entry: StoredHeadacheEntry) -> some View {
        Button {
            editingEntry = entry
            showLogSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.onset.formatted(
                        .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                        .font(.subheadline.weight(.medium))
                    Text("· \(durationLabel(entry))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    severityBadge(entry)
                }

                let symptoms = entry.symptoms + entry.customSymptoms
                if !symptoms.isEmpty {
                    chipRow(symptoms, tint: Theme.accent)
                }
                if !entry.factors.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Possible triggers")
                            .font(.caption2).foregroundStyle(.tertiary)
                        chipRow(entry.factors, tint: .secondary)
                    }
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes)
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Provenance, so an entry read back from Apple Health is never mistaken for one the
                // user typed here (the store keeps the two apart for the same reason).
                if entry.source == .healthImport {
                    Label("From Apple Health", systemImage: "heart.text.square")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                // That morning's FROZEN score, so the user can audit the correlation between what
                // we said and what actually happened to them. Always the frozen row and never a
                // recomputation: a score recomputed against today's fuller baseline would be
                // retro-fitted to the very label it is meant to be judged against (§3.8).
                frozenLine(for: entry)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit this entry")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(onset: entry.onset)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The frozen index + band for the morning a logged headache belongs to, with the two caveats
    /// that decide whether the pairing means anything at all.
    @ViewBuilder
    private func frozenLine(for entry: StoredHeadacheEntry) -> some View {
        if let day = frozen[Calendar.current.startOfDay(for: entry.onset)] {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let band = day.band {
                        let style = HeadacheSignalCopy.band(band)
                        // Decorative: the band word is in the text beside it, so a second spoken
                        // copy would only be noise. The CHIP (HeadacheBandChip) is the one that
                        // carries the explicit label.
                        Image(systemName: style.glyph)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(style.tint)
                            .accessibilityHidden(true)
                        Text("That morning: index \(day.index) · \(style.label.lowercased())")
                    } else {
                        Text("That morning: index \(day.index)")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)

                if entry.onset <= day.computedAt {
                    // §5.1: a score computed at or after the onset did not predict anything. Saying
                    // so on the row is the difference between an audit and a flattering coincidence.
                    Text("Scored after this had already started, so it isn't evidence either way.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if day.restaged {
                    Text("That night re-staged after the score was frozen, so this day is left out of any accuracy check.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else {
            Text("No score for that morning.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func chipRow(_ tags: [String], tint: Color) -> some View {
        HeadacheChipFlow {
            // Indexed: two tags can be textually identical across the catalog + free-text lists, and
            // `id: \.self` would collapse them into one chip.
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                HeadacheChip(text: tag, tint: tint)
            }
        }
    }

    private func severityBadge(_ entry: StoredHeadacheEntry) -> some View {
        let tint = HeadacheLogSheet.Severity(rawValue: entry.severityRaw)?.tint ?? .secondary
        return Text(entry.severityLabel.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }

    /// Duration, or an explicit "no end logged". Never a substituted zero and never an assumed
    /// length: a missing end means the user didn't record one, which is a different fact from a
    /// short headache.
    private func durationLabel(_ entry: StoredHeadacheEntry) -> String {
        guard let end = entry.end, end > entry.onset else { return "no end logged" }
        let minutes = Int(end.timeIntervalSince(entry.onset) / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: Grouping

    /// Entries grouped into calendar months, newest first. A single linear pass over an
    /// already-sorted, sparse table — no analytics on the render path.
    private var months: [MonthGroup] {
        let cal = Calendar.current
        var groups: [MonthGroup] = []
        for entry in entries {
            let key = cal.date(from: cal.dateComponents([.year, .month], from: entry.onset))
                ?? cal.startOfDay(for: entry.onset)
            if groups.last?.month == key {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(MonthGroup(month: key, entries: [entry]))
            }
        }
        return groups
    }

    private struct MonthGroup: Identifiable {
        let month: Date
        var entries: [StoredHeadacheEntry]
        var id: Date { month }
        var title: String { month.formatted(.dateTime.year().month(.wide)) }
    }

    // MARK: Delete

    /// Remove an entry and the Apple Health sample(s) it wrote, so a deleted headache doesn't leave
    /// an orphan behind in Health. Mirrors the period-delete path in CycleCalendarView.
    private func delete(onset: Date) {
        // Drop the reference to the row BEFORE destroying it: the delete invalidates the model
        // object, and the re-render it triggers would otherwise re-read a deleted instance while
        // rebuilding the sheet (a SwiftData trap, not a graceful nil).
        if editingEntry?.onset == onset { editingEntry = nil }
        let store = LocalStore(modelContext)
        let staleUUIDs = (try? store.deleteHeadacheEntry(onset: onset)) ?? []
        if !staleUUIDs.isEmpty {
            Task { await HealthKitWriter().deleteHeadacheSamples(uuidStrings: staleUUIDs) }
        }
    }
}

// MARK: - Band chip

/// The band chip: shape AND colour, never colour alone — the `CycleCalendarView.dayState` house
/// standard (CycleCalendarView.swift:139-150), so the three states stay distinguishable in
/// greyscale and under a colour-blindness filter. ● typical, ▲ unusual, ◆ very unusual.
///
/// The palette stops deliberately short of alarm-red. At the published ceiling roughly three in
/// four flagged nights are followed by nothing at all, and a red badge would claim an urgency the
/// estimate cannot support.
struct HeadacheBandChip: View {
    let band: HeadacheSignals.Band

    var body: some View {
        let style = HeadacheSignalCopy.band(band)
        return HStack(spacing: 4) {
            Image(systemName: style.glyph)
                .font(.system(size: 9, weight: .bold))
            Text(style.label)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(style.tint.opacity(0.15)))
        .foregroundStyle(style.tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.spoken)
    }
}

// MARK: - Shared copy

/// Everything both signal surfaces say, in ONE place.
///
/// The card and this screen must never disagree about what a night meant, and the same drift hazard
/// `HeadacheDefaults` exists to prevent (a string typed twice, changed once) applies with more force
/// here: these strings are the entire safety story of the feature.
///
/// THE HONESTY CONSTRAINT THAT SHAPES EVERY STRING BELOW. `Contribution` carries a `z`, not the
/// reading it came from, and `z` does not mean the same thing for every feature
/// (HeadacheSignals.swift:332-405):
///   · the five series features carry an UNSIGNED, MAD-scaled z — `|today − median| /
///     max(1.4826·MAD, noiseFloor)`, clamped to ±4. Neither the reading nor the median is in the
///     `Assessment`, so the only statement in real units that is guaranteed true is a LOWER BOUND:
///     the divisor is at least the feature's noise floor, so `|today − median| ≥ |z| × noiseFloor`
///     (and the clamp only ever makes the bound safer). Hence "at least 12 bpm from your usual" —
///     never "12 bpm above", because the sign is discarded on purpose (§3.2: the pre-attack
///     direction inverts between people) and the true gap may be larger.
///   · `.scheduleShift` carries `deltaMinutes / 30`, so the same arithmetic yields the EXACT shift.
///   · `.skinTempDeviation` carries the canonical SIGNED offset in °C — a real value as it stands.
///   · `.arousalLetdown` is already a difference of two z scores and has no natural unit.
///   · `.perimenstrual` is binary.
/// Nothing here fills a gap with a plausible number. Where the value isn't knowable from what the
/// Kit returns, the copy says what IS knowable and stops.
enum HeadacheSignalCopy {
    typealias Feature = HeadacheSignals.Feature
    typealias Contribution = HeadacheSignals.Contribution
    typealias AbsentReason = HeadacheSignals.AbsentReason
    typealias Band = HeadacheSignals.Band
    typealias Verdict = HeadacheSignals.Verdict

    /// The eight RING-derived features — the denominator of every coverage line. Derived, not
    /// typed as "8", so adding a feature can't leave a stale number in the copy.
    static let ringFeatureTotal = Feature.allCases.filter(\.isRingDerived).count

    // MARK: Naming

    static func name(_ feature: Feature) -> String {
        switch feature {
        case .sleepEfficiencyDrop:    return "Sleep efficiency"
        case .arousalLetdown:         return "Daytime heart rate"
        case .hrvDeviation:           return "Overnight HRV"
        case .restingHRDeviation:     return "Resting heart rate"
        case .sleepFragmentation:     return "Time awake in bed"
        case .sleepDurationDeviation: return "Time asleep"
        case .scheduleShift:          return "Bedtime"
        case .skinTempDeviation:      return "Skin temperature"
        case .perimenstrual:          return "Cycle phase"
        }
    }

    /// Mid-sentence form. Only HRV needs a special case — lowercasing an initialism reads as a typo.
    static func inlineName(_ feature: Feature) -> String {
        feature == .hrvDeviation ? "overnight HRV" : name(feature).lowercased()
    }

    // MARK: Verdict headlines

    /// Headline + supporting line for a verdict. Shared so the card and the detail screen cannot
    /// drift into saying different things about the same night.
    static func headline(_ verdict: Verdict) -> (title: String, detail: String?) {
        switch verdict {
        case .notEnabled:
            // Never rendered — visibility is the caller's job on both surfaces.
            return ("Not assessed", nil)

        case .buildingBaseline(let daysRemaining):
            guard daysRemaining > 0 else {
                return ("Learning your normal",
                        "A few more nights of overnight wear before anything is scored.")
            }
            return ("Learning your normal — \(daysRemaining) more night\(daysRemaining == 1 ? "" : "s")",
                    "Nothing is scored until then.")

        case .interrupted(let since):
            guard let since else {
                return ("No ring data for over 24 hours", "Last night wasn't assessed.")
            }
            return ("No ring data for over 24 hours",
                    "Last reading \(since.formatted(.relative(presentation: .named))). Last night wasn't assessed.")

        case .insufficientData(let missing):
            return ("Not enough was measured last night", missingPhrase(missing))

        case .scored(let assessment):
            return headline(recordedBand: displayBand(assessment))
        }
    }

    /// Headline for a band we already hold — the FROZEN row's, which is the number of record and
    /// what the dashboard card shows once a day is frozen (`HeadacheCardView.recordedBand`).
    ///
    /// Deliberately the SAME function the `.scored` branch above returns through, so a recorded
    /// band and a live one can never be described in different words.
    static func headline(recordedBand band: Band) -> (title: String, detail: String?) {
        band == .typical
            ? ("Nothing unusual for you last night", nil)
            : ("Last night was unusual for you", nil)
    }

    /// Names the missing inputs in WORDS — never a count, never a score.
    ///
    /// Phrased by REASON rather than by name, because they are different facts: "no overnight HRV
    /// last night" is simply untrue when the reading is there and it is the BASELINE that is still
    /// short. Missing readings are reported first — the common case, and the only one the user can
    /// act on. Cycle phase is excluded throughout: it is context rather than a measurement, and
    /// "no cycle phase" reads as a fault when it is merely not applicable.
    ///
    /// Each clause carries its OWN timeframe rather than the sentence appending one blanket "last
    /// night" to every name. `.arousalLetdown` is a DAYTIME term over yesterday and the day before
    /// (HeadacheSignals.swift:389-397), so the shared suffix reported a missing NIGHTLY reading for
    /// the one signal that never looks at the night. Two nightly features still merge into the
    /// compact single-timeframe sentence they always had; only a mixed pair spells both out.
    static func missingPhrase(_ missing: [Feature: AbsentReason]) -> String? {
        /// The (at most two) heaviest ring features missing for one of `reasons`.
        func features(_ reasons: Set<AbsentReason>) -> [Feature] {
            Array(missing
                .filter { $0.key.isRingDerived && reasons.contains($0.value) }
                .keys
                .sorted {
                    // Heaviest missing input first; rawValue breaks ties so the sentence is stable
                    // across renders (dictionary key order is not, and `sorted` is not stable).
                    $0.weight != $1.weight ? $0.weight > $1.weight : $0.rawValue < $1.rawValue
                }
                .prefix(2))
        }
        /// Sentence-case + full stop over clauses that each already carry their own timeframe.
        func sentence(_ clauses: [String]) -> String? {
            guard let first = clauses.first else { return nil }
            let body = clauses.count > 1 ? "\(first), and \(clauses[1])" : first
            return "\(body.prefix(1).uppercased())\(body.dropFirst())."
        }
        func orList(_ named: [String]) -> String {
            named.count > 1 ? "\(named[0]) or \(named[1])" : (named.first ?? "")
        }

        let unread = features([.noDataThisDay, .lowCoverage])
        if !unread.isEmpty {
            return unread.contains(.arousalLetdown)
                ? sentence(unread.map(unreadClause))
                : "No \(orList(unread.map(inlineName))) last night."
        }
        let unlearned = features([.noBaseline])
        if !unlearned.isEmpty {
            return unlearned.contains(.arousalLetdown)
                ? sentence(unlearned.map(unlearnedClause))
                : "Not enough nights yet to know your usual \(orList(unlearned.map(inlineName)))."
        }
        let off = features([.featureDisabled])
        if !off.isEmpty {
            return "Turned off in Settings: \(orList(off.map(inlineName)))."
        }
        return nil
    }

    /// "no <input> <when>" — one missing READING, with the timeframe that input is actually taken
    /// over. Lowercase and unterminated so `missingPhrase` can join two of them.
    private static func unreadClause(_ feature: Feature) -> String {
        // Named in full here — unlike `absence`, this sentence stands alone with no feature name
        // above it, so "no daytime readings" would leave the reader asking "of what?".
        feature == .arousalLetdown
            ? "no daytime heart rate readings yesterday or the day before"
            : "no \(inlineName(feature)) last night"
    }

    /// The same, for an input that IS being read but has no baseline behind it yet.
    private static func unlearnedClause(_ feature: Feature) -> String {
        feature == .arousalLetdown
            ? "not enough days yet to know your usual daytime heart rate"
            : "not enough nights yet to know your usual \(inlineName(feature))"
    }

    // MARK: Bands

    /// The band a surface is willing to SHOW.
    ///
    /// Banding is a per-user percentile BUDGET over the trailing frozen indices, not a fixed
    /// threshold (HeadacheSignals.swift:455-476). On a very stable person whose prior indices are
    /// mostly 0, an index of 0 can still sit at or above the 75th percentile — `.elevated` on a
    /// night where literally nothing stood out. "Last night was unusual for you" would then be
    /// false, so a band with no contributing signal is presented as `.typical`.
    static func displayBand(_ assessment: HeadacheSignals.Assessment) -> Band {
        drivers(assessment.contributions).isEmpty ? .typical : assessment.band
    }

    static func band(_ band: Band) -> (glyph: String, label: String, tint: Color, spoken: String) {
        switch band {
        case .typical:  return ("circle.fill",   "Typical",      .secondary,   "Typical for you")
        case .elevated: return ("triangle.fill", "Unusual",      Theme.accent, "Unusual for you")
        case .flagged:  return ("diamond.fill",  "Very unusual", Theme.temp,   "Very unusual for you")
        }
    }

    // MARK: Contributions

    /// A term's real share of the weighted sum — `effectiveWeight × contribution`, not the raw z,
    /// so a large deviation on a deliberately down-weighted feature can't masquerade as the
    /// headline reason.
    static func influence(_ contribution: Contribution) -> Double {
        contribution.effectiveWeight * (contribution.contribution ?? 0)
    }

    /// The features that actually MOVED the index, most influential first. Features that were
    /// measured but sat below the ramp's onset are excluded: they contributed exactly nothing, and
    /// listing one as a reason would invent a cause.
    static func drivers(_ contributions: [Contribution]) -> [Contribution] {
        contributions
            .filter { ($0.contribution ?? 0) > 0 }
            .sorted {
                let a = influence($0), b = influence($1)
                return a != b ? a > b : $0.feature.rawValue < $1.feature.rawValue
            }
    }

    /// This feature's share of the index that was actually produced: `wᵢ·cᵢ / Σ wⱼ·cⱼ`. Exact, so
    /// the detail screen can be reconciled against the index it shows.
    static func indexShare(_ contribution: Contribution, in all: [Contribution]) -> Double? {
        guard contribution.contribution != nil else { return nil }
        let total = all.reduce(0.0) { $0 + influence($1) }
        guard total > 0 else { return nil }
        return influence(contribution) / total
    }

    /// What a feature read last night, in the user's own units, using only what the Kit returns.
    /// See this enum's header for why five of the nine can only be stated as a lower bound.
    ///
    /// Returned as a lowercase fragment with no full stop, matching the house style for secondary
    /// lines ("no end logged", "estimate only"), so the same string works standalone under a
    /// feature name and inline after one ("Resting heart rate — at least 12 bpm from your usual").
    static func deviation(_ contribution: Contribution, tempUnit: TemperatureUnit) -> String? {
        guard let z = contribution.z else { return nil }
        switch contribution.feature {
        case .restingHRDeviation:
            return boundPhrase(z, contribution.feature, unit: "bpm")
        case .hrvDeviation:
            return boundPhrase(z, contribution.feature, unit: "ms")
        case .sleepEfficiencyDrop:
            return boundPhrase(z, contribution.feature, unit: "percentage points")

        case .sleepFragmentation:
            let m = boundMinutes(z, contribution.feature)
            return m == 0 ? "in line with your usual time awake in bed"
                          : "at least \(minutes(m)) from your usual time awake in bed"
        case .sleepDurationDeviation:
            let m = boundMinutes(z, contribution.feature)
            return m == 0 ? "in line with your usual night"
                          : "at least \(minutes(m)) from your usual night"

        case .scheduleShift:
            // EXACT, not a bound: this z is literally `deltaMinutes / noiseFloor`
            // (HeadacheSignals.swift:371-380), and the delta is circular, so a 23:50-vs-00:10
            // sleeper reads as regular rather than maximally irregular.
            let m = boundMinutes(z, contribution.feature)
            return m == 0 ? "on your usual schedule"
                          : "\(minutes(m)) from your usual bedtime, earlier or later"

        case .skinTempDeviation:
            // The canonical signed offset — the only feature whose actual reading survives into the
            // assessment, so it is the only one allowed to state a direction. Formatted through the
            // shared delta formatter, which scales by 9/5 with NO +32 (#83): an absolute conversion
            // would render a +0.5 °C offset as +32.9 °F.
            return "\(UnitsFormatter.temperatureDelta(z, unit: tempUnit)) against your baseline"

        case .arousalLetdown:
            guard z > 0 else { return "no fall from the day before yesterday" }
            return String(format: "fell %.1f× your usual day-to-day spread, from the day before yesterday to yesterday", z)

        case .perimenstrual:
            return z > 0 ? "in the days around your period" : "outside the days around your period"
        }
    }

    /// Why a feature isn't there, in plain words. A missing input is ABSENT with a reason — never a
    /// substituted zero, and never a silence the reader could mistake for a normal reading.
    static func absence(_ reason: AbsentReason, feature: Feature) -> String {
        // `.arousalLetdown` is the one DAYTIME term: it compares yesterday's WAKING heart rate with
        // the day before's, over a baseline of earlier waking days (HeadacheSignals.swift:389-397).
        // Every timeframe word it uses therefore has to name those days — the generic wording below
        // told the user there was "no reading last night" for a signal that never looks at a night,
        // which is not a vaguer statement but a false one.
        if feature == .arousalLetdown { return daytimeAbsence(reason) }
        switch reason {
        case .noBaseline:
            return feature == .scheduleShift
                ? "not enough nights yet to know your usual bedtime"
                : "not enough nights yet to know your normal"
        case .noDataThisDay:
            return "no reading last night"
        case .featureDisabled:
            return "turned off in Settings"
        case .lowCoverage:
            return "too little of the night was measured"
        case .notApplicable:
            // `isPerimenstrual` is nil when cycle tracking is off OR too few periods are logged to
            // know (HeadacheSignals.swift:213) — both, because we can't tell them apart here.
            return feature == .perimenstrual
                ? "cycle tracking is off, or too few periods are logged to know"
                : "doesn't apply to last night"
        }
    }

    /// `absence` for the daytime let-down term. A full switch of its own rather than a special case
    /// per reason, so no future reason can inherit a nightly timeframe by default.
    private static func daytimeAbsence(_ reason: AbsentReason) -> String {
        switch reason {
        case .noDataThisDay:   return "no daytime readings yesterday or the day before"
        case .noBaseline:      return "not enough days yet to know your usual daytime heart rate"
        case .lowCoverage:     return "too little of those two days was measured"
        case .featureDisabled: return "turned off in Settings"
        case .notApplicable:   return "doesn't apply to those days"
        }
    }

    /// "at least N <unit> from your usual" — a guaranteed-true floor, because the z divisor is at
    /// least the noise floor. Says nothing numeric when the bound rounds to zero rather than
    /// printing "at least 0".
    private static func boundPhrase(_ z: Double, _ feature: Feature, unit: String) -> String {
        let bound = Int((abs(z) * feature.noiseFloor).rounded())
        return bound == 0 ? "in line with your usual" : "at least \(bound) \(unit) from your usual"
    }

    private static func boundMinutes(_ z: Double, _ feature: Feature) -> Int {
        Int((abs(z) * feature.noiseFloor).rounded())
    }

    static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

// MARK: - Quality-monitor copy

/// Every string the "Is this working for you?" panel says, in one place and free of SwiftUI, so the
/// wording can be read (and argued with) without reading a view hierarchy.
///
/// THE VOCABULARY RULE. Nothing here may use the words the statistics are written in. No "AUC", no
/// "p-value", no "confidence interval", no "precision", no "base rate", no "lift" — the reader did
/// not opt into a statistics course, and a term they cannot check is indistinguishable from a term
/// we made up. Every quantity is either restated as the thing it literally counts ("of the 22
/// mornings it flagged, 6 were followed by a headache") or left out.
///
/// THE p-VALUE IS DELIBERATELY NEVER SHOWN. There is no short plain-language rendering of it that
/// is also true — every honest one is a paragraph — and a p-value printed as a decimal is the
/// clearest example there is of a number that decorates rather than informs.
///
/// AND THE ONE THAT MATTERS MOST: nothing here may be phrased as a forecast. The panel reports what
/// HAS happened on this user's own logged days. It never says a headache is coming, never attaches a
/// likelihood to tomorrow, and never converts a measured difference into a prediction.
enum HeadacheMonitorCopy {
    typealias Metrics = HeadacheEvaluation.Metrics
    typealias Status = HeadacheEvaluation.Status

    static func isRetired(_ status: Status) -> Bool {
        if case .retired = status { return true }
        return false
    }

    // MARK: Headline

    /// Title plus supporting lines for the current status. The four branches are four genuinely
    /// different situations and share no wording by accident.
    static func headline(_ report: HeadacheMonitorReport,
                         alertsLive: Bool) -> (title: String, lines: [String]) {
        let tuning = HeadacheEvaluation.Tuning()
        let window = windowPhrase(report)

        switch report.status {
        case .building(let daysRemaining):
            // Stated as progress, never as a lack. Nothing has been checked yet because there is
            // nothing checkable yet, which is a fact about the calendar rather than about the user.
            let scored = max(0, report.daysNeeded - daysRemaining)
            return ("Still learning — \(scored) of \(report.daysNeeded) nights scored.",
                    ["With fewer than \(report.daysNeeded) scored nights there is no usual to compare a night against, so nothing here has been measured yet. Wearing the ring overnight is all it needs."])

        case .monitoring(let m):
            var lines: [String] = []
            let title: String
            if m.labelledDays < tuning.minPositivesForWorking {
                // NOT "not enough headaches logged". The gate is `labelledDays` — scored mornings a
                // logged headache could be paired with — and the two part company for exactly the
                // user the exclusions list below is written for: someone who imported years of
                // Apple Health entries, or logged before switching this on, has logged plenty and
                // still has almost none that LANDED anywhere. Telling them they haven't logged
                // enough is false, and it asks them to fix something that is already done.
                title = "Not enough of your headaches have landed on a scored morning to tell yet."
                lines.append("\(m.labelledDays) of your logged headaches landed on a morning this check could use. It needs at least \(tuning.minPositivesForWorking) before it can conclude anything either way, and usually a good deal more.")
            } else if m.scoredDays < tuning.minScoredDaysForWorking {
                title = "Not enough scored days yet to tell whether this is meaningful for you."
                lines.append("\(m.scoredDays) days scored of the \(tuning.minScoredDaysForWorking) this check needs, with \(count(m.labelledDays, "headache", "headaches")) among them.")
            } else {
                title = "Measured, and still too close to call."
                lines.append(contentsOf: [comparisonLine(m, window: window),
                                          rankingLine(m)].compactMap { $0 })
            }
            // The line that stops the whole panel reading as a fault report. §1.1's own arithmetic:
            // at the realistic operating point a detector that genuinely works still cannot clear
            // the bar inside a year for most people. Staying here is the expected outcome.
            lines.append("This is the ordinary place to be, not a fault. For most people a year does not contain enough headaches to settle the question in either direction.")
            return (title, lines)

        case .working(let m):
            var lines = [comparisonLine(m, window: window), rankingLine(m)].compactMap { $0 }
            // Attached to the good news, not tucked into a footer. A user who has just read that
            // flagged mornings beat their normal rate is precisely the user about to over-read it.
            lines.append("That is a measured difference, not a forecast. Most of the mornings it flags are still followed by nothing at all.")
            return ("On the mornings this flagged, a headache followed more often than usual.", lines)

        case .retired(let m, let reason):
            let title = alertsLive
                ? "Switched off once — and back on because you asked for it."
                : "Morning alerts are off."
            var lines = [retirementLine(m, reason: reason, window: window)]
            // Said plainly and immediately. The feature being switched off must not leave any doubt
            // that the user's own entries survived it — that log is the most irreplaceable data in
            // the app, and a person who suspects it was cleared will stop logging.
            lines.append("Your headache log is untouched. Every entry is still here, and last night's signals are still measured and shown above — only the notification stopped.")
            return (title, lines)
        }
    }

    // MARK: Numbers, in words

    /// "It flagged N mornings … M were followed by a headache — X %. Across all its scored days, Y %."
    ///
    /// The user's OWN rate is always in the same sentence as ours. A flagged-morning percentage on
    /// its own is unreadable: 27 % sounds poor next to nothing and is excellent next to 13 %.
    static func comparisonLine(_ m: Metrics, window: String) -> String? {
        guard let precision = m.precision, let base = m.baseRate, m.flaggedDays > 0 else { return nil }
        return "It flagged \(count(m.flaggedDays, "morning", "mornings")) in \(window). \(m.truePositives) of those were followed by a headache within a day — \(pct(precision)). Across all \(count(m.scoredDays, "day", "days")) it scored, \(pct(base)) were."
    }

    /// The AUC and its 95 % interval, stated as the thing they literally measure.
    ///
    /// This IS the confidence interval, in plain language: the point estimate is the head-to-head
    /// rate, and the interval is the range the data actually supports for it. Written as "AUC 0.71
    /// (95 % CI 0.55–0.87)" it would be unreadable to almost everyone and would read as authority
    /// rather than as uncertainty — which is the opposite of what an interval is for.
    static func rankingLine(_ m: Metrics) -> String? {
        guard let auc = m.auc, let low = m.aucCILow, let high = m.aucCIHigh else { return nil }
        return "Put two of your mornings side by side — one that was followed by a headache, one that wasn't. This scored the headache morning higher \(pct(auc)) of the time, and your data narrows that to somewhere between \(pct(low)) and \(pct(high)). A coin toss would be 50%."
    }

    /// Why the notification was withdrawn — the measured finding, in the user's own numbers.
    static func retirementLine(_ m: Metrics,
                               reason: HeadacheEvaluation.Reason,
                               window: String) -> String {
        switch reason {
        case .noBetterThanChance:
            let measured = m.auc.map { " It put a headache morning above an ordinary one \(pct($0)) of the time, where a coin toss is 50%." } ?? ""
            return "Over \(window), this did no better than chance at telling your headache mornings apart from your ordinary ones, so OpenCircuit stopped sending the alert.\(measured)"
        case .noUsefulPrecisionGain:
            guard let precision = m.precision, let base = m.baseRate else {
                return "Over \(window), the mornings this flagged were followed by a headache no more often than any other morning, so OpenCircuit stopped sending the alert."
            }
            return "Over \(window), the mornings this flagged were followed by a headache about as often as any other morning — \(pct(precision)) against \(pct(base)) — so OpenCircuit stopped sending the alert."
        }
    }

    // MARK: Exclusions

    /// "You logged N … K of them landed on a morning this check could use."
    static func usableLine(_ report: HeadacheMonitorReport, _ m: Metrics) -> String {
        let window = windowPhrase(report)
        guard report.loggedHeadaches > 0 else { return "No headaches logged in \(window)." }
        return "You logged \(count(report.loggedHeadaches, "headache", "headaches")) in \(window). \(m.labelledDays) landed on a morning this check could use."
    }

    /// Every reason a day or a label was left out, itemised, non-zero terms only.
    ///
    /// TWO DIFFERENT CATEGORIES, AND THE UNITS DIFFER TOO. The first line counts LOGGED HEADACHES
    /// that never had a score to be paired with; every line after it counts MORNINGS that WERE
    /// scored and then could not be used. The wording says which is which — they are different
    /// quantities and printing them as if they subtracted from one another would be an arithmetic
    /// the reader could not reproduce.
    ///
    /// That first line must not be worded as a ring failure. Its largest population is a headache
    /// that predates any score at all: an entry from before this feature was switched on, or one
    /// imported from Apple Health with years of history behind it. Telling that user the ring
    /// wasn't worn is simply untrue, and it is the kind of untrue that makes a person distrust the
    /// device rather than the sentence. (It also, more rarely, catches a second headache on a day
    /// whose one score was already paired with the first — still "no score to pair with", still not
    /// the ring's doing.)
    static func exclusions(_ report: HeadacheMonitorReport, _ m: Metrics) -> [String] {
        var out: [String] = []
        // Never scored — outside what the check can see, rather than something it rejected.
        if report.labelsWithNoScore > 0 {
            out.append("\(count(report.labelsWithNoScore, "headache", "headaches")) fell on a day OpenCircuit hadn't scored — from before you turned this on, imported from Apple Health, or a night the ring wasn't worn or hadn't synced.")
        }
        // Scored, then set aside for a stated reason. Each says "scored" out loud so the reader can
        // tell this group from the one above it.
        if m.excludedInProgress > 0 {
            out.append("\(count(m.excludedInProgress, "morning was", "mornings were")) scored while a headache was already under way. Those can't count either way — we didn't predict something that had already started.")
        }
        if m.excludedRestaged > 0 {
            out.append("\(count(m.excludedRestaged, "morning", "mornings")) had the night re-staged after the score was frozen, so the score no longer describes the night that was kept.")
        }
        if m.excludedUnresolved > 0 {
            out.append("\(count(m.excludedUnresolved, "scored morning is", "scored mornings are")) still too recent — the day after them isn't over yet.")
        }
        if report.rowsWithUnknownBand > 0 {
            out.append("\(count(report.rowsWithUnknownBand, "score was", "scores were")) written by a newer version of OpenCircuit and can't be read by this one.")
        }
        return out
    }

    // MARK: Cadence and state

    /// How many times the check has been run, and when it last was.
    static func lookLine(_ report: HeadacheMonitorReport) -> String? {
        guard report.lookCount > 0 else { return nil }
        let times = report.lookCount == 1 ? "once" : "\(report.lookCount) times"
        guard let at = report.lastDecisionAt else { return "Checked \(times)." }
        return "Checked \(times), most recently on \(at.formatted(.dateTime.day().month(.wide)))."
    }

    /// Whether the morning notification is live, and — only when we can honestly say so — why not.
    ///
    /// The "never live yet" branch exists because the notification switches on when a band becomes
    /// possible at all, which is measured over the trailing banding window, while the panel's status
    /// is measured over the evaluation year. A user with a scattered year can therefore be told
    /// "still too early to tell" while alerts have not started; without this line that pair of
    /// statements is simply baffling.
    ///
    /// Note what the last branch does NOT say, and why that matters. `retired` is the check's
    /// CURRENT reading, which is not the same fact as why the alerts are off right now: a user the
    /// monitor withdrew months ago whose trailing year has since drifted back over the retirement
    /// bar reads as `.monitoring` while still being switched off. An earlier draft told exactly that
    /// user "this check isn't the reason — it has found nothing against them", which was false for
    /// the one person it was aimed at. Nothing in the stored state can support an attribution here
    /// (a future settings toggle would be another route to off), so none is claimed at all: the
    /// finding is stated in the headline above and this line reports only the state and the remedy.
    static func alertStateLine(_ report: HeadacheMonitorReport,
                               alertsLive: Bool,
                               everLive: Bool,
                               retired: Bool) -> String {
        if alertsLive {
            return retired ? "Morning alerts are on because you turned them back on."
                           : "Morning alerts are on."
        }
        if !everLive {
            return "Morning alerts haven't started yet. They begin once \(report.daysNeeded) nights have been scored inside the last \(HeadacheSignals.Tuning().bandWindowDays) days — that is the point at which an unusual night can be told apart from an ordinary one at all."
        }
        return "Morning alerts are off. You can turn them back on below."
    }

    // MARK: Formatting

    /// Whole percent. Rounded once, here, so the same fraction never renders two ways on one screen.
    /// Unspaced, matching the percentages already shipped on this screen (`coverageRow`,
    /// `featureRow`) — two spacings of the same unit on one screen reads as two different units.
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    /// The evaluation window in words. Kept in step with the Kit's own value rather than hardcoded,
    /// so a retuned window can't leave the copy quoting a horizon nobody measures over any more.
    static func windowPhrase(_ report: HeadacheMonitorReport) -> String {
        report.windowDays == 365 ? "the last year" : "the last \(report.windowDays) days"
    }
}
