import SwiftUI
import OpenCircuitKit

@MainActor
struct UserProfileSettingsView: View {
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage("userProfile.weightKg") private var weightKg = 70.0
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue

    // Height is edited via local feet/inches buffers, seeded from `heightCm` on appear and
    // written back on change. Binding the text fields straight to a `heightCm`-derived value
    // reset them on every keystroke (the shared @AppStorage write re-rendered the field
    // mid-edit), which made the inches field nearly uneditable — couldn't enter 10/11.
    @State private var heightFeetInput = 0
    @State private var heightInchesInput = 0

    // Apple Health connection. Auth lives here so there's ALWAYS a reachable entry point — the
    // dashboard's authorize button is a post-sync nudge that only appears when there's un-synced
    // history. `health` queries the shared HKHealthStore, so its status matches the dashboard's.
    private let health = HealthKitWriter()
    @State private var healthAuthorized = false
    @State private var healthUnavailable = false

    // Periodic auto-measure toggle — same UserDefaults key RingSession reads. Default true
    // (the user opted into periodic measuring); flip off to save ring battery.
    @AppStorage(RingSession.autoMeasureEnabledKey) private var autoMeasureEnabled = true

    // Sleep schedule (manual). Persisted as minutes-since-midnight so it's timezone-free
    // and feeds OpenCircuitKit's `SleepWindow` math directly. Keys/defaults are shared with
    // `ManualSleepSchedule` via `SleepScheduleDefaults`. Disabled by default: until the
    // user opts in, the night-temp window keeps using the detected sleep span.
    @AppStorage(SleepScheduleDefaults.enabled) private var sleepEnabled = false
    @AppStorage(SleepScheduleDefaults.bedMinutes)
    private var bedMinutes = SleepScheduleDefaults.defaultBedMinutes
    @AppStorage(SleepScheduleDefaults.wakeMinutes)
    private var wakeMinutes = SleepScheduleDefaults.defaultWakeMinutes

    // Daily goals (#77). Keys/defaults shared with GoalsCardView via `GoalDefaults`.
    @AppStorage(GoalDefaults.workdaySteps)    private var workdaySteps    = GoalDefaults.defaultWorkdaySteps
    @AppStorage(GoalDefaults.weekendSteps)    private var weekendSteps    = GoalDefaults.defaultWeekendSteps
    @AppStorage(GoalDefaults.activeKcal)      private var activeKcalGoal  = GoalDefaults.defaultActiveKcal
    @AppStorage(GoalDefaults.activityMinutes) private var actMinGoal      = GoalDefaults.defaultActivityMinutes
    @AppStorage(GoalDefaults.workdaySleepMin) private var workdaySleepMin = GoalDefaults.defaultWorkdaySleepMin
    @AppStorage(GoalDefaults.weekendSleepMin) private var weekendSleepMin = GoalDefaults.defaultWeekendSleepMin

    // Women's health toggle (#78). Off by default — users who don't want this feature
    // never see the cycle calendar card on the dashboard. Shared key with ContentView.
    @AppStorage("userProfile.womensHealthEnabled") private var womensHealthEnabled = false

    // Unit preferences (#83). Default to locale-appropriate units out of the box.
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue
    @AppStorage("units.distance")    private var distUnitRaw = DistanceUnit.localeDefault.rawValue

    // Indoor-workout background keep-alive — shared key with WorkoutSessionManager. Off by default.
    // When on, an indoor workout runs a coarse location session purely to keep the app alive while
    // the screen is locked so HR keeps recording (costs battery; shows the blue location indicator).
    @AppStorage(WorkoutSessionManager.indoorKeepAliveEnabledKey) private var indoorKeepAlive = false

    // App-side reminder settings (#84). Keys/defaults shared with ReminderDefaults.
    @AppStorage(ReminderDefaults.sedentaryEnabled)     private var sedentaryEnabled    = true
    @AppStorage(ReminderDefaults.sedentaryIntervalMin) private var sedentaryIntervalMin = 50
    @AppStorage(ReminderDefaults.wearEnabled)          private var wearEnabled          = false
    @AppStorage(ReminderDefaults.bedtimeEnabled)       private var bedtimeEnabled       = false
    @AppStorage(ReminderDefaults.bedtimeMinutesBefore) private var bedtimeMinutesBefore = 30

