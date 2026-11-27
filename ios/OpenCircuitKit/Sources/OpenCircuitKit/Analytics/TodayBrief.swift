// The Today brief: the facts behind the Today synthesis line, for Apple's on-device model to phrase.
//
// The template sentence (`TodaySynthesis.sentence`) stays the source of truth and is what the line
// shows first and whenever the model is unavailable, slow, or its reply fails the vet. The brief only
// rewords the SAME input: readiness, last night against the person's recent nights, and the tiles'
// above/within/below directions. Every number is worked out here, never by the model.
//
// Two extra rules over the Sleep recap's vet:
// - Advice. The template suggests "an easier day" only when readiness needs improvement, and "take
//   today gently" only on Vitals Status's fever verdict. The facts say so in words when it applies,
//   and `vetBrief` rejects advice wording in any reply whose facts gave none.
// - No brief for the states that are about MISSING data (no data, stale, still loading, no night or no
//   score): the template tells the person what to do there, and there is nothing for a model to add.

import Foundation

extension TodaySynthesis {

    /// Longest brief shown, in characters (two short sentences under a large title).
    public static let briefMaxLength = 220

    public static let briefInstructions = """
    You write the opening line of a health app's home screen: one or two natural, friendly sentences \
    telling the person how they are doing today.
    Cover every fact under "Must mention". You may add one fact from "May mention" if it fits, \
    preferring one that is above or below their usual.
    Write flowing sentences in your own words. Do not copy the facts as a list and do not use colons.
    Do not greet the person. Do not say how they feel or how they are doing in general (no "well \
    rested", "refreshed", "doing well"); say only what their numbers show.
    Use only the facts you are given. Copy every number exactly as it is written in the facts. \
    Never calculate, round, estimate or invent a number, and do not write numbers as words.
    Only suggest an easier day or taking it gently if a fact says the app suggests it. Otherwise give \
    no advice.
    Keep it under 35 words, speaking to the person as "you".
    Do not give medical advice, do not diagnose, and do not name any health condition.
    """

    /// Advice wording a brief may use only when its facts carry a suggestion.
    public static let adviceStems: [String] = [
        "should", "consider", "recommend", "make sure", "try to", "take it", "take today", "easier",
        "gentl", "hydrat", "avoid", "prioriti", "listen to your body",
    ]

    /// Words that claim how the person feels or is doing, which no number on the screen shows. In the
    /// second live run the model wrote "you are well rested" on a day whose night had not synced, and
    /// "doing well" next to the fever pair.
    public static let feelingStems: [String] = [
        "rested", "refresh", "calm", "energ", "tired", "fatigu", "exhaust", "feel", "doing well",
        "doing great", "doing okay", "doing ok", "doing fine", "challeng", "struggl", "stress", "recover",
    ]

    /// Openers the brief must not start with (the second live run opened 48 of 48 with "Hello,").
    public static let greetingStems: [String] = ["hello", "hi ", "hi,", "hey", "good morning", "good afternoon", "good evening"]

    /// The suggestion lines, when the template makes one. Their presence is what allows advice wording.
    static let easierDayLine = "An easier day may help."
    static let gentlyLine = "Taking today gently may help."

