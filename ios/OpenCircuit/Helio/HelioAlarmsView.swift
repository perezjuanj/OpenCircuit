import SwiftUI
import ZeppKit

/// The strap's alarms (decision 20; ZEPP_PROTOCOL.md §12, §15.2). The strap's list is the truth:
/// nothing is kept on the phone. Every change goes through `ZeppAlarmEditor`: read first, write ONE
/// slot, read back. Edits need the clock set on this connection, because alarms fire in the strap's
/// local time.
///
/// DECISION-GAP: decision 20 asks the strap once per connection which alarm features it supports.
/// The only capability request (`01`, §12.2) has an unknown reply layout, so ZeppKit never sends it
/// (SPEC-GAP in ZeppAlarms.swift). What IS asked once per connection is the services list and the
/// alarm list (§14): alarms show only when both came back well-formed. Smart wake is never offered
/// (no capability for it is known, §14); an alarm that already has it keeps it and says so.
struct HelioAlarmsView: View {
    let connection: HelioConnection
    @State private var editing: AlarmEdit?
    @State private var adding = false
    @State private var confirmDelete: ZeppAlarm?

    private var session: HelioSession? { connection.session }
    private var editor: ZeppAlarmEditor? { session?.alarmEditor }
    /// The slot a Shortcut's wake alarm holds while it is still as written (#260, decision 52b).
    private var managedSlot: UInt8? {
        guard let session, let alarms = editor?.alarms else { return nil }
        return StrapWakeAlarmStore().managedSlot(strapID: session.identityID, alarms: alarms)
    }

    var body: some View {
        List {
            if let editor, editor.canView, let alarms = editor.alarms {
                Section {
                    if alarms.isEmpty {
                        Text("No alarms on the strap.").foregroundStyle(.secondary)
                    }
                    ForEach(alarms, id: \.slot) { alarm in
                        row(alarm, canEdit: editor.canEdit)
                    }
                } footer: {
                    Text(footer(editor))
                }
                if editor.canEdit, !editor.freeSlots.isEmpty {
                    Section { Button("Add Alarm") { adding = true } }
                }
            } else if case .unreadable? = editor?.list {
                Section {
                    Text("Couldn't read the strap's alarms.").foregroundStyle(.secondary)
                    Button("Read again") { session?.readAlarms() }.disabled(editor?.isBusy == true)
                }
            } else {
                Section { Text("Reading the strap's alarms…").foregroundStyle(.secondary) }
            }
            if let notice = session?.alarmNotice {
                Section { Text(notice).font(.caption) }
            }
        }
        .navigationTitle("Alarms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { session?.readAlarms() }.disabled(editor?.isBusy != false)
            }
        }
        .sheet(item: $editing) { edit in
            HelioAlarmEditorSheet(title: "Edit Alarm", initial: edit.alarm) { edited in
                session?.replaceAlarm(edited)
            }
        }
        .sheet(isPresented: $adding) {
            HelioAlarmEditorSheet(title: "New Alarm", initial: ZeppAlarm(slot: 0, hour: 7, minute: 0, days: .weekdays)) { new in
                session?.addAlarm(hour: new.hour, minute: new.minute, days: new.days)
            }
        }
        .confirmationDialog("Delete this alarm from the strap?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let alarm = confirmDelete { session?.deleteAlarm(slot: alarm.slot) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    private func row(_ alarm: ZeppAlarm, canEdit: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%02d:%02d", alarm.hour, alarm.minute))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(alarm.isEnabled ? .primary : .secondary)
                Text(Self.daysText(alarm.days) + (alarm.smartWake ? ", smart wake (set in Zepp)" : "")
                     + (managedSlot == alarm.slot ? ". Set by Shortcuts" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { alarm.isEnabled }, set: { on in
                var changed = alarm
                changed.isEnabled = on
                session?.replaceAlarm(changed)
            }))
            .labelsHidden()
            .disabled(!canEdit)
        }
        .contentShape(Rectangle())
        .onTapGesture { if canEdit { editing = AlarmEdit(alarm: alarm) } }
        .swipeActions {
            if canEdit { Button("Delete", role: .destructive) { confirmDelete = alarm } }
        }
        .accessibilityElement(children: .combine)
    }

    private func footer(_ editor: ZeppAlarmEditor) -> String {
        var parts = ["The strap vibrates for up to a minute; tap it to stop. Times are the strap's local time."]
        if !editor.canEdit {
            if !editor.isTimeSet {
                parts.append("Editing needs the strap's clock set on this connection; reconnect to set it.")
            } else if editor.isListStale {
                parts.append("The list changed on the strap. Refresh before editing.")
            }
        }
        if editor.freeSlots.isEmpty { parts.append("The strap is full (10 alarms).") }
        return parts.joined(separator: " ")
    }

    static func daysText(_ days: ZeppAlarmDays) -> String {
        switch days {
        case .once: return "Once"
        case .everyDay: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekend: return "Weekends"
        default:
            let names: [(ZeppAlarmDays, String)] = [(.monday, "Mon"), (.tuesday, "Tue"), (.wednesday, "Wed"),
                                                    (.thursday, "Thu"), (.friday, "Fri"), (.saturday, "Sat"), (.sunday, "Sun")]
            return names.filter { days.contains($0.0) }.map(\.1).joined(separator: " ")
        }
    }
}

/// The alarm a sheet edits; a slot is an alarm's only identity (§12.3).
private struct AlarmEdit: Identifiable {
    let alarm: ZeppAlarm
    var id: UInt8 { alarm.slot }
}

/// Time and repeat days for one alarm. Smart wake is not offered (see `HelioAlarmsView`).
private struct HelioAlarmEditorSheet: View {
    let title: String
    let initial: ZeppAlarm
    let onSave: (ZeppAlarm) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var days: ZeppAlarmDays = .once

    private static let dayOptions: [(ZeppAlarmDays, String)] = [
        (.monday, "Monday"), (.tuesday, "Tuesday"), (.wednesday, "Wednesday"), (.thursday, "Thursday"),
        (.friday, "Friday"), (.saturday, "Saturday"), (.sunday, "Sunday"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                Section("Repeat") {
                    ForEach(Self.dayOptions, id: \.1) { option in
                        Toggle(option.1, isOn: Binding(
                            get: { days.contains(option.0) },
                            set: { on in if on { days.insert(option.0) } else { days.remove(option.0) } }))
                    }
                    Text(days.isEmpty ? "Once, at the next occurrence." : HelioAlarmsView.daysText(days))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        var alarm = initial
                        alarm.hour = UInt8(parts.hour ?? 0)
                        alarm.minute = UInt8(parts.minute ?? 0)
                        alarm.days = days
                        onSave(alarm)
                        dismiss()
                    }
                }
            }
            .onAppear {
                time = Calendar.current.date(bySettingHour: Int(initial.hour), minute: Int(initial.minute), second: 0, of: Date()) ?? Date()
                days = initial.days
            }
        }
    }
}
