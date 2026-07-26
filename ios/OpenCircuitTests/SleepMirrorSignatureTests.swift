import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The night→Health mirror re-writes Apple Health only when the staging *signature* changes, so the
/// signature must (a) be stable for identical staging — otherwise every flush churns Health with a
/// delete/replace — and (b) change for any Health-visible staging difference, including an interior
/// awake→asleep reclassification that keeps the asleep TOTAL constant (exactly the 449→482 case that
/// left Apple Health frozen 33 min short of the card). These lock both directions in.
@MainActor
final class SleepMirrorSignatureTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_769_000_000)  // fixed reference

    private func seg(_ startMin: Double, _ endMin: Double, _ stage: SleepStage) -> SleepSegment {
        SleepSegment(start: base.addingTimeInterval(startMin * 60),
                     end: base.addingTimeInterval(endMin * 60), stage: stage)
    }

    /// A plausible night: in-bed span + latency-awake + a few sleep stages.
    private func night() -> [SleepSegment] {
        [
            seg(0, 520, .inBed),
            seg(0, 17, .awake),          // latency
            seg(17, 200, .asleepCore),
            seg(200, 260, .asleepDeep),
            seg(260, 380, .asleepREM),
            seg(380, 500, .asleepCore),
            seg(500, 520, .awake),       // brief pre-wake
        ]
    }

    func testIdenticalStagingHasIdenticalSignature() {
        XCTAssertEqual(HealthKitWriter.sleepSignature(night()),
                       HealthKitWriter.sleepSignature(night()),
                       "Same staging must sign identically — else the mirror rewrites Health every flush.")
    }

    func testSignatureIsOrderIndependent() {
        let shuffled = night().reversed().map { $0 }
        XCTAssertEqual(HealthKitWriter.sleepSignature(night()),
                       HealthKitWriter.sleepSignature(shuffled),
                       "Signature sorts by start, so input order must not matter.")
    }

    func testInteriorReclassificationChangesSignature() {
        // The bug: 33 min of interior AWAKE gets re-staged to ASLEEP on a later pass. The asleep
        // total grows but even if it DIDN'T, the stage samples differ — the mirror must notice.
        var restaged = night()
        // Flip the 500–520 pre-wake awake block to core sleep (interior reclassification).
        restaged[restaged.count - 1] = seg(500, 520, .asleepCore)
        XCTAssertNotEqual(HealthKitWriter.sleepSignature(night()),
                          HealthKitWriter.sleepSignature(restaged),
                          "A reclassified block must change the signature so Health is corrected.")
    }

    func testExtendedWakeChangesSignature() {
        var later = night()
        later[0] = seg(0, 560, .inBed)          // in-bed extends
        later.append(seg(520, 560, .asleepCore)) // slept 40 min longer
        XCTAssertNotEqual(HealthKitWriter.sleepSignature(night()),
                          HealthKitWriter.sleepSignature(later),
                          "A longer night must change the signature.")
    }

    func testSubSecondJitterDoesNotChangeSignature() {
        // Boundaries are rounded to the second, so re-derived dates with µs jitter must sign the same
        // (otherwise floating-point noise from re-staging would churn Health).
        let jittered = night().map {
            SleepSegment(start: $0.start.addingTimeInterval(0.4),
                         end: $0.end.addingTimeInterval(-0.3), stage: $0.stage)
        }
        XCTAssertEqual(HealthKitWriter.sleepSignature(night()),
                       HealthKitWriter.sleepSignature(jittered),
                       "Sub-second jitter must not change the signature.")
    }

    func testEmptyIsStable() {
        XCTAssertEqual(HealthKitWriter.sleepSignature([]), HealthKitWriter.sleepSignature([]))
    }
}
