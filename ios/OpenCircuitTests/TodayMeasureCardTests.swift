import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// #245 / decision 47: the Vitals card leaves Today, and on-demand Measure moves under the metric
// detail's chart. Two things have to be pinned, because both have been silently broken before:
//
//  1. a layout saved by an older build still names `vitals`, and must keep loading — in its saved
//     order, without the card;
//  2. the Measure control itself. A UI PR once erased the on-demand HR/SpO₂ buttons with the tests
//     still green, so the enable rules, the device choice and the settled-HR rule are asserted here
//     against the pure `VitalMeasureState`, with no device in the room.
//
// Every value is synthetic.

final class DashboardSectionOrderTests: XCTestCase {

    /// A layout saved while the Vitals card still existed. Every other section keeps the order the
    /// user put it in; `vitals` is simply not there any more.
    func testASavedOrderNamingVitalsLoadsTheRestInItsSavedOrder() {
        let saved = "sync,vitals,goals,readiness,metrics,vitalsStatus,calories,cycle,headache"
        let order = DashboardSectionOrder.decode(saved)

        XCTAssertFalse(order.contains { $0.rawValue == "vitals" })
        XCTAssertEqual(order, [.sync, .goals, .metrics, .vitalsStatus, .calories, .cycle, .headache])
        XCTAssertEqual(Set(order), Set(DashboardSection.allCases), "every live section still loads")
    }

    /// The decode drops ids this build no longer has WITHOUT disturbing the rest — including the
    /// tab-move ids (`sleep`, `workout`, `trends`) that predate `vitals`, `readiness` (now the pinned
    /// scores card, decision 93), and duplicates, both retired (`readiness`) and live (`goals`).
    func testUnknownAndDuplicateIdsAreDroppedInPlace() {
        let order = DashboardSectionOrder.decode("sleep,readiness,vitals,workout,goals,readiness,goals,trends")
        XCTAssertFalse(order.contains { $0.rawValue == "readiness" })
        XCTAssertEqual(Array(order.prefix(3)), [.metrics, .goals, .vitalsStatus],
                       "a missing metrics goes first; the retired ids leave no gap")
    }

    /// First run (and any store with no saved layout): the canonical order, which no longer has a
    /// Vitals card in it.
    func testAnEmptySavedOrderGivesTheDefaultWithoutVitals() {
        XCTAssertEqual(DashboardSectionOrder.decode(""), DashboardSection.allCases)
        XCTAssertFalse(DashboardSection.allCases.contains { $0.rawValue == "vitals" })
    }

    /// `vitals` never comes back after a reorder: the saved order is re-encoded from live sections
    /// only, so the retired id is gone from the store the first time the user drags a card.
    func testVitalsNeverComesBackAfterAReorder() {
        let saved = "readiness,vitals,metrics,vitalsStatus,calories,goals,cycle,headache,sync"
        let full = DashboardSectionOrder.decode(saved)
        // Drag the Sync card (last) to the top, as a long-press-drag does.
        let moved = DashboardSectionOrder.reordered(full: full, visible: full,
                                                    from: IndexSet(integer: full.count - 1), to: 0)
        let written = DashboardSectionOrder.encode(moved)

        XCTAssertFalse(written.split(separator: ",").contains("vitals"),
                       "a retired id must never be written back")
        XCTAssertEqual(DashboardSectionOrder.decode(written), moved)
        XCTAssertEqual(moved.first, .sync)
        XCTAssertEqual(Set(moved), Set(DashboardSection.allCases))
    }

    /// A hidden section (the opt-in cycle / headache cards) comes back at its prior absolute
    /// position rather than being dropped — the rule `moveSection` relies on.
    func testAHiddenSectionIsMergedBackAtItsPriorPosition() {
        let full = DashboardSectionOrder.decode("")
        let visible = full.filter { $0 != .cycle && $0 != .headache }
        let moved = DashboardSectionOrder.reordered(full: full, visible: visible,
                                                    from: IndexSet(integer: 0), to: visible.count)
        XCTAssertEqual(Set(moved), Set(full))
        XCTAssertTrue(moved.contains(.cycle))
        XCTAssertTrue(moved.contains(.headache))
    }
}

