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
