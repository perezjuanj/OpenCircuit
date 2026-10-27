// HeartRateZones.swift — the ONE source of heart-rate zone bounds (decision 83, #338).
//
// Every zone classification in the app (live workout, summary bars, workout history, training
// load) reads a `HeartRateZones`; nothing else holds a percentage. A `HeartRateZones` is five LOWER
// bounds in whole bpm. Zone n runs from its lower bound up to one below the next lower bound;
// zone 5 has no upper bound. A reading below zone 1's lower bound is in no zone (83e).
//
// MAX HEART RATE (83c). Automatic is `220 − age`, exactly the value every site used before this
// file existed. Manual is an integer the user typed, 100…230 bpm.
//
// METHOD (83d). All bounds are integers, derived with integer arithmetic so a bpm exactly on a
// bound never depends on floating-point rounding:
//   • % of max heart rate (default): lower bounds 50/60/70/80/90 % of max, rounded UP to a whole bpm.
//     A reading is in zone n when bpm ≥ ceil(pct × max / 100), the same test as bpm / max ≥ pct.
//   • % of heart-rate reserve (Karvonen): rest + pct × (max − rest) / 100, same 50/60/70/80/90 %,
//     rounded up. Needs a resting heart rate; with none, or one that is not below max, the zones are
//     % of max and `fallbackNote` says so (the screen shows it).
//   • Custom: five lower bounds in bpm the user typed, strictly increasing.
//
// Pure value math, Foundation only.

import Foundation

/// How the five zone lower bounds are derived.
public enum HeartRateZoneMethod: String, CaseIterable, Sendable {
    case percentOfMax
    case percentOfReserve
    case custom
}

/// Max heart rate: where it comes from and which values are allowed.
public enum MaxHeartRate {
    /// The values a manual max HR may take, in bpm.
    public static let manualRange = 100...230

    public static func isValidManual(_ bpm: Int) -> Bool { manualRange.contains(bpm) }

    /// `220 − age`, floored at 1: the formula every site used before the helper, unchanged. The
    /// age is NOT clamped here (a few sites clamp it themselves with `max(age, 1)` first), so each
    /// site keeps its exact old value for every age.
    public static func automatic(age: Int) -> Int { max(220 - age, 1) }

    /// The max heart rate to use: the user's own when it is a valid manual value, else
    /// `automatic(age:)`. The ONE place a max HR is chosen (decision 83c).
    public static func resolve(age: Int, manual: Int?) -> Int {
        if let manual, isValidManual(manual) { return manual }
        return automatic(age: age)
    }
}

/// The user's zone choices. Pure data; the app stores it in UserDefaults (`HeartRateZoneDefaults`).
public struct HeartRateZoneSettings: Equatable, Sendable {
    public var method: HeartRateZoneMethod
    /// nil = Automatic (`220 − age`). A value outside `MaxHeartRate.manualRange` is treated as nil.
    public var manualMaxHR: Int?
    /// Five lower bounds in bpm for `.custom`. Used only while valid (`HeartRateZones.isValidCustom`).
    public var customLowerBounds: [Int]

    public init(method: HeartRateZoneMethod = .percentOfMax,
                manualMaxHR: Int? = nil,
                customLowerBounds: [Int] = HeartRateZoneSettings.defaultCustomLowerBounds) {
        self.method = method
        self.manualMaxHR = manualMaxHR
        self.customLowerBounds = customLowerBounds
    }

    /// Where the Custom editor starts: the percent-of-max bounds for a 190 bpm max.
    public static let defaultCustomLowerBounds = [95, 114, 133, 152, 171]

    /// Today's behaviour: Automatic max, % of max.
    public static let standard = HeartRateZoneSettings()

    public var usesManualMaxHR: Bool { manualMaxHR.map(MaxHeartRate.isValidManual) ?? false }

    /// The max heart rate these settings give for `age`.
    public func maxHR(age: Int) -> Int {
        MaxHeartRate.resolve(age: age, manual: manualMaxHR)
    }
}

public struct HeartRateZones: Equatable, Sendable {

    /// Why the zones are not the ones the settings asked for, or nil when they are.
    public enum Fallback: Equatable, Sendable {
        /// % of reserve was chosen but there is no usable resting heart rate.
        case noRestingHR
        /// Custom was chosen but its five bounds are not strictly increasing / in range.
        case invalidCustom
    }

    /// The default percentages: lower bounds of zones 1…5 (decision 83d).
    public static let defaultLowerPercents = [50, 60, 70, 80, 90]
    /// The bpm range a custom bound may take.
    public static let customRange = 30...230

    /// The method actually used (differs from the requested one under a `fallback`).
    public let method: HeartRateZoneMethod
    public let maxHR: Int
    /// The resting heart rate the bounds were built on, only for `.percentOfReserve`.
    public let restingHR: Int?
    /// Five lower bounds in bpm, ascending, for zones 1…5.
    public let lowerBounds: [Int]
    public let fallback: Fallback?
    /// True when `maxHR` is the `220 − age` formula, false when the user typed it.
    public let maxHRIsAutomatic: Bool

