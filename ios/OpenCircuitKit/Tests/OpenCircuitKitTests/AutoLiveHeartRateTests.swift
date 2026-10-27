import XCTest
@testable import OpenCircuitKit

// Decision 81 (#336): every branch of the pure decision behind "Live heart rate when the app opens".
final class AutoLiveHeartRateTests: XCTestCase {
    typealias Inputs = AutoLiveHeartRate.Inputs

    private let activated = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Ready, idle, in front, one second after the activation: the one case that starts.
    private func inputs(_ edit: (inout Inputs) -> Void = { _ in }) -> Inputs {
        var i = Inputs(supported: true, settingOn: true, inFront: true, activatedAt: activated,
                       now: activated.addingTimeInterval(1), sessionReady: true, syncing: false,
                       syncRanSinceActivation: false, syncStillToDecide: false, owner: .none,
                       alreadyAutoStarted: false, stoppedByPerson: false)
        edit(&i)
        return i
    }

    private func decide(_ edit: (inout Inputs) -> Void = { _ in }) -> AutoLiveHeartRate.Decision {
        AutoLiveHeartRate.decide(inputs(edit))
    }

    // MARK: 81a

    func testReadyIdleAndInFrontStartsNow() {
        XCTAssertEqual(decide(), .startNow)
    }

    func testDeviceWithoutTheCapabilityNeverStarts() {
        XCTAssertEqual(decide { $0.supported = false }, .never)
    }

    func testSettingOffNeverStarts() {
        XCTAssertEqual(decide { $0.settingOn = false }, .never)
    }

    func testSessionNotReadyWaits() {
        XCTAssertEqual(decide { $0.sessionReady = false }, .wait)
    }

    func testSessionNotReadyStillWaitsLongAfterActivationWhenNoSyncIsInvolved() {
        XCTAssertEqual(decide {
            $0.sessionReady = false
            $0.now = activated.addingTimeInterval(600)
        }, .wait)
    }

    func testSyncRunningWaits() {
        XCTAssertEqual(decide { $0.syncing = true }, .wait)
    }

    func testStartsWhenTheSyncEndsWithinTwoMinutes() {
        XCTAssertEqual(decide {
            $0.syncRanSinceActivation = true
            $0.now = activated.addingTimeInterval(90)
        }, .startNow)
    }

    func testStartsWhenTheSyncEndsExactlyAtTwoMinutes() {
        XCTAssertEqual(decide {
            $0.syncRanSinceActivation = true
            $0.now = activated.addingTimeInterval(AutoLiveHeartRate.afterSyncWindow)
        }, .startNow)
    }

    func testDoesNotStartWhenTheSyncEndsAfterTwoMinutes() {
        XCTAssertEqual(decide {
            $0.syncRanSinceActivation = true
            $0.now = activated.addingTimeInterval(AutoLiveHeartRate.afterSyncWindow + 1)
        }, .never)
    }

    func testStillSyncingAfterTwoMinutesNeverStarts() {
        XCTAssertEqual(decide {
            $0.syncing = true
            $0.syncRanSinceActivation = true
            $0.now = activated.addingTimeInterval(AutoLiveHeartRate.afterSyncWindow + 1)
        }, .never)
    }

    func testLeftTheFrontNeverStartsEvenAfterASync() {
        XCTAssertEqual(decide {
            $0.inFront = false
            $0.syncRanSinceActivation = true
        }, .never)
    }

    func testLeftTheFrontWhileWaitingNeverStarts() {
        XCTAssertEqual(decide {
            $0.inFront = false
            $0.sessionReady = false
        }, .never)
    }

    // MARK: 81b

    func testWorkoutOwnedStreamNeverStarts() {
        XCTAssertEqual(decide { $0.owner = .workout }, .never)
    }

    func testWorkoutOwnedStreamNeverStartsWhileSyncingEither() {
        XCTAssertEqual(decide {
            $0.owner = .workout
            $0.syncing = true
        }, .never)
    }

    func testMeasureAlreadyRunningNeverStartsAnother() {
        XCTAssertEqual(decide { $0.owner = .measure }, .never)
    }

    func testForegroundSyncNotYetDecidedWaitsSoItIsNeverDelayed() {
        XCTAssertEqual(decide { $0.syncStillToDecide = true }, .wait)
    }

    // MARK: 81c

    func testAtMostOneAutomaticStartPerActivation() {
        XCTAssertEqual(decide { $0.alreadyAutoStarted = true }, .never)
    }

    func testManualStopIsRespectedUntilTheNextActivation() {
        XCTAssertEqual(decide { $0.stoppedByPerson = true }, .never)
    }

    func testANewActivationAsksAfresh() {
        let second = activated.addingTimeInterval(1_000)
        XCTAssertEqual(decide {
            $0.activatedAt = second
            $0.now = second.addingTimeInterval(1)
        }, .startNow)
    }
}
