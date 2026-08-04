// Retention buffer for `0x4c` history pages that arrive with NO drain open (#188).
//
// WHY THIS EXISTS. The BLE layer ACKs every `0x4c` page unconditionally — the ack (`cc 00 00`) is
// what makes the ring send the next page — and that same ack advances the ring's single resume
// pointer. So an acked page is GONE from the ring whether or not we kept it. Retention that is
// conditional on app state (`syncing`, `livePreparing`) while the ack is unconditional is therefore
// a silent, permanent data-loss bug.
//
// 🟢 MEASURED, two independent testers, 2026-08-04, different hardware/firmware/timezone:
//   • Gen 2 / FR02.018: ring streamed 208 contiguous records (00:15→08:53, 8.6 h) as 35 pages,
//     remaining-counter 202→0 unbroken. 174 records acked outside a drain and dropped. The app
//     reported a 1 h 25 m night.
//   • Gen 2 Air / FR04.009: 189 records (22:38→06:28, 7.8 h) streamed at 06:31:22; the app's first
//     drain opened 44 s later and banked 3. No sleep summary was produced at all.
//
// This type is deliberately pure and Apple-framework-free so the invariant is unit-testable: the
// BLE session owns one of these and delegates every out-of-drain page to it.

import Foundation

/// Holds records from acked-but-unattributed `0x4c` pages until they can be banked.
///
/// The contract in one line: **if we ACK a page, we KEEP it.** There is no app state in which the
/// ack and the retention disagree.
public struct UnattributedPageBuffer: Equatable {

    /// Leak bound only — reaching it means "bank NOW", never "drop". 4 000 records ≈ 92 KB, well
    /// past the 30 h the `EpochArchive` retains anyway.
    public static let defaultCap = 4_000

    public private(set) var records: [BulkRecord] = []
    /// How many pages contributed to the current buffer (diagnostics — distinguishes "one big
    /// handoff we missed" from "a trickle of stragglers").
    public private(set) var pages = 0
    public let cap: Int

    public init(cap: Int = defaultCap) {
        self.cap = cap
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    /// Retain one page's records.
    ///
    /// - Returns: `true` when the buffer has reached `cap` and the caller must bank immediately
    ///   instead of waiting out its debounce. An empty page is a no-op and never trips the cap.
    @discardableResult
    public mutating func retain(_ incoming: [BulkRecord]) -> Bool {
        guard !incoming.isEmpty else { return false }
        records += incoming
        pages += 1
        return records.count >= cap
    }

    /// Take everything and reset. The caller is responsible for durably banking the result — this
    /// type never drops records on its own.
    public mutating func drain() -> [BulkRecord] {
        let out = records
        records.removeAll()
        pages = 0
        return out
    }
}
