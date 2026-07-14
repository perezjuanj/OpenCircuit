// Manual sleep-time edit sheet (#176) — RingConn parity (EditSleepStagePage / SleepEditableTimeRange).
//
// Two time pickers over the night's in-bed window, hard-bounded to ±3 h of the recorded onset/wake
// (SleepEdit.bounds), with a live in-bed duration preview and the app's own limit copy. On Save it
// runs the NON-DESTRUCTIVE edit via the injected closure (→ RingSession.applySleepEdit): extending a
// truncated night APPENDS the added sleep to Apple Health; trimming updates the in-app view only.
// Nothing in Apple Health is ever deleted.

import SwiftUI
import OpenCircuitKit

struct EditSleepView: View {
    let night: Date
    let recordedOnset: Date
    let recordedWake: Date
    /// Runs the edit, returning the new asleep minutes (nil = failed). Injected by SleepCardView.
    let onSave: (SleepEdit.Window) async -> Int?

    @Environment(\.dismiss) private var dismiss

    @State private var bedtime: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var saveFailed = false
    private let initialWindow: SleepEdit.Window
    private static let minimumDuration: TimeInterval = 30 * 60

    init(night: Date, inBedStart: Date, inBedEnd: Date,
         recordedOnset: Date, recordedWake: Date,
         onSave: @escaping (SleepEdit.Window) async -> Int?) {
        self.night = night
        self.recordedOnset = recordedOnset
        self.recordedWake = recordedWake
        self.onSave = onSave
        // Clamp the initial values into the editable bounds so the DatePickers never start out of range.
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
        var start = SleepEdit.clamp(inBedStart, to: b)
        var end = SleepEdit.clamp(inBedEnd, to: b)
        if end.timeIntervalSince(start) < Self.minimumDuration {
            end = min(b.latest, start.addingTimeInterval(Self.minimumDuration))
            start = max(b.earliest, end.addingTimeInterval(-Self.minimumDuration))
        }
        let initial = SleepEdit.Window(inBedStart: start, inBedEnd: end)
        initialWindow = initial
        _bedtime = State(initialValue: initial.inBedStart)
        _wake = State(initialValue: initial.inBedEnd)
    }

    private var bounds: SleepEdit.Bounds {
        SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake)
    }
    private var window: SleepEdit.Window { .init(inBedStart: bedtime, inBedEnd: wake) }
    private var invalid: SleepEdit.Invalid? {
        SleepEdit.validate(window, recordedOnset: recordedOnset, recordedWake: recordedWake,
                           minDuration: Self.minimumDuration)
    }
    private var hasChanges: Bool {
        !SleepEdit.isSamePickerMinute(window.inBedStart, initialWindow.inBedStart)
            || !SleepEdit.isSamePickerMinute(window.inBedEnd, initialWindow.inBedEnd)
    }
    private var bedtimeRange: ClosedRange<Date> {
        bounds.earliest...min(bounds.latest,
                              wake.addingTimeInterval(-Self.minimumDuration))
    }
    private var wakeRange: ClosedRange<Date> {
        max(bounds.earliest,
            bedtime.addingTimeInterval(Self.minimumDuration))...bounds.latest
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Bedtime", selection: $bedtime, in: bedtimeRange,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Wake up", selection: $wake, in: wakeRange,
                               displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("Editable Time Range")
                } footer: {
                    Text("To help improve accuracy, edits are limited to within 3 hours before your recorded sleep time and within 3 hours after your recorded wake time.")
                }
                Section {
                    LabeledContent("Time in bed", value: durationText)
                    if let invalid {
                        Text(message(for: invalid)).font(.caption).foregroundStyle(.orange)
                    }
                    if saveFailed {
                        Text("The edit couldn’t be saved. Please try again.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Extending a night adds the sleep to Apple Health; trimming updates this app only. Your ring's original recording is never changed.")
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

    private func message(for e: SleepEdit.Invalid) -> String {
        switch e {
        case .endNotAfterStart:    return "Wake time must be after bedtime."
        case .startBeforeEarliest: return "Bedtime can’t be more than 3 hours before your recorded sleep."
        case .endAfterLatest:      return "Wake time can’t be more than 3 hours after your recorded wake."
        case .tooShort:            return "That window is too short for a night."
        }
    }

    private func save() async {
        saving = true
        saveFailed = false
        let saved = await onSave(window) != nil
        saving = false
        if saved { dismiss() } else { saveFailed = true }
    }
}
