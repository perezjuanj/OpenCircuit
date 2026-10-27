import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 79d (#331 item 5), review F2: the call LINES of the Vitals Status card and the Sleep card, not
// only the statics they call. Each card is rendered (hosted in a window) over a store with a strap night
// that carries an in-bed lead-in and over the same store without one; what the card itself produced (the
// Vitals Status report it hands to `onReport`, the Sleep card's "Overnight average" HR) must be the same.
// A card line that read the untrimmed in-bed window would average the lead-in's readings. Synchronous on
// purpose (as `StoreRefreshSignalTests`): a nested run loop inside an `async` test does not run the
// cards' main-actor continuations. Every value, time and identifier is synthetic.

@MainActor
final class StrapLeadInViewCallLineHostedTests: XCTestCase {
    private let ownership = OwnershipOverride()
    private var containers: [ModelContainer] = []
    private let calendar = Calendar.current
    private let strap = SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-00000000D07D")

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func host<V: View>(_ view: V) -> (UIWindow, UIHostingController<AnyView>) {
        let vc = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2_400))
        window.rootViewController = vc
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window.windowScene = scene }
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        pump(2.0)
        vc.view.layoutIfNeeded()
        return (window, vc)
    }

    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        pump(0.3)
    }

    /// A strap night asleep `bed…wake`, with the store path's lead-in from `leadIn` when given.
    private func saveStrapNight(bed: Date, wake: Date, leadIn: Date?, store: LocalStore) throws {
        let window = DateInterval(start: bed, end: wake)
        var segments = [SleepSegment(start: bed, end: wake, stage: .inBed), SleepSegment(start: bed, end: wake, stage: .asleepCore)]
        if let leadIn { segments = HelioSleepSelection.withLeadIn(segments, window: window, from: leadIn) }
        let start = segments.map(\.start).min()!
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments
        extras.skinTempC = 34.0
        XCTAssertEqual(try store.saveSleepSummary(SleepStaging.summary(segments), night: SleepNightKey.night(inBedStart: start, inBedEnd: wake),
                                                  inBedStart: start, inBedEnd: wake, sleepOnset: bed, sleepWake: wake,
                                                  extras: extras, device: strap), .inserted)
    }

    private func sample(_ kind: MetricKind, at t: Date, _ value: Double, store: LocalStore) {
        store.context.insert(StoredSample(kindRaw: kind.rawValue, start: t, end: t.addingTimeInterval(60), value: value, deviceID: strap.rawValue))
    }

    // MARK: Vitals Status

    /// Nine strap nights ending on the last nine mornings at 07:00 (asleep from 23:00; with a lead-in, in
    /// bed from 22:00), HRV every 5 min: 60 asleep (last night 42) and 35 in the hour before sleep.
    private func vitalsStore(leadIn: Bool) throws -> LocalStore {
        let store = try makeStore()
        let today = calendar.startOfDay(for: Date())
        for k in 0...8 {
            let day = calendar.date(byAdding: .day, value: -k, to: today)!
            let bed = day.addingTimeInterval(-3600), wake = day.addingTimeInterval(7 * 3600), lead = day.addingTimeInterval(-2 * 3600)
            try saveStrapNight(bed: bed, wake: wake, leadIn: leadIn ? lead : nil, store: store)
            for t in stride(from: lead.timeIntervalSince1970, to: wake.timeIntervalSince1970, by: 300) {
                let inLeadIn = t < bed.timeIntervalSince1970
                sample(.hrvSDNN, at: Date(timeIntervalSince1970: t + 30), inLeadIn ? 35 : (k == 0 ? 42 : 60), store: store)
            }
        }
        try store.context.save()
        return store
    }

    /// The report the card itself computed and handed to `onReport`, once its reads have landed.
    private func cardReport(_ store: LocalStore) throws -> VitalsBaseline.Report? {
        var reports: [VitalsBaseline.Report?] = []
        let (window, _) = host(VitalsStatusCardView(onReport: { reports.append($0) })
            .environment(\.storeRefreshSignal, StoreRefreshSignal(interval: 60))
            .modelContainer(store.context.container))
        pump(2.0)
        close(window)
        return try XCTUnwrap(reports.last, "the card reported")
    }

    func testTheVitalsStatusCardReadsAStrapNightWithoutItsLeadIn() throws {
        let without = try cardReport(vitalsStore(leadIn: false))
        let hrv = try XCTUnwrap(without?.signals.first { $0.vital == .overnightHRV }, "the card judged last night's HRV")
        XCTAssertNotNil(hrv.baselineMean)
        let with = try cardReport(vitalsStore(leadIn: true))
        XCTAssertEqual(with, without, "the lead-in's HRV is not averaged into the nights")
    }

    // MARK: The Sleep card

    /// Last night, asleep for 7 h until an hour ago (with a lead-in: in bed an hour before), HR every 10
    /// min: 60 asleep and 90 in the hour before sleep. The card's "Overnight average" HR.
    private func overnightHR(leadIn: Bool) throws -> String? {
        let store = try makeStore()
        // Whole minutes, as the strap's records are (a fraction of a second is pinned in the readers' tests).
        let wake = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 3600)
        let bed = wake.addingTimeInterval(-7 * 3600), lead = bed.addingTimeInterval(-3600)
        try saveStrapNight(bed: bed, wake: wake, leadIn: leadIn ? lead : nil, store: store)
        for t in stride(from: lead.timeIntervalSince1970, to: wake.timeIntervalSince1970, by: 600) {
            sample(.heartRate, at: Date(timeIntervalSince1970: t + 30), t < bed.timeIntervalSince1970 ? 90 : 60, store: store)
        }
        try store.context.save()
        let (window, vc) = host(SleepCardView()
            .environment(\.storeRefreshSignal, StoreRefreshSignal(interval: 60))
            .modelContainer(store.context.container))
        pump(1.0)
        vc.view.layoutIfNeeded()
        let labels = AccessibilityTestSupport.labels(in: vc.view)
        close(window)
        guard let i = labels.firstIndex(of: "Overnight average"), let hr = labels[(i + 1)...].firstIndex(of: "HR"),
              hr + 1 < labels.count else {
            XCTFail("no overnight HR on the card: \(labels)")
            return nil
        }
        return labels[hr + 1]
    }

    func testTheSleepCardsOvernightAverageReadsAStrapNightWithoutItsLeadIn() throws {
        AccessibilityTestSupport.enableAutomation()
        XCTAssertEqual(try overnightHR(leadIn: false), "60")
        XCTAssertEqual(try overnightHR(leadIn: true), "60", "the lead-in's heart rate is not averaged")
    }
}