    // Health-alert thresholds (#73) + skin-temp/fever toggle (#85) + the shared quiet-hours (DND)
    // window. Keys/defaults shared with the notification engine via `HealthAlertDefaults`.
    @AppStorage(HealthAlertDefaults.highHREnabled) private var highHREnabled = true
    @AppStorage(HealthAlertDefaults.highHRBpm) private var highHRBpm = HealthAlertDefaults.defaultHighHRBpm
    @AppStorage(HealthAlertDefaults.lowSpO2Enabled) private var lowSpO2Enabled = true
    @AppStorage(HealthAlertDefaults.lowSpO2Percent) private var lowSpO2Percent = HealthAlertDefaults.defaultLowSpO2Percent
    @AppStorage(HealthAlertDefaults.elevatedHREnabled) private var elevatedHREnabled = true
    @AppStorage(HealthAlertDefaults.elevatedHRBpm) private var elevatedHRBpm = HealthAlertDefaults.defaultElevatedHRBpm
    @AppStorage(HealthAlertDefaults.tempFeverEnabled) private var tempFeverEnabled = true
    @AppStorage(HealthAlertDefaults.quietEnabled) private var quietEnabled = false
    @AppStorage(HealthAlertDefaults.quietStartMinutes) private var quietStart = HealthAlertDefaults.defaultQuietStart
    @AppStorage(HealthAlertDefaults.quietEndMinutes) private var quietEnd = HealthAlertDefaults.defaultQuietEnd