    /// Zones from the user's settings. `restingHR` is the app's resting heart rate for the active
    /// device (nil = none yet).
    public init(settings: HeartRateZoneSettings, age: Int, restingHR: Double?) {
        let maxHR = settings.maxHR(age: age)
        let automatic = !settings.usesManualMaxHR
        switch settings.method {
        case .percentOfMax:
            self.init(maxHR: maxHR, restingHR: nil, method: .percentOfMax,
                      lowerBounds: Self.maxBounds(maxHR: maxHR), fallback: nil, automatic: automatic)
        case .percentOfReserve:
            if let rest = Self.usableResting(restingHR, maxHR: maxHR) {
                self.init(maxHR: maxHR, restingHR: rest, method: .percentOfReserve,
                          lowerBounds: Self.reserveBounds(maxHR: maxHR, restingHR: rest), fallback: nil,
                          automatic: automatic)
            } else {
                self.init(maxHR: maxHR, restingHR: nil, method: .percentOfMax,
                          lowerBounds: Self.maxBounds(maxHR: maxHR), fallback: .noRestingHR, automatic: automatic)
            }
        case .custom:
            if Self.isValidCustom(settings.customLowerBounds) {
                self.init(maxHR: maxHR, restingHR: nil, method: .custom,
                          lowerBounds: settings.customLowerBounds, fallback: nil, automatic: automatic)
            } else {
                self.init(maxHR: maxHR, restingHR: nil, method: .percentOfMax,
                          lowerBounds: Self.maxBounds(maxHR: maxHR), fallback: .invalidCustom, automatic: automatic)
            }
        }
    }

    /// The default 50/60/70/80/90 % of `maxHR` zones (`maxHR` taken to be the `220 − age` formula
    /// unless `automatic` says otherwise).
    public init(percentOfMax maxHR: Int, automatic: Bool = true) {
        self.init(maxHR: maxHR, restingHR: nil, method: .percentOfMax,
                  lowerBounds: Self.maxBounds(maxHR: maxHR), fallback: nil, automatic: automatic)
    }

    private init(maxHR: Int, restingHR: Int?, method: HeartRateZoneMethod,
                 lowerBounds: [Int], fallback: Fallback?, automatic: Bool) {
        self.maxHRIsAutomatic = automatic
        self.maxHR = maxHR
        self.restingHR = restingHR
        self.method = method
        self.lowerBounds = lowerBounds
        self.fallback = fallback
    }

    // MARK: Derivation

    /// ceil(pct × max / 100), in integers.
    private static func maxBounds(maxHR: Int) -> [Int] {
        defaultLowerPercents.map { (max(maxHR, 0) * $0 + 99) / 100 }
    }

    /// ceil(rest + pct × (max − rest) / 100), in integers.
    private static func reserveBounds(maxHR: Int, restingHR: Int) -> [Int] {
        defaultLowerPercents.map { restingHR + ((maxHR - restingHR) * $0 + 99) / 100 }
    }

    /// The resting heart rate, rounded to a whole bpm, when it can anchor a reserve: positive and
    /// below max.
    private static func usableResting(_ resting: Double?, maxHR: Int) -> Int? {
        guard let resting, resting.isFinite else { return nil }
        let rounded = Int(resting.rounded())
        return rounded > 0 && rounded < maxHR ? rounded : nil
    }

    // MARK: Validation

    /// Whether `bounds` is a usable custom set: exactly five values, each in `customRange`,
    /// strictly increasing.
    public static func isValidCustom(_ bounds: [Int]) -> Bool {
        guard bounds.count == 5, bounds.allSatisfy(customRange.contains) else { return false }
        return zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 }
    }

    // MARK: Reading

    /// The zone for a reading, or nil below zone 1's lower bound (and for a non-positive reading).
    public func zone(bpm: Int) -> HRZone? {
        guard bpm > 0 else { return nil }
        for zone in HRZone.allCases.reversed() where bpm >= lowerBound(of: zone) {
            return zone
        }
        return nil
    }

    public func lowerBound(of zone: HRZone) -> Int { lowerBounds[zone.rawValue - 1] }

    /// The highest bpm still in `zone`; nil for zone 5, which has no upper bound.
    public func upperBound(of zone: HRZone) -> Int? {
        zone == .extreme ? nil : lowerBounds[zone.rawValue] - 1
    }

    /// "120–139 bpm" for zones 1…4, "160+ bpm" for zone 5.
    public func rangeText(of zone: HRZone) -> String {
        if let upper = upperBound(of: zone) { return "\(lowerBound(of: zone))–\(upper) bpm" }
        return "\(lowerBound(of: zone))+ bpm"
    }

    /// One sentence for a `fallback`, shown with the zones; nil when the zones are the requested ones.
    public var fallbackNote: String? {
        switch fallback {
        case .noRestingHR?:
            return "No resting heart rate yet, so these zones use % of max heart rate."
        case .invalidCustom?:
            return "The custom zones are not valid, so these zones use % of max heart rate."
        case nil:
            return nil
        }
    }
}