final class VitalMeasureStateTests: XCTestCase {

    /// A ring that is connected, ready and doing nothing else.
    private var readyRing: RingMeasureFacts {
        var f = RingMeasureFacts()
        f.ready = true
        return f
    }

    // MARK: The control

    func testAReadyIdleRingOffersAnEnabledStartControl() {
        for vital in MeasuredVital.allCases {
            let s = VitalMeasureState.resolve(vital, ring: readyRing, strap: nil)
            XCTAssertEqual(s.control, .ring(active: false, enabled: true), "\(vital)")
            XCTAssertFalse(s.streaming)
            XCTAssertNil(s.statusText)
        }
    }

    /// Exactly `measureDisabled()`'s cases, one at a time, so none of them can be dropped in a
    /// refactor without this failing.
    func testEveryBusyRingStateDisablesTheControl() {
        let busy: [(String, WritableKeyPath<RingMeasureFacts, Bool>)] = [
            ("syncing", \.syncing),
            ("not streaming", \.notStreaming),
            ("calibrating", \.calibrationCapturing),
            ("historic pull", \.capturingHistoricPull),
            ("forensic sweep", \.capturingForensicSweep),
            ("probing", \.probing),
            ("workout holding", \.workoutHolding),
        ]
        for (name, flag) in busy {
            var ring = readyRing
            ring[keyPath: flag] = true
            XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil).control,
                           .ring(active: false, enabled: false), "heart rate while \(name)")
            XCTAssertEqual(VitalMeasureState.resolve(.spo2, ring: ring, strap: nil).control,
                           .ring(active: false, enabled: false), "SpO₂ while \(name)")
        }
    }

    /// Not ready = no control at all, not a greyed one (`measureButton` draws nothing).
    func testARingThatIsNotReadyOffersNoControl() {
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: RingMeasureFacts(), strap: nil).control, .none)
    }

    /// The stop button belongs only to a user-initiated measurement of THIS vital: an auto-measure
    /// or a workout cycle owns the link and must not be stoppable from here.
    func testOnlyAUserMeasurementOfThisVitalIsActive() {
        var ring = readyRing
        ring.monitoring = true
        ring.mode = .heartRate

        ring.userMeasuring = false
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil).control,
                       .ring(active: false, enabled: true), "an auto-measure is not the user's")
        XCTAssertTrue(VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil).streaming,
                      "it still streams, so the live chart shows — exactly as Today's live card does")

        ring.userMeasuring = true
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil).control,
                       .ring(active: true, enabled: true))
        XCTAssertEqual(VitalMeasureState.resolve(.spo2, ring: ring, strap: nil).control,
                       .ring(active: false, enabled: true), "the other vital's card is not active")
        XCTAssertFalse(VitalMeasureState.resolve(.spo2, ring: ring, strap: nil).streaming,
                       "an HR stream never draws on the SpO₂ card")
    }

    // MARK: The strap (decision 30)

    func testAStrapThatCanStreamOffersItsOwnButtonForHeartRateOnly() {
        let strap = StrapMeasureFacts(canMeasure: true)
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: nil, strap: strap).control, .strap)
        XCTAssertEqual(VitalMeasureState.resolve(.spo2, ring: nil, strap: strap).control, .none,
                       "decision 30: the strap has no on-demand SpO₂")
    }

    func testAStrapThatCannotStreamOffersNoControl() {
        let strap = StrapMeasureFacts(canMeasure: false)
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: nil, strap: strap).control, .none)
    }

    func testNoDeviceAtAllOffersNoControl() {
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: nil, strap: nil).control, .none)
    }

    /// The strap says "measuring…" until the first reading, then shows it.
    func testTheStrapSaysMeasuringUntilItHasAReading() {
        var strap = StrapMeasureFacts(canMeasure: true, measuring: true, liveHR: nil)
        var s = VitalMeasureState.resolve(.heartRate, ring: nil, strap: strap)
        XCTAssertEqual(s.statusText, "measuring…")
        XCTAssertNil(s.liveValue)
        XCTAssertTrue(s.streaming)

        strap.liveHR = 64
        s = VitalMeasureState.resolve(.heartRate, ring: nil, strap: strap)
        XCTAssertNil(s.statusText)
        XCTAssertEqual(s.liveValue, 64)
        XCTAssertTrue(s.isLive)
    }

    // MARK: Whether the card is drawn (#259)

    /// With no device ready the card still shows the latest recorded reading and its age; only the
    /// button is gone. It disappears only when there is nothing recorded either.
    func testWithNoDeviceReadyTheLatestReadingStillShowsWithoutAButton() {
        let notReady = [
            VitalMeasureState.resolve(.heartRate, ring: RingMeasureFacts(), strap: nil),
            VitalMeasureState.resolve(.heartRate, ring: nil, strap: StrapMeasureFacts(canMeasure: false)),
            VitalMeasureState.resolve(.heartRate, ring: nil, strap: nil),
            VitalMeasureState.resolve(.spo2, ring: nil, strap: nil),
        ]
        for s in notReady {
            XCTAssertEqual(s.control, .none, "the button stays gated on a ready device")
            XCTAssertTrue(s.showsCard(hasLatestReading: true), "the latest reading and its age still show")
            XCTAssertFalse(s.showsCard(hasLatestReading: false), "no empty card")
        }
    }

    /// A ready device, or a running stream, draws the card even before anything is recorded.
    func testAReadyDeviceOrALiveStreamDrawsTheCardWithNothingRecorded() {
        XCTAssertTrue(VitalMeasureState.resolve(.heartRate, ring: readyRing, strap: nil)
            .showsCard(hasLatestReading: false))
        XCTAssertTrue(VitalMeasureState.resolve(.heartRate, ring: nil,
                                                strap: StrapMeasureFacts(canMeasure: false, measuring: true))
            .showsCard(hasLatestReading: false))
    }

    // MARK: Settled heart rate

    /// The card must not render whichever poll frame arrived last. The repo's only real capture
    /// locks on 82, 84, 88, 90, 91, 66, 61 inside ONE measurement, so the last frame is a coin
    /// flip; `LiveHR.settled` answers with the median of the last five instead.
    func testTheCardSaysMeasuringUntilTheHeartRateSettlesAndThenShowsTheSettledValue() {
        let locked = [82, 84, 88, 90, 91, 66, 61]
        var ring = readyRing
        ring.userMeasuring = true
        ring.monitoring = true
        ring.mode = .heartRate

        for n in 0..<LiveHR.settleSampleCount {
            ring.liveHRTrend = Array(locked.prefix(n))
            ring.liveHR = ring.liveHRTrend.last
            let s = VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil)
            XCTAssertEqual(s.statusText, "measuring…", "only \(n) locked frames")
            XCTAssertNil(s.liveValue)
            XCTAssertFalse(s.isLive)
        }

        ring.liveHRTrend = locked
        ring.liveHR = locked.last           // 61 — the frame a last-frame display would show
        let s = VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil)
        XCTAssertNil(s.statusText)
        XCTAssertEqual(s.liveValue, LiveHR.settled(locked))
        XCTAssertEqual(s.liveValue, 88, "the median of the last five locked frames")
        XCTAssertNotEqual(s.liveValue, 61, "never the last frame")
        XCTAssertEqual(s.latestFrame, 61, "the big live readout still shows what Today's does")
    }

    /// Before live mode starts the ring is draining its backlog (#55) — say so rather than
    /// "measuring…", which would promise a reading that is not being taken yet.
    func testPreparingIsSaidWhileTheBacklogDrains() {
        var ring = readyRing
        ring.userMeasuring = true
        ring.monitoring = true
        ring.livePreparing = true
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil).statusText, "preparing…")
    }

    /// A quiet link must not let a lingering settled value read as current (#36).
    func testAStaleLinkWithholdsTheLiveValue() {
        var ring = readyRing
        ring.userMeasuring = true
        ring.monitoring = true
        ring.liveHRTrend = [70, 71, 72, 73, 74]
        XCTAssertEqual(VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil).liveValue, 72)

        ring.liveReadingsStale = true
        let s = VitalMeasureState.resolve(.heartRate, ring: ring, strap: nil)
        XCTAssertNil(s.liveValue, "a stale reading falls back to the latest STORED one")
        XCTAssertNil(s.statusText, "and it is not described as still measuring")
        XCTAssertFalse(s.isLive)
    }

    /// SpO₂'s live value is the decoded percent, with its "est." caveat, and it settles in one frame.
    func testSpO2ShowsItsDecodedPercentWithTheEstimateCaveat() {
        var ring = readyRing
        ring.userMeasuring = true
        ring.monitoring = true
        ring.mode = .spo2
        XCTAssertEqual(VitalMeasureState.resolve(.spo2, ring: ring, strap: nil).statusText, "measuring…")

        ring.liveSpO2 = 96
        XCTAssertEqual(VitalMeasureState.resolve(.spo2, ring: ring, strap: nil).liveValue, 96)
        XCTAssertEqual(MeasuredVital.spo2.caveat, "est.")
        XCTAssertNil(MeasuredVital.heartRate.caveat)
    }

    /// The ring is chosen whenever its session exists, exactly as the Vitals card chose.
    func testTheRingWinsWheneverItsSessionExists() {
        let s = VitalMeasureState.resolve(.heartRate, ring: readyRing,
                                          strap: StrapMeasureFacts(canMeasure: true))
        XCTAssertEqual(s.control, .ring(active: false, enabled: true))
    }

    // MARK: Which detail carries a card

    func testOnlyTheHeartRateAndSpO2DetailsCarryAMeasureCard() {
        XCTAssertEqual(TodayTile.Metric.restingHR.measuredVital, .heartRate,
                       "the Resting HR tile is the only heart-rate tile; its Day view is the day's HR")
        XCTAssertEqual(TodayTile.Metric.spo2.measuredVital, .spo2)
        for m: TodayTile.Metric in [.hrv, .respiratoryRate, .skinTemp, .steps] {
            XCTAssertNil(m.measuredVital, "\(m) has no on-demand read on either device")
        }
    }

    /// #259: a tap on Today's live card opens the detail that carries the SAME vital's Measure card,
    /// because that card's button is the stop control.
    func testTodaysLiveCardOpensTheDetailThatCanStopIt() {
        for vital in MeasuredVital.allCases {
            XCTAssertEqual(vital.detailMetric.measuredVital, vital, "\(vital)")
        }
    }

    // MARK: The latest reading

    /// A finished sync's newest reading can be newer than anything the cursor dedup let into the
    /// store (#67), and after a disconnect there is no batch at all.
    func testTheLatestReadingPrefersWhicheverSourceIsNewer() {
        let older = StampedReading(value: 58, start: Date(timeIntervalSince1970: 1_000))
        let newer = StampedReading(value: 72, start: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(StampedReading.newest(stored: older, synced: newer), newer)
        XCTAssertEqual(StampedReading.newest(stored: newer, synced: older), newer)
        XCTAssertEqual(StampedReading.newest(stored: older, synced: nil), older)
        XCTAssertEqual(StampedReading.newest(stored: nil, synced: newer), newer)
        XCTAssertNil(StampedReading.newest(stored: nil, synced: nil))
    }

    /// A stored SpO₂ sample is a fraction; a live one is already a whole percent. Mixing them up
    /// would render "0 %".
    func testStoredAndLiveReadingsAreFormattedInTheirOwnUnits() {
        XCTAssertEqual(MeasuredVital.spo2.formatStored(0.96), "96 %")
        XCTAssertEqual(MeasuredVital.spo2.formatLive(96), "96 %")
        XCTAssertEqual(MeasuredVital.heartRate.formatStored(58), "58 bpm")
        XCTAssertEqual(MeasuredVital.heartRate.formatLive(58), "58 bpm")
    }
}
