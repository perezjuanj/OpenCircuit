import Foundation
import OpenCircuitKit

/// Each night's saved Sleep Score factors (`SleepScoreFactors`), keyed by the night row's key —
/// Application Support/SleepScore/factors.json.
///
/// WHY A SIDE FILE AND NOT A COLUMN. Only the Int `sleepScore` is stored on `StoredSleepSummary`, and
/// a new column is a SwiftData schema change (frozen snapshot, migration stage, an on-phone upgrade
/// rehearsal). The entry is display-only and self-checking — the sheet shows it only while its score
/// is still the row's (`SleepScoreBreakdown.make(saved:storedScore:)`) — so losing or keeping a stale
/// one can only ever hide a breakdown, never show a wrong one. That makes a plain file safe here.
///
/// The rules that keep it in step with the rows:
///   • every writer of `sleepScore` saves (or clears) the night's entry in the same call, AFTER the
///     row's `context.save()` succeeded, so a rolled-back save never leaves a fresh entry behind;
///   • a re-key moves it with the row (`LocalStore.renameNightScopedOverlays`);
///   • the store wipe clears it (`OpenCircuitApp.wipeAndRecoverForeground`);
///   • it keeps the newest `capacity` nights only.
///
/// Not a health record and never exported or written to Apple Health: every value in it is derived
/// from columns the row already holds or from the score's own inputs.
final class SleepScoreFactorStore: @unchecked Sendable {
    /// The app's store. Replaceable by tests only.
    static var shared = SleepScoreFactorStore()

    /// Newest nights kept. Older entries are dropped on the next save.
    static let defaultCapacity = 400

    private let url: URL
    private let capacity: Int
    private let lock = NSLock()
    /// Loaded on first use; every write updates it and then the file.
    private var cache: [String: SleepScoreFactors]?

    init(folder: URL? = nil, capacity: Int = SleepScoreFactorStore.defaultCapacity) {
        let folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SleepScore", isDirectory: true)
        url = folder.appendingPathComponent("factors.json")
        self.capacity = capacity
    }

    /// The key a night row is filed under. Whole seconds of the row's `night` stamp.
    static func key(_ night: Date) -> String { String(Int64(night.timeIntervalSince1970.rounded())) }

    func entry(night: Date) -> SleepScoreFactors? {
        lock.lock(); defer { lock.unlock() }
        return loaded()[Self.key(night)]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return loaded().count
    }

    /// Save `entry` for `night`, or remove the night's entry when `entry` is nil (a score written
    /// without factors must not leave the previous score's behind).
    func set(_ entry: SleepScoreFactors?, night: Date) {
        lock.lock(); defer { lock.unlock() }
        var all = loaded()
        let key = Self.key(night)
        if let entry {
            all[key] = entry
            if all.count > capacity {
                let newest = all.keys.sorted { (Int64($0) ?? 0) > (Int64($1) ?? 0) }.prefix(capacity)
                all = all.filter { newest.contains($0.key) }
            }
        } else {
            guard all[key] != nil else { return }
            all[key] = nil
        }
        write(all)
    }

    /// Move a night's entry to the row's new key. An entry already at the destination is replaced:
    /// the row being moved is the one that now owns that key.
    func rename(from oldNight: Date, to newNight: Date) {
        lock.lock(); defer { lock.unlock() }
        var all = loaded()
        guard let entry = all.removeValue(forKey: Self.key(oldNight)) else { return }
        all[Self.key(newNight)] = entry
        write(all)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: File

    private func loaded() -> [String: SleepScoreFactors] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = [:]
            return [:]
        }
        // A file that exists but cannot be READ (data protection before the first unlock) is not
        // cached and not overwritten — `write` would otherwise replace every night with one. A file
        // that reads but does not decode is corrupt and is replaced by the next save.
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoded = (try? JSONDecoder().decode([String: SleepScoreFactors].self, from: data)) ?? [:]
        cache = decoded
        return decoded
    }

    private func write(_ all: [String: SleepScoreFactors]) {
        // Unreadable file (see `loaded`): leave it alone. The entry is lost, so the night shows no
        // breakdown — the safe direction.
        guard cache != nil || !FileManager.default.fileExists(atPath: url.path) else { return }
        cache = all
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
