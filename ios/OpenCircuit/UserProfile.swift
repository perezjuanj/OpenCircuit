import SwiftUI
import UIKit
import UserNotifications
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

    /// Presents the onboarding/welcome flow again from About ▸ "How it works" (#103).
    @State private var showOnboarding = false

    // Apple Health connection. Auth lives here so there's ALWAYS a reachable entry point — the
    // dashboard's authorize button is a post-sync nudge that only appears when there's un-synced
    // history. `health` queries the shared HKHealthStore, so its status matches the dashboard's.
    private let health = HealthKitWriter()
    private let historyInspector = HealthKitHistoryInspector()
    @State private var healthAuthorized = false
    @State private var healthUnavailable = false
    /// Tri-state Health share status (#132): a PARTIAL grant (heart rate on, another type off) must
    /// not read as a plain "Connected" while those metrics silently never reach Health.
    @State private var healthShareState: HealthKitWriter.ShareState = .unauthorized
    /// Persisted per-metric Health write failures (#135), surfaced here alongside the partial-grant
    /// state so Profile and the dashboard tell one consistent story.
    @State private var healthWriteFailures: [MetricKind] = []
    /// The one-time iOS permission sheet was already used (declined) — `requestAuthorization`
    /// would silently no-op, so the button must route to the Health app instead. Re-probed on
    /// appear, on foreground return (the user may have just flipped the toggles), and after a
    /// live decline.
    @State private var healthPromptExhausted = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var historicalReport: HealthKitHistoryInspector.Report?
    @State private var historicalCheckError: String?
    @State private var historicalCheckRunning = false

    // Periodic background recording toggle — same UserDefaults key RingSession reads. Default true
    // so connected sessions keep recording fresh HR/SpO₂ samples without requiring a foreground
    // live-measure screen; flip off to save ring battery.
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

    // Local calibration server + BP estimate Health writeback.
    @AppStorage(CalibrationDefaults.baseURLKey) private var calibrationBaseURL = CalibrationDefaults.defaultBaseURL
    @AppStorage(CalibrationDefaults.apiTokenKey) private var calibrationAPIToken = ""
    @AppStorage(CalibrationDefaults.autoWriteBPToHealthKey) private var autoWriteBPToHealth = false

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

    /// System notification-authorization status, surfaced so the alert / quiet-hours / reminder
    /// settings warn when delivery is off (#136). Refreshed on appear + on scene-active (the user
    /// may flip it in iOS Settings while away). `.provisional`/`.ephemeral` still deliver (quietly),
    /// so they are treated as OK — no banner. Read-only here: opening Settings never itself requests
    /// authorization (the lazy-prompt design is preserved).
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

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
                    let missing = healthAttentionNames
                    if missing.isEmpty {
                        LabeledContent("Status") {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.green)
                        }
                        Text("OpenCircuit is writing your ring's metrics into Apple Health.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        // A partial grant (#132) or a persisted write failure (#135): don't claim a
                        // blanket "Connected" while these metrics silently never reach Health.
                        LabeledContent("Status") {
                            Label("Partial", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.orange)
                        }
                        Text("These aren't reaching Apple Health: \(missing.joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            openURL(HealthKitWriter.healthAppURL)
                        } label: {
                            Label("Review in the Health App", systemImage: "heart.text.square")
                        }
                    }
                } else if HealthKitWriter.isAvailable {
                    if healthPromptExhausted {
                        // iOS shows the permission sheet once, ever — after a decline,
                        // requestAuthorization is a silent no-op (the "dead button" bug). The
                        // only remaining path is Health's own toggles, so take the user there.
                        Button {
                            openURL(HealthKitWriter.healthAppURL)
                        } label: {
                            Label("Turn On in the Health App", systemImage: "heart.text.square")
                        }
                        Text("Health access was declined earlier, and iOS only shows that "
                             + "prompt once. Tap above to open Health, then: profile picture "
                             + "▸ Privacy ▸ Apps ▸ OpenCircuit — switch on what you'd like to "
                             + "share. It takes effect the moment you come back.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
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
                                await refreshHealthAuthState()
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
                                 + "into Apple Health.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Apple Health isn't available on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if HealthKitWriter.isAvailable {
                    Button {
                        Task { await runHistoricalHealthCheck() }
                    } label: {
                        Label("Check historical baseline data", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .disabled(historicalCheckRunning)
                    if historicalCheckRunning {
                        ProgressView("Scanning Apple Health history…")
                            .font(.caption)
                    }
                    if let historicalReport {
                        HistoricalHealthCheckView(report: historicalReport)
                    } else if let historicalCheckError {
                        Text(historicalCheckError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Read the last 30 days of Apple Health history to see whether missing baseline inputs can be recovered there before adding a full reverse import.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task { await refreshHealthAuthState() }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from the Health app: reflect freshly-flipped toggles immediately.
                if phase == .active { Task { await refreshHealthAuthState() } }
            }

            Section("Tracking") {
                Toggle("Auto-record HR & SpO₂", isOn: $autoMeasureEnabled)
                Text("While connected, OpenCircuit periodically records heart rate (~every 10 min) "
                     + "and blood oxygen in the background so the app and Apple Health pick up fresh "
                     + "samples without relying on a live home-screen reading. Uses more ring battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Calibration server") {
                TextField("Base URL", text: $calibrationBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("API token (optional)", text: $calibrationAPIToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Write BP estimates to Apple Health", isOn: $autoWriteBPToHealth)
                Text("Used by the cuff + PPG calibration flow. OpenCircuit uploads raw PPG to `/ppg/import`, optional ECG to `/ecg/raw-import`, and calibration metadata to `/calibration/session`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                notifAuthBanner
                Toggle("High heart rate", isOn: $highHREnabled)
                    .onChange(of: highHREnabled) { _, on in escalateNotifAuth(enabled: on) }
                if highHREnabled {
                    Stepper(value: $highHRBpm, in: 80...200, step: 5) {
                        LabeledContent("Notify above", value: "\(highHRBpm) bpm")
                    }
                }
                Toggle("Low blood oxygen", isOn: $lowSpO2Enabled)
                    .onChange(of: lowSpO2Enabled) { _, on in escalateNotifAuth(enabled: on) }
                if lowSpO2Enabled {
                    Stepper(value: $lowSpO2Percent, in: 80...99) {
                        LabeledContent("Notify below", value: "\(lowSpO2Percent)%")
                    }
                }
                Toggle("Elevated HR while inactive", isOn: $elevatedHREnabled)
                    .onChange(of: elevatedHREnabled) { _, on in escalateNotifAuth(enabled: on) }
                if elevatedHREnabled {
                    Stepper(value: $elevatedHRBpm, in: 80...160, step: 5) {
                        LabeledContent("Sustained above", value: "\(elevatedHRBpm) bpm")
                    }
                    Text("Notifies if heart rate stays above this for 10 minutes while inactive. "
                         + "Sharpens once activity detection lands.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Skin-temp & fever alerts", isOn: $tempFeverEnabled)
                    .onChange(of: tempFeverEnabled) { _, on in escalateNotifAuth(enabled: on) }
                Text("Note: OpenCircuit is not a medical device. These reminders are based on ring "
                     + "sensor data only and are not a diagnosis. If you feel unwell, consult a "
                     + "qualified medical professional.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .task { await refreshNotifAuthState() }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from iOS Settings: reflect a freshly-flipped notification switch
                // (enabled or disabled) in the banner without an app relaunch (#136).
                if phase == .active { Task { await refreshNotifAuthState() } }
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
                Button {
                    showOnboarding = true
                } label: {
                    Label("How it works", systemImage: "sparkles")
                }
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
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
    }

    // MARK: Goal helpers

    /// Re-probe Health share status and whether the one-time permission sheet is still
    /// available. A live decline flips the button to the Health-app route on the spot; flipping
    /// the toggles in Health and returning flips it back to Connected.
    private func refreshHealthAuthState() async {
        healthAuthorized = health.isShareAuthorized
        // Recompute the honest partial-grant (#132) + persisted write-failure (#135) surfaces at the
        // same points, since the user can flip a type off in the Health app while away.
        healthShareState = health.shareState
        healthWriteFailures = HealthKitWriter.healthWriteFailures().keys.sorted { $0.rawValue < $1.rawValue }
        if healthAuthorized {
            healthUnavailable = false
            healthPromptExhausted = false
        } else if HealthKitWriter.isAvailable {
            // nil = status unknown (entitlement-stripped sideload): keep the Connect button so
            // its tap path can throw and surface the sideload notice, as before.
            healthPromptExhausted = (await health.authorizationPromptAvailable()) == false
        }
    }

    // MARK: Notification-auth banner (#136) + full-auth escalation (#133)

    /// Warns when notifications can't reach the user so the alert / quiet-hours / reminder controls
    /// below don't read as "armed" when they're silently dropped (#136). Shown once at the top of the
    /// "Health alerts" section — it visually covers Quiet hours and Reminders too, which share the
    /// same app-wide authorization. `.authorized`/`.provisional`/`.ephemeral` all still deliver, so
    /// no banner then. Mirrors the "dead button" precedent in the Apple Health section above.
    @ViewBuilder private var notifAuthBanner: some View {
        switch notifStatus {
        case .denied:
            Label {
                Text("Notifications are turned off for OpenCircuit, so no alerts or reminders "
                     + "can be delivered.")
            } icon: {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("Turn On in Settings", systemImage: "arrow.up.forward.app")
            }
        case .notDetermined:
            // Soft hint only — matches the lazy-authorization design (the engine prompts on the
            // first real post, #133). Do NOT eagerly request auth from this screen.
            Text("iOS will ask permission the first time an alert needs to fire.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// Read (never request) the system notification-authorization status for the banner (#136).
    private func refreshNotifAuthState() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Opting into a body-vital alert is a foreground consent moment: escalate a provisional (or
    /// not-yet-determined) grant to FULL alert+sound+badge auth so the alert the user JUST enabled
    /// won't deliver silently under a provisional grant the morning-summary/observability paths won
    /// first (#133). No-op when the toggle is turned OFF. The one-time flag guard + the actual
    /// request live in `HealthNotificationCenter.requestFullAuthorizationIfNeeded()` so the engine
    /// and the UI share one policy. Refreshes the banner afterward to reflect the new grant.
    private func escalateNotifAuth(enabled: Bool) {
        guard enabled else { return }
        Task {
            await HealthNotificationCenter().requestFullAuthorizationIfNeeded()
            await refreshNotifAuthState()
        }
    }

    /// Friendly names of metrics not reaching Health: partial-grant denied types (#132) unioned with
    /// persisted per-metric write failures (#135), de-duplicated and sorted. Empty ⇒ fully connected.
    private var healthAttentionNames: [String] {
        var names = Set<String>()
        if case .partial(let denied) = healthShareState {
            names.formUnion(HealthKitWriter.friendlyNames(for: denied))
        }
        names.formUnion(healthWriteFailures.map(\.displayName))
        return names.sorted()
    }

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

    private func runHistoricalHealthCheck() async {
        historicalCheckRunning = true
        historicalCheckError = nil
        defer { historicalCheckRunning = false }
        do {
            if !healthAuthorized {
                try await health.requestAuthorization()
                healthAuthorized = health.isShareAuthorized
            }
            historicalReport = try await historyInspector.inspectHistoricalCoverage()
            if historicalReport?.nightsFound == 0 {
                historicalCheckError = "No qualifying overnight Apple Health sleep history was found in the last 30 days, or OpenCircuit does not have Health read permission yet."
            }
        } catch {
            historicalReport = nil
            historicalCheckError = "Couldn't read Apple Health history on this build."
        }
    }
}
