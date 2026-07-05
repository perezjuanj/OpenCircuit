import SwiftData
import XCTest
@testable import OpenCircuit

/// Regression coverage for #131 — "Background sync can wipe the local store".
///
/// The BGTask background-sync handler used to build its SwiftData container via the SAME
/// `makeContainer()` whose failure path wipes+recreates the on-disk store (`exportBeforeWipe` +
/// `removeStoreFiles`). A transient container-open failure during a routine background wake-drain
/// (these fire ~hourly all day) therefore silently DELETED the raw `StoredSample`/`StoredStepSample`/
/// `StoredCursor` history — none of which `RollupBackup` carries — with no UI notice.
///
/// The fix (a) adds a NON-destructive `makeContainerOrThrow()` and shares one process-wide container
/// so the BGTask handler never calls the destructive builder, and (b) gates the destructive wipe on
/// real foreground presence, so a BACKGROUND cold launch (which also runs `App.init` →
/// `makeContainer()`) can never reach `removeStoreFiles` either. These tests pin both.
///
/// Every test here uses a temp-URL or in-memory store — NONE touch the app's real default store.
///
/// MANUAL CHECK (device repro from the issue): with a populated store, background the app, then
/// trigger the BGTask via the debugger —
///   e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
///     _simulateLaunchForTaskWithIdentifier:@"com.standardsoftwaresolutions.opencircuit.bgrefresh"]
/// — and confirm the `.store`/`-shm`/`-wal` files in Library/Application Support survive and
/// `localHistoryWasReset` stays unset even if the drain fails. Also cold-launch post-reboot (before
/// first unlock) via a scheduled BGProcessing task and confirm the same.
@MainActor
final class ContainerRecoveryTests: XCTestCase {

    private enum TestError: Error { case openFailed }

    /// A throwaway in-memory container used as the dummy return value from injected builder
    /// closures (its identity/contents are irrelevant — the tests assert the DECISION, not the
    /// container).
    private func dummyContainer() throws -> ModelContainer {
        try ModelContainer(for: StoredSample.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func uniqueTempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bg131-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        let base = url.deletingPathExtension()
        for u in [url, base.appendingPathExtension("store-shm"), base.appendingPathExtension("store-wal")] {
            try? FileManager.default.removeItem(at: u)
        }
    }

    // MARK: The core #131 regression guard — the wipe decision (no real store, no real launch)

    /// When the store open FAILS on a BACKGROUND launch, the destructive path
    /// (`wipeAndRecover` → `removeStoreFiles`) must NEVER run: the in-memory fallback is used
    /// instead, the result is NOT published as the shared container, and no reset notice is raised.
    /// This is the exact hole the adversarial review found — the wipe reachable from `App.init` on
    /// a background cold launch.
    func testBackgroundOpenFailureNeverWipes() throws {
        UserDefaults.standard.removeObject(forKey: OpenCircuitApp.historyResetDefaultsKey)
        let dummy = try dummyContainer()
        var wipeCalled = false
        var inMemoryCalled = false

        let (_, publishAsShared) = OpenCircuitApp.resolveContainer(
            isBackground: true,
            build: { throw TestError.openFailed },
            wipeAndRecover: { wipeCalled = true; return dummy },
            inMemoryFallback: { inMemoryCalled = true; return dummy })

        XCTAssertFalse(wipeCalled,
                       "a background open failure must NEVER reach wipeAndRecover/removeStoreFiles")
        XCTAssertTrue(inMemoryCalled,
                      "a background open failure falls back to a throwaway in-memory container")
        XCTAssertFalse(publishAsShared,
                       "the in-memory fallback must NOT be published — the BGTask handler must fall "
                       + "through to makeContainerOrThrow() and abort-and-retry")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: OpenCircuitApp.historyResetDefaultsKey),
                       "no history-reset notice may be raised on a background launch")
    }

    /// A FOREGROUND open failure still runs the destructive wipe+recover, so first-launch /
    /// migration recovery (and the user-facing reset notice) is unchanged.
    func testForegroundOpenFailureRecovers() throws {
        let dummy = try dummyContainer()
        var wipeCalled = false
        var inMemoryCalled = false

        let (_, publishAsShared) = OpenCircuitApp.resolveContainer(
            isBackground: false,
            build: { throw TestError.openFailed },
            wipeAndRecover: { wipeCalled = true; return dummy },
            inMemoryFallback: { inMemoryCalled = true; return dummy })

        XCTAssertTrue(wipeCalled,
                      "a foreground open failure must run wipe+recover (unchanged migration recovery)")
        XCTAssertFalse(inMemoryCalled)
        XCTAssertTrue(publishAsShared, "the recovered on-disk container is published as shared")
    }

    /// A successful open is published as the shared container regardless of launch context, and
    /// never touches the recovery paths.
    func testSuccessfulOpenIsPublishedAndNeverRecovers() throws {
        let dummy = try dummyContainer()
        var wipeCalled = false
        var inMemoryCalled = false

        for isBackground in [true, false] {
            let (container, publishAsShared) = OpenCircuitApp.resolveContainer(
                isBackground: isBackground,
                build: { dummy },
                wipeAndRecover: { wipeCalled = true; return dummy },
                inMemoryFallback: { inMemoryCalled = true; return dummy })
            XCTAssertTrue(publishAsShared)
            XCTAssertTrue(container === dummy)
        }
        XCTAssertFalse(wipeCalled)
        XCTAssertFalse(inMemoryCalled)
    }

    // MARK: The non-destructive builder itself, against a temp store (never the real one)

    /// `makeContainerOrThrow` opens a healthy store and never raises the history-reset notice
    /// (that flag belongs only to the foreground wipe path).
    func testMakeContainerOrThrowOpensHealthyStoreWithoutResetFlag() throws {
        UserDefaults.standard.removeObject(forKey: OpenCircuitApp.historyResetDefaultsKey)
        let url = uniqueTempStoreURL()
        defer { removeStore(at: url) }

        let container = try OpenCircuitApp.makeContainerOrThrow(storeURL: url)
        _ = container

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "opening the store must materialize its file")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: OpenCircuitApp.historyResetDefaultsKey),
                       "the non-destructive builder must never raise the history-reset notice")
    }

    /// Re-opening a PRE-SEEDED healthy store (as a subsequent hourly background wake would) leaves
    /// the store file and its seeded row intact — i.e. the non-destructive builder never wipes.
    func testBackgroundReopenLeavesHealthyStoreIntact() throws {
        let url = uniqueTempStoreURL()
        defer { removeStore(at: url) }

        do {
            let first = try OpenCircuitApp.makeContainerOrThrow(storeURL: url)
            let ctx = first.mainContext
            ctx.insert(StoredSample(kindRaw: "heartRate",
                                    start: Date(timeIntervalSince1970: 1_000),
                                    end: Date(timeIntervalSince1970: 1_000),
                                    value: 62))
            try ctx.save()
        }   // release `first` so the re-open below mirrors a fresh background process

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        UserDefaults.standard.removeObject(forKey: OpenCircuitApp.historyResetDefaultsKey)

        let second = try OpenCircuitApp.makeContainerOrThrow(storeURL: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the non-destructive builder must never remove the store files")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: OpenCircuitApp.historyResetDefaultsKey),
                       "re-opening a healthy store must not raise the reset notice")
        let seeded = try second.mainContext.fetch(FetchDescriptor<StoredSample>())
        XCTAssertTrue(seeded.contains { $0.value == 62 },
                      "the pre-seeded sample must survive the background re-open")
    }
}
