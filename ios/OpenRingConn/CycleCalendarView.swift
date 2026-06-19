import SwiftUI
import SwiftData
import OpenRingKit

// Women's health — period logging, cycle calendar + prediction (#78).
//
// Gated behind `userProfile.womensHealthEnabled` (settings toggle) so users
// who don't want this feature never see it. All cycle predictions are labeled
// as ESTIMATES and come with a medical-disclaimer footer.
//
// Temperature corroboration consumes `StoredSleepSummary.skinTempC` via
// `SkinTempBaseline` — it never adds a new temperature write path. (#78 scope).

// MARK: - Symptoms catalog

enum PeriodSymptom: String, CaseIterable, Identifiable {
    case cramping      = "Cramping"
    case bloating      = "Bloating"
    case headache      = "Headache"
    case moodChanges   = "Mood changes"
    case backPain      = "Back pain"
    case breastTender  = "Breast tenderness"
    case fatigue       = "Fatigue"
    case acne          = "Acne"
    var id: String { rawValue }
}

// MARK: - Main calendar view

struct CycleCalendarView: View {
    @Environment(\.modelContext) private var modelContext

    /// All logged period entries, sorted by start.
    @Query(sort: \StoredPeriodEntry.start, order: .forward)
    private var entries: [StoredPeriodEntry]

    /// Trailing sleep summaries for skin-temp corroboration — bounded query.
    @Query(sort: \StoredSleepSummary.night, order: .reverse)
    private var sleepSummaries: [StoredSleepSummary]

    @State private var displayedMonth: Date = Calendar.current.startOfDay(for: Date())
    @State private var showLogSheet = false
    @State private var editingEntry: StoredPeriodEntry? = nil

    private let cal = Calendar.current

    // MARK: Prediction inputs

    /// Convert stored period entries to `CyclePredictor.PeriodEntry` values.
    private var predictorEntries: [CyclePredictor.PeriodEntry] {
        entries.map { CyclePredictor.PeriodEntry(start: $0.start, end: $0.end) }
    }

    /// Nightly skin-temp deviations from the trailing sleep summaries.
    /// Consumes the canonical `skinTempC` values + the 30-night rolling
    /// baseline from `SkinTempBaseline` — no new temperature write. (#78)
    private var skinTempDeviations: [(night: Date, offsetC: Double)] {
        let nights = sleepSummaries
            .filter { $0.skinTempC > 0 }
            .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
        guard nights.count >= SkinTempBaseline.minBaselineNights else { return [] }
        return nights.compactMap { n in
            // Exclude tonight from the prior nights used to build its own baseline.
            let prior = nights.filter { $0.night < n.night }
            guard let base = SkinTempBaseline.baseline(priorNights: prior) else { return nil }
            return (night: n.night, offsetC: SkinTempBaseline.offset(tonight: n.celsius, baseline: base))
        }
    }

    /// The current cycle prediction (nil < 2 logged cycles).
    private var prediction: CyclePredictor.CyclePrediction? {
        CyclePredictor.predict(from: predictorEntries, skinTempDeviations: skinTempDeviations)
    }

    // MARK: Calendar grid helpers

