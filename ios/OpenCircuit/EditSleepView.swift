// Manual sleep-time edit sheet (#176) — RingConn parity (EditSleepStagePage / SleepEditableTimeRange).
//
// Three independent time pickers for bedtime, sleep onset, and wake, hard-bounded to ±3 h of the
// recorded onset/wake (SleepEdit.bounds), with live in-bed and asleep-window previews. On Save it
// runs the NON-DESTRUCTIVE edit via the injected closure (→ RingSession.applySleepEdit): extending a
// truncated night APPENDS the added sleep to Apple Health; trimming updates the in-app view only.
// Nothing in Apple Health is ever deleted.

import SwiftUI
import OpenCircuitKit

struct EditSleepView: View {
    let night: Date
    let recordedOnset: Date
    let recordedWake: Date
    /// Span of epoch records we actually hold for this night. Widens the editable bounds beyond the
    /// ±3 h parity margin so a badly TRUNCATED night is still correctable (#188 fallout — a night
    /// detected as 07:30–08:55 offered an "In bed" picker of 04:30–07:30, making the real 00:15
    /// bedtime unreachable). Computed by the caller via `SleepEdit.dataCoverage` and passed to
    /// `applySleepEdit` too, so the picker can never offer a time the validator rejects.
    let dataCoverage: ClosedRange<Date>?
    /// Runs the edit, returning the new asleep minutes (nil = failed). Injected by SleepCardView.
    let onSave: (SleepEdit.Times) async -> Int?

    @Environment(\.dismiss) private var dismiss

    @State private var bedtime: Date
    @State private var onset: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var saveFailed = false
    private let initialTimes: SleepEdit.Times
    private static let minimumDuration: TimeInterval = 30 * 60

    init(night: Date, inBedStart: Date, sleepOnset: Date, sleepWake: Date,
         recordedOnset: Date, recordedWake: Date,
         dataCoverage: ClosedRange<Date>? = nil,
         onSave: @escaping (SleepEdit.Times) async -> Int?) {
        self.night = night
        self.recordedOnset = recordedOnset
        self.recordedWake = recordedWake
        self.dataCoverage = dataCoverage
        self.onSave = onSave
        // Clamp the initial values into the editable bounds so the DatePickers never start out of range.
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: dataCoverage)
        var start = SleepEdit.clamp(inBedStart, to: b)
        var asleep = SleepEdit.clamp(sleepOnset, to: b)
        var end = SleepEdit.clamp(sleepWake, to: b)
        asleep = max(start, asleep)
        if end.timeIntervalSince(asleep) < Self.minimumDuration {
            end = min(b.latest, asleep.addingTimeInterval(Self.minimumDuration))
            asleep = max(start, end.addingTimeInterval(-Self.minimumDuration))
        }
        start = min(start, asleep)
        let initial = SleepEdit.Times(inBedStart: start, sleepOnset: asleep, sleepWake: end)
        initialTimes = initial
        _bedtime = State(initialValue: initial.inBedStart)
        _onset = State(initialValue: initial.sleepOnset)
        _wake = State(initialValue: initial.sleepWake)
    }

    private var bounds: SleepEdit.Bounds {
        SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                         dataCoverage: dataCoverage)
    }
    private var times: SleepEdit.Times {
        .init(inBedStart: bedtime, sleepOnset: onset, sleepWake: wake)
    }
    private var invalid: SleepEdit.Invalid? {
        SleepEdit.validate(times, recordedOnset: recordedOnset, recordedWake: recordedWake,
                           minDuration: Self.minimumDuration, dataCoverage: dataCoverage)
    }
    private var hasChanges: Bool {
        !SleepEdit.isSamePickerMinute(times.inBedStart, initialTimes.inBedStart)
            || !SleepEdit.isSamePickerMinute(times.sleepOnset, initialTimes.sleepOnset)
            || !SleepEdit.isSamePickerMinute(times.sleepWake, initialTimes.sleepWake)
    }
    private var bedtimeRange: ClosedRange<Date> {
        bounds.earliest...onset
    }
    private var onsetRange: ClosedRange<Date> {
        bedtime...min(bounds.latest, wake.addingTimeInterval(-Self.minimumDuration))
    }
    private var wakeRange: ClosedRange<Date> {
        max(bounds.earliest,
            onset.addingTimeInterval(Self.minimumDuration))...bounds.latest
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("In bed", selection: $bedtime, in: bedtimeRange,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Fell asleep", selection: $onset, in: onsetRange,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Woke up", selection: $wake, in: wakeRange,
                               displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("Editable Time Range")
                } footer: {
                    Text("To help improve accuracy, edits are limited to within 3 hours before your recorded sleep time and within 3 hours after your recorded wake time.")
                }
                Section {
                    LabeledContent("Time in bed", value: durationText)
                    LabeledContent("Sleep window", value: asleepDurationText)
                    if let invalid {
                        Text(message(for: invalid)).font(.caption).foregroundStyle(.orange)
                    }
                    if saveFailed {
                        Text("The edit couldn’t be saved. Please try again.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Time before “Fell asleep” counts as awake in bed. Changing the sleep window updates the estimate without changing your ring's original recording.")
                }
            }
            .navigationTitle("Edit Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!hasChanges || invalid != nil || saving)
                }
            }
        }
    }

    private var durationText: String {
        let mins = Int(max(0, wake.timeIntervalSince(bedtime)) / 60)
        return "\(mins / 60)h \(mins % 60)m"
    }

    private var asleepDurationText: String {
        let mins = Int(max(0, wake.timeIntervalSince(onset)) / 60)
        return "\(mins / 60)h \(mins % 60)m"
    }

    private func message(for e: SleepEdit.Invalid) -> String {
        switch e {
        case .endNotAfterStart:    return "Wake time must be after bedtime."
        case .onsetBeforeBedtime:  return "Fell asleep can’t be before In bed."
        case .wakeNotAfterOnset:   return "Woke up must be after Fell asleep."
        case .startBeforeEarliest: return "Bedtime can’t be more than 3 hours before your recorded sleep."
        case .endAfterLatest:      return "Wake time can’t be more than 3 hours after your recorded wake."
        case .tooShort:            return "That window is too short for a night."
        }
    }

    private func save() async {
        saving = true
        saveFailed = false
        let saved = await onSave(times) != nil
        saving = false
        if saved { dismiss() } else { saveFailed = true }
    }
}
