import Foundation

// ExportDestination — where a finished export actually lands (#80 rich schema v3).
//
// Two destinations, in this order:
//   1. A folder the user picked once (Files, iCloud Drive, a third-party provider), remembered as a
//      security-scoped bookmark so it survives relaunches. This is what makes a repeatable export
//      workflow possible: same folder every time, no share sheet, no manual filing.
//   2. The system share sheet, always available as the fallback.
//
// The fallback is not an afterthought. A bookmarked folder can disappear between exports — the
// provider is signed out, iCloud Drive is unavailable offline, the folder was deleted, or the
// bookmark simply went stale after an OS restore. Every one of those has to end with the user
// holding their file, not with an error and no export, so every failure path here degrades to the
// share sheet and reports WHY.
//
// SANDBOX EXTENSIONS. `startAccessingSecurityScopedResource()` takes a kernel-level extension that
// is released only by a matching `stopAccessingSecurityScopedResource()`. An unbalanced pair leaks
// it for the lifetime of the process, so every start in this file is paired with a `defer`, and the
// return value is checked — calling `stop` on a start that FAILED is itself unbalanced.
//
// `@MainActor` to match `ExportBuilder`/`LocalStore`: every caller (the export screen and the App
// Intent's `perform`) is already on the main actor, so this costs nothing and keeps the payload
// types single-isolation.
@MainActor
enum ExportDestination {

    // Versioned keys: a future change to what a bookmark points at (a file rather than a folder,
    // say) must not silently resolve an old bookmark into the new meaning.
    private static let bookmarkKey = "export.destination.bookmark.v1"
    private static let displayNameKey = "export.destination.name.v1"

    /// Where the bytes ended up, so the caller can tell the user the truth rather than "Done".
    enum Delivery {
        /// Written into the user's chosen folder. Nothing else to do.
        case savedToFolder(url: URL, folderName: String)
        /// Written to the app's temporary directory; the caller must present the share sheet.
        /// `reason` is nil for the ordinary "no folder chosen" case and carries an explanation when
        /// a chosen folder was unusable.
        case temporaryFile(url: URL, reason: String?)
    }

    enum Failure: LocalizedError {
        case couldNotWriteTemporaryFile(String)

        var errorDescription: String? {
            switch self {
            case .couldNotWriteTemporaryFile(let detail):
                return "Couldn't write the export file: \(detail)"
            }
        }
    }

    // MARK: - The user's chosen folder

    /// The folder's display name, or nil when none is chosen.
    ///
    /// Stored alongside the bookmark rather than derived from it at read time, so the settings row
    /// can name the folder without resolving the bookmark — resolution can prompt the provider and
    /// is far too heavy for a view body.
    static var chosenFolderName: String? {
        UserDefaults.standard.string(forKey: displayNameKey)
    }

