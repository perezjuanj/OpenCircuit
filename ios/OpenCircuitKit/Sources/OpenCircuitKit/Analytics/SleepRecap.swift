// On-device sleep recap: the facts handed to Apple's on-device language model, and the check its
// reply must pass before anything is shown.
//
// The model only PHRASES. Every number in a recap is worked out here, in Swift, from the stored night
// and the nights before it; the model is told to copy numbers exactly and never compute one. `vet`
// then enforces that rather than trusting it: a reply carrying any number that is not in the facts
// (digits or a spelled-out small number), any diagnostic or medical wording, or more than a short
// paragraph is rejected, and the app shows nothing instead of a sentence it cannot stand behind.
//
// Pure Foundation, no FoundationModels: the model call lives in the app target behind
// `#if canImport(FoundationModels)` and `@available(iOS 26, *)`, so this file builds and tests with
// `swift test` and the iOS 17 deployment target is unchanged.

import Foundation

public enum SleepRecap {

    /// One night as stored. Minutes are whole minutes, as on the Sleep card.
    public struct Night: Equatable, Sendable {
        public var asleepMin: Int
        public var inBedMin: Int
        public var deepMin: Int
        public var lightMin: Int
        public var remMin: Int
        public var awakeMin: Int
        /// 0…1 (the stored `efficiency`); 0 = unknown.
        public var efficiency: Double
        /// 1…100, 0 = not scored.
        public var score: Int
        public var isManuallyEdited: Bool

        public init(asleepMin: Int, inBedMin: Int, deepMin: Int, lightMin: Int, remMin: Int,
                    awakeMin: Int, efficiency: Double, score: Int, isManuallyEdited: Bool = false) {
            self.asleepMin = asleepMin
            self.inBedMin = inBedMin
            self.deepMin = deepMin
            self.lightMin = lightMin
            self.remMin = remMin
            self.awakeMin = awakeMin
            self.efficiency = efficiency
            self.score = score
            self.isManuallyEdited = isManuallyEdited
        }
    }

    /// Prior nights used for the comparison lines (newest first, the night itself excluded).
    public static let baselineNights = 7
    /// Fewer usable prior nights than this and there is no recap at all (`facts` returns nil). The
    /// comparison is what a recap adds over the card, and in the live run a model given a night with no
    /// history invented one anyway ("longer than earlier nights", "33 m longer than the previous night"
    /// where 33 m was the awake time): a real number used for the wrong thing, which the vet cannot see.
    public static let minBaselineNights = 3
    /// A difference within this many minutes reads as "about the same".
    public static let sameBandMin = 10
    /// A score difference within this many points reads as "about the same".
    public static let sameBandScore = 3
    /// Longest reply shown, in characters (about three short sentences).
    public static let maxReplyLength = 420

    /// What the model is given, plus the numbers it may use.
    public struct Facts: Hashable, Sendable {
        public let lines: [String]
        /// Every integer token that appears in `lines`. A reply may contain only these.
        public let allowedNumbers: Set<Int>
        public var prompt: String {
            "Facts about last night:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
                + "\n\nWrite the recap."
        }
    }

    /// The model's standing instructions. Kept here so tests pin them with the vet rules they back.
    public static let instructions = """
    You write a short, friendly recap of one night's sleep for the person who slept it.
    If the facts compare the night with earlier nights, start with that comparison. Then mention \
    one or two details that stand out. Do not list every fact.
    Use only the facts you are given. Copy every number exactly as it is written in the facts. \
    Never calculate, round, estimate or invent a number, and do not write numbers as words.
    Write two or three sentences, under 60 words, speaking to the person as "you".
    Do not give medical advice, do not diagnose, and do not name any health condition.
    Do not recommend products, apps or supplements. Do not mention that you are a model.
    """

