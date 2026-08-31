import SwiftUI
import OpenCircuitKit

/// Vibration + wake-up alarm settings for a Gen 3 ring.
///
/// Reached only from `DeviceInfoView`, and only while a Gen 3 is connected — the motor command is
/// confirmed on Gen 3 and nowhere else (`RingVibration.isSupported`), so the whole screen stays
/// hidden rather than offering controls that might do nothing on other models.
///
/// The copy here is deliberately blunt about what the alarm can and cannot promise. iOS gives an
/// app no way to run code at a wall-clock instant in the background, so the ring buzz is
/// best-effort and the notification is the guaranteed part. Telling the user that plainly is
/// cheaper than having them discover it by oversleeping.
struct RingVibrationView: View {
    var session: RingSession?

    /// Not `@State`: the controller is a shared singleton whose state lives in UserDefaults, so
    /// there is nothing for SwiftUI to observe. `alarm` below is the editable copy the view drives.
    private var controller: RingAlarmController { .shared }
    @State private var alarm = RingAlarmController.shared.alarm
    @State private var testMessage: String?
    @State private var testFailed = false

    private static let weekdaySymbols: [(index: Int, label: String)] = {
        let symbols = Calendar.current.shortWeekdaySymbols  // index 0 == Sunday == weekday 1
        return (1...7).map { ($0, symbols[$0 - 1]) }
    }()

    var body: some View {
        List {
            alertsSection
            alarmSection
            if alarm.isEnabled {
                repeatSection
                patternSection
                reliabilitySection
            }
            testSection
        }
        .navigationTitle("Vibration")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: alarm) { _, newValue in
            controller.alarm = newValue
        }
    }

    // MARK: - App alerts

    private var alertsSection: some View {
        Section {
            Toggle(isOn: Binding(get: { controller.buzzAlertsEnabled },
                                 set: { controller.buzzAlertsEnabled = $0 })) {
                Label("Buzz for app alerts", systemImage: "bell.and.waves.left.and.right")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Adds a buzz on the ring whenever OpenCircuit sends you a notification — move and "
                 + "wear reminders, bedtime, and health alerts. It follows the settings those "
                 + "already have, including quiet hours, so it can't produce a buzz you weren't "
                 + "going to get a notification for. Skipped while the ring is charging or busy "
                 + "syncing.")
        }
    }

    // MARK: - Alarm

    private var alarmSection: some View {
        Section {
            Toggle(isOn: $alarm.isEnabled) {
                Label("Wake-up alarm", systemImage: "alarm")
            }
            if alarm.isEnabled {
                DatePicker("Time",
                           selection: Binding(get: { alarmDate }, set: { setAlarmDate($0) }),
                           displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Alarm")
        } footer: {
            if alarm.isEnabled, let next = controller.nextFireDate() {
                Text("Next alarm \(next.formatted(date: .abbreviated, time: .shortened)).")
            } else {
                Text("The ring buzzes to wake you without making a sound — useful if someone else "
                     + "is asleep next to you.")
            }
        }
    }

    private var repeatSection: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(Self.weekdaySymbols, id: \.index) { day in
                    let on = alarm.repeats(onWeekday: day.index)
                    Button {
                        toggle(weekday: day.index)
                    } label: {
                        Text(day.label)
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.clear)
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.label)
                    .accessibilityValue(on ? "on" : "off")
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Repeat")
        } footer: {
            Text(alarm.weekdays.isEmpty
                 ? "Every day. Tap days to limit it to some of them."
                 : "Tap to add or remove days. Clear them all for every day.")
        }
    }

    private var patternSection: some View {
        Section {
            Picker("Pattern", selection: $alarm.pattern) {
                ForEach(VibrationPattern.allCases, id: \.self) { pattern in
                    Text(pattern.displayName).tag(pattern)
                }
            }
            Stepper(value: $alarm.burstCount, in: 1...10) {
                HStack {
                    Text("Repeat buzz")
                    Spacer()
                    Text("\(alarm.burstCount)×").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("How it buzzes")
        } footer: {
            Text(alarm.pattern.displayDetail
                 + " Repeating it a few times, a few seconds apart, makes it harder to sleep through.")
        }
    }

    // MARK: - The honest part

    private var reliabilitySection: some View {
        Section {
            Toggle(isOn: $alarm.backupNotification) {
                Label("Backup alert", systemImage: "bell.badge")
            }
            if let outcome = controller.lastOutcome, let at = controller.lastOutcomeAt {
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome).font(.caption)
                    Text(at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Reliability")
        } footer: {
            // Say this plainly. The mechanism genuinely cannot guarantee the buzz, and a user who
            // finds that out by oversleeping is worse off than one who reads it here.
            Text("The ring buzz is best-effort. iPhone apps can't run at an exact time in the "
                 + "background, so OpenCircuit buzzes the ring at the first moment it hears from it "
                 + "at or after your alarm — usually within a minute or two, and not at all if the "
                 + "ring is charging, disconnected, or you've swiped the app closed. The backup "
                 + "alert is a normal iPhone notification scheduled by iOS itself, so it always "
                 + "arrives. Leave it on unless you have another alarm you trust.")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                let failure = controller.testBuzz(session: session)
                testFailed = failure != nil
                testMessage = failure ?? "Sent. You should feel the ring buzz now."
            } label: {
                Label("Buzz the ring now", systemImage: "waveform")
            }
            .disabled(session?.ready != true)
            if let testMessage {
                Text(testMessage)
                    .font(.caption)
                    .foregroundStyle(testFailed ? Color.orange : Color.secondary)
            }
        } footer: {
            Text("The ring confirms it received the command, but it can't tell us the motor "
                 + "actually ran — if you don't feel anything, the ring is the place to check.")
        }
    }

    // MARK: - Binding helpers

    private var alarmDate: Date {
        Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0,
                              of: Date()) ?? Date()
    }

    private func setAlarmDate(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        alarm.hour = parts.hour ?? alarm.hour
        alarm.minute = parts.minute ?? alarm.minute
    }

    /// Toggling the last remaining day gives EVERY day, not an alarm that never fires — an empty
    /// set means daily (`RingAlarm.repeats(onWeekday:)`), and silently arming a seven-day alarm is
    /// friendlier than leaving an enabled alarm that can never go off.
    private func toggle(weekday: Int) {
        var days = alarm.weekdays
        if days.isEmpty {
            // Currently "every day" — the first tap means "only this day".
            days = [weekday]
        } else if days.contains(weekday) {
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        if days.count == 7 { days = [] }
        alarm.weekdays = days
    }
}