    static var hasChosenFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Remember a folder the user just picked with `.fileImporter`.
    ///
    /// The picker hands back a security-scoped URL, and creating a bookmark from it requires holding
    /// that scope. On iOS the default bookmark options already produce a security-scoped bookmark —
    /// `.withSecurityScope` is a macOS-only option and passing it here would not compile.
    ///
    /// `scoped == false` is NOT treated as failure. It is the documented answer for a URL that is
    /// not security-scoped, which this app really can be handed: `UIFileSharingEnabled`
    /// (project.yml) publishes our own `Documents/` in Files, so a user may legitimately pick a
    /// folder we can already reach. Refusing those would break a working destination. What DOES
    /// have to hold is that the bytes we persist are usable later, so the bookmark is resolved
    /// before it is stored — an unresolvable one would leave the settings row naming a folder every
    /// later export silently falls back away from, which is the failure this guard exists to stop.
    @discardableResult
    static func remember(folder url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return false }
        var isStale = false
        guard (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                        bookmarkDataIsStale: &isStale)) != nil else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: displayNameKey)
        return true
    }

    /// Forget the chosen folder; exports fall back to the share sheet.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
    }

    // MARK: - Delivery

    /// Write `payload` to the chosen folder, falling back to a temporary file for the share sheet.
    ///
    /// The temporary copy is written FIRST and unconditionally, so a folder write that fails halfway
    /// still leaves the user with a complete file to share — and is RECLAIMED the moment the folder
    /// write succeeds, since only the fallback paths still need it (`writeIntoFolder`).
    static func deliver(_ payload: ExportBuilder.Payload) throws -> Delivery {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(payload.fileName)
        do {
            try payload.data.write(to: temp, options: .atomic)
        } catch {
            throw Failure.couldNotWriteTemporaryFile(error.localizedDescription)
        }

        guard hasChosenFolder else { return .temporaryFile(url: temp, reason: nil) }
        guard let folder = resolveFolder() else {
            return .temporaryFile(url: temp,
                                  reason: "That saved folder is no longer reachable, so the export "
                                        + "was prepared for sharing instead.")
        }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard scoped else {
            return .temporaryFile(url: temp,
                                  reason: "OpenCircuit no longer has permission to write to "
                                        + "\(folder.lastPathComponent). Pick the folder again, or "
                                        + "share the file from here.")
        }

        do {
            let target = try writeIntoFolder(payload, folder: folder, discarding: temp)
            return .savedToFolder(url: target, folderName: folder.lastPathComponent)
        } catch {
            return .temporaryFile(url: temp,
                                  reason: "Couldn't write to \(folder.lastPathComponent) "
                                        + "(\(error.localizedDescription)); the export was prepared "
                                        + "for sharing instead.")
        }
    }

    // MARK: - Internals

    /// Write the payload into `folder` under a name that isn't taken, then reclaim the temporary
    /// copy — whose only job ("a folder write that fails halfway still leaves the user with a
    /// complete file to share", see `deliver`) is finished the moment the coordinated write
    /// returned.
    ///
    /// Left behind, that copy is a SECOND complete file of the user's vitals, hypnograms and base64
    /// `historySyncEvidence` blobs, under a name that changes every calendar day
    /// (`opencircuit-new-sessions-YYYY-MM-DD`, ExportBuilder), so a nightly automation accumulated
    /// one per night in `tmp/` — invisible in the UI, not user-deletable (`UIFileSharingEnabled`
    /// publishes `Documents/`, never `tmp/`), and reclaimed only whenever iOS decides to.
    ///
    /// `internal` rather than `private` so the app-target suite can exercise the naming and the
    /// cleanup against a plain directory; the real path additionally needs a security scope, which
    /// a test cannot mint.
    @discardableResult
    static func writeIntoFolder(_ payload: ExportBuilder.Payload,
                                folder: URL, discarding temp: URL?) throws -> URL {
        let target = uniqueURL(in: folder, fileName: payload.fileName)
        try coordinatedWrite(payload.data, to: target)
        if let temp { try? FileManager.default.removeItem(at: temp) }
        return target
    }

    /// Resolve the stored bookmark, refreshing it when the system reports it stale.
    ///
    /// A stale bookmark still resolves — it just won't keep resolving forever — so the refresh is
    /// best-effort: failing to re-store it costs nothing today and only risks the fallback path on a
    /// later run.
    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if scoped, let fresh = try? url.bookmarkData(options: [],
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }

    /// A name that isn't taken yet in `folder`.
    ///
    /// Two exports on the same day produce the same filename, and silently replacing yesterday's
    /// file with today's would destroy an export the user believed they had. Suffixing is the
    /// non-destructive direction. The 99-suffix cap is arbitrary and mechanical — it only stops a
    /// folder that somehow contains every candidate name from spinning the loop forever; hitting it
    /// falls through to overwriting the last candidate, which needs 98 same-day exports to reach.
    ///
    /// `internal` rather than `private` so it can be tested: it is the ONLY thing standing between a
    /// second same-day export and the destruction of the first one, and it had no test at all.
    static func uniqueURL(in folder: URL, fileName: String) -> URL {
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path), suffix <= 99 {
            let name = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    /// Coordinated write, because the destination is very often a file-provider folder (iCloud
    /// Drive, Dropbox…) whose daemon is a second writer. An uncoordinated write there can race the
    /// provider's own upload and produce a truncated or conflicted file.
    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