    private var monthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth))!
    }

    private var monthTitle: String {
        monthStart.formatted(.dateTime.year().month(.wide))
    }

    /// All dates shown in the 6-row grid (padding before month-start with prior-month days).
    private var gridDates: [Date] {
        let firstWeekday = cal.component(.weekday, from: monthStart)  // 1 = Sun
        let offset = firstWeekday - 1   // days to prepend from prior month
        return (-offset ..< 42 - offset).compactMap {
            cal.date(byAdding: .day, value: $0, to: monthStart)
        }
    }

    // MARK: Day classification

    private func isCurrentMonth(_ date: Date) -> Bool {
        cal.component(.month, from: date) == cal.component(.month, from: monthStart)
            && cal.component(.year, from: date) == cal.component(.year, from: monthStart)
    }

    private func isToday(_ date: Date) -> Bool { cal.isDateInToday(date) }

    private func isLoggedPeriod(_ date: Date) -> Bool {
        CyclePredictor.isLoggedPeriodDay(date, entries: predictorEntries, calendar: cal)
    }

    private func isPredictedPeriod(_ date: Date) -> Bool {
        guard let p = prediction else { return false }
        return CyclePredictor.isInPredictedPeriod(date, prediction: p, calendar: cal)
    }

    private func isFertile(_ date: Date) -> Bool {
        guard let p = prediction else { return false }
        return CyclePredictor.isInFertileWindow(date, prediction: p, calendar: cal)
    }

    private func isOvulation(_ date: Date) -> Bool {
        guard let p = prediction else { return false }
        return CyclePredictor.isOvulationDay(date, prediction: p, calendar: cal)
    }

    // MARK: Day tile coloring

    private func tileFill(_ date: Date) -> Color {
        if isLoggedPeriod(date) { return Color.red.opacity(0.75) }
        if isPredictedPeriod(date) { return Color.orange.opacity(0.25) }
        if isOvulation(date) { return Color.green.opacity(0.35) }
        if isFertile(date) { return Color.green.opacity(0.15) }
        return Color.clear
    }

    private func tileTextColor(_ date: Date) -> Color {
        if !isCurrentMonth(date) { return Color(uiColor: .tertiaryLabel) }
        if isToday(date) { return .white }
        if isLoggedPeriod(date) { return .white }
        return .primary
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                calendarSection
                predictionSection
                loggedPeriodsSection
                disclaimerFooter
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Cycle Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingEntry = nil
                    showLogSheet = true
                } label: {
                    Label("Log Period", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            // Capture the original start so editing can RELOCATE the row (not duplicate it) if
            // the user changes the start date, and reset the HK watermark on a clinical change.
            let originalStart = editingEntry?.start
            PeriodLogSheet(editing: editingEntry) { start, end, flow, symptoms, notes in
                let store = LocalStore(modelContext)
                try? store.savePeriodEntry(
                    start: start, end: end, flowLevelRaw: flow.rawValue,
                    symptoms: symptoms.map(\.rawValue), notes: notes,
                    originalStart: originalStart)
            }
        }
    }

    // MARK: Calendar section

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Month nav header
            HStack {
                Button {
                    displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth)!
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthTitle).font(.headline)
                Spacer()
                Button {
                    displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth)!
                } label: {
                    Image(systemName: "chevron.right")
                }
            }

            // Day-of-week header
            let weekdaySymbols = cal.veryShortWeekdaySymbols
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day grid — 6 rows × 7 columns
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(gridDates.enumerated()), id: \.offset) { _, date in
                    dayTile(date)
                }
            }

            legendRow
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private func dayTile(_ date: Date) -> some View {
        let dayNum = cal.component(.day, from: date)
        let fill = tileFill(date)
        let textColor = tileTextColor(date)

        return ZStack {
            // Today gets a solid circle
            if isToday(date) {
                Circle().fill(Color.accentColor)
            } else if fill != .clear {
                Circle().fill(fill)
            }
            // Predicted period gets an orange ring outline
            if isPredictedPeriod(date) && !isLoggedPeriod(date) {
                Circle().stroke(Color.orange.opacity(0.7), lineWidth: 1.5)
            }
            // Ovulation day gets a green ring outline
            if isOvulation(date) && !isLoggedPeriod(date) {
                Circle().stroke(Color.green.opacity(0.8), lineWidth: 1.5)
            }
            Text("\(dayNum)")
                .font(.system(size: 14, weight: isToday(date) ? .bold : .regular))
                .foregroundStyle(textColor)
        }
        .frame(width: 36, height: 36)
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            legendItem(color: .red.opacity(0.75), label: "Period")
            legendItem(color: .orange.opacity(0.25), label: "Predicted", outlined: .orange)
            legendItem(color: .green.opacity(0.15), label: "Fertile")
            legendItem(color: .green.opacity(0.35), label: "Ovulation est.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String,
                             outlined: Color? = nil) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(color).frame(width: 12, height: 12)
                if let outline = outlined {
                    Circle().stroke(outline.opacity(0.8), lineWidth: 1).frame(width: 12, height: 12)
                }
            }
            Text(label)
        }
    }

    // MARK: Prediction section

    @ViewBuilder
    private var predictionSection: some View {
        if let p = prediction {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(.purple)
                    Text("CYCLE PREDICTION (ESTIMATE)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }

                predictionRow("Next period",
                              value: p.nextPeriodStart.formatted(.dateTime.month().day()),
                              note: "~\(Int(p.avgCycleLengthDays.rounded()))-day avg cycle")

                predictionRow("Fertile window",
                              value: fertileWindowLabel(p),
                              note: "estimate only")

                predictionRow("Ovulation est.",
                              value: p.ovulationEstimate.formatted(.dateTime.month().day()),
                              note: "estimate only")

                if p.tempCorroborated {
                    HStack(spacing: 6) {
                        Image(systemName: "thermometer.medium").foregroundStyle(.orange)
                        Text("Skin-temp data shows a rise near the predicted ovulation window (soft signal only — not a confirmation).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1)))
                }

                Text("Based on \(Int(p.avgCycleLengthDays.rounded()))-day average from \(predictorEntries.count) logged period(s).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground)))
        } else {
            noPredictionCard
        }
    }

    private var noPredictionCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
            Text("Log at least 2 periods to see cycle predictions.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private func predictionRow(_ label: String, value: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold))
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func fertileWindowLabel(_ p: CyclePredictor.CyclePrediction) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: p.fertileWindowStart))–\(fmt.string(from: p.fertileWindowEnd))"
    }

    // MARK: Logged periods section

    @ViewBuilder
    private var loggedPeriodsSection: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("LOGGED PERIODS")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                ForEach(entries.reversed()) { entry in
                    periodRow(entry)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    private func periodRow(_ entry: StoredPeriodEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.7)).frame(width: 8, height: 8)
                    Text(entry.start.formatted(.dateTime.month().day().year()))
                        .font(.subheadline.weight(.medium))
                    if let end = entry.end {
                        Text("–")
                        Text(end.formatted(.dateTime.month().day()))
                            .font(.subheadline)
                    }
                }
                HStack(spacing: 8) {
                    Text(entry.flowLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    if !entry.symptoms.isEmpty {
                        Text(entry.symptoms.prefix(3).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            // Edit button
            Button {
                editingEntry = entry
                showLogSheet = true
            } label: {
                Image(systemName: "pencil").foregroundStyle(.secondary)
            }
            // Delete button — also removes the previously-written Apple Health sample(s) so a
            // deleted period doesn't leave an orphaned menstrual-flow entry in Health.
            Button(role: .destructive) {
                let store = LocalStore(modelContext)
                let staleUUIDs = (try? store.deletePeriodEntry(start: entry.start)) ?? []
                if !staleUUIDs.isEmpty {
                    Task { await HealthKitWriter().deleteMenstrualFlowSamples(uuidStrings: staleUUIDs) }
                }
            } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Disclaimer footer

    private var disclaimerFooter: some View {
        Text("Cycle predictions are statistical estimates only. OpenCircuit is not a medical device. Do not use these estimates for contraception or medical decisions. If you have concerns about your menstrual health, consult a qualified healthcare professional.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

// MARK: - Period log sheet

struct PeriodLogSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Existing entry being edited, nil for a new entry.
    let editing: StoredPeriodEntry?
    /// Called on save with (start, end?, flowLevel, symptoms, notes).
    let onSave: (Date, Date?, FlowLevel, Set<PeriodSymptom>, String) throws -> Void

    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var flowLevel: FlowLevel
    @State private var selectedSymptoms: Set<PeriodSymptom>
    @State private var notes: String
    @State private var saveError: String? = nil

    /// App-facing flow level (mirrors StoredPeriodEntry.flowLevelRaw).
    enum FlowLevel: Int, CaseIterable {
        case light = 1, medium = 2, heavy = 3
        var label: String {
            switch self {
            case .light:  return "Light"
            case .medium: return "Medium"
            case .heavy:  return "Heavy"
            }
        }
    }

    init(editing: StoredPeriodEntry?,
         onSave: @escaping (Date, Date?, FlowLevel, Set<PeriodSymptom>, String) throws -> Void) {
        self.editing = editing
        self.onSave = onSave

        let start = editing?.start ?? Calendar.current.startOfDay(for: Date())
        let end   = editing?.end
        let flow  = FlowLevel(rawValue: editing?.flowLevelRaw ?? 2) ?? .medium
        let syms  = Set(
            (editing?.symptoms ?? []).compactMap { PeriodSymptom(rawValue: $0) }
        )
        _startDate       = State(initialValue: start)
        _hasEndDate      = State(initialValue: end != nil)
        _endDate         = State(initialValue: end ?? start.addingTimeInterval(4 * 86_400))
        _flowLevel       = State(initialValue: flow)
        _selectedSymptoms = State(initialValue: syms)
        _notes           = State(initialValue: editing?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Period") {
                    DatePicker("Start date", selection: $startDate,
                               displayedComponents: .date)
                    Toggle("Log end date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("End date", selection: $endDate,
                                   in: startDate...,
                                   displayedComponents: .date)
                    }
                }

                Section("Flow") {
                    Picker("Flow level", selection: $flowLevel) {
                        ForEach(FlowLevel.allCases, id: \.rawValue) { fl in
                            Text(fl.label).tag(fl)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Symptoms") {
                    ForEach(PeriodSymptom.allCases) { sym in
                        Toggle(sym.rawValue, isOn: Binding(
                            get: { selectedSymptoms.contains(sym) },
                            set: { on in
                                if on { selectedSymptoms.insert(sym) }
                                else  { selectedSymptoms.remove(sym) }
                            }
                        ))
                    }
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
            }
            .navigationTitle(editing == nil ? "Log Period" : "Edit Period")
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

    private func save() {
        do {
            let end = hasEndDate ? endDate : nil
            try onSave(startDate, end, flowLevel, selectedSymptoms, notes)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