    var body: some View {
        Form {
            Section("Profile") {
                Stepper(value: $age, in: 13...120) {
                    LabeledContent("Age", value: "\(age)")
                }
                LabeledContent("Weight") {
                    HStack(spacing: 4) {
                        TextField("lb", value: weightLb, format: .number.precision(.fractionLength(0)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("lb").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Height") {
                    HStack(spacing: 4) {
                        TextField("ft", value: $heightFeetInput, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 36)
                            .onChange(of: heightFeetInput) { _, _ in commitHeight() }
                        Text("ft").foregroundStyle(.secondary)
                        TextField("in", value: $heightInchesInput, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 36)
                            .onChange(of: heightInchesInput) { _, newValue in
                                // A typed value ≥12 (or negative) snaps back into 0...11.
                                let clamped = min(max(newValue, 0), 11)
                                if clamped != newValue { heightInchesInput = clamped }
                                commitHeight()
                            }
                        Text("in").foregroundStyle(.secondary)
                    }
                    .onAppear { seedHeightInputs() }
                }
                Picker("Sex", selection: $sexRaw) {
                    ForEach(BiologicalSex.allCases, id: \.rawValue) { sex in
                        Text(sex.rawValue.capitalized).tag(sex.rawValue)
                    }
                }
            }

            Section("Apple Health") {
                if healthAuthorized {
                    LabeledContent("Status") {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    }
                    Text("OpenCircuit is writing your ring's metrics into Apple Health.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if HealthKitWriter.isAvailable {
                    Button {
                        Task {
                            do {
                                try await health.requestAuthorization()
                            } catch {
                                // Thrown only when the HealthKit entitlement is absent — the
                                // signature of a free-Apple-ID sideload (the entitlement is paid-
                                // account only and is stripped on re-sign). Surface it; the app
                                // still works as a local dashboard. (#104)
                                healthUnavailable = true
                            }
                            healthAuthorized = health.isShareAuthorized
                            if healthAuthorized { healthUnavailable = false }
                        }
                    } label: {
                        Label("Connect Apple Health", systemImage: "heart.text.square")
                    }
                    if healthUnavailable {
                        Text("This build can't write to Apple Health — that needs the TestFlight "
                             + "build. (Free side-loaded builds can't use HealthKit.) OpenCircuit "
                             + "still works as a local dashboard.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Write your ring's heart rate, HRV, SpO₂, temperature, sleep and more "
                             + "into Apple Health. If you previously declined, turn OpenCircuit on in "
                             + "Settings ▸ Health ▸ Data Access & Devices.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Apple Health isn't available on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .task { healthAuthorized = health.isShareAuthorized }

            Section("Tracking") {
                Toggle("Auto-measure HR & SpO₂", isOn: $autoMeasureEnabled)
                Text("While connected, the ring re-measures heart rate (~every 10 min) and "
                     + "blood oxygen on its own, so the dashboard stays fresh — like the "
                     + "official app. Uses more ring battery; turn off to measure only on tap.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sleep schedule") {
                Toggle("Use manual sleep schedule", isOn: $sleepEnabled)
                if sleepEnabled {
                    DatePicker("Bedtime", selection: bedTimeBinding,
                               displayedComponents: .hourAndMinute)
                    DatePicker("Wake", selection: wakeTimeBinding,
                               displayedComponents: .hourAndMinute)
                }
                Text("Bounds the overnight skin-temp window. When Apple Health is "
                     + "authorized, your iOS Sleep schedule is used instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Daily goals") {
                Stepper(value: $workdaySteps, in: 1_000...30_000, step: 500) {
                    LabeledContent("Weekday steps", value: workdaySteps.formatted())
                }
                Stepper(value: $weekendSteps, in: 1_000...30_000, step: 500) {
                    LabeledContent("Weekend steps", value: weekendSteps.formatted())
                }
                Stepper(value: $activeKcalGoal, in: 50...1_500, step: 25) {
                    LabeledContent("Active calories", value: "\(Int(activeKcalGoal)) kcal")
                }
                Stepper(value: $actMinGoal, in: 5...180, step: 5) {
                    LabeledContent("Exercise minutes", value: "\(Int(actMinGoal)) min")
                }
                Stepper(value: $workdaySleepMin, in: 240...600, step: 15) {
                    LabeledContent("Weekday sleep", value: formatGoalSleep(workdaySleepMin))
                }
                Stepper(value: $weekendSleepMin, in: 240...600, step: 15) {
                    LabeledContent("Weekend sleep", value: formatGoalSleep(weekendSleepMin))
                }
                Text("Progress rings on the dashboard show today's goal vs. actual. Exercise minutes = elevated-HR minutes (basic threshold estimate), independent of steps/calories.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Health alerts") {
                Toggle("High heart rate", isOn: $highHREnabled)
                if highHREnabled {
                    Stepper(value: $highHRBpm, in: 80...200, step: 5) {
                        LabeledContent("Notify above", value: "\(highHRBpm) bpm")
                    }
                }
                Toggle("Low blood oxygen", isOn: $lowSpO2Enabled)
                if lowSpO2Enabled {
                    Stepper(value: $lowSpO2Percent, in: 80...99) {
                        LabeledContent("Notify below", value: "\(lowSpO2Percent)%")
                    }
                }
                Toggle("Elevated HR while inactive", isOn: $elevatedHREnabled)
                if elevatedHREnabled {
                    Stepper(value: $elevatedHRBpm, in: 80...160, step: 5) {
                        LabeledContent("Sustained above", value: "\(elevatedHRBpm) bpm")
                    }
                    Text("Notifies if heart rate stays above this for 10 minutes while inactive. "
                         + "Sharpens once activity detection lands.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Skin-temp & fever alerts", isOn: $tempFeverEnabled)
                Text("Note: OpenCircuit is not a medical device. These reminders are based on ring "
                     + "sensor data only and are not a diagnosis. If you feel unwell, consult a "
                     + "qualified medical professional.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Women's health") {
                Toggle("Show cycle calendar", isOn: $womensHealthEnabled)
                Text("Enables period logging, cycle predictions, and a menstrual-flow "
                     + "write to Apple Health. The feature is hidden by default — only "
                     + "turn it on if you want it. Predictions are estimates only and "
                     + "are not a contraception tool or medical advice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Toggle("Mute alerts overnight", isOn: $quietEnabled)
                if quietEnabled {
                    DatePicker("From", selection: timeBinding($quietStart),
                               displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding($quietEnd),
                               displayedComponents: .hourAndMinute)
                }
                Text("Health alerts are held during this window (delivered once it ends if still "
                     + "relevant).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: Reminders (#84)
            Section("Reminders") {
                Toggle("Sedentary / move reminder", isOn: $sedentaryEnabled)
                if sedentaryEnabled {
                    Stepper(value: $sedentaryIntervalMin, in: 30...120, step: 10) {
                        LabeledContent("Remind after", value: "\(sedentaryIntervalMin) min inactive")
                    }
                }
                Toggle("Wear reminder", isOn: $wearEnabled)
                Toggle("Bedtime reminder", isOn: $bedtimeEnabled)
                if bedtimeEnabled {
                    Stepper(value: $bedtimeMinutesBefore, in: 15...60, step: 15) {
                        LabeledContent("Warn before bed", value: "\(bedtimeMinutesBefore) min")
                    }
                }
                Text("Reminder quiet hours and backoff use the same settings as health alerts above.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: Workouts
            Section("Workouts") {
                Toggle("Keep tracking when screen is off", isOn: $indoorKeepAlive)
                Text("For indoor workouts (strength, yoga), keep recording heart rate while your "
                     + "phone is locked. Uses location to stay active, so the blue location "
                     + "indicator shows and battery use is higher — no location is stored. Outdoor "
                     + "workouts always keep tracking via GPS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: Units (#83)
            Section("Units") {
                Picker("Temperature", selection: $tempUnitRaw) {
                    Text("°C").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                }
                Picker("Distance", selection: $distUnitRaw) {
                    Text("km").tag(DistanceUnit.metric.rawValue)
                    Text("mi").tag(DistanceUnit.imperial.rawValue)
                }
                Text("Affects how temperature and distance values are shown throughout the app. "
                     + "Values are always stored in metric internally.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: Data export (#80)
            Section("Data export") {
                NavigationLink {
                    ExportView()
                } label: {
                    Label("Export health data", systemImage: "square.and.arrow.up")
                }
                Text("Export all stored ring data (HR, SpO₂, sleep, steps) as CSV or JSON "
                     + "for your own analysis. Data stays on your device unless you share it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: About / legal (#100 rebrand, #101 privacy)
            Section("About") {
                LabeledContent("App", value: "OpenCircuit")
                LabeledContent("Version", value: appVersion)
                Link(destination: URL(string: Self.privacyPolicyURL)!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Text("OpenCircuit is an independent, local-first app compatible with the RingConn "
                     + "Gen 2 smart ring. It is not affiliated with, authorized, or endorsed by "
                     + "RingConn or JZ_Tech; \"RingConn\" is a trademark of its respective owner. "
                     + "Your data stays on your device and is written only to Apple Health — nothing "
                     + "is sent to any server. OpenCircuit is not a medical device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .navigationTitle("User Profile")
    }

    // MARK: Goal helpers

    private func formatGoalSleep(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    // MARK: About helpers
    /// Privacy policy (required for HealthKit). GitHub renders the markdown as a reachable page;
    /// swap for a GitHub Pages URL when one is set up (#101).
    private static let privacyPolicyURL = "https://github.com/perezjuanj/OpenCircuit/blob/master/docs/PRIVACY.md"
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    // MARK: Imperial display over metric storage
    // Storage stays kg/cm (OpenCircuitKit's BMR math expects metric); these bindings present
    // and edit it in lb / ft+in, converting on the way through.

    private static let lbPerKg = 2.2046226218
    private static let cmPerIn = 2.54

    private var weightLb: Binding<Double> {
        Binding(get: { weightKg * Self.lbPerKg },
                set: { weightKg = max($0, 0) / Self.lbPerKg })
    }

    /// Total height in whole inches (rounded), the basis for the ft/in split.
    private var totalInches: Int { Int((heightCm / Self.cmPerIn).rounded()) }

    /// Seed the local ft/in editing fields from the stored height. Done on appear so the text
    /// fields hold their own state and typing isn't reset by the shared `heightCm` store.
    private func seedHeightInputs() {
        let total = totalInches
        heightFeetInput = total / 12
        heightInchesInput = total % 12
    }

    /// Write the local ft/in fields back to `heightCm`, clamping inches to 0...11.
    private func commitHeight() {
        let feet = max(heightFeetInput, 0)
        let inches = min(max(heightInchesInput, 0), 11)
        heightCm = Double(feet * 12 + inches) * Self.cmPerIn
    }

    // MARK: Sleep-schedule bindings (minutes-since-midnight <-> Date for DatePicker)

    private var bedTimeBinding: Binding<Date> { timeBinding($bedMinutes) }
    private var wakeTimeBinding: Binding<Date> { timeBinding($wakeMinutes) }

    /// Bridges an `Int` minutes-since-midnight store to a `Date` an `.hourAndMinute`
    /// `DatePicker` can edit (anchored to today; only the time component is used).
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        let cal = Calendar.current
        return Binding(
            get: {
                cal.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
            },
            set: { newValue in
                let c = cal.dateComponents([.hour, .minute], from: newValue)
                minutes.wrappedValue = SleepWindow.minutes(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
        )
    }
}
