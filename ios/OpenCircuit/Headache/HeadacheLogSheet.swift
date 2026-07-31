import SwiftUI

// Headache logging sheet — Phase 1 of the headache-signals feature.
//
// Modelled on `PeriodLogSheet` (CycleCalendarView.swift, #78), the house pattern for user-entered
// data that mirrors into Apple Health: NavigationStack + Form + cancellation/confirmation toolbar
// actions + inline save-error text.
//
// Everything logged here is the user stating a fact about themselves. Phase 1 has no detector, no
// score and no prediction, so nothing in this file infers, forecasts or explains a headache — it
// only records one. The resulting rows are the ground-truth LABEL series any later detector can be
// validated against, which is why the sheet leans on completeness (mild headaches count) rather
// than on clever inference.

// MARK: - Tag catalogs

/// 🟡 The symptom tags the sheet offers.
///
/// INFORMED BY the RingConn APK's i18n keys — the official app logs a comparable symptom set — but
/// the key-to-English pairing CANNOT be proven mechanically: the Dart snapshot's string pool is
/// hash-ordered, so adjacency between a key and a nearby literal is meaningless. These are
/// therefore our own user-facing labels, chosen to be the ones a person can answer without a
/// clinician, and they make NO protocol claim: nothing here is decoded from, or written to, the
/// ring.
enum HeadacheSymptom: String, CaseIterable, Identifiable {
    case throbbing        = "Throbbing"
    case oneSided         = "One-sided"
    case lightSensitivity = "Light sensitivity"
    case soundSensitivity = "Sound sensitivity"
    case nausea           = "Nausea"
    case aura             = "Aura"
    case neckStiffness    = "Neck stiffness"
    var id: String { rawValue }
}

/// 🟡 The possible-trigger tags the sheet offers. Same provenance and same caveat as
/// `HeadacheSymptom`: informed by the RingConn APK's i18n keys, unprovable pairing (hash-ordered
/// Dart string pool), user-facing labels only, no protocol claim.
///
/// "Possible" is load-bearing in the UI copy: these are the user's own hunches about their day, not
/// causes this app has established. Phase 1 does nothing with them beyond storing them.
enum HeadacheTrigger: String, CaseIterable, Identifiable {
    case poorSleep    = "Poor sleep"
    case stress       = "Stress"
    case skippedMeal  = "Skipped meal"
    case dehydration  = "Dehydration"
    case alcohol      = "Alcohol"
    case caffeine     = "Caffeine"
    case screenTime   = "Screen time"
    case menstrual    = "Menstrual"
    case weather      = "Weather"
    var id: String { rawValue }
}

// MARK: - Log sheet

