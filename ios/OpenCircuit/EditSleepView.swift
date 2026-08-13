// Manual sleep-time edit sheet (#176) — RingConn parity (EditSleepStagePage / SleepEditableTimeRange).
//
// Three independent time pickers for bedtime, sleep onset, and wake, bounded by `SleepEdit.bounds`
// — the ±3 h parity margin around the recorded onset/wake, WIDENED by the epochs we actually hold
// for the night (#188: a night truncated to its tail was otherwise uncorrectable). Live in-bed and
// asleep-window previews. On Save it
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
    /// The night's already-SAVED edited window, if any. Keeps a prior edit selectable even if the
    /// archive has since pruned the coverage that first allowed it (#188 review).
    let existingEdit: ClosedRange<Date>?
    /// Runs the edit, returning the new asleep minutes (nil = failed). Injected by SleepCardView.
    /// The sheet hands back the coverage snapshot its pickers were bounded by, so
    /// the server-side validator can honour exactly what the user was offered (#188 review).
    let onSave: (SleepEdit.Times, ClosedRange<Date>?) async -> Int?

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
         existingEdit: ClosedRange<Date>? = nil,
         onSave: @escaping (SleepEdit.Times, ClosedRange<Date>?) async -> Int?) {
        self.night = night
        self.recordedOnset = recordedOnset
        self.recordedWake = recordedWake
        self.dataCoverage = dataCoverage
        self.existingEdit = existingEdit
        self.onSave = onSave
        // Clamp the initial values into the editable bounds so the DatePickers never start out of range.
        let b = SleepEdit.bounds(recordedOnset: recordedOnset, recordedWake: recordedWake,
                                 dataCoverage: dataCoverage, existingEdit: existingEdit)
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
                         dataCoverage: dataCoverage, existingEdit: existingEdit)
    }
    private var times: SleepEdit.Times {
        .init(inBedStart: bedtime, sleepOnset: onset, sleepWake: wake)
    }
    private var invalid: SleepEdit.Invalid? {
        SleepEdit.validate(times, recordedOnset: recordedOnset, recordedWake: recordedWake,
                           minDuration: Self.minimumDuration, dataCoverage: dataCoverage,
                           existingEdit: existingEdit)
    }
    private var hasChanges: Bool {
        !SleepEdit.isSamePickerMinute(times.inBedStart, initialTimes.inBedStart)
            || !SleepEdit.isSamePickerMinute(times.sleepOnset, initialTimes.sleepOnset)
            || !SleepEdit.isSamePickerMinute(times.sleepWake, initialTimes.sleepWake)
    }
    // ══ WHY THE PICKERS ARE BOUNDED BY WHOLE DAYS, NOT BY THE EXACT RULE ══
    //
    // 🟢 A tester with a night detected as in-bed 22:51 / asleep 23:47 / wake 08:57 reported that
    // his real onset was 01:13 and that he "can't even edit my asleep time to that" (2026-08-12).
    // `SleepEdit.validate` ALLOWS 01:13 — it is inside the bounds and after bedtime. The picker was
    // the blocker.
    //
    // A SwiftUI `DatePicker(selection:in:)` clamps every intermediate value, and it exposes the
    // date and the time as SEPARATE controls. With an exact range of 22:51 (Aug 11) … 08:27
    // (Aug 12), moving a selection of "Aug 11 23:47" to "Aug 12 01:13" has no legal path:
    //   • change the TIME first → "Aug 11 01:13", which is before 22:51 → clamped back;
    //   • change the DATE first → "Aug 12 23:47", which is after 08:27 → clamped back.
    // Every sub-day range that spans midnight is unreachable across the midnight boundary in
    // exactly this way, which is the entire population of nights this editor exists for.
    //
    // So the pickers now offer the CONTAINING CALENDAR DAYS and the real rule is enforced where it
    // was always meant to be: `invalid` prints the reason inline and `Save` stays disabled. That
    // path already existed and was simply unreachable — `.startBeforeEarliest` / `.endAfterLatest`
    // could never be produced by a picker that clamped them away first.
    //
    // The ORDERING rules (bedtime ≤ onset, wake ≥ onset + 30 min) move to validation for the same
    // reason. They used to bound the pickers against each other, which reproduces the identical
    // trap one level down: with bedtime at 22:51 on Aug 11, the onset picker's own lower bound was
    // 22:51 Aug 11 — so onset still could not cross midnight even though `bounds` allowed it. Every
    // anchor therefore shares ONE day-granular range, and `invalid` is the sole judge.
    private var pickerRange: ClosedRange<Date> {
        let cal = Calendar.current
        let b = bounds
        let lo = cal.startOfDay(for: b.earliest)
        let dayAfterLatest = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: b.latest))
        // …minus a minute so the edge reads as 23:59 rather than the next midnight. `max(_, b.latest)`
        // matters when `b.latest` itself falls in a day's final minute: the initial @State values are
        // clamped INTO `bounds`, so a range that stopped short of `b.latest` would silently drag the
        // wake time backwards the moment the sheet opened.
        let hi = max((dayAfterLatest ?? b.latest).addingTimeInterval(-60), b.latest)
        // `bounds` is monotone and always contains the clamped initial values, so lo ≤ hi holds;
        // the max() is a belt-and-braces guard because an inverted ClosedRange traps at runtime.
        return lo...max(lo, hi)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("In bed", selection: $bedtime, in: pickerRange,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Fell asleep", selection: $onset, in: pickerRange,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Woke up", selection: $wake, in: pickerRange,
                               displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("Editable Time Range")
                } footer: {
                    Text(boundsFooter)
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

    /// Describe the ACTUAL rule. The ±3 h sentence was RingConn's copy and stopped being true once
    /// `dataCoverage` may widen the bounds — showing the real clock times is both honest and more
    /// useful than a margin the user cannot compute in their head (#188 review).
    private var boundsFooter: String {
        "To help improve accuracy, edits are limited to the period your ring recorded around this "
            + "night — \(clock(bounds.earliest)) to \(clock(bounds.latest))."
    }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(
            Calendar.current.isDate(d, inSameDayAs: bounds.latest) ? "jmm" : "EEEjmm")
        return f.string(from: d)
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
        case .startBeforeEarliest: return "Bedtime can’t be earlier than \(clock(bounds.earliest))."
        case .endAfterLatest:      return "Wake time can’t be later than \(clock(bounds.latest))."
        case .tooShort:            return "That window is too short for a night."
        }
    }

    private func save() async {
        saving = true
        saveFailed = false
        let saved = await onSave(times, dataCoverage) != nil
        saving = false
        if saved { dismiss() } else { saveFailed = true }
    }
}
