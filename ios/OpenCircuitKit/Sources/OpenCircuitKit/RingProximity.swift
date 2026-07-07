// RingProximity.swift — turn a BLE link RSSI into a human-facing "how close is my ring" estimate (#96).
//
// This backs the Find My Ring screen. The official app shows an approximate Bluetooth distance
// ("~3 ft") plus a locate-by-LED control; we mirror the distance readout from the live RSSI of the
// already-connected ring (CoreBluetooth `readRSSI()` works on a connected peripheral).
//
// RSSI→distance is intrinsically noisy — multipath, the wearer's body, and antenna orientation swing
// it several dBm — so the QUALITATIVE band is the primary signal and the distance is a rough hint,
// deliberately coarse. Distance uses the standard log-distance path-loss model:
//     d = 10^((txPower − rssi) / (10·n))
// where txPower = the RSSI you'd read at 1 m and n = the environmental path-loss exponent.

import Foundation

public enum RingProximity {

    /// Reference RSSI (dBm) at 1 m for the RingConn link — an empirical BLE ballpark (small low-power
    /// antenna, body-worn). Not ring-calibrated; only anchors the rough distance curve.
    public static let txPowerAt1m: Double = -59
    /// Path-loss exponent: 2.0 in free space, ~2.5–3.0 indoors with a body in the path. 2.5 splits it.
    public static let pathLossExponent: Double = 2.5

    /// Coarse proximity buckets — the reliable part of the estimate. Thresholds picked from observed
    /// RingConn link levels (contiguous, no gaps).
    public enum Band: Equatable, Sendable {
        case searching   // no / very weak signal
        case far
        case nearby
        case close
        case veryClose

        public var label: String {
            switch self {
            case .searching: return "Searching…"
            case .far:       return "Far"
            case .nearby:    return "Nearby"
            case .close:     return "Close"
            case .veryClose: return "Very close"
            }
        }
    }

    /// Map a (smoothed) RSSI to a band. `nil`, a non-negative value (CoreBluetooth's 127 "not
    /// available" sentinel), or anything below −95 dBm all read as "searching".
    public static func band(forRSSI rssi: Int?) -> Band {
        guard let rssi, rssi < 0 else { return .searching }
        switch rssi {
        case (-55)...:      return .veryClose
        case (-68)...(-56): return .close
        case (-80)...(-69): return .nearby
        case (-95)...(-81): return .far
        default:            return .searching   // < −95 dBm (or a bogus positive sentinel)
        }
    }

    /// Approximate distance in metres from RSSI via the path-loss model. `nil` when there's no usable
    /// signal (missing, non-negative sentinel, or beyond ~−100 dBm where the estimate is meaningless).
    public static func approximateMeters(forRSSI rssi: Int?) -> Double? {
        guard let rssi, rssi < 0, rssi > -100 else { return nil }
        let exponent = (txPowerAt1m - Double(rssi)) / (10.0 * pathLossExponent)
        return pow(10.0, exponent)
    }

    /// Approximate distance in feet. `nil` when there's no usable signal.
    public static func approximateFeet(forRSSI rssi: Int?) -> Double? {
        approximateMeters(forRSSI: rssi).map { $0 * 3.280839895 }
    }

    /// A short display string for the distance hint — "Right here" up close, "≈ N ft" in between, and
    /// "≈ 20+ ft" past the point the estimate is trustworthy. `nil` when there's no signal.
    public static func distanceText(forRSSI rssi: Int?) -> String? {
        guard let feet = approximateFeet(forRSSI: rssi) else { return nil }
        if feet < 1.5 { return "Right here" }
        if feet >= 20 { return "≈ 20+ ft" }
        return "≈ \(Int(feet.rounded())) ft"
    }

    /// Signal strength as a 0…1 fraction for a meter/dial, mapping −95…−45 dBm linearly onto 0…1.
    public static func signalFraction(forRSSI rssi: Int?) -> Double {
        guard let rssi else { return 0 }
        let clamped = Double(min(-45, max(-95, rssi)))
        return (clamped + 95.0) / 50.0
    }
}