struct HeadacheLogSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Existing entry being edited, nil for a new entry.
    let editing: StoredHeadacheEntry?
    /// Called on save with the user's input. Throws propagate to the inline error row.
    let onSave: (Draft) throws -> Void
    /// Called when the user deletes the entry being edited, with its onset (the store key). The
    /// CALLER runs `LocalStore.deleteHeadacheEntry`, which hands back the stale HealthKit sample
    /// UUIDs, and passes those to `HealthKitWriter.deleteHeadacheSamples` — that way this sheet
    /// never touches HealthKit. nil = no delete affordance (a new entry has nothing to delete).
    let onDelete: ((Date) -> Void)?

    @State private var onsetDate: Date
    @State private var hasEnd: Bool
    @State private var endDate: Date
    @State private var severity: Severity
    @State private var selectedSymptoms: Set<HeadacheSymptom>
    @State private var customSymptoms: [String]
    @State private var customEntry: String = ""
    @State private var selectedTriggers: Set<HeadacheTrigger>
    @State private var notes: String
    @State private var saveError: String? = nil

    /// Free-text symptom tags are capped so one row can't grow unbounded — they are labels, not a
    /// journal (that's what Notes is for).
    private static let maxCustomSymptoms = 12
    private static let maxCustomSymptomLength = 40

    init(editing: StoredHeadacheEntry?,
         onDelete: ((Date) -> Void)? = nil,
         onSave: @escaping (Draft) throws -> Void) {
        self.editing = editing
        self.onDelete = onDelete
        self.onSave = onSave

        let onset = editing?.onset ?? Date()
        let end = editing?.end
        _onsetDate = State(initialValue: onset)
        _hasEnd = State(initialValue: end != nil)
        // When the user flips "it has ended" on, the picker opens on NOW (or the onset, if the
        // onset is in the future of it) — never on `onset + some plausible offset`. An offset
        // default would put a duration the user never stated in front of them, pre-confirmed; a
        // wrong "now" is at least visible and correctable.
        _endDate = State(initialValue: end ?? max(onset, Date()))
        _severity = State(initialValue: Severity(rawValue: editing?.severityRaw ?? 0) ?? .unspecified)
        _selectedSymptoms = State(initialValue: Set(
            (editing?.symptoms ?? []).compactMap { HeadacheSymptom(rawValue: $0) }
        ))
        _customSymptoms = State(initialValue: editing?.customSymptoms ?? [])
        _selectedTriggers = State(initialValue: Set(
            (editing?.factors ?? []).compactMap { HeadacheTrigger(rawValue: $0) }
        ))
        _notes = State(initialValue: editing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Started", selection: $onsetDate,
                               displayedComponents: [.date, .hourAndMinute])
                    Toggle("It has ended", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Ended", selection: $endDate,
                                   in: onsetDate...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section {
                    Picker("Severity", selection: $severity) {
                        ForEach(Severity.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Severity")
                } footer: {
                    Text("“Unspecified” is a real answer — leave it there if you'd rather not rate it.")
                }

                Section("Symptoms") {
                    ForEach(HeadacheSymptom.allCases) { sym in
                        Toggle(sym.rawValue, isOn: Binding(
                            get: { selectedSymptoms.contains(sym) },
                            set: { on in
                                if on { selectedSymptoms.insert(sym) }
                                else  { selectedSymptoms.remove(sym) }
                            }
                        ))
                    }
                    if !customSymptoms.isEmpty {
                        HeadacheChipFlow {
                            ForEach(customSymptoms, id: \.self) { tag in
                                Button {
                                    customSymptoms.removeAll { $0 == tag }
                                } label: {
                                    HeadacheChip(text: tag, systemImage: "xmark.circle.fill",
                                                 tint: Theme.accent)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove symptom \(tag)")
                            }
                        }
                    }
                    if customSymptoms.count < Self.maxCustomSymptoms {
                        HStack {
                            TextField("Add your own", text: $customEntry)
                                .submitLabel(.done)
                                .onSubmit { addCustomSymptom() }
                            Button("Add") { addCustomSymptom() }
                                .buttonStyle(.borderless)
                                .disabled(trimmedCustomEntry.isEmpty)
                        }
                    }
                }

                Section {
                    ForEach(HeadacheTrigger.allCases) { trigger in
                        Toggle(trigger.rawValue, isOn: Binding(
                            get: { selectedTriggers.contains(trigger) },
                            set: { on in
                                if on { selectedTriggers.insert(trigger) }
                                else  { selectedTriggers.remove(trigger) }
                            }
                        ))
                    }
                } header: {
                    Text("Possible triggers")
                } footer: {
                    Text("Your own hunches about the day. OpenCircuit doesn't check them against anything.")
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(3...)
                }

                if let err = saveError {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }

                if let editing, let onDelete {
                    Section {
                        Button("Delete this entry", role: .destructive) {
                            onDelete(editing.onset)
                            dismiss()
                        }
                    } footer: {
                        Text("Also removes it from Apple Health, if it was written there.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "Log Headache" : "Edit Headache")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    // MARK: Custom symptom tags

    private var trimmedCustomEntry: String {
        customEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Add the typed tag, ignoring blanks and case-insensitive duplicates of either an already-added
    /// tag or a catalog symptom (a "Nausea" typed by hand must not sit next to the toggled one).
    private func addCustomSymptom() {
        let tag = String(trimmedCustomEntry.prefix(Self.maxCustomSymptomLength))
        guard !tag.isEmpty, customSymptoms.count < Self.maxCustomSymptoms else { return }
        let existing = customSymptoms.map { $0.lowercased() }
            + HeadacheSymptom.allCases.map { $0.rawValue.lowercased() }
        guard !existing.contains(tag.lowercased()) else {
            customEntry = ""
            return
        }
        customSymptoms.append(tag)
        customEntry = ""
    }

    // MARK: Save

    private func save() {
        let end = hasEnd ? endDate : nil
        // A headache that hasn't happened yet isn't a label, it's a guess — and the whole point of
        // this log is that every row is something the user actually experienced.
        if onsetDate > Date() {
            saveError = "That time hasn’t happened yet."
            return
        }
        if let end, end < onsetDate {
            saveError = "The end time is before the start."
            return
        }
        do {
            try onSave(Draft(
                onset: onsetDate,
                end: end,
                severityRaw: severity.rawValue,
                // Catalog order, NOT `Set` iteration order: `saveHeadacheEntry` treats a changed
                // `symptoms` array as a CLINICAL change and resets the Apple Health watermark, so an
                // unstable order would make every re-save look like an edit and churn a
                // delete-then-rewrite through the user's Health store.
                symptoms: HeadacheSymptom.allCases.filter { selectedSymptoms.contains($0) }
                    .map(\.rawValue),
                customSymptoms: customSymptoms,
                factors: HeadacheTrigger.allCases.filter { selectedTriggers.contains($0) }
                    .map(\.rawValue),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                // The onset the sheet opened on, so moving it RELOCATES the row instead of leaving
                // the original behind as a duplicate (`saveHeadacheEntry(originalOnset:)`).
                originalOnset: editing?.onset))
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension HeadacheLogSheet {

    /// One sheet's worth of input, handed to the caller on save. A struct rather than eight
    /// positional closure arguments so two same-typed fields can't be silently swapped at a call
    /// site — the field names are the contract.
    struct Draft {
        var onset: Date
        var end: Date?
        var severityRaw: Int
        var symptoms: [String]
        var customSymptoms: [String]
        var factors: [String]
        var notes: String
        var originalOnset: Date?
    }

    /// The severity choices offered, carrying `HKCategoryValueSeverity`'s raw values so the stored
    /// `severityRaw` needs no mapping table and cannot drift from HealthKit's.
    ///
    /// `1` (`notPresent`) is deliberately absent: this sheet logs a headache that HAPPENED, so
    /// "not present" is not an answer it can honestly offer. An entry carrying it (only reachable
    /// from an older store) opens on Unspecified and is only rewritten if the user saves.
    enum Severity: Int, CaseIterable, Identifiable {
        case unspecified = 0
        case mild = 2
        case moderate = 3
        case severe = 4

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .unspecified: return "Unspecified"
            case .mild:        return "Mild"
            case .moderate:    return "Moderate"
            case .severe:      return "Severe"
            }
        }

        /// Tint for the badge on a logged row. Teal (not green) for mild: the dashboard's mid
        /// accent, so a logged headache never reads as "you're fine".
        var tint: Color {
            switch self {
            case .unspecified: return .secondary
            case .mild:        return .teal
            case .moderate:    return .orange
            case .severe:      return .red
            }
        }
    }
}

// MARK: - Shared tag presentation

/// One tag pill, matching the house capsule badge (cf. `VitalsStatusCardView.statusBadge`).
/// `systemImage` carries the remove affordance when the chip is tappable.
struct HeadacheChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.caption2)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// Chips that wrap onto as many lines as they need.
///
/// iOS 17 ships no wrapping stack, and both obvious fallbacks lose information: an `HStack`
/// truncates and a horizontal `ScrollView` hides tags behind a gesture inside an already-scrolling
/// list. The tags ARE the user's logged detail, so none of them may be dropped from the row.
struct HeadacheChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height }
            + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Break the subviews into rows at `width`. A chip wider than the row still gets its own row
    /// rather than being dropped.
    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
