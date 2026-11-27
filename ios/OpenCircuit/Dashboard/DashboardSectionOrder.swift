// The Today tab's reorderable sections and the saved order's decode/encode (#245).
//
// Lifted out of `ContentView` so a test can pin the one rule that matters across releases: a layout
// saved by an older build names sections that no longer exist — `readiness` (its card became Today's
// pinned scores card, decision 93), `vitals` (its card left Today with decision 47), and before them
// `sleep` / `workout` / `trends` (moved to their own tabs) — and those ids must be dropped WITHOUT
// disturbing the order of the sections that remain.

import Foundation

/// The reorderable Today-tab sections. `rawValue` is the persistence key written to
/// `dashboard.sectionOrder`, so keep these stable across releases; `allCases` order is the default
/// (first-run) layout. Today's scores card is pinned above these and is not one of them.
enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case metrics, vitalsStatus, calories, goals, cycle, headache, sync
    var id: String { rawValue }
}

/// The saved Today layout: `dashboard.sectionOrder` ⇄ `[DashboardSection]`.
enum DashboardSectionOrder {
    /// The full canonical-or-saved order. Decodes the stored string, dropping unknown/duplicate ids,
    /// then appends any section not yet present (a new feature) in its canonical `allCases` order —
    /// so a saved order keeps working across app updates that add or retire cards.
    static func decode(_ raw: String) -> [DashboardSection] {
        var result: [DashboardSection] = []
        var seen = Set<DashboardSection>()
        for id in raw.split(separator: ",") {
            if let s = DashboardSection(rawValue: String(id)), !seen.contains(s) {
                result.append(s); seen.insert(s)
            }
        }
        for s in DashboardSection.allCases where !seen.contains(s) {
            // The metric tiles (#216) are new since some saved orders: put them first, straight under
            // the pinned scores card where Readiness used to sit, rather than at the bottom of an
            // existing layout.
            if s == .metrics {
                result.insert(s, at: 0)
            } else {
                result.append(s)
            }
            seen.insert(s)
        }
        return result
    }

    /// The string written back to `dashboard.sectionOrder`. Only live ids are ever written, so a
    /// retired id cannot survive a reorder.
    static func encode(_ sections: [DashboardSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Apply a long-press-drag reorder. The move arrives in `visible` index space; we apply it
    /// there, then merge any hidden section back at its prior absolute position (so turning a
    /// feature on later restores its card roughly where it was).
    static func reordered(full: [DashboardSection], visible: [DashboardSection],
                          from source: IndexSet, to destination: Int) -> [DashboardSection] {
        var moved = visible
        moved.move(fromOffsets: source, toOffset: destination)
        var merged = moved
        for section in full where !moved.contains(section) {
            let idx = min(full.firstIndex(of: section) ?? merged.count, merged.count)
            merged.insert(section, at: idx)
        }
        return merged
    }
}
