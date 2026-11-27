// On-device sleep recap on the Sleep card: a short plain-language summary of the night on screen,
// written by Apple's ON-DEVICE language model (Foundation Models, `SystemLanguageModel.default`).
//
// Local-first holds: the model runs on the iPhone, the prompt is built from numbers already on the
// card, and nothing is sent anywhere. `PrivateCloudComputeLanguageModel` (iOS 27, Apple's server
// model) is deliberately never used; `SleepRecapSourceTests` greps the app sources for it.
//
// The model only phrases. `SleepRecap` (OpenCircuitKit) works out every number, and its `vet` rejects
// a reply with any number the facts lack or any medical wording, in which case the card shows a
// "couldn't write a summary" line instead. Hidden entirely below iOS 26, on hardware without Apple
// Intelligence, with Apple Intelligence off, or while the model is still downloading.
//
// Generated only on a tap, never on render: a generation takes a few seconds of the Neural Engine.

import SwiftUI
import OpenCircuitKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The recap's words. Tests pin the privacy and not-medical-advice phrases.
enum SleepRecapCopy {
    static let button = "Summarize this night"
    static let writing = "Writing a summary…"
    static let footnote = "Written on this iPhone by Apple Intelligence from the numbers on this card. Nothing is sent off your phone. Not medical advice."
    static let failed = "A summary couldn’t be written for this night."
    static let retry = "Try again"
    static let needsHistory = "A summary needs a few more nights from this device to compare with."
    static let accessibilityHint = "Writes a short summary of this night on your iPhone"
}

/// The card's displayed night and stored history, as the Kit's plain values.
enum SleepRecapAdapter {

    /// The night exactly as the card shows it: its minutes and efficiency, plus the stored score only
    /// when the stored row IS this night (a live staging has no score of its own).
    static func night(_ night: SleepCardView.Night, row: StoredSleepSummary?) -> SleepRecap.Night {
        let m = night.summary.minutes
        let score = (row?.night == night.nightKey) ? (row?.sleepScore ?? 0) : 0
        return SleepRecap.Night(asleepMin: m.asleep, inBedMin: m.inBed, deepMin: m.deep,
                                lightMin: m.light, remMin: m.rem, awakeMin: m.awake,
                                efficiency: night.summary.efficiency, score: score,
                                isManuallyEdited: night.isManuallyEdited)
    }

    /// Earlier stored nights, newest first, without the night on screen. `rows` should already be one
    /// device's nights (`LocalStore.sameDevice`), so a ring night is never compared with strap nights.
    static func prior(_ rows: [StoredSleepSummary], excluding nightKey: Date) -> [SleepRecap.Night] {
        rows.filter { $0.night != nightKey && $0.asleepMin > 0 }
            .sorted { $0.night > $1.night }
            .map { row in
                let m = row.asSummary.minutes
                return SleepRecap.Night(asleepMin: m.asleep, inBedMin: m.inBed, deepMin: m.deep,
                                        lightMin: m.light, remMin: m.rem, awakeMin: m.awake,
                                        efficiency: row.efficiency, score: row.sleepScore)
            }
    }

    /// Cheap check for `body`: enough stored nights besides this one that a recap COULD have a
    /// baseline. The tap still builds the real facts from one device's nights and may find too few.
    static func mayHaveBaseline(_ rows: [StoredSleepSummary], excluding nightKey: Date) -> Bool {
        rows.lazy.filter { $0.night != nightKey && $0.asleepMin > 0 }.prefix(SleepRecap.minBaselineNights)
            .count >= SleepRecap.minBaselineNights
    }
}

/// The on-device model, reachable from the iOS 17 deployment target.
enum SleepRecapModel {

    /// True only when the on-device model can answer now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// A vetted recap, or nil (unavailable, refused, or every attempt failed the vet).
    static func write(_ facts: SleepRecap.Facts) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return await OnDeviceSleepRecapWriter.write(facts) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum OnDeviceSleepRecapWriter {

    /// One retry: a fresh session at the same low temperature usually fixes a stray number.
    static let attempts = 2

    static func write(_ facts: SleepRecap.Facts) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 160)
        for _ in 0..<attempts {
            if Task.isCancelled { return nil }
            // A new session per attempt: a rejected reply must not sit in the next attempt's context.
            let session = LanguageModelSession(model: model, instructions: SleepRecap.instructions)
            do {
                let response = try await session.respond(to: facts.prompt, options: options)
                if case .success(let text) = SleepRecap.vet(response.content, facts: facts) { return text }
            } catch {
                // Guardrail, locale or asset errors: try once more, then show the failure line. Never
                // logged: the error can quote the prompt, which is health data.
            }
        }
        return nil
    }
}
#endif

/// The recap row under the score. The parent gives it an `.id` of the night's identity, so a new
/// night (or an edit) starts it back at the button.
struct SleepRecapRow: View {
    /// Built on tap, not on render. nil = not enough earlier nights from this device.
    let makeFacts: () -> SleepRecap.Facts?

    private enum Phase: Equatable { case idle, writing, done(String), failed, needsHistory }
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .idle:
                Button(action: start) {
                    HStack(spacing: 5) {
                        KeylineGlyph(.sparkles, size: 13, relativeTo: .caption)
                        Text(SleepRecapCopy.button)
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityHint(SleepRecapCopy.accessibilityHint)
            case .writing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(SleepRecapCopy.writing)
                }
                .font(.caption).foregroundStyle(.secondary)
            case .done(let text):
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(SleepRecapCopy.footnote)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                HStack(spacing: 6) {
                    Text(SleepRecapCopy.failed).foregroundStyle(.secondary)
                    Button(SleepRecapCopy.retry, action: start)
                        .buttonStyle(.plain).foregroundStyle(.tint)
                }
                .font(.caption)
            case .needsHistory:
                Text(SleepRecapCopy.needsHistory)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.default, value: phase)
        #if DEBUG
        // `-OCDemoSleepRecap YES` (with the demo data): start the recap on appear, for screenshots.
        .task {
            if DemoData.isRequested, UserDefaults.standard.bool(forKey: "OCDemoSleepRecap"), phase == .idle { start() }
        }
        #endif
        // Scrolled away mid-generation: cancel and go back to the button rather than spin forever.
        .onDisappear {
            task?.cancel()
            if phase == .writing { phase = .idle }
        }
    }

    private func start() {
        task?.cancel()
        guard let facts = makeFacts() else { phase = .needsHistory; return }
        phase = .writing
        task = Task {
            let text = await SleepRecapModel.write(facts)
            guard !Task.isCancelled else { return }
            phase = text.map(Phase.done) ?? .failed
        }
    }
}
