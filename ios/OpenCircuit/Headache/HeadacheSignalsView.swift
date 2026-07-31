import SwiftUI
import SwiftData

// Headache history — the detail screen behind the dashboard's headache card.
//
// PHASE 1 IS THE LOG AND ONLY THE LOG. The user's entries are the ground-truth LABEL series; a
// later phase's detector can only ever be validated against them, and a label that was never
// logged cannot be recovered afterwards. So this screen's whole job is to make the history
// visible, correctable and complete — every affordance here is about getting entries IN and
// keeping them accurate.
//
// Nothing on this screen predicts, forecasts or detects anything, and there is no placeholder for
// something that would: see the `// Phase 2:` marker below.

struct HeadacheSignalsView: View {
    @Environment(\.modelContext) private var modelContext

    /// The whole log, newest first. Unbounded on purpose — this IS the history screen, and the
    /// table is user-entered and sparse (a heavy sufferer logs a few hundred rows a year).
    @Query(sort: \StoredHeadacheEntry.onset, order: .reverse)
    private var entries: [StoredHeadacheEntry]

    @State private var showLogSheet = false
    @State private var editingEntry: StoredHeadacheEntry? = nil

    var body: some View {
        List {
            // Phase 2: the overnight-signals section goes here, above the history.
            // Nothing stands in for it today: there is no index, band or chart yet, and a
            // greyed-out gauge or a "coming soon" placeholder would advertise a capability this
            // app does not have.

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
