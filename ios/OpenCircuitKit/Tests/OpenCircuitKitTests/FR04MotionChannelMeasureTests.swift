import XCTest
@testable import OpenCircuitKit

// MEASUREMENT ENTRY POINTS for the FR04 raised-floor motion channel (#211). Neither test asserts a
// staging outcome: they exist so that every number written into `BulkSleep`'s doc comments — the
// per-night motion census and the `activityMagnitudeActiveCut` sweep — is re-derivable by one
// command instead of being retyped from a review note.
//
//   cd ios/OpenCircuitKit && \
//     OC_SLEEP_MOTION_CORPUS=<corpus-dir> swift test --filter FR04MotionChannelMeasureTests
//
// With the variable unset both entry points skip LOUDLY through `SleepReplay.requireCorpus`
// (docs/SLEEP_REPLAY_HARNESS.md §1) — a run without it proves nothing and says so.
//
// WHY A SWEEP AND NOT A FIT. `activityMagnitudeActiveCut` decides which epochs on the decoded
// `[15:23)` channel read as movement. Picking it by looking at one night's chart is the failure mode
// this project forbids, and there is no labelled Gen 2 Air night to fit against — so the honest
// artefact is the whole response curve over the whole corpus, printed, with the plateau visible.
// Read `BulkSleep.activityMagnitudeActiveCut` for what was concluded from it.
final class FR04MotionChannelMeasureTests: XCTestCase {

    /// The literal has to sit as `requireCorpus`'s FIRST ARGUMENT — a name held in a constant is
    /// exactly the shape `CorpusGateLoudnessTests` bans, because every other route ends in an
    /// Optional whose nil becomes a silent early return that XCTest reports as PASSED.
    private func corpus(_ purpose: String) throws -> URL {
        try SleepReplay.requireCorpus(
            "OC_SLEEP_MOTION_CORPUS",
            purpose: purpose,
            consequence: "No motion-channel measurement was produced, so any census or sweep number "
                       + "you were about to quote is from a stale note, not from this tree.")
    }

    // MARK: - Census: what the two channels look like on each corpus night

    /// Per night, over WORN epochs of the whole file (which is the scope `motionSource` is really
    /// evaluated at — `latestNightRecords` hands it the full ~30 h archive union):
    ///   • `placeholder`  — share whose `[10:15]` is a constant run
    ///   • `medMin`       — median per-epoch `min(raw[10..<15])`, the raised-pedestal statistic
    ///   • `quiet`        — epochs the DECODED magnitude channel calls motionless
    ///   • `intraStill`   — of those, the share `motionResolvesStillness` (the intra-epoch proxy)
    ///   • `floorStill`   — of those, the share `primaryChannelIsStillAfterFloor` (what `detect()`
    ///                      actually consumes). The gap between the last two columns is the whole
    ///                      argument for measuring through the rolling floor.
    ///   • `source`       — the channel selected with the flag OFF and with it ON
    func testMotionChannelCensus() throws {
        let dir = try corpus("the per-night motion-channel census")
        let nights = try SleepReplay.loadManifest(at: dir)
        let on = BulkSleep.MotionChannelPolicy(magnitudeChannelEnabled: true)

        print("\n=== FR04 MOTION-CHANNEL CENSUS — corpus \(dir.path)")
        print(String(format: "%-22@ %6@ %6@ %11@ %7@ %6@ %10@ %10@ %-16@ %-20@",
                     "night" as NSString, "recs" as NSString, "worn" as NSString,
                     "placeholder" as NSString, "medMin" as NSString, "quiet" as NSString,
                     "intraStill" as NSString, "floorStill" as NSString,
                     "source(off)" as NSString, "source(on)" as NSString))
        var measured = 0
        for n in nights where !n.recordsFile.isEmpty {
            let recs = try SleepReplay.loadRecords(n, in: dir)
            let worn = recs.filter { $0.layout != .idle }
            guard !worn.isEmpty else { continue }
            let quiet = worn.indices.filter { worn[$0].activityMagnitudesAreZero }
            let floorStill = BulkSleep.primaryChannelIsStillAfterFloor(worn)
            let placeholder = Double(worn.filter(\.motionIsPlaceholder).count) / Double(worn.count)
            let medMin = quiet.isEmpty ? -1 : BulkSleep.medianQuietMinimum(quiet.map { worn[$0] })
            let intra = quiet.isEmpty ? Double.nan
                : Double(quiet.filter { worn[$0].motionResolvesStillness }.count) / Double(quiet.count)
            let floor = quiet.isEmpty ? Double.nan
                : Double(quiet.filter { floorStill[$0] }.count) / Double(quiet.count)
            print(String(format: "%-22@ %6d %6d %10.1f%% %7d %6d %9.1f%% %9.1f%% %-16@ %-20@",
                         n.id as NSString, recs.count, worn.count, placeholder * 100, medMin,
                         quiet.count, intra * 100, floor * 100,
                         "\(BulkSleep.motionSource(recs))" as NSString,
                         "\(BulkSleep.motionSource(recs, policy: on))" as NSString))
            measured += 1
        }
        // The gate above stops a MISSING corpus; this stops an EMPTY one — a census that walked no
        // night would otherwise print a header and pass.
        XCTAssertGreaterThan(measured, 0, "no night carried records — nothing was censused")
    }