    /// The facts for the model, or nil when the template line should stand alone.
    ///
    /// "Must mention" holds what the template itself would never leave out: the readiness score (or
    /// why there is none), the fever pair, a short night, the first concern, and the app's suggestion.
    /// `vetBrief` checks each is in the reply. In the first live run, with a flat list, the model
    /// dropped the fever pair in 8 of 8 replies and answered most days with "Readiness: 82 out of 100".
    public static func briefFacts(_ input: Input) -> SleepRecap.Facts? {
        guard let newest = input.newestDataAt, input.now.timeIntervalSince(newest) <= staleAfter else { return nil }
        var must: [String] = [], may: [String] = [], required: [[String]] = []
        switch input.readiness {
        case .pending:
            return nil
        case let .scored(score, tier, factorCount):
            switch tier {
            case .excellent: must.append("Readiness today is excellent, at \(score) out of 100.")
            case .good: must.append("Readiness today is good, at \(score) out of 100.")
            case .needsImprovement: must.append("Readiness today needs improvement, at \(score) out of 100.")
            }
            required.append(["\(score)"])
            if factorCount <= 1 { may.append("Readiness is based on last night's sleep alone.") }
        case .noNight, .noScore:
            // No score to lead with. In the live run the model filled the gap by inventing a resting
            // heart rate (4 of 8 replies), and the template already says what is missing.
            return nil
        }

        if input.feverSuspected {
            must.append("Skin temperature and resting heart rate are both above your usual.")
            required.append(["skin temperature"])
        }
        let short = sleepWasShortForBrief(input)
        if short {
            must.append("Last night's sleep was short.")
            required.append(["short"])
        }
        if let last = input.lastNightSleepMinutes, last > 0 {
            var line = "Last night you slept \(SleepRecap.duration(last))"
            if let usual = input.usualSleepMinutes, usual > 0 {
                let u = Int(usual.rounded())
                let diff = last - u
                if abs(diff) <= SleepRecap.sameBandMin {
                    line += ", about the same as your recent average of \(SleepRecap.duration(u))"
                } else {
                    line += ", \(SleepRecap.duration(abs(diff))) \(diff > 0 ? "more" : "less") than your recent average of \(SleepRecap.duration(u))"
                }
            }
            may.append(line + ".")
        }

        // The vitals directions. The first concern is a must (the template leads with it); the rest
        // are optional. Skin temperature and resting HR are already covered by the fever pair.
        var concerns: [(String, [String])] = [], others: [String] = []
        if let d = input.hrv {
            let line = "HRV is \(phrase(d))."
            if d == .below { concerns.append((line, ["hrv"])) } else { others.append(line) }
        }
        if !input.feverSuspected {
            if let d = input.restingHR {
                let line = "Resting heart rate is \(phrase(d))."
                if d == .above { concerns.append((line, ["resting heart rate", "heart rate"])) } else { others.append(line) }
            }
            if let d = input.skinTemp {
                let line = "Skin temperature is \(phrase(d))."
                if d == .above { concerns.append((line, ["skin temperature"])) } else { others.append(line) }
            }
        }
        if let first = concerns.first, !input.feverSuspected, !short {
            must.append(first.0)
            required.append(first.1)
            may += concerns.dropFirst().map(\.0)
        } else {
            may += concerns.map(\.0)
        }
        may += others

        if input.feverSuspected {
            must.append(gentlyLine)
            required.append(["gentl", "easy", "easier"])
        } else if case .scored(_, .needsImprovement, _) = input.readiness {
            must.append(easierDayLine)
            required.append(["easier", "easy", "gentl"])
        }
        return SleepRecap.Facts(lines: must, optionalLines: may, required: required,
                                header: "Facts about today:",
                                request: "Write the summary in one or two natural sentences.")
    }

    /// `SleepRecap.vet` with the brief's length, plus the coverage, list and advice rules.
    public static func vetBrief(_ reply: String, facts: SleepRecap.Facts) -> Result<String, SleepRecap.Rejection> {
        let vetted = SleepRecap.vet(reply, facts: facts, maxLength: briefMaxLength)
        guard case .success(let text) = vetted else { return vetted }
        let lower = text.lowercased()
        if text.contains(":") { return .failure(.listLike) }
        if greetingStems.contains(where: { lower.hasPrefix($0) }) { return .failure(.greeting) }
        for stem in feelingStems where SleepRecap.wordStarts(stem, in: lower) {
            return .failure(.claimsFeeling(stem))
        }
        for group in facts.required where !group.contains(where: { lower.contains($0) }) {
            return .failure(.missing(group.first ?? ""))
        }
        if !facts.lines.contains(where: { $0 == easierDayLine || $0 == gentlyLine }) {
            for stem in adviceStems where SleepRecap.wordStarts(stem, in: lower) {
                return .failure(.unrequestedAdvice(stem))
            }
        }
        return .success(text)
    }

    private static func phrase(_ d: BaselineTrend.Direction) -> String {
        switch d {
        case .above: return "above your usual"
        case .below: return "below your usual"
        case .within: return "within your usual range"
        }
    }

    /// The template's own "short night" rule, so the brief never calls a night short that the
    /// template wouldn't.
    private static func sleepWasShortForBrief(_ i: Input) -> Bool {
        guard let last = i.lastNightSleepMinutes, last > 0 else { return false }
        if last < shortNightMinutes { return true }
        if let usual = i.usualSleepMinutes, usual > 0, Double(last) < usual - shortVsUsualMinutes { return true }
        return false
    }
}