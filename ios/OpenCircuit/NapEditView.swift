// Manual nap add / edit sheet (#nap-parity) — RingConn's SleepNapModel.isEdited / add-nap.
//
// Two time pickers over a nap window, validated by SleepEdit's sibling `NapEdit` (15 min – 6 h,
// daytime, no overlap with the main night or another nap), with a live duration + inline save
// feedback. Saving runs the NON-DESTRUCTIVE nap action via the injected closure: an ADD appends the
// nap to Apple Health; an EDIT updates the app view (an already-mirrored nap is not re-written or
// deleted). Nothing in Apple Health is ever removed.

import SwiftUI
import OpenCircuitKit

struct NapEditView: View {
    /// nil originalStart = ADD; non-nil = EDIT that existing nap (keyed by its original start).
    let originalStart: Date?
    let night: DateInterval?
    let otherNaps: [DateInterval]
    /// Runs the nap action, returning success. Injected by SleepCardView (→ RingSession.applyNapEdit).
    let onSave: (Date?, NapEdit.Window) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var saving = false
    @State private var saveFailed = false

    init(originalStart: Date?, initialStart: Date, initialEnd: Date,
         night: DateInterval?, otherNaps: [DateInterval],
         onSave: @escaping (Date?, NapEdit.Window) async -> Bool) {
        self.originalStart = originalStart
        self.night = night
        self.otherNaps = otherNaps
        self.onSave = onSave
        _start = State(initialValue: initialStart)
        _end = State(initialValue: initialEnd)
    }

    private var isAdd: Bool { originalStart == nil }
    private var window: NapEdit.Window { .init(start: start, end: end) }
    private var invalid: NapEdit.Invalid? {
        NapEdit.validate(window, night: night, otherNaps: otherNaps, now: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("A nap is 15 minutes to 6 hours, during the day, and can't overlap your main sleep or another nap.")
                }
                Section {
                    LabeledContent("Duration", value: durationText)
                    if let invalid {
                        Text(message(for: invalid)).font(.caption).foregroundStyle(.orange)
                    }
                    if saveFailed {
                        Text("Couldn’t save the nap. Please try again.").font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(isAdd
                         ? "Adding a nap records it as sleep in Apple Health."
                         : "Editing updates this app; a nap already recorded in Apple Health is left as-is (never deleted).")
                }
            }
            .navigationTitle(isAdd ? "Add Nap" : "Edit Nap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(invalid != nil || saving)
                }
            }
        }
    }

    private var durationText: String {
        let mins = Int(max(0, end.timeIntervalSince(start)) / 60)
        return "\(mins / 60)h \(mins % 60)m"
    }

    private func message(for e: NapEdit.Invalid) -> String {
        switch e {
        case .endNotAfterStart:   return "End time must be after the start."
        case .tooShort(let m):    return "A nap is at least \(m) minutes."
        case .tooLong(let h):     return "That’s over \(h) hours — log it as a night, not a nap."
        case .notDaytime:         return "A nap has to be during the day."
        case .inFuture:           return "That time hasn’t happened yet."
        case .overlapsNight:      return "This overlaps your main sleep."
        case .overlapsNap:        return "This overlaps another nap."
        }
    }

    private func save() async {
        saving = true
        saveFailed = false
        let ok = await onSave(originalStart, window)
        saving = false
        if ok { dismiss() } else { saveFailed = true }
    }
}
