import Observation
import SwiftData
import SwiftUI
import UIKit
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// Decision 75b: the dashboard's one coalesced store-change signal. Saves outside a sync refresh at
// once; during a sync at most once per interval, trailing; every way a sync ends refreshes exactly
// once, immediately. The strap's end paths run a real `HelioSession` against the simulated strap
// (`FakeZeppDevice`); the ring's `RingSession` needs CoreBluetooth, so its end paths are driven as the
// shapes its `syncing` takes (every ring end path sets `syncing = false`; a dropped link also drops
// the session). Every value and time is synthetic.

// MARK: - Strap fixtures

/// 2026-09-20T00:00:00Z: in the past, so `ingest`'s "not in the future" guard always passes.
private let sMidnight: TimeInterval = 1_789_862_400
private let sNow = Date(timeIntervalSince1970: sMidnight + 12 * 3600)
private let sKeyHex = "00112233445566778899aabbccddeeff"

private func sStamp(_ t: TimeInterval) -> [UInt8] {
    ZeppFetchTimestamp.encode(Date(timeIntervalSince1970: t), timeZone: TimeZone(identifier: "UTC")!)
}

/// 60 worn activity minutes from 23:00 (5 steps, HR 55 each).
private func sActivity() -> [UInt8] { (0..<60).flatMap { _ in [0x01, 0x08, 5, 55, 0, 0, 0, 0] as [UInt8] } }

private let sServices: [(endpoint: UInt16, flag: UInt8)] = [
    (0x0000, 0), (0x000A, 1), (0x000F, 0), (0x001A, 1), (0x001D, 0), (0x0029, 0), (0x0043, 0), (0x0047, 0), (0x004B, 0),
    (0x0082, 0),
]
private let sDeviceInfo: [UInt8] = [0x02, 0x01, 0x0c, 0, 0, 0, 0, 0, 0, 0]
    + Array("9.9.9.9".utf8) + [0] + Array("1.2.3.4".utf8) + [0]

private func sStrap() -> FakeZeppDevice {
    let device = FakeZeppDevice(authKey: ZeppHex.bytes(sKeyHex)!, privateKey: Array(UInt8(0x81)...UInt8(0x98)),
                                random: Array(UInt8(0xf0)...UInt8(0xff)), writeLength: 244)
    device.services = sServices
    device.deviceInfoReply = sDeviceInfo
    device.dataPacketLength = 200
    device.fetchData = [.activity: (sStamp(sMidnight - 3600), sActivity())]
    return device
}

/// `HelioTransport` over `FakeZeppDevice`, delivering queued events only when asked, as CoreBluetooth
/// does on later run-loop turns.
@MainActor
private final class SlowStrapTransport: HelioTransport {
    let device: FakeZeppDevice
    weak var session: HelioSession?
    var maxWriteLength = 244
    private var inbox: [(ZeppCharacteristic, [UInt8]?, Bool)] = []
    private let available = Set(ZeppCharacteristic.allCases).subtracting([.firmwareRevision, .currentTime])

    init(device: FakeZeppDevice) { self.device = device }

    func has(_ characteristic: ZeppCharacteristic) -> Bool { available.contains(characteristic) }
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        has(characteristic) && ![ZeppCharacteristic.hardwareRevision, .firmwareRevision, .currentTime].contains(characteristic)
    }
    func write(_ write: ZeppWrite) {
        for n in device.phoneWrote(write) { inbox.append((n.characteristic, n.bytes, false)) }
    }
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) { inbox.append((characteristic, nil, enabled)) }
    func read(_ characteristic: ZeppCharacteristic) {
        switch characteristic {
        case .hardwareRevision: inbox.append((characteristic, Array("9.9.9.9".utf8), false))
        case .batteryLevel: inbox.append((characteristic, [64], false))
        default: break
        }
    }

    var isEmpty: Bool { inbox.isEmpty }

    func drain(steps: Int = .max) {
        var n = 0
        while !inbox.isEmpty, n < steps {
            n += 1
            let (characteristic, bytes, enabled) = inbox.removeFirst()
            if let bytes { session?.received(characteristic, bytes) }
            else { session?.notificationStateChanged(characteristic, enabled: enabled, failed: false) }
        }
    }
}

