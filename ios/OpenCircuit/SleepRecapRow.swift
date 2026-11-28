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
    static let title = "Night summary"
    static let prompt = "How this night compares with your recent ones, in a few sentences."
    static let button = "Summarize"
    static let buttonLabel = "Summarize this night"
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

    /// A vetted Sleep recap, or nil (unavailable, refused, or every attempt failed the vet).
    static func write(_ facts: SleepRecap.Facts) async -> String? {
        await write(prompt: facts.prompt, instructions: SleepRecap.instructions, maxTokens: 160) {
            if case .success(let text) = SleepRecap.vet($0, facts: facts) { return text }
            return nil
        }
    }

    /// One model-written line: `accept` vets each reply and returns the text to show, or nil to retry.
    static func write(prompt: String, instructions: String, maxTokens: Int,
                      accept: @escaping @Sendable (String) -> String?) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await OnDeviceWriter.write(prompt: prompt, instructions: instructions,
                                              maxTokens: maxTokens, accept: accept)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum OnDeviceWriter {

    /// One retry: a fresh session at the same low temperature usually fixes a stray number.
    static let attempts = 2

    static func write(prompt: String, instructions: String, maxTokens: Int,
                      accept: @Sendable (String) -> String?) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
        for _ in 0..<attempts {
            if Task.isCancelled { return nil }
            // A new session per attempt: a rejected reply must not sit in the next attempt's context.
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, options: options)
                if let text = accept(response.content) { return text }
            } catch {
                // Guardrail, locale or asset errors: try once more, then show the failure line. Never
                // logged: the error can quote the prompt, which is health data.
            }
        }
        return nil
    }
}
#endif

/// The recap panel under the score: an inset, sleep-tinted block with its own header, so it reads as
/// one feature rather than another caption link. The parent gives it an `.id` of the night's
/// identity, so a new night (or an edit) starts it back at the prompt.
struct SleepRecapRow: View {
    /// Built on tap, not on render. nil = not enough earlier nights from this device.
    let makeFacts: () -> SleepRecap.Facts?

    private enum Phase: Equatable { case idle, writing, done(String), failed, needsHistory }
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.sleep.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.sleep.opacity(0.18), lineWidth: 1)
        )
        .padding(.top, 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: phase)
        #if DEBUG
        .task {
            guard DemoData.isRequested, phase == .idle else { return }
            // `-OCDemoSleepRecapState idle|writing|done|failed`: pin a state for screenshots (the
            // simulator's model can't answer). `-OCDemoSleepRecap YES`: run the real model on appear.
            switch UserDefaults.standard.string(forKey: "OCDemoSleepRecapState") {
            case "writing": phase = .writing
            case "done": phase = .done("You slept 7 h 17 m, about the same as your average over the previous 7 nights, and your sleep score was 85 out of 100.")
            case "failed": phase = .failed
            default: if UserDefaults.standard.bool(forKey: "OCDemoSleepRecap") { start() }
            }
        }
        #endif
        // Scrolled away mid-generation: cancel and go back to the prompt rather than spin forever.
        .onDisappear {
            task?.cancel()
            if phase == .writing { phase = .idle }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            KeylineGlyph(.sparkles, size: 15, relativeTo: .subheadline)
                .foregroundStyle(Theme.sleep)
            Text(SleepRecapCopy.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            // Side by side when it fits; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    promptText
                    Spacer(minLength: 0)
                    summarizeButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    promptText
                    summarizeButton
                }
            }
        case .writing:
            SkeletonLines(animated: !reduceMotion)
                .accessibilityElement()
                .accessibilityLabel(SleepRecapCopy.writing)
        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(SleepRecapCopy.footnote)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    KeylineGlyph(.circleAlert, size: 13, relativeTo: .footnote)
                        .foregroundStyle(.secondary)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(SleepRecapCopy.failed)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(SleepRecapCopy.retry, action: start)
                    .buttonStyle(RecapCapsuleStyle(filled: false))
            }
        case .needsHistory:
            Text(SleepRecapCopy.needsHistory)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptText: some View {
        Text(SleepRecapCopy.prompt)
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summarizeButton: some View {
        Button(SleepRecapCopy.button, action: start)
            .buttonStyle(RecapCapsuleStyle(filled: true))
            .accessibilityLabel(SleepRecapCopy.buttonLabel)
            .accessibilityHint(SleepRecapCopy.accessibilityHint)
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

/// The panel's capsule button: filled sleep tint for the main action, tinted outline for a retry.
private struct RecapCapsuleStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(filled ? Color.white : Theme.sleep)
            .background(Capsule().fill(filled ? Theme.sleep : Theme.sleep.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Three placeholder lines that pulse while the model writes (still with Reduce Motion on).
private struct SkeletonLines: View {
    let animated: Bool
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array([1.0, 0.92, 0.6].enumerated()), id: \.offset) { _, width in
                GeometryReader { geo in
                    Capsule().fill(Theme.sleep.opacity(dim ? 0.10 : 0.22))
                        .frame(width: geo.size.width * width)
                }
                .frame(height: 10)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}
