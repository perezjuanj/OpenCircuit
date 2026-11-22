// The guided breathing exercise, opened as a sheet from the heart-rate detail (below the Measure
// card). Pick a pattern and a length, follow the circle, and watch heart rate while breathing.
//
// The cue is a pure function of the clock (`BreathingPattern.position(at:)`), drawn by a
// `TimelineView`; the small loop below only reads the clock to fire the haptic, collect heart-rate
// readings and end the session. Nothing is stored and nothing is written to Apple Health.
//
// Live heart rate reuses the Measure card's own path (`VitalMeasureSource.state(for:)`,
// `RingSession.startMonitoring` / `stopLiveMonitoring`, `StrapLiveHeartRate`'s session). This
// screen stops a measurement only when it started it.

import SwiftUI
import UIKit

struct BreathingSessionView: View {
    let source: VitalMeasureSource
#if DEBUG
    /// DEBUG screenshot runs only: freeze a running session at this many seconds in.
    var demoFrozenElapsed: TimeInterval?
#endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("breathing.pattern.v1") private var patternID = BreathingPattern.box.id
    @AppStorage("breathing.length.v1") private var lengthSeconds = BreathingLength.three.rawValue

    private enum Stage { case setup, running, finished }
    @State private var stage = Stage.setup
    @State private var startedAt = Date()
    @State private var lastPhaseID: Int?
    @State private var summary = BreathingHeartRateSummary()
    @State private var ownsRing = false
    @State private var ownsStrap = false
    @State private var lastRestart = Date.distantPast

    init(source: VitalMeasureSource) { self.source = source }

#if DEBUG
    init(source: VitalMeasureSource, demoFrozenElapsed: TimeInterval) {
        self.source = source
        self.demoFrozenElapsed = demoFrozenElapsed
        _stage = State(initialValue: .running)
    }
    private var isFrozen: Bool { demoFrozenElapsed != nil }
#else
    private var isFrozen: Bool { false }
#endif

