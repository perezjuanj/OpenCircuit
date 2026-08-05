import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

// The export watermark ("only sessions I haven't exported yet") and the disconnected-export ring
// metadata cache.
//
// The watermark shares the `StoredCursor` table with the ingest and `hk:` HealthKit cursors under an
// `export:` prefix, so the two things worth pinning are: it is FORWARD-ONLY (a watermark that can
// regress silently re-offers nights the user already exported), and it stays invisible to the
// store-ingest cursor it shares a table with.
@MainActor
final class ExportWatermarkTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    func testWatermarkIsNilBeforeAnyExport() throws {
        let store = try makeStore()
        XCTAssertNil(store.lastExportWatermark())
    }

    func testFirstExportSetsTheWatermark() throws {
        let store = try makeStore()
        try store.markExported(through: at(8))
        XCTAssertEqual(store.lastExportWatermark(), at(8))
    }

    func testWatermarkIsForwardOnly() throws {
        let store = try makeStore()
        try store.markExported(through: at(8))
        try store.markExported(through: at(2))
        XCTAssertEqual(store.lastExportWatermark(), at(8),
                       "an earlier export must be a no-op, never a regression")
        try store.markExported(through: at(8))
        XCTAssertEqual(store.lastExportWatermark(), at(8), "re-exporting the same range is idempotent")
        try store.markExported(through: at(32))
        XCTAssertEqual(store.lastExportWatermark(), at(32))
        try store.markExported(through: .distantPast)
        XCTAssertEqual(store.lastExportWatermark(), at(32))
    }

    func testWatermarkSurvivesAFreshStoreOverTheSameContext() throws {
        let store = try makeStore()
        try store.markExported(through: at(8))
        // A second LocalStore over the same context is what the App Intent path constructs.
        XCTAssertEqual(LocalStore(store.context).lastExportWatermark(), at(8))
    }

    // MARK: - The CONTENT watermark ("has this night changed since I exported it?")

    func testContentWatermarkIsNilBeforeAnyExport() throws {
        XCTAssertNil(try makeStore().lastExportContentWatermark())
    }

    func testContentWatermarkIsForwardOnly() throws {
        let store = try makeStore()
        try store.markExported(through: at(8), contentAsOf: at(9))
        try store.markExported(through: at(8), contentAsOf: at(3))
        XCTAssertEqual(store.lastExportContentWatermark(), at(9),
                       "an earlier read time must be a no-op, never a regression")
        try store.markExported(through: at(8), contentAsOf: at(20))
        XCTAssertEqual(store.lastExportContentWatermark(), at(20))
    }

    /// The two watermarks answer different questions and must move independently. An export whose
    /// newest night is not settled yet advances no NIGHT watermark, but it still read its rows at a
    /// known instant — blocking that on the night watermark would leave a re-offered older night
    /// re-offered forever, because its `updatedAt` would stay ahead of a frozen content watermark.
    func testContentWatermarkAdvancesEvenWhenTheNightWatermarkDoesNot() throws {
        let store = try makeStore()
        try store.markExported(through: at(8), contentAsOf: at(9))
        try store.markExported(through: at(2), contentAsOf: at(15))
        XCTAssertEqual(store.lastExportWatermark(), at(8), "night watermark still forward-only")
        XCTAssertEqual(store.lastExportContentWatermark(), at(15))
    }

    func testContentWatermarkStaysOutOfTheIngestCursor() throws {
        let store = try makeStore()
        let before = try store.loadCursor()
        try store.markExported(through: at(8), contentAsOf: at(9))
        XCTAssertEqual(try store.loadCursor(), before,
                       "both export rows must be filtered out of the store-ingest cursor")
    }

    /// It lives in the same table as the ingest cursor, so it must never be mistaken for one — an
    /// export watermark leaking into `SyncCursor` would gate real sample ingestion.
    func testExportWatermarkDoesNotEnterTheIngestCursor() throws {
        let store = try makeStore()
        let before = try store.loadCursor()
        try store.markExported(through: at(8))
        XCTAssertEqual(try store.loadCursor(), before,
                       "the export row must be filtered out of the store-ingest cursor")

        // And ingestion still works normally afterwards.
        let sample = QuantitySample(kind: .heartRate, start: at(1), end: at(1), value: 60)
        XCTAssertEqual(try store.ingest([sample]).count, 1)
    }
}

// MARK: - Ring metadata cache (export metadata while the ring is DISCONNECTED)

