// User-configurable display units for temperature and distance (#83).
//
// All ring sensor values are STORED in SI (Celsius, metres). Only the display layer
// converts. Both enum types are `RawRepresentable` with a String raw value so they can
// be stored directly in `@AppStorage` without a custom binding.
//
// `localeDefault` uses `Locale.current.measurementSystem` (iOS 16+, which the app
// requires via its iOS 17 deployment target) to pick a sane out-of-box default.

import Foundation

// MARK: - Temperature

public enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
    case celsius    = "celsius"
    case fahrenheit = "fahrenheit"

    /// Convert a Celsius value to this unit.
    public func convert(fromCelsius c: Double) -> Double {
        switch self {
        case .celsius:    return c
        case .fahrenheit: return c * 9 / 5 + 32
        }
    }

    /// Convert a temperature DIFFERENCE (a delta/offset, e.g. "+0.5 °C above baseline") to this
    /// unit. A delta scales by the ratio only — the +32 offset of an ABSOLUTE conversion must NOT
    /// be applied, or a +0.5 °C delta would read as +32.9 °F. Always use this (never `convert`)
    /// for an offset-from-baseline.
    public func convertDelta(fromCelsius c: Double) -> Double {
        switch self {
        case .celsius:    return c
        case .fahrenheit: return c * 9 / 5
        }
    }

    /// The unit abbreviation shown next to a formatted value.
    public var symbol: String {
        switch self {
        case .celsius:    return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Sensible default inferred from the current locale (US → °F, everything else → °C).
    public static var localeDefault: TemperatureUnit {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
        }
        // Fallback for older OS versions: region-code heuristic.
        return Locale.current.regionCode == "US" ? .fahrenheit : .celsius
    }
}

// MARK: - Distance

public enum DistanceUnit: String, CaseIterable, Codable, Sendable {
    case metric   = "metric"    // kilometres
    case imperial = "imperial"  // miles

    /// Convert metres to this unit.
    public func convert(fromMeters m: Double) -> Double {
        switch self {
        case .metric:   return m / 1_000
        case .imperial: return m / 1_609.344
        }
    }

    public var symbol: String {
        switch self {
        case .metric:   return "km"
        case .imperial: return "mi"
        }
    }

    public static var localeDefault: DistanceUnit {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.measurementSystem == .us ? .imperial : .metric
        }
        return Locale.current.regionCode == "US" ? .imperial : .metric
    }
}

// MARK: - Formatter

/// Stateless helpers that turn raw SI values into localised display strings.
public enum UnitsFormatter {

    /// Format a Celsius value in the requested unit, e.g. "36.5 °C" or "97.7 °F".
    public static func temperature(_ celsius: Double, unit: TemperatureUnit,
                                   fractionDigits: Int = 1) -> String {
        let v = unit.convert(fromCelsius: celsius)
        return String(format: "%.\(fractionDigits)f \(unit.symbol)", v)
    }

    /// Format a temperature DELTA (offset from baseline) in the requested unit, signed, e.g.
    /// "+0.5 °C" or "+0.9 °F". Uses `convertDelta` (ratio only, no +32) so a small offset stays
    /// small after conversion — the fix for a baseline delta that was hardcoded to °C.
    public static func temperatureDelta(_ celsiusDelta: Double, unit: TemperatureUnit,
                                        fractionDigits: Int = 1) -> String {
        let v = unit.convertDelta(fromCelsius: celsiusDelta)
        return String(format: "%+.\(fractionDigits)f \(unit.symbol)", v)
    }

    /// Format a metres value in the requested unit, e.g. "3.2 km" or "2.0 mi".
    public static func distance(_ meters: Double, unit: DistanceUnit,
                                fractionDigits: Int = 1) -> String {
        let v = unit.convert(fromMeters: meters)
        return String(format: "%.\(fractionDigits)f \(unit.symbol)", v)
    }
}
