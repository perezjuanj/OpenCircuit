// Today's one Vitals Status computation (#396, decision 95a; replaces #395's hidden-card runner).
//
// The verdict feeds Recovery and the sentence's fever pair, so it must not depend on the Vitals Status
// card's row: a shown card below the fold is never built by the lazy list, a hidden one isn't drawn,
// and a moved one is built at a different time. `TodayVitalsRunner` is exactly one
// `VitalsStatusLoader` behind Today's content (outside the list), and the card only displays its report.
//
// Recovery waits for the first complete report (local history and the Apple Health fallback both tried)
// so it shows one number from launch, never the two-factor value and then the three-factor one. A read
// that never completes settles after `settleTimeout`, as no verdict: then Recovery is the two-factor score.

import SwiftUI
import OpenCircuitKit

/// The Vitals Status verdict as Recovery reads it.
struct TodayVitals: Equatable {
    /// The report; nil while there isn't enough baseline history (or before the first one lands).
    var report: VitalsBaseline.Report?
    /// The first complete report has landed, or the wait timed out. Until then Recovery is pending.
    var settled: Bool

    /// Before the first report: Recovery waits.
    static let pending = TodayVitals(report: nil, settled: false)
    /// Settled with no verdict: Recovery is the two-factor score. Also what a caller without a loader passes.
    static let noVerdict = TodayVitals(report: nil, settled: true)

    /// Folds one loader result in. Once settled it stays settled; the report always follows the newest.
    func receiving(_ result: VitalsStatusLoader.Result) -> TodayVitals {
        TodayVitals(report: result.report, settled: settled || result.isComplete)
    }
}

/// Today's one `VitalsStatusLoader`, mounted as a background behind Today's content (never inside the
/// list), reporting every change of the verdict and settling after `settleTimeout` at the latest.
struct TodayVitalsRunner: View {
    /// How long Recovery waits for a complete report before it settles with what it has.
    static var settleTimeout: Duration { .seconds(6) }

    let onChange: (TodayVitals) -> Void

    @State private var vitals = TodayVitals.pending

    var body: some View {
        VitalsStatusLoader { result in publish(vitals.receiving(result)) }
            .task {
                try? await Task.sleep(for: Self.settleTimeout)
                if !vitals.settled { publish(TodayVitals(report: vitals.report, settled: true)) }
            }
    }

    private func publish(_ new: TodayVitals) {
        vitals = new
        onChange(new)
    }
}