    private var pattern: BreathingPattern { .pattern(id: patternID) }
    private var length: BreathingLength { .from(seconds: lengthSeconds) }
    private var hrState: VitalMeasureState { source.state(for: .heartRate) }
    private var hasDevice: Bool { hrState.control != .none || hrState.streaming }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .setup: setup
                case .running: running
                case .finished: finished
                }
            }
            .background(Theme.pageBackground)
            .navigationTitle("Breathing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(stage == .running ? "End" : "Done") { close() }
                }
            }
        }
        .onDisappear { teardown() }
        .task(id: stage == .running) {
            guard stage == .running else { return }
            await runLoop()
        }
    }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                OCCard {
                    OCSectionHeader("Pattern")
                    ForEach(BreathingPattern.all) { p in
                        Button { patternID = p.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(p.summary).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.id == patternID {
                                    Image(keyline: .circleCheck).resizable().renderingMode(.template)
                                        .scaledToFit().frame(width: 22, height: 22)
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(p.id == patternID ? .isSelected : [])
                    }
                }
                OCCard {
                    OCSectionHeader("Length")
                    Picker("Length", selection: $lengthSeconds) {
                        ForEach(BreathingLength.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Text(hasDevice
                     ? "Your heart rate shows while you breathe, and the lowest reading is noted at the end."
                     : "Heart rate shows here when your wearable is connected. The exercise works without it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(action: start) {
                    Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(16)
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 24) {
            Text("\(pattern.name), \(length.title)").font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : nil)) { context in
                cue(at: elapsed(at: context.date))
            }
            Spacer(minLength: 0)
            heartRateArea
        }
        .padding(16)
    }

    private func elapsed(at date: Date) -> TimeInterval {
#if DEBUG
        if let demoFrozenElapsed { return demoFrozenElapsed }
#endif
        return date.timeIntervalSince(startedAt)
    }

    private func cue(at elapsed: TimeInterval) -> some View {
        let pos = pattern.position(at: min(elapsed, length.seconds))
        let diameter: CGFloat = 260
        let scale = reduceMotion ? 0.8 : 0.45 + 0.55 * pos.fullness
        return ZStack {
            Circle().fill(Theme.accent.opacity(0.15))
            Circle().fill(Theme.accent.opacity(0.35)).scaleEffect(scale)
            Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 2).scaleEffect(scale)
            VStack(spacing: 4) {
                Text(pos.kind.label)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: pos.kind)
                Text("\(pos.countdown)")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pos.kind.label), \(pos.countdown) seconds")
    }

    @ViewBuilder
    private var heartRateArea: some View {
        if hasDevice {
            OCCard {
                OCSectionHeader("Heart rate", systemImage: "heart.fill", tint: Theme.hr)
                LiveVitalReadout(value: hrState.latestFrame, unit: "bpm", tint: Theme.hr,
                                 pulses: false, sessionRange: LiveSessionRange(), compact: true)
            }
        } else {
            Text("Heart rate shows here when your wearable is connected.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: Finished

    private var finished: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                OCCard {
                    OCSectionHeader("Done", systemImage: nil)
                    Text("\(length.title) of \(pattern.name)").font(.headline)
                }
                OCCard {
                    OCSectionHeader("Heart rate", systemImage: "heart.fill", tint: Theme.hr)
                    if summary.hasReadings {
                        statRow("Start", summary.start)
                        statRow("End", summary.end)
                        statRow("Lowest", summary.lowest)
                    } else {
                        Text("No heart rate").font(.body).foregroundStyle(.secondary)
                    }
                }
                Button { stage = .setup } label: {
                    Text("Again").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
        }
    }

    private func statRow(_ title: String, _ value: Int?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { "\($0) bpm" } ?? "—").monospacedDigit().fontWeight(.semibold)
        }
    }

    // MARK: Lifecycle

    private func start() {
        summary = BreathingHeartRateSummary()
        lastPhaseID = nil
        startedAt = Date()
        startHeartRate()
        UIApplication.shared.isIdleTimerDisabled = true
        stage = .running
    }

    /// Start live HR the way the Measure card's button does, unless a measurement is already running
    /// (then it is left alone, and left running).
    private func startHeartRate() {
        switch hrState.control {
        case .ring(let active, let enabled):
            guard !active, enabled, let session = source.session else { return }
            session.startMonitoring(mode: .hr, userInitiated: true, quickLiveRead: true)
            ownsRing = true
        case .strap:
            guard let live = source.strapLive, !live.measuring, !live.disabled else { return }
            live.session.startLiveHeartRate(duration: StrapLiveHeartRate.duration)
            ownsStrap = true
        case .none:
            break
        }
    }

    /// One Measure runs 90 s on both devices; a longer session starts the next one if this screen
    /// started the first.
    private func restartHeartRateIfEnded() {
        guard Date().timeIntervalSince(lastRestart) > 5 else { return }
        let state = hrState
        if ownsRing, case .ring(false, true) = state.control {
            lastRestart = Date()
            source.session?.startMonitoring(mode: .hr, userInitiated: true, quickLiveRead: true)
        } else if ownsStrap, let live = source.strapLive, !live.measuring, !live.disabled, live.canMeasure {
            lastRestart = Date()
            live.session.startLiveHeartRate(duration: StrapLiveHeartRate.duration)
        }
    }

    private func runLoop() async {
        if isFrozen { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        while !Task.isCancelled {
            let t = Date().timeIntervalSince(startedAt)
            if length.isFinished(at: t) { finish(); return }
            let pos = pattern.position(at: t)
            if pos.phaseID != lastPhaseID {
                lastPhaseID = pos.phaseID
                generator.impactOccurred()
            }
            // The settled value, like the Measure card's number; never the raw last frame.
            if let bpm = hrState.liveValue { summary.record(bpm) }
            restartHeartRateIfEnded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish() {
        releaseHeartRate()
        UIApplication.shared.isIdleTimerDisabled = false
        stage = .finished
    }

    private func close() {
        teardown()
        dismiss()
    }

    private func teardown() {
        releaseHeartRate()
        if !isFrozen { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Stop live HR only if this screen started it.
    private func releaseHeartRate() {
        if ownsRing { source.session?.stopLiveMonitoring() }
        if ownsStrap { source.strapLive?.session.stopLiveHeartRate() }
        ownsRing = false
        ownsStrap = false
    }
}

/// The heart-rate detail's entry row, below the Measure card.
struct BreathingEntryRow: View {
    let source: VitalMeasureSource
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            OCCard {
                HStack(spacing: 10) {
                    KeylineGlyph(.wind, size: 20, relativeTo: .body).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Breathing exercise").font(.body.weight(.semibold)).foregroundStyle(.primary)
                        Text("Follow a guided pattern and watch your heart rate").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(keyline: .chevronRight).resizable().renderingMode(.template).scaledToFit()
                        .frame(width: 16, height: 16).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { BreathingSessionView(source: source) }
    }
}
