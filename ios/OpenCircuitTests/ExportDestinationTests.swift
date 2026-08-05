import XCTest
@testable import OpenCircuit

// `ExportDestination`'s file handling — the part that decides whether the user still HAS their
// previous export afterwards, and whether a second full copy of their health data is left behind.
//
// Neither behaviour had a test. `uniqueURL` is the only thing standing between two exports on the
// same day and the destruction of the first one, and `deliver`'s temporary copy was never reclaimed
// on the save-to-folder path — so a nightly automation accumulated one complete file of vitals,
// hypnograms and base64 `historySyncEvidence` blobs per night in `tmp/`, invisible in the UI
// (`UIFileSharingEnabled` publishes `Documents/`, never `tmp/`) and reclaimed only when iOS felt
// like it.
//
// What is NOT tested here, plainly: the security-scoped bookmark path (`remember` / `resolveFolder`
// / the `startAccessingSecurityScopedResource` guard in `deliver`). A test process cannot mint a
// security-scoped URL — those come from the document picker — so `writeIntoFolder` is exercised
// against a plain directory, which is every part of the write EXCEPT the sandbox extension.
@MainActor
final class ExportDestinationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    private func payload(_ content: String, named name: String) -> ExportBuilder.Payload {
        ExportBuilder.Payload(content: content, fileName: name, format: .csv,
                              sessionCount: 1, watermarkAdvance: nil, contentAsOf: nil)
    }

    private func contents(of name: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - A repeat same-day export must not destroy the first file

    func testASecondExportOnTheSameDaySuffixesInsteadOfOverwriting() throws {
        let name = "opencircuit-export-2026-08-05.csv"
        try ExportDestination.writeIntoFolder(payload("first", named: name),
                                             folder: folder, discarding: nil)
        try ExportDestination.writeIntoFolder(payload("second", named: name),
                                             folder: folder, discarding: nil)

        XCTAssertEqual(contents(of: name), "first",
                       "yesterday's — or this morning's — export must survive verbatim")
        XCTAssertEqual(contents(of: "opencircuit-export-2026-08-05-2.csv"), "second")
    }

    func testSuffixingKeepsCountingRatherThanReusingTheSameName() throws {
        let name = "opencircuit-export-2026-08-05.csv"
        for index in 1 ... 4 {
            try ExportDestination.writeIntoFolder(payload("run\(index)", named: name),
                                                  folder: folder, discarding: nil)
        }
        XCTAssertEqual(contents(of: name), "run1")
        XCTAssertEqual(contents(of: "opencircuit-export-2026-08-05-2.csv"), "run2")
        XCTAssertEqual(contents(of: "opencircuit-export-2026-08-05-3.csv"), "run3")
        XCTAssertEqual(contents(of: "opencircuit-export-2026-08-05-4.csv"), "run4")
    }

    /// The suffix goes before the extension, so the file still opens as a CSV/JSON.
    func testTheSuffixIsInsertedBeforeTheExtension() {
        let taken = folder.appendingPathComponent("report.json")
        FileManager.default.createFile(atPath: taken.path, contents: Data())
        XCTAssertEqual(ExportDestination.uniqueURL(in: folder, fileName: "report.json")
                        .lastPathComponent, "report-2.json")
    }

    func testAnExtensionlessNameStillGetsAUniqueSuffix() {
        let taken = folder.appendingPathComponent("report")
        FileManager.default.createFile(atPath: taken.path, contents: Data())
        XCTAssertEqual(ExportDestination.uniqueURL(in: folder, fileName: "report")
                        .lastPathComponent, "report-2")
    }

    func testAFreeNameIsUsedAsIs() {
        XCTAssertEqual(ExportDestination.uniqueURL(in: folder, fileName: "fresh.csv")
                        .lastPathComponent, "fresh.csv")
    }

    // MARK: - The temporary copy is reclaimed once the folder write succeeded

    func testTheTemporaryCopyIsRemovedAfterASuccessfulFolderWrite() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-temp-\(UUID().uuidString).csv")
        try Data("health data".utf8).write(to: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))

        try ExportDestination.writeIntoFolder(payload("health data", named: "export.csv"),
                                              folder: folder, discarding: temp)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path),
                       "a second complete copy of the user's health data must not be left in tmp")
        XCTAssertEqual(contents(of: "export.csv"), "health data",
                       "…and the copy that WAS asked for is intact")
    }

    /// A failed folder write must leave the temporary copy alone — it is the fallback the share
    /// sheet is about to hand the user, and reclaiming it there would turn a recoverable failure
    /// into no export at all.
    func testAFailedFolderWriteKeepsTheTemporaryCopy() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencircuit-temp-\(UUID().uuidString).csv")
        try Data("health data".utf8).write(to: temp)

        let missing = folder.appendingPathComponent("no-such-subfolder", isDirectory: true)
        XCTAssertThrowsError(try ExportDestination.writeIntoFolder(
            payload("health data", named: "export.csv"), folder: missing, discarding: temp))

        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path),
                      "the share-sheet fallback still needs the file it is going to share")
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - `remember` must not persist a bookmark that cannot be resolved

    /// A plain (non-security-scoped) directory is exactly the case
    /// `startAccessingSecurityScopedResource()` answers `false` for, and it is reachable in the real
    /// app: `UIFileSharingEnabled` publishes our own `Documents/` in Files, so a user really can
    /// pick a folder we already reach. Refusing those would break a working destination — the
    /// guarantee `remember` makes is that whatever it STORES resolves later.
    func testAPlainFolderIsRememberedAndItsBookmarkResolves() throws {
        // These two write the app's REAL destination key, so they stand down rather than clobber a
        // folder a developer running the suite on their own phone actually chose.
        try XCTSkipIf(ExportDestination.hasChosenFolder,
                      "a destination is already configured in the host app; not overwriting it")
        defer { ExportDestination.forget() }

        XCTAssertTrue(ExportDestination.remember(folder: folder),
                      "an already-reachable folder must still be usable as a destination")
        XCTAssertEqual(ExportDestination.chosenFolderName, folder.lastPathComponent)
        XCTAssertTrue(ExportDestination.hasChosenFolder)
    }

    func testAFolderThatDoesNotExistIsNotRemembered() throws {
        try XCTSkipIf(ExportDestination.hasChosenFolder,
                      "a destination is already configured in the host app; not overwriting it")
        defer { ExportDestination.forget() }

        let missing = folder.appendingPathComponent("gone", isDirectory: true)
        XCTAssertFalse(ExportDestination.remember(folder: missing),
                       "an unusable bookmark must be refused, not stored — the settings row would "
                       + "otherwise name a folder every later export silently falls back away from")
        XCTAssertFalse(ExportDestination.hasChosenFolder, "…and nothing was persisted")
    }
}
