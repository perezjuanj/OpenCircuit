// Today's strain words (#216), kept out of the views so a test can pin them. The number is `DailyStrain`
// over today's heart rate from the shared trends load (`TrendsData.todayStrain`), on the 0…21 scale
// `Strain` computes. Since decision 93 it shows on Today's scores card (the Strain dial) and the
// Strain detail (`StrainDetailView`), no longer as a tile in Your Numbers.
//
// It has no usual range and no "vs usual": today's strain is a running total that only grows until
// midnight, so comparing it with whole past days would read every morning as "below usual".
//
// Honest when it can't score: no heart rate today, under the 10 minutes `Strain` needs, or no resting
// heart rate to build zones on each say so in words, never a 0. Wording is device-neutral ("your
// wearable"): every wearer sees it.

import SwiftUI
import OpenCircuitKit

/// The tile's words, kept out of the view so a test can pin them.
enum StrainTileText {
    /// "8.4", or nil when there is no score.
    static func value(_ reading: DailyStrain.Reading?) -> String? {
        reading?.strain.map { String(format: "%.1f", $0) }
    }

    /// The line under the value: the band while there's a score, else nothing.
    static func bandLine(_ reading: DailyStrain.Reading?) -> String? {
        reading?.band.map { "\($0.label) · so far today" }
    }

    /// The bottom line: what the number is, or why there isn't one.
    static func status(_ reading: DailyStrain.Reading?) -> String {
        guard let reading, !reading.hasNoData else { return "No heart rate yet today" }
        if reading.strain != nil { return "Heart-rate effort · 0–21 scale" }
        if reading.coveredSeconds < DailyStrain.minCoveredSeconds {
            let need = DailyStrain.minCoveredSeconds / 60
            return "Needs \(need) min of heart rate · \(reading.coveredSeconds / 60) min so far"
        }
        return "Needs a resting heart rate first"
    }

    /// "as of 9:41 AM" from the newest reading used, or nil without one.
    static func freshness(_ reading: DailyStrain.Reading?) -> String? {
        reading?.latestSampleAt.map { "as of \($0.formatted(date: .omitted, time: .shortened))" }
    }

    static func accessibilityLabel(_ reading: DailyStrain.Reading?) -> String {
        var parts = ["Strain"]
        if let reading, let strain = reading.strain {
            parts.append("\(String(format: "%.1f", strain)) out of 21")
            if let band = reading.band { parts.append("\(band.label), so far today") }
            if let fresh = freshness(reading) { parts.append(fresh) }
            parts.append("Heart-rate effort on a 0 to 21 scale")
        } else {
            parts.append(status(reading).replacingOccurrences(of: " · ", with: ", "))
        }
        return parts.joined(separator: ". ")
    }
}
