import SwiftUI
import OpenCircuitKit

// The strap's workout screens (#227): the same layout as the ring's `WorkoutView` (sport picker →
// live session → summary, with its `SportButton` and `ZoneBarRow`), plus pause/resume and the
// strap's own honesty notes. The ring's view is not changed.

struct StrapWorkoutView: View {
    let recorder: StrapWorkoutRecorder
    let session: HelioSession?
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var hrSize: CGFloat = 40
    @AppStorage("units.distance") private var distUnitRaw = DistanceUnit.localeDefault.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distUnitRaw) ?? .metric }

    var body: some View {
        NavigationStack {
            Group {
                switch recorder.state {
                case .idle:
                    idleView
                case .active:
                    activeView
                case .finishing:
                    ProgressView("Saving workout…").padding()
                case .finished(let summary, let saved):
                    summaryView(summary, saved: saved)
                case .error(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                        Text("Workout error").font(.title3.weight(.semibold))
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("Dismiss") { recorder.reset(); dismiss() }.buttonStyle(.bordered)
                    }
                    .padding()
                }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if recorder.state == .idle { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // As the ring's: closing the sheet only puts the recording in the background.
                    if recorder.isRecording { Button("Minimize") { dismiss() } }
                }
            }
        }
    }

    // MARK: Idle

    private var idleView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("SELECT SPORT")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                    ForEach(WorkoutSportType.allCases, id: \.rawValue) { sport in
                        SportButton(sport: sport, selected: recorder.selectedSport == sport) {
                            recorder.selectedSport = sport
                        }
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("OpenCircuit records this workout on your phone: heart rate from the strap once a second, and your phone's location outdoors. The strap keeps no workout record of its own. If the strap disconnects, the workout keeps running and the gap is shown; nothing is filled in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
                if recorder.selectedSport.isOutdoor {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill").foregroundStyle(.blue)
                        Text("GPS route will be captured using your phone's location.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    recorder.start()
                } label: {
                    Label("Start Workout", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!recorder.canStart(session))
                if let reason = startBlockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }

    private var startBlockedReason: String? {
        guard let session else { return "Connect the strap to start a workout." }
        if session.syncing { return "Waiting for the strap's sync to finish…" }
        if !session.ready { return "Connect the strap to start a workout." }
        if !session.canStreamHeartRate { return "Workouts need the strap's live heart rate, which needs its key." }
        return nil
    }

    // MARK: Active

    private var activeView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(Self.clock(recorder.activeSeconds))
                    .font(.system(size: timerSize, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(recorder.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(recorder.isPaused ? "PAUSED" : recorder.selectedSport.displayName.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recorder.isPaused ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .padding(.top, 8)

            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let hr = recorder.currentHR, !recorder.linkDown {
                            Text("\(hr)").font(.system(size: hrSize, weight: .bold, design: .rounded))
                                .monospacedDigit().contentTransition(.numericText())
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .foregroundStyle(recorder.currentHRIsStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        } else {
                            Text("--").font(.system(size: hrSize, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.secondary)
                        }
                        Text("bpm").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if recorder.linkDown {
                        Text("strap disconnected").font(.caption2).foregroundStyle(.orange)
                    } else if recorder.currentHR == nil || recorder.currentHRIsStale {
                        Text("measuring…").font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("Heart Rate").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    Text("\(recorder.hrSampleCount)").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Readings").font(.caption2).foregroundStyle(.secondary)
                }
                if recorder.selectedSport.isOutdoor {
                    Spacer()
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(String(format: "%.2f", distanceUnit.convert(fromMeters: recorder.location.distanceMeters ?? 0)))
                                .font(.title2.weight(.semibold)).monospacedDigit()
                            Text(distanceUnit.symbol).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 3) {
                            if recorder.location.gpsActive {
                                Image(systemName: "location.fill").font(.caption2).foregroundStyle(.blue)
                            }
                            Text("Distance").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("HR ZONES (live)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(HRZone.allCases, id: \.rawValue) { zone in
                    ZoneBarRow(zone: zone,
                               seconds: recorder.liveZoneBreakdown.seconds(in: zone),
                               fraction: recorder.liveZoneBreakdown.fraction(in: zone))
                }
            }
            .padding(.horizontal)

            Spacer()

            if recorder.linkDown {
                notice("antenna.radiowaves.left.and.right.slash",
                       "The strap is disconnected. The workout keeps running, and heart rate resumes when it reconnects.")
            } else if recorder.isPaused {
                notice("pause.circle", "Paused. Time, heart rate and distance aren't counted until you resume.")
            }
            if recorder.location.keepAliveUnavailable {
                notice("exclamationmark.triangle.fill",
                       "Location is off, so tracking will pause when the screen locks. Keep the app open, or enable location for OpenCircuit in Settings.")
            }

            HStack(spacing: 12) {
                Button {
                    if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                } label: {
                    Label(recorder.isPaused ? "Resume" : "Pause",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button(role: .destructive) {
                    Task { await recorder.end() }
                } label: {
                    Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private func notice(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: Summary

    private func summaryView(_ result: StrapWorkoutSummary, saved: Bool) -> some View {
        let summary = result.summary
        return ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: summary.sport.systemImageName).font(.system(size: 40)).foregroundStyle(.blue)
                    Text(summary.sport.displayName).font(.title2.weight(.bold))
                    Text(summary.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCell("Duration", Self.duration(result.activeSeconds))
                    statCell("Avg HR", summary.avgHR.map { "\($0) bpm" } ?? "--")
                    statCell("Max HR", summary.maxHR.map { "\($0) bpm" } ?? "--")
                    statCell("Active Cal (est.)", summary.estimatedActiveKcal.map { "\(Int($0.rounded())) kcal" } ?? "--")
                    statCell("HR Readings", "\(summary.hrSampleCount)")
                    if let distance = summary.distanceMeters {
                        statCell("Distance", UnitsFormatter.distance(distance, unit: distanceUnit, fractionDigits: 2))
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("HR ZONE DISTRIBUTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if summary.zoneBreakdown.totalZoneSeconds > 0 {
                        ForEach(HRZone.allCases, id: \.rawValue) { zone in
                            ZoneBarRow(zone: zone, seconds: summary.zoneBreakdown.seconds(in: zone),
                                       fraction: summary.zoneBreakdown.fraction(in: zone))
                        }
                    } else {
                        Text("No HR zone data captured (no readings from the strap).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // Training load, and the VO₂ max estimate for an outdoor run (#232) — the ring's
                // section, over the strap's heart rate.
                WorkoutTrainingMetricsSection(summary: summary,
                                              vo2Outcome: recorder.vo2MaxOutcome,
                                              vo2HealthStatus: recorder.vo2MaxHealthStatus,
                                              distanceUnit: distanceUnit)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    noteRow("iphone", .secondary,
                            "Duration, calories and zones are OpenCircuit's own, worked out on your phone from the strap's live heart rate\(summary.hasRoute ? " and your phone's location" : ""). The strap made no record of this workout.")
                    if !result.pauses.isEmpty {
                        noteRow("pause.circle", .secondary,
                                "Paused \(result.pauses.count) time\(result.pauses.count == 1 ? "" : "s") for \(Self.duration(result.pauses.reduce(0) { $0 + $1.duration })) in total; that time isn't counted.")
                    }
                    if result.gapSeconds >= 1 {
                        noteRow("antenna.radiowaves.left.and.right.slash", .orange,
                                "No heart rate for \(Self.duration(result.gapSeconds)) while the strap was disconnected. That time has no readings and no zone time.")
                    }
                    if summary.estimatedActiveKcal != nil {
                        noteRow("info.circle", .secondary, summary.hrSampleCount > 0
                                ? "Active calories are an ESTIMATE (from your heart rate, active time, age and body mass; not strap sensor data)."
                                : "Active calories are an ESTIMATE (from GPS distance x body mass; no heart rate was recorded).")
                    }
                    if summary.hrSampleCount > 0 {
                        // Diagnostic (on-demand HRV needs beat-to-beat intervals; whether the Helio
                        // sends them is unknown, ZEPP_PROTOCOL.md §7.1).
                        noteRow("waveform.path.ecg", .secondary, recorder.rrIntervalCount > 0
                                ? "The strap sent beat-to-beat (RR) intervals during this workout (\(recorder.rrIntervalCount))."
                                : "The strap sent no beat-to-beat (RR) intervals during this workout, only heart rate.")
                    }
                    if summary.hasRoute {
                        noteRow("location.fill", .blue, saved ? "GPS route captured and saved to Apple Health." : "GPS route captured.")
                    } else if summary.sport.isOutdoor {
                        noteRow("location.slash", .secondary, "No GPS route — location access is off for OpenCircuit.")
                    }
                    if saved {
                        noteRow("checkmark.circle", .green, "Workout saved to Apple Health.")
                    } else {
                        noteRow("exclamationmark.triangle", .orange, "Apple Health didn't accept this workout, so it isn't in Health.")
                    }
                }
                .padding(.horizontal)

                Button("Done") { recorder.reset(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func noteRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Formatting (the ring's shapes)

    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, s)
    }
}

// MARK: - The Activity tab's entry

/// The strap's WORKOUT card, the ring's card's twin (`ContentView.workoutCard`), with the same way
/// back into a running session.
struct StrapWorkoutCard: View {
    let recorder: StrapWorkoutRecorder
    @Binding var show: Bool

    var body: some View {
        Button { show = true } label: {
            OCCard {
                HStack(spacing: 8) {
                    Image(systemName: "figure.run").foregroundStyle(.blue)
                    Text("WORKOUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                if recorder.isRecording {
                    Label("\(recorder.isPaused ? "Paused" : "Recording") \(recorder.selectedSport.displayName) — tap to open",
                          systemImage: recorder.isPaused ? "pause.circle" : "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(recorder.isPaused ? .orange : .red)
                } else {
                    Text("Record a workout with the strap's heart rate, zones + GPS route (outdoor)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hooks on the dashboard

/// Everything the strap's workout hangs on `ContentView`, in one modifier: the sheet, the launch-time
/// recovery offer and landing pass, and the interrupted-workout alert. For a ring-only install the
/// launch work reads one absent file and does nothing.
struct StrapWorkoutHooks: ViewModifier {
    let recorder: StrapWorkoutRecorder
    let session: HelioSession?
    @Binding var show: Bool
    let onWorkoutsChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .task {
                recorder.resolveOrphan()
                recorder.landPendingHeartRate()
                if recorder.recoverable != nil { show = false }
            }
            .sheet(isPresented: $show, onDismiss: {
                onWorkoutsChanged()
                // A terminal state must not outlive its sheet (the ring's rule, same reason).
                switch recorder.state {
                case .finished, .error: recorder.reset()
                default: break
                }
            }) {
                StrapWorkoutView(recorder: recorder, session: session)
            }
            .alert("Interrupted workout", isPresented: Binding(
                get: { recorder.recoverable != nil },
                set: { if !$0 { recorder.postponeRecovered() } })
            ) {
                Button("Save to Health") {
                    Task {
                        if await recorder.saveRecovered() { onWorkoutsChanged() }
                    }
                }
                Button("Discard", role: .destructive) { recorder.discardRecovered() }
                Button("Not Now", role: .cancel) { recorder.postponeRecovered() }
            } message: {
                if let recovered = recorder.recoverable { Text(Self.message(recovered)) }
            }
    }

    static func message(_ recovered: RecoveredStrapWorkout) -> String {
        let start = recovered.ledger.start.formatted(date: .abbreviated, time: .shortened)
        let readings = recovered.samples.count
        return "OpenCircuit closed during a strap workout on \(start). It can be saved as "
            + "\(recovered.sport.displayName), \(StrapWorkoutView.duration(recovered.activeSeconds)) long, "
            + "with \(readings) heart-rate reading\(readings == 1 ? "" : "s"). It ends at the last reading the "
            + "app received, so it may be short. The GPS route isn't kept."
    }
}