    /// "6 h 40 m", "45 m", "8 h": the Sleep card's own duration style.
    public static func duration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) m" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) m"
    }

    /// The facts for `night`, compared with up to `baselineNights` of `prior` (newest first; nights
    /// with no asleep minutes are skipped). nil when fewer than `minBaselineNights` remain.
    ///
    /// No clock times: the card already shows bedtime and wake, and in the live run the model rewrote
    /// "11:26 PM" as "23:26" in most replies (13 of 20), which the vet must reject. The comparison
    /// with earlier nights is what the recap adds, so the facts are durations, stages and score only.
    public static func facts(for night: Night, prior: [Night]) -> Facts? {
        let base = Array(prior.filter { $0.asleepMin > 0 }.prefix(baselineNights))
        guard night.asleepMin > 0, base.count >= minBaselineNights else { return nil }
        var lines: [String] = []
        lines.append("Time asleep: \(duration(night.asleepMin)).")
        if night.inBedMin > night.asleepMin {
            lines.append("Time in bed: \(duration(night.inBedMin)).")
        }
        if night.efficiency > 0 {
            let pct = Int((night.efficiency * 100).rounded())
            lines.append("Sleep efficiency: \(pct)%.")
        }
        let staged = night.deepMin + night.lightMin + night.remMin
        if staged > 0 {
            lines.append("Stages: deep \(duration(night.deepMin)), REM \(duration(night.remMin)), "
                         + "light \(duration(night.lightMin)), awake \(duration(night.awakeMin)).")
        }
        if night.score > 0 {
            lines.append("Sleep score: \(night.score) out of 100.")
        }

        lines.append(compare("Time asleep", night.asleepMin, avg(base.map(\.asleepMin)), nights: base.count))
        if staged > 0 {
            let stagedBase = base.filter { $0.deepMin + $0.lightMin + $0.remMin > 0 }
            if stagedBase.count >= minBaselineNights {
                lines.append(compare("Deep sleep", night.deepMin, avg(stagedBase.map(\.deepMin)),
                                     nights: stagedBase.count))
                lines.append(compare("REM sleep", night.remMin, avg(stagedBase.map(\.remMin)),
                                     nights: stagedBase.count))
            }
        }
        let scored = base.filter { $0.score > 0 }
        if night.score > 0, scored.count >= minBaselineNights {
            lines.append(compareScore(night.score, avg(scored.map(\.score)), nights: scored.count))
        }
        if night.isManuallyEdited {
            lines.append("The person edited this night's times by hand.")
        }
        return Facts(lines: lines, allowedNumbers: numbers(in: lines.joined(separator: " ")))
    }

    private static func avg(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        return Int((Double(xs.reduce(0, +)) / Double(xs.count)).rounded())
    }

    private static func compare(_ label: String, _ value: Int, _ usual: Int, nights: Int) -> String {
        let diff = value - usual
        let usualText = "your average of \(duration(usual)) over the previous \(nights) nights"
        if abs(diff) <= sameBandMin { return "\(label) was about the same as \(usualText)." }
        return "\(label) was \(duration(abs(diff))) \(diff > 0 ? "more" : "less") than \(usualText)."
    }

    private static func compareScore(_ value: Int, _ usual: Int, nights: Int) -> String {
        let diff = value - usual
        let usualText = "your average score of \(usual) over the previous \(nights) nights"
        if abs(diff) <= sameBandScore { return "The score was about the same as \(usualText)." }
        return "The score was \(abs(diff)) points \(diff > 0 ? "higher" : "lower") than \(usualText)."
    }

    // MARK: Vetting the reply

    public enum Rejection: Error, Equatable, Sendable {
        case empty
        case tooLong
        /// A number the facts don't contain (digits or a spelled-out word).
        case inventedNumber(String)
        /// Diagnostic or medical wording.
        case medicalWording(String)
    }

    /// Words a recap must never contain. Lowercased stems, matched at the start of a word.
    public static let bannedStems: [String] = [
        "diagnos", "apnea", "apnoea", "insomnia", "narcolep", "disorder", "disease", "illness",
        "sick", "doctor", "physician", "medical", "medicat", "prescri", "treatment", "condition",
        "symptom", "fever", "infection", "melatonin", "supplement",
    ]

    /// Spelled-out numbers the vet catches (the instructions forbid them; "one" is left out because
    /// "no one", "one of" read as words, not counts). Each word is checked on its own, so
    /// "eighty-two" needs both 80 and 2 in the facts: in the live run that is how a reply saying
    /// "seven hours, nineteen minutes" for a 7 h 18 m night was caught.
    static let numberWords: [String: Int] = [
        "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100,
    ]

    /// The reply, trimmed, if it may be shown; otherwise why not.
    public static func vet(_ reply: String, facts: Facts) -> Result<String, Rejection> {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= maxReplyLength else { return .failure(.tooLong) }
        let lower = text.lowercased()
        for stem in bannedStems {
            if wordStarts(stem, in: lower) { return .failure(.medicalWording(stem)) }
        }
        for token in integerTokens(in: text) where !facts.allowedNumbers.contains(token) {
            return .failure(.inventedNumber(String(token)))
        }
        for word in words(in: lower) {
            if let n = numberWords[word], !facts.allowedNumbers.contains(n) {
                return .failure(.inventedNumber(word))
            }
        }
        return .success(text)
    }

    static func numbers(in text: String) -> Set<Int> { Set(integerTokens(in: text)) }

    private static func integerTokens(in text: String) -> [Int] {
        var out: [Int] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isNumber { current.append(ch) } else {
                if let n = Int(current) { out.append(n) }
                current = ""
            }
        }
        if let n = Int(current) { out.append(n) }
        return out
    }

    private static func words(in lower: String) -> [String] {
        lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// `stem` at the start of a word in `lower`, so "sick" catches "sickness" but not "homesick".
    /// No stem may be a prefix of an ordinary sleep word ("pill" would catch "pillow").
    private static func wordStarts(_ stem: String, in lower: String) -> Bool {
        var search = lower.startIndex..<lower.endIndex
        while let r = lower.range(of: stem, range: search) {
            if r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter {
                return true
            }
            search = r.upperBound..<lower.endIndex
        }
        return false
    }
}