final class RingMetadataStoreTests: XCTestCase {
    private let suiteName = "test.RingMetadataStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEmptyBeforeAnyRingConnects() {
        XCTAssertEqual(RingMetadataStore(defaults).load(), RingMetadataSnapshot())
    }

    func testRecordsModelFirmwareAndGeneration() {
        let store = RingMetadataStore(defaults)
        store.record(from: FirmwareInfo(version: "FR02.018", modelName: "RingConn Gen2"),
                     identifier: "ring-A")
        let snapshot = store.load()
        XCTAssertEqual(snapshot.modelName, "RingConn Gen2")
        XCTAssertEqual(snapshot.version, "FR02.018")
        XCTAssertEqual(snapshot.generation, RingGeneration.gen2.rawValue)
        XCTAssertEqual(snapshot.identifier, "ring-A")
    }

    func testUnknownGenerationIsBlankNotTheWordUnknown() {
        let store = RingMetadataStore(defaults)
        store.record(from: FirmwareInfo(version: "", modelName: "RingConn"), identifier: "ring-A")
        XCTAssertEqual(store.load().generation, "",
                       "an unread firmware string must not be exported as a guessed generation")
    }

    /// DIS characteristics arrive one at a time: the model name is seeded at connect, the firmware
    /// string lands later. A partial later write for the SAME ring must not erase what we know.
    func testPartialUpdateForTheSameRingKeepsEarlierFields() {
        let store = RingMetadataStore(defaults)
        store.record(from: FirmwareInfo(version: "FR02.018", modelName: "RingConn Gen2"),
                     identifier: "ring-A")
        store.record(from: FirmwareInfo(version: "", modelName: ""), identifier: "ring-A")
        let snapshot = store.load()
        XCTAssertEqual(snapshot.version, "FR02.018")
        XCTAssertEqual(snapshot.modelName, "RingConn Gen2")
        XCTAssertEqual(snapshot.generation, RingGeneration.gen2.rawValue)
    }

    /// A different ring replaces the record wholesale — one ring's firmware must never be reported
    /// under another ring's identifier (#multi-ring).
    func testDifferentRingReplacesTheWholeRecord() {
        let store = RingMetadataStore(defaults)
        store.record(from: FirmwareInfo(version: "FR02.018", modelName: "RingConn Gen2"),
                     identifier: "ring-A")
        store.record(from: FirmwareInfo(version: "", modelName: "RingConn Air"), identifier: "ring-B")
        let snapshot = store.load()
        XCTAssertEqual(snapshot.identifier, "ring-B")
        XCTAssertEqual(snapshot.modelName, "RingConn Air")
        XCTAssertEqual(snapshot.version, "", "ring-A's firmware must not be attributed to ring-B")
        XCTAssertEqual(snapshot.generation, "")
    }

    /// PRIVACY: an export is a file the user hands to third parties. The MAC is a stable hardware
    /// identifier and must never reach it, so it must never be cached here in the first place.
    ///
    /// The fixture is the REAL advertised name. `FirmwareInfo.modelName` is seeded from
    /// `CBPeripheral.name` and nothing ever replaces it, so "RingConn Gen2-03AD" — not the tidy
    /// "RingConn Gen2" this test used to hand it — is what every install actually caches, and the
    /// suffix is the last two bytes of that ring's MAC F8:79:99:F7:03:AD (🟢 docs/PROTOCOL.md:55).
    func testMACIsNeverPersisted() {
        let mac = "AA:BB:CC:DD:EE:FF"
        RingMetadataStore(defaults).record(
            from: FirmwareInfo(version: "FR02.018", modelName: "RingConn Gen2-EEFF",
                               manufacturer: "RingConn", hardwareRevision: "1.0", mac: mac),
            identifier: "ring-A")
        let persisted = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("ring.meta.") }
        XCTAssertFalse(persisted.isEmpty, "the cache must actually have written something")
        for (key, value) in persisted {
            XCTAssertFalse(String(describing: value).contains(mac), "\(key) leaked the ring MAC")
            XCTAssertFalse(String(describing: value).contains("AA:BB"), "\(key) leaked part of the MAC")
            XCTAssertFalse(String(describing: value).contains("EEFF"),
                           "\(key) leaked the advertised name's MAC-suffix bytes")
        }
    }

    /// The concrete rings the repo has captured: Gen 2 (docs/PROTOCOL.md:55) and Gen 3
    /// (FirmwareInfo.swift:6, from an FR05.008 capture). Both advertise a MAC suffix.
    func testAdvertisedNameSuffixIsStrippedForEveryCapturedRing() {
        for (advertised, family) in [("RingConn Gen2-03AD", "RingConn Gen2"),
                                     ("RingConn Gen3-C384", "RingConn Gen3")] {
            let store = RingMetadataStore(defaults)
            store.record(from: FirmwareInfo(version: "", modelName: advertised),
                         identifier: advertised)   // distinct id → whole record replaced
            XCTAssertEqual(store.load().modelName, family,
                           "\(advertised) must be cached as its model family only")
        }
    }

    /// Only a trailing `-` plus exactly four hex digits is a MAC suffix. Anything else is a real
    /// part of the name and truncating it would invent a model that does not exist.
    func testOnlyAFourHexDigitSuffixIsStripped() {
        XCTAssertEqual(RingMetadataStore.modelFamily("RingConn Gen2"), "RingConn Gen2")
        XCTAssertEqual(RingMetadataStore.modelFamily("RingConn Air"), "RingConn Air")
        XCTAssertEqual(RingMetadataStore.modelFamily("Ring-Conn"), "Ring-Conn",
                       "'Conn' is not four hex digits")
        XCTAssertEqual(RingMetadataStore.modelFamily("RingConn Gen2-03A"), "RingConn Gen2-03A",
                       "three digits is not the suffix shape")
        XCTAssertEqual(RingMetadataStore.modelFamily(""), "")
    }
}