    // MARK: - Sweep: the whole response curve of `activityMagnitudeActiveCut`

    /// The ladder. Absolute Σ-magnitude values spanning "every positive stir is movement" (1) to
    /// well past the shipped-in-the-PR 700, so the plateau structure is visible rather than assumed.
    private static let cuts = [1, 25, 50, 75, 100, 125, 150, 200, 250, 300, 350, 400,
                               500, 600, 700, 900, 1100, 1500, 2000]

    func testSweepActivityMagnitudeActiveCut() throws {
        let dir = try corpus("the activityMagnitudeActiveCut sweep")
        let nights = try SleepReplay.loadManifest(at: dir).filter { !$0.recordsFile.isEmpty }

        // Row 0 is the shipped default (flag OFF) — the thing every sweep row is a delta against.
        var off: [String: (wake: String, asleep: Int)] = [:]
        for n in nights {
            let r = try SleepReplay.measure(n, in: dir)
            off[n.id] = (SleepReplay.clock(r.wake, n.timeZone), r.asleepMin)
        }

        print("\n=== activityMagnitudeActiveCut SWEEP — corpus \(dir.path)")
        print("=== flag OFF (shipped default):")
        for n in nights { print("      \(n.id)  wake \(off[n.id]!.wake)  asleepMin \(off[n.id]!.asleep)") }
        print("=== flag ON, per cut — only nights whose staged night MOVES are listed:")

        var moved = 0
        for cut in Self.cuts {
            let policy = BulkSleep.MotionChannelPolicy(magnitudeChannelEnabled: true,
                                                       magnitudeActiveCut: cut)
            var deltas: [String] = []
            for n in nights {
                let r = try SleepReplay.measure(n, in: dir, motionPolicy: policy)
                let wake = SleepReplay.clock(r.wake, n.timeZone)
                guard let base = off[n.id], base.wake != wake || base.asleep != r.asleepMin else { continue }
                deltas.append("\(n.id): wake \(base.wake) -> \(wake), "
                              + "asleepMin \(base.asleep) -> \(r.asleepMin)")
                moved += 1
            }
            print(String(format: "  cut %5d  %@", cut,
                         (deltas.isEmpty ? "— no night moves" : deltas.joined(separator: " | ")) as NSString))
        }
        XCTAssertGreaterThan(moved, 0,
                             "the sweep moved NO night at ANY cut — either the corpus holds no "
                             + "raised-floor archive or the channel is unreachable; in both cases "
                             + "this run is not evidence that the cut was chosen from data")
    }
}
