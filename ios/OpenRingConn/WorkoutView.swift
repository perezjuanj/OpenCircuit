// WorkoutView.swift — Workout session UI: sport picker → live session → summary.
//
// Structure:
//   • Idle:    sport picker + Start button
//   • Active:  live duration, live HR, zone bars, GPS distance (outdoor)
//   • Summary: duration, avg/max HR, 5-zone bar chart, distance (outdoor), HealthKit note
//
// IMPORTANT — Issue #45 (live HR flakiness):
//   Live HR during a workout is best-effort. The ring's 0x95→0x15 on-demand poll has no
//   background refresh and frequently misses updates during a long session. HR gaps are
//   displayed honestly; the data shown is ONLY from actual decoded readings — never
//   fabricated or interpolated. A disclaimer note is shown during active sessions.

import SwiftUI
import OpenRingKit

// MARK: - Main view

struct WorkoutView: View {
    let session: RingSession?
    @State private var manager = WorkoutSessionManager()
    @Environment(\.dismiss) private var dismiss

    // Distance display unit (#83) — same key/default as UserProfileSettingsView. Storage stays in
    // metres (manager.distanceMeters); only the display converts. @AppStorage re-renders the live
    // and summary distance when the user flips the toggle. `?? .metric` mirrors the temp sites.
    @AppStorage("units.distance") private var distUnitRaw = DistanceUnit.localeDefault.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distUnitRaw) ?? .metric }

    /// True while a session is starting/active (recording in progress).
    private var isRecording: Bool {
        switch manager.recordingState {
        case .starting, .active: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch manager.recordingState {
                case .idle:
                    idleView
                case .starting, .active:
                    activeView
                case .finishing:
                    ProgressView("Saving workout…")
                        .padding()
                case .finished(let summary):
                    summaryView(summary)
                case .error(let msg):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(.orange)
                        Text("Workout error").font(.title3.weight(.semibold))
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                        Button("Dismiss") { manager.reset(); dismiss() }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .idle = manager.recordingState {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        // Block interactive swipe-to-dismiss while recording so the session can't be abandoned
        // mid-workout (which would leave the ring stuck polling and silently drop the workout).
        .interactiveDismissDisabled(isRecording)
        // Guarantee teardown if the sheet is dismissed any other way while still recording:
        // stop() cancels the poll/timer tasks, calls session.stopLiveMonitoring() (so the ring
        // stops live-HR polling), and writes the in-progress workout to HealthKit. No-op once
        // the session has already finished/idled (stop() guards its own state). (#75)
        .onDisappear {
            if isRecording { Task { await manager.stop() } }
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 24) {
            Text("SELECT SPORT")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                ForEach(WorkoutSportType.allCases, id: \.rawValue) { sport in
                    SportButton(sport: sport, selected: manager.selectedSport == sport) {
                        manager.selectedSport = sport
                    }
                }
            }

            Spacer()

            // Best-effort HR note (#45)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Live heart rate during workouts is best-effort (issue #45: on-demand polling, no background refresh). HR gaps will be shown honestly — data is never fabricated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))

            if manager.selectedSport.isOutdoor {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                    Text("GPS route will be captured using your phone's location.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button {
                guard let session else { return }
                manager.selectedSport = manager.selectedSport
                manager.start(session: session)
            } label: {
                Label("Start Workout", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Also blocked during a #99 stream probe — it owns the link, so workout HR couldn't
            // start (and would silently record nothing) until the ~45 s sweep finishes (review P3).
            .disabled(session == nil || session?.ready != true || session?.probing == true)

            if session == nil || session?.ready != true {
                Text("Connect to the ring before starting a workout.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if session?.probing == true {
                Text("Finishing an all-day HR/SpO₂ stream probe… you can start a workout in a moment.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Active

    private var activeView: some View {
        VStack(spacing: 20) {
            // Duration
            VStack(spacing: 4) {
                Text(formattedElapsed)
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(manager.selectedSport.displayName.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            // Live HR
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // Show the last REAL reading; dim it once it ages out (the ring's spot-read
                        // can't lock under motion — we never pretend a held value is live, #45).
                        if let hr = manager.currentHR {
                            Text("\(hr)").font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit().contentTransition(.numericText())
                                .foregroundStyle(manager.currentHRIsStale ? AnyShapeStyle(.secondary)
                                                                          : AnyShapeStyle(.red))
                        } else {
                            Text("--").font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Text("bpm").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if manager.currentHR == nil || manager.currentHRIsStale {
                        Text("measuring…").font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("Heart Rate").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    Text("\(manager.hrSampleCount)")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Readings").font(.caption2).foregroundStyle(.secondary)
                }
                if manager.selectedSport.isOutdoor {
                    Spacer()
                    VStack(spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(distanceText)
                                .font(.title2.weight(.semibold)).monospacedDigit()
                            Text(distanceUnit.symbol).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 3) {
                            if manager.gpsActive {
                                Image(systemName: "location.fill")
                                    .font(.caption2).foregroundStyle(.blue)
                            }
                            Text("Distance").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            // Live zone bars
            VStack(alignment: .leading, spacing: 8) {
                Text("HR ZONES (live)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(HRZone.allCases, id: \.rawValue) { zone in
                    ZoneBarRow(
                        zone: zone,
                        seconds: manager.liveZoneBreakdown.seconds(in: zone),
                        fraction: manager.liveZoneBreakdown.fraction(in: zone)
                    )
                }
            }
            .padding(.horizontal)

            Spacer()

            // Indoor keep-alive needs location to hold the app alive while locked; if it's not
            // granted, the opt-in can't work — say so rather than failing silently.
            if manager.keepAliveUnavailable {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Location is off, so tracking will pause when the screen locks. Keep the app open, or enable location for OpenCircuit in Settings.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            // #45 disclaimer
            Text("Live HR is best-effort (polling, no background refresh — issue #45). Gaps are shown honestly.")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Stop button
            Button(role: .destructive) {
                Task { await manager.stop() }
            } label: {
                Label("Stop Workout", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding()
        }
    }

    // MARK: - Summary

    private func summaryView(_ summary: WorkoutSummary) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: summary.sport.systemImageName)
                        .font(.system(size: 40)).foregroundStyle(.blue)
                    Text(summary.sport.displayName)
                        .font(.title2.weight(.bold))
                    Text(summarySubtitle(summary))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top)

                // Stats grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCell("Duration", formattedDuration(summary.durationSeconds))
                    if let avg = summary.avgHR {
                        statCell("Avg HR", "\(avg) bpm")
                    } else {
                        statCell("Avg HR", "--")
                    }
                    if let max = summary.maxHR {
                        statCell("Max HR", "\(max) bpm")
                    } else {
                        statCell("Max HR", "--")
                    }
                    if let kcal = summary.estimatedActiveKcal {
                        statCell("Active Cal (est.)", "\(Int(kcal.rounded())) kcal")
                    } else {
                        statCell("Active Cal (est.)", "--")
                    }
                    statCell("HR Readings", "\(summary.hrSampleCount)")
                    if let dist = summary.distanceMeters {
                        statCell("Distance", UnitsFormatter.distance(dist, unit: distanceUnit, fractionDigits: 2))
                    }
                }
                .padding(.horizontal)

                // Zone chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("HR ZONE DISTRIBUTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if summary.zoneBreakdown.totalZoneSeconds > 0 {
                        ForEach(HRZone.allCases, id: \.rawValue) { zone in
                            ZoneBarRow(
                                zone: zone,
                                seconds: summary.zoneBreakdown.seconds(in: zone),
                                fraction: summary.zoneBreakdown.fraction(in: zone)
                            )
                        }
                    } else {
                        Text("No HR zone data captured (insufficient readings — see issue #45).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // Honesty notes
                VStack(alignment: .leading, spacing: 6) {
                    if summary.hrSampleCount < 30 {
                        noteRow(icon: "exclamationmark.triangle", color: .orange,
                                text: "Few HR readings captured (\(summary.hrSampleCount)). Live HR polling is best-effort — the ring may have missed updates (issue #45).")
                    }
                    if summary.estimatedActiveKcal != nil {
                        // Label the ACTUAL source: HR-TRIMP when HR locked, else the GPS-distance
                        // fallback (a zero-HR walk's calories come from distance × body mass).
                        noteRow(icon: "info.circle", color: .secondary,
                                text: summary.hrSampleCount > 0
                                    ? "Active calories are an ESTIMATE (Edwards-TRIMP from HR — not ring sensor data)."
                                    : "Active calories are an ESTIMATE (from GPS distance × body mass — HR didn't lock; not ring sensor data).")
                    }
                    if summary.hasRoute {
                        noteRow(icon: "location.fill", color: .blue,
                                text: "GPS route captured and saved to Apple Health.")
                    } else if summary.sport.isOutdoor {
                        noteRow(icon: "location.slash", color: .secondary,
                                text: "No GPS route (location permission not granted or denied).")
                    }
                    noteRow(icon: "checkmark.circle", color: .green,
                            text: "Workout saved to Apple Health.")
                }
                .padding(.horizontal)

                Button("Done") {
                    manager.reset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let t = Int(manager.elapsedSeconds)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private var distanceText: String {
        let v = distanceUnit.convert(fromMeters: manager.distanceMeters ?? 0)
        return String(format: "%.2f", v)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        let h = t / 3600; let m = (t % 3600) / 60; let s = t % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }

    private func summarySubtitle(_ s: WorkoutSummary) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return df.string(from: s.startDate)
    }

    @ViewBuilder
    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func noteRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sport button

private struct SportButton: View {
    let sport: WorkoutSportType
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: sport.systemImageName)
                    .font(.title2)
                Text(sport.displayName)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected
                      ? Color.blue.opacity(0.15)
                      : Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Zone bar row

private struct ZoneBarRow: View {
    let zone: HRZone
    let seconds: Double
    let fraction: Double

    private var zoneColor: Color {
        switch zone {
        case .warmUp:    return .blue
        case .fatBurn:   return .green
        case .aerobic:   return .yellow
        case .anaerobic: return .orange
        case .extreme:   return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(zone.displayName)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemFill))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(zoneColor.opacity(0.8))
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0),
                               height: 14)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 14)
            Text(formattedTime)
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var formattedTime: String {
        let t = Int(seconds)
        if t == 0 { return "  0:00" }
        let m = t / 60; let s = t % 60
        return String(format: "%2d:%02d", m, s)
    }
}
