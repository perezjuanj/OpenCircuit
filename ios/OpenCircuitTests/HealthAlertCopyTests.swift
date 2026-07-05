import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The elevated-HR-while-inactive alert used to word its body around the sample that COMPLETED the
/// 10-minute run ("stayed elevated (above 143 bpm)"), which read as if 143 were the trigger threshold.
/// It must instead cite the user's CONFIGURED threshold. (UX sweep #159)
@MainActor
final class HealthAlertCopyTests: XCTestCase {
    func testElevatedHRCopyCitesConfiguredThresholdNotCompletingSample() {
        let threshold = HealthAlertDefaults.thresholds().elevatedHRBpm   // default 100
        // hit.value is the completing reading (e.g. 143), deliberately different from the threshold.
        let hit = HealthAlertHit(notification: .elevatedHRInactive, value: 143, time: Date())
        let (_, body) = HealthNotificationCenter.copy(for: .elevatedHRInactive, hit: hit)

        XCTAssertTrue(body.contains("\(threshold) bpm threshold"),
                      "copy must cite the configured threshold; got: \(body)")
        XCTAssertFalse(body.contains("143"),
                       "copy must NOT present the completing sample (143) as the threshold; got: \(body)")
    }
}