@MainActor
private final class SKeyStore: HelioKeyStoring {
    var text: String? = sKeyHex
    var isRejected = false
    func load() -> ZeppAuthKey? { text.flatMap(HelioKeyText.parse) }
    func save(pasted text: String) throws -> Bool { self.text = text; return true }
    func forget() { text = nil }
    func markRejected() { isRejected = true }
}

/// What owns "the session", as `RingScanner` / `HelioConnection` do: the session goes when the link does.
@Observable
@MainActor
private final class SessionHolder<S: AnyObject> {
    var session: S?
}

/// The ring's session as far as the signal reads it.
@Observable
@MainActor
private final class FakeRingSession {
    var syncing = false
}

// MARK: - Tests

@MainActor
final class StoreRefreshSignalTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var clock = sNow
    private let ownership = OwnershipOverride()

    override func setUp() {
        super.setUp()
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: .distantPast)]))
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let c = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            StoredHeadacheEntry.self, StoredHeadacheRisk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return LocalStore(c.mainContext)
    }

    /// A signal following saves on `store`'s container only, recording each refresh's reason.
    private final class Recorder {
        var reasons: [StoreRefreshSignal.Reason] = []
        var breadcrumbs: [String] = []
        func count(_ r: StoreRefreshSignal.Reason) -> Int { reasons.filter { $0 == r }.count }
    }

    private func signal(_ store: LocalStore, interval: TimeInterval) -> (StoreRefreshSignal, Recorder) {
        let s = StoreRefreshSignal(interval: interval)
        let rec = Recorder()
        s.onRefresh = { rec.reasons.append($0) }
        s.breadcrumb = { rec.breadcrumbs.append($0) }
        s.observeSaves(of: store.context.container)
        return (s, rec)
    }

    private var nextHR = Date(timeIntervalSince1970: sMidnight + 13 * 3600)

    /// One save: one new ring heart-rate sample through `ingest`.
    private func save(_ store: LocalStore) throws {
        nextHR = nextHR.addingTimeInterval(60)
        _ = try store.ingest([QuantitySample(kind: .heartRate, start: nextHR, end: nextHR.addingTimeInterval(60), value: 70)])
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Lets the main actor run what is queued on it (the monitor's re-read after a change).
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: The signal itself

    func testASaveOutsideASyncRefreshesAtOnce() throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let before = s.version
        try save(store)
        XCTAssertEqual(s.version, before + 1, "the save refreshed before control came back")
        try save(store)
        try save(store)
        XCTAssertEqual(rec.reasons, [.save, .save, .save], "each save outside a sync refreshes")
    }

    func testSavesDuringASyncRefreshAtMostOncePerIntervalAndTheEndOnce() throws {
        let store = try makeStore()
        let interval: TimeInterval = 0.25
        let (s, rec) = signal(store, interval: interval)
        s.setSyncActive(true)
        let started = Date()
        for _ in 0..<30 {
            try save(store)
            pump(0.05)
        }
        let duration = Date().timeIntervalSince(started)
        let duringSync = rec.reasons.count
        XCTAssertEqual(rec.count(.save), 0, "no save refreshed on its own during the sync")
        XCTAssertLessThanOrEqual(duringSync, Int((duration / interval).rounded(.up)) + 1,
                                 "30 saves over \(duration) s refreshed \(duringSync) times")
        XCTAssertGreaterThanOrEqual(rec.count(.trailing), 1, "a long sync still refreshes on the way (trailing)")
        s.setSyncActive(false)
        XCTAssertEqual(rec.count(.syncEnd), 1, "the end refreshed at once")
        XCTAssertEqual(rec.reasons.last, .syncEnd)
    }

    func testTheSyncEndRefreshesOnceAndNothingTrailsIt() throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 0.3)
        s.setSyncActive(true)
        try save(store)   // a trailing refresh is now pending
        XCTAssertEqual(rec.reasons, [])
        s.setSyncActive(false)
        XCTAssertEqual(rec.reasons, [.syncEnd], "one refresh, immediately")
        pump(0.6)
        XCTAssertEqual(rec.reasons, [.syncEnd], "the pending trailing refresh was dropped, not run late")
        try save(store)
        XCTAssertEqual(rec.reasons, [.syncEnd, .save], "after the sync a save refreshes at once again")
    }

    func testASyncThatSavedNothingStillRefreshesOnceWhenItEnds() throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        s.setSyncActive(true)
        s.setSyncActive(false)
        XCTAssertEqual(rec.reasons, [.syncEnd])
    }

    // MARK: Ring end paths (the shapes `RingSession.syncing` takes)

    /// `finishSync` (success and every partial or failed outcome), `startLiveMonitoring` (a sync cancelled
    /// for a live reading) and `teardown` (a disconnect, a background run's capture ending) all set
    /// `syncing = false` on the same session; a dropped link also replaces or removes the session.
    func testEveryWayARingSyncEndsRefreshesOnceImmediately() async throws {
        enum End: CaseIterable { case finishedOrFailedOrCancelled, sessionDropped, sessionReplaced }
        for end in End.allCases {
            let store = try makeStore()
            let (s, rec) = signal(store, interval: 60)
            let scanner = SessionHolder<FakeRingSession>()
            scanner.session = FakeRingSession()
            s.followSyncs { scanner.session?.syncing == true }
            scanner.session?.syncing = true
            await settle()
            XCTAssertTrue(s.syncActive, "\(end): the sync was seen")
            try save(store)
            try save(store)
            XCTAssertEqual(rec.reasons, [], "\(end): saves during the sync wait")
            switch end {
            case .finishedOrFailedOrCancelled: scanner.session?.syncing = false
            case .sessionDropped: scanner.session = nil
            case .sessionReplaced: scanner.session = FakeRingSession()
            }
            await settle()
            XCTAssertFalse(s.syncActive, "\(end)")
            XCTAssertEqual(rec.reasons, [.syncEnd], "\(end): exactly one immediate refresh")
        }
    }

    func testSwitchingTheActiveDeviceMidSyncEndsTheSync() async throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let ring = SessionHolder<FakeRingSession>()
        ring.session = FakeRingSession()
        let choice = SessionHolder<NSString>()   // non-nil = the ring is chosen
        choice.session = "ring"
        s.followSyncs { choice.session != nil && ring.session?.syncing == true }
        ring.session?.syncing = true
        await settle()
        XCTAssertTrue(s.syncActive)
        choice.session = nil
        await settle()
        XCTAssertEqual(rec.reasons, [.syncEnd])
    }

    // MARK: Strap end paths (a real `HelioSession`)

    private struct StrapRig {
        let session: HelioSession
        let transport: SlowStrapTransport
        let device: FakeZeppDevice
    }

    private func connectStrap(_ device: FakeZeppDevice, store: LocalStore, autoSync: Bool) -> StrapRig {
        let transport = SlowStrapTransport(device: device)
        let keys = SKeyStore()
        let session = HelioSession(transport: transport, identityID: "5B1E4C2A-0000-4000-8000-0000000000B2",
                                   key: keys.load(), keyStore: keys, sink: HelioStoreSink(store: store),
                                   findState: HelioFindState(), clock: { [unowned self] in self.clock },
                                   autoTick: false, autoSyncOnConnect: autoSync)
        transport.session = session
        session.start()
        transport.drain()
        return StrapRig(session: session, transport: transport, device: device)
    }

    /// A strap sync stuck on a round the strap never answers (as in `HelioSessionTests`): in progress
    /// until something ends it.
    private func stuckStrapSync(_ store: LocalStore, _ s: StoreRefreshSignal,
                                _ connection: SessionHolder<HelioSession>, follow: Bool = true) async -> StrapRig {
        let device = sStrap()
        device.announcedLengths[.autoStress] = 4 << 20
        device.unansweredAckTypes = [.autoStress]
        if follow { s.followSyncs { connection.session?.syncing == true } }
        let rig = connectStrap(device, store: store, autoSync: true)
        connection.session = rig.session
        await settle()
        XCTAssertEqual(rig.session.phase, .syncing, "the strap sync is in progress")
        XCTAssertTrue(s.syncActive, "and the signal knows")
        return rig
    }

    func testAStrapSyncThatFinishesRefreshesOnceAtItsEnd() async throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let connection = SessionHolder<HelioSession>()
        s.followSyncs { connection.session?.syncing == true }
        let rig = connectStrap(sStrap(), store: store, autoSync: false)
        connection.session = rig.session
        await settle()
        XCTAssertEqual(rig.session.phase, .ready)
        rec.reasons = []
        rig.session.syncHistory(manual: true)
        await settle()
        XCTAssertTrue(s.syncActive)
        // The strap's replies arrive over many run-loop turns, as over Bluetooth.
        while !rig.transport.isEmpty {
            rig.transport.drain(steps: 3)
            await settle()
        }
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.lastSyncResult?.interrupted, false)
        XCTAssertGreaterThan(try store.context.fetchCount(FetchDescriptor<StoredSample>()), 0, "the sync stored rows")
        XCTAssertFalse(s.syncActive)
        XCTAssertEqual(rec.count(.save), 0, "the sync's saves did not refresh one by one")
        XCTAssertEqual(rec.count(.syncEnd), 1, "its end refreshed once")
    }

    func testAStrapSyncThatStallsOutRefreshesOnceAtItsEnd() async throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let connection = SessionHolder<HelioSession>()
        let rig = await stuckStrapSync(store, s, connection)
        rec.reasons = []
        clock = clock.addingTimeInterval(HelioSession.syncStallTimeout + 1)
        rig.session.tick(now: clock)
        rig.transport.drain()
        await settle()
        XCTAssertEqual(rig.session.lastSyncResult?.interrupted, true, "the watchdog ended it")
        XCTAssertEqual(rec.reasons.filter { $0 != .save }, [.syncEnd], "one immediate refresh at the end")
    }

    func testAStrapSyncCutByALostLinkRefreshesOnceAtItsEnd() async throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let connection = SessionHolder<HelioSession>()
        let rig = await stuckStrapSync(store, s, connection)
        rec.reasons = []
        rig.session.linkLost()
        connection.session = nil   // the connection lets the session go with its link
        await settle()
        XCTAssertFalse(s.syncActive)
        XCTAssertEqual(rec.reasons.filter { $0 != .save }, [.syncEnd])
    }

    func testAStrapSyncStoppedByABackgroundRunsExpiryRefreshesOnceAtItsEnd() async throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let connection = SessionHolder<HelioSession>()
        let rig = await stuckStrapSync(store, s, connection)
        rec.reasons = []
        rig.session.stopSyncForTeardown()   // `HelioBackgroundSyncService.tearDownForExpiry`
        rig.transport.drain()
        await settle()
        XCTAssertFalse(s.syncActive)
        XCTAssertEqual(rec.reasons.filter { $0 != .save }, [.syncEnd])
    }

    // MARK: Production wiring

    /// The default sync source is the active wearable's session (`ActiveWearable.session`), here a real
    /// strap session behind an injected `ActiveWearable`, as `HelioConnection` holds it.
    func testTheDefaultSyncSourceIsTheActiveWearablesSession() async throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        let connection = SessionHolder<HelioSession>()
        s.followSyncs(ActiveWearable(session: { connection.session }))
        let rig = await stuckStrapSync(store, s, connection, follow: false)
        XCTAssertTrue(s.syncActive, "the active session's sync was seen")
        rec.reasons = []
        rig.session.linkLost()
        connection.session = nil
        await settle()
        XCTAssertFalse(s.syncActive)
        XCTAssertEqual(rec.reasons.filter { $0 != .save }, [.syncEnd])
    }

    /// `AppDelegate` starts the shared signal at launch (the test host launched the app): it follows
    /// syncs, and a save anywhere moves it.
    func testTheAppStartsTheSharedSignalAtLaunch() throws {
        let shared = StoreRefreshSignal.shared
        XCTAssertTrue(shared.isFollowingSyncs, "launch did not start following syncs")
        let store = try makeStore()
        let before = shared.version
        try save(store)
        if shared.syncActive {
            XCTAssertGreaterThanOrEqual(shared.version, before)
        } else {
            XCTAssertEqual(shared.version, before + 1, "launch did not start following saves")
        }
    }

    // MARK: Breadcrumb (decision 75d ii)

    func testTheSyncEndLogsTheLongestMainThreadStallInCountsAndMilliseconds() throws {
        let store = try makeStore()
        let (s, rec) = signal(store, interval: 60)
        XCTAssertFalse(s.stallProbeRunning, "no probe outside a sync")
        s.setSyncActive(true)
        XCTAssertTrue(s.stallProbeRunning)
        pump(0.05)
        try save(store)
        Thread.sleep(forTimeInterval: 0.12)   // a 120 ms main-thread stall
        pump(0.05)
        s.setSyncActive(false)
        XCTAssertFalse(s.stallProbeRunning, "the probe stops with the sync")
        let line = try XCTUnwrap(rec.breadcrumbs.first)
        XCTAssertEqual(rec.breadcrumbs.count, 1)
        let fields = Dictionary(uniqueKeysWithValues: line.split(separator: " ").map { field -> (String, String) in
            let kv = field.split(separator: "=", maxSplits: 1)
            return (String(kv[0]), String(kv[1]))
        })
        XCTAssertEqual(Set(fields.keys), ["longest", "busy", "stretches", "saves", "refreshes"], line)
        let longest = try XCTUnwrap(Int(fields["longest"]!.dropLast(2)))
        XCTAssertGreaterThanOrEqual(longest, 110, line)
        XCTAssertLessThan(longest, 2_000, line)
        XCTAssertEqual(fields["saves"], "1")
        XCTAssertEqual(fields["refreshes"], "1", "the end's own refresh")
    }

    // MARK: The cards (no stale card after a sync)

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

    /// "Active (est.) N" on the Calories card, and the Sleep card's overnight-average HR.
    private func shown(_ vc: UIViewController) -> (active: String?, overnightHR: String?) {
        vc.view.layoutIfNeeded()
        let labels = AccessibilityTestSupport.labels(in: vc.view)
        let active = labels.lazy.compactMap { label in
            label.range(of: "Active (est.) ").map { String(label[$0.upperBound...]) }
        }.first
        var overnight: String?
        if let i = labels.firstIndex(of: "Overnight average"), let hr = labels[(i + 1)...].firstIndex(of: "HR"),
           hr + 1 < labels.count {
            overnight = labels[hr + 1]
        }
        return (active, overnight)
    }

    /// Synchronous on purpose: a nested run loop inside an `async` test does not run the cards'
    /// main-actor continuations, so their reads would never land while the test pumps.
    func testTheCardsShowThePostSyncDataOnceTheSyncEnds() throws {
        AccessibilityTestSupport.enableAutomation()
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let container = store.context.container
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        // Last night 18:00 → 02:00 with HR 60, then a quiet hour at HR 65. The sync's hard half hour
        // ends 15 minutes ago, so the day needs 4.5 hours behind it.
        let wake = today.addingTimeInterval(2 * 3_600)
        let bed = wake.addingTimeInterval(-8 * 3_600)
        guard now > today.addingTimeInterval(4.5 * 3_600) else { throw XCTSkip("needs 04:30 behind the day") }
        store.context.insert(StoredSleepSummary(night: today, asleepMin: 420, deepMin: 80, lightMin: 260, remMin: 80,
                                                awakeMin: 60, efficiency: 0.9, inBedStart: bed, inBedEnd: wake,
                                                sleepOnset: bed.addingTimeInterval(600), sleepWake: wake,
                                                sleepScore: 80, stressScore: 30))
        for i in 0..<48 {
            let t = bed.addingTimeInterval(Double(i) * 600)
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t, end: t.addingTimeInterval(60), value: 60))
        }
        for i in 0..<60 {
            let t = wake.addingTimeInterval(1_800 + Double(i) * 60)
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t, end: t.addingTimeInterval(60), value: 65))
        }
        try store.context.save()

        let (s, _) = signal(store, interval: 600)
        func cards() -> some View {
            VStack { CaloriesCardView(); SleepCardView() }
                .environment(\.storeRefreshSignal, s)
                .modelContainer(container)
        }
        let (window, vc) = host(cards())
        let before = shown(vc)
        XCTAssertNotNil(before.active, "labels: \(AccessibilityTestSupport.labels(in: vc.view))")
        XCTAssertEqual(before.overnightHR, "60")

        // A sync lands a hard half hour this morning and more of last night's heart rate.
        s.setSyncActive(true)
        for i in 0..<30 {
            let t = now.addingTimeInterval(-45 * 60 + Double(i) * 60)
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t, end: t.addingTimeInterval(60), value: 150))
            try store.context.save()
        }
        for i in 0..<48 {
            let t = bed.addingTimeInterval(Double(i) * 600 + 300)
            store.context.insert(StoredSample(kindRaw: MetricKind.heartRate.rawValue, start: t, end: t.addingTimeInterval(60), value: 90))
        }
        try store.context.save()
        pump(1.5)
        let during = shown(vc)
        XCTAssertEqual(during.active, before.active, "throttled: the 10-minute interval has not passed")
        XCTAssertEqual(during.overnightHR, "60")

        s.setSyncActive(false)
        pump(2.0)
        let after = shown(vc)
        // The same store, on a freshly built screen: what the post-sync data shows.
        let (freshWindow, freshVC) = host(cards())
        let fresh = shown(freshVC)
        XCTAssertNotEqual(fresh.active, before.active, "the sync's half hour moved the estimate")
        XCTAssertEqual(after.active, fresh.active, "the Calories card shows the post-sync data")
        XCTAssertEqual(fresh.overnightHR, "75")
        XCTAssertEqual(after.overnightHR, fresh.overnightHR, "the Sleep card shows the post-sync data")
        withExtendedLifetime((window, freshWindow)) {}
        window.rootViewController = nil
        freshWindow.rootViewController = nil
        pump(0.5)
    }

    // MARK: Day change (#297)

    func testADayChangeReKeysTheTodayReads() throws {
        let store = try makeStore()
        let container = store.context.container
        let cal = Calendar.current
        let day4 = cal.date(from: DateComponents(year: 2026, month: 5, day: 4))!
        let day5 = cal.date(byAdding: .day, value: 1, to: day4)!
        var now = day4.addingTimeInterval(23 * 3_600 + 55 * 60)
        let clock = DayClock(now: { now }, calendar: { cal })
        _ = DashboardReads.fetchThreadLog.takeTodayActivityDays(of: container)
        let (window, _) = host(
            VStack { GoalsCardView(); CaloriesCardView(); WellnessBalanceCardView() }
                .environment(\.dayClock, clock)
                .environment(\.storeRefreshSignal, StoreRefreshSignal(interval: 60))
                .modelContainer(container))
        XCTAssertEqual(Set(DashboardReads.fetchThreadLog.takeTodayActivityDays(of: container)), [day4], "built for the injected day")
        now = day5.addingTimeInterval(120)
        NotificationCenter.default.post(name: .currentDayMayHaveChanged, object: nil)
        pump(1.0)
        let after = DashboardReads.fetchThreadLog.takeTodayActivityDays(of: container)
        XCTAssertGreaterThanOrEqual(after.count, 3, "each card read again: \(after)")
        XCTAssertEqual(Set(after), [day5], "for the new day")
        window.rootViewController = nil
        pump(0.3)
    }
}
