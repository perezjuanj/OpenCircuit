// Edit Today (#394, decision 94): which Today cards and Your Numbers tiles show, and in what order.
//
// The saved layout is four comma-joined strings in UserDefaults: the existing `dashboard.sectionOrder`
// plus `dashboard.hiddenSections`, `dashboard.tileOrder` and `dashboard.hiddenTiles`. Every one is
// decoded by the rule `DashboardSectionOrder.decode` already follows: unknown and duplicate ids are
// dropped in place, and an id a newer build ships is appended, visible. So an old or damaged value can
// never crash Today or lose a card.
//
// Everything here is pure (no UserDefaults, no clock), so the rules are pinned by tests:
// - Today's scores card is pinned above these sections and is not one of them, so it can't be hidden.
// - History & Sleep (the `sync` section) can't be hidden: it holds the manual sync and Health-push
//   buttons.
// - A feature gate (women's health for Cycle, the headache log) and the hidden flag both apply. A gated
//   card's hidden flag lives only while its feature is on (`droppingHiddenFlags(gatedOffBy:)`), so
//   turning the feature back on shows the card.
// - Hiding is display-only. The Today sentence's input is built here from the whole trends load, every
//   tile included, whatever is hidden (`sentenceInput`), and the Vitals Status report that feeds it
//   (and Recovery) is computed once by `TodayVitalsRunner`, whatever the layout (decision 95a). Alerts,
//   Health writes and background work never read these keys.
// - A part of the layout left at its default is stored as "" (no override), so a later build's new ids
//   land in their canonical place.

import Foundation
import OpenCircuitKit

/// One Your Numbers tile: the six `TodayTile` metrics, then the strap's Stress and PAI tiles.
/// `rawValue` is the persistence key written to `dashboard.tileOrder` / `dashboard.hiddenTiles`, so keep
/// these stable across releases; `allCases` order is the default layout.
enum TodayTileID: String, CaseIterable, Identifiable, Hashable {
    case hrv, restingHR, spo2, respiratoryRate, skinTemp, steps, stress, pai
    var id: String { rawValue }

    init(_ metric: TodayTile.Metric) {
        switch metric {
        case .hrv:             self = .hrv
        case .restingHR:       self = .restingHR
        case .spo2:            self = .spo2
        case .respiratoryRate: self = .respiratoryRate
        case .skinTemp:        self = .skinTemp
        case .steps:           self = .steps
        }
    }

    /// The `TodayTile` this id draws; nil for the strap's Stress and PAI tiles, which are not `TodayTile`s.
    var metric: TodayTile.Metric? {
        switch self {
        case .hrv:             return .hrv
        case .restingHR:       return .restingHR
        case .spo2:            return .spo2
        case .respiratoryRate: return .respiratoryRate
        case .skinTemp:        return .skinTemp
        case .steps:           return .steps
        case .stress, .pai:    return nil
        }
    }

    /// The row's name in the Edit sheet: the tile's own title.
    var title: String {
        switch self {
        case .hrv:             return "HRV"
        case .restingHR:       return "Resting HR"
        case .spo2:            return "SpO₂"
        case .respiratoryRate: return "Resp. rate"
        case .skinTemp:        return "Skin temp"
        case .steps:           return "Steps"
        case .stress:          return "Stress"
        case .pai:             return "PAI"
        }
    }

    /// The name VoiceOver reads ("Show respiratory rate", not "Show Resp. rate").
    var spokenTitle: String {
        switch self {
        case .hrv:             return "HRV"
        case .restingHR:       return "resting heart rate"
        case .spo2:            return "blood oxygen"
        case .respiratoryRate: return "respiratory rate"
        case .skinTemp:        return "skin temperature"
        case .steps:           return "steps"
        case .stress:          return "stress"
        case .pai:             return "PAI"
        }
    }
}

extension DashboardSection {
    /// The row's name in the Edit sheet.
    var editTitle: String {
        switch self {
        case .metrics:      return "Your Numbers"
        case .vitalsStatus: return "Vitals Status"
        case .calories:     return "Calories"
        case .goals:        return "Daily Goals"
        case .cycle:        return "Cycle"
        case .headache:     return "Headache log"
        case .sync:         return "History & Sleep"
        }
    }
}

/// The opt-in features that decide whether a card exists at all, whatever the layout says.
struct TodayFeatureGates: Equatable {
    var womensHealth: Bool
    var headache: Bool

    func allows(_ section: DashboardSection) -> Bool {
        switch section {
        case .cycle:    return womensHealth
        case .headache: return headache
        default:        return true
        }
    }
}

/// Which tiles have something to draw right now. The six `TodayTile`s always do; the strap's Stress and
/// PAI tiles only while a fresh strap reading exists (the caller checks freshness, with its own clock).
struct TodayTileAvailability: Equatable {
    var stress: Bool
    var pai: Bool

    static let ringOnly = TodayTileAvailability(stress: false, pai: false)

    func allows(_ tile: TodayTileID) -> Bool {
        switch tile {
        case .stress: return stress
        case .pai:    return pai
        default:      return true
        }
    }
}

struct TodayLayout: Equatable {
    var sections: [DashboardSection]
    var hiddenSections: Set<DashboardSection>
    var tiles: [TodayTileID]
    var hiddenTiles: Set<TodayTileID>

    /// The UserDefaults keys. `sectionOrder` is the one the in-list long-press reorder has always written.
    enum Keys {
        static let sectionOrder = "dashboard.sectionOrder"
        static let hiddenSections = "dashboard.hiddenSections"
        static let tileOrder = "dashboard.tileOrder"
        static let hiddenTiles = "dashboard.hiddenTiles"
    }

    /// The four stored strings, as read from and written to UserDefaults.
    struct Stored: Equatable {
        var sectionOrder = ""
        var hiddenSections = ""
        var tileOrder = ""
        var hiddenTiles = ""
    }

    /// The first-run layout, and what "Reset to default layout" restores: every card and tile shown,
    /// in canonical order.
    static let standard = TodayLayout(sections: DashboardSection.allCases, hiddenSections: [],
                                      tiles: TodayTileID.allCases, hiddenTiles: [])

    init(sections: [DashboardSection], hiddenSections: Set<DashboardSection>,
         tiles: [TodayTileID], hiddenTiles: Set<TodayTileID>) {
        self.sections = sections
        self.hiddenSections = hiddenSections.filter { Self.canHide($0) }
        self.tiles = tiles
        self.hiddenTiles = hiddenTiles
    }

    init(stored: Stored) {
        self.init(sections: DashboardSectionOrder.decode(stored.sectionOrder),
                  hiddenSections: Self.decodeSet(stored.hiddenSections),
                  tiles: Self.decodeOrder(stored.tileOrder),
                  hiddenTiles: Self.decodeSet(stored.hiddenTiles))
    }

    /// The four strings to write. A part left at its default is written as "", so the standard layout
    /// (after Reset) stores no override at all.
    var stored: Stored {
        Stored(sectionOrder: sections == Self.standard.sections ? "" : DashboardSectionOrder.encode(sections),
               hiddenSections: Self.encodeSet(hiddenSections.filter { Self.canHide($0) }),
               tileOrder: tiles == Self.standard.tiles ? "" : tiles.map(\.rawValue).joined(separator: ","),
               hiddenTiles: Self.encodeSet(hiddenTiles))
    }

    // MARK: Rules

    /// A card on Today that the Edit sheet lists: the pinned scores card, or one of the sections.
    enum Card: Hashable {
        case scores
        case section(DashboardSection)
    }

    /// Today's scores card is pinned and never hidden, and History & Sleep is always shown (decision
    /// 94a). Every other section can be hidden.
    static func canHide(_ card: Card) -> Bool {
        switch card {
        case .scores:              return false
        case .section(let s):      return s != .sync
        }
    }

    static func canHide(_ section: DashboardSection) -> Bool { canHide(.section(section)) }

    func isShown(_ section: DashboardSection) -> Bool { !Self.canHide(section) || !hiddenSections.contains(section) }
    func isShown(_ tile: TodayTileID) -> Bool { !hiddenTiles.contains(tile) }

    /// The Edit sheet's card rows: every section whose feature is on, hidden ones included.
    func editableSections(gates: TodayFeatureGates) -> [DashboardSection] {
        sections.filter(gates.allows)
    }

    /// The sections Today draws, in order: feature on AND not hidden.
    func shownSections(gates: TodayFeatureGates) -> [DashboardSection] {
        editableSections(gates: gates).filter(isShown)
    }

    /// The Edit sheet's tile rows: every tile that would show, hidden ones included.
    func editableTiles(available: TodayTileAvailability) -> [TodayTileID] {
        tiles.filter(available.allows)
    }

    /// The tiles Your Numbers draws, in order. Stress and PAI are listed whatever their freshness: the
    /// grid checks that at render, so a reading that ages out while the app is open drops its tile.
    var shownTiles: [TodayTileID] { tiles.filter(isShown) }

    /// Today's sentence input (decision 94c): built from the whole trends load, every tile included,
    /// whatever this layout hides. The layout is a parameter only so a test can prove it changes
    /// nothing; hiding a tile or a card changes what is drawn, never what the sentence says.
    func sentenceInput(trends: TrendsData, tempUnit: TemperatureUnit, readiness: ReadinessReport?,
                       feverSuspected: Bool, lastSyncAt: Date?, now: Date = Date()) -> TodaySynthesis.Input {
        TodaySynthesis.input(trends: trends, tiles: TodayTiles.build(trends: trends, tempUnit: tempUnit, now: now),
                             readiness: readiness, feverSuspected: feverSuspected,
                             lastSyncAt: lastSyncAt, now: now)
    }

    /// Where the Vitals Status card's report runs. Its fever verdict is one of the sentence's inputs,
    /// so exactly one copy always runs: the card itself while shown, a hidden copy while it is hidden.
    /// Whether the Vitals Status card is drawn (`.card`) or not. Since decision 95a the report itself
    /// no longer depends on it: `TodayVitalsRunner` computes it once for every layout.
    enum VitalsReport: Equatable { case card, hiddenRunner }

    var vitalsReport: VitalsReport { isShown(.vitalsStatus) ? .card : .hiddenRunner }

    // MARK: Edits

    mutating func setShown(_ section: DashboardSection, _ shown: Bool) {
        guard Self.canHide(section) else { return }
        if shown { hiddenSections.remove(section) } else { hiddenSections.insert(section) }
    }

    mutating func setShown(_ tile: TodayTileID, _ shown: Bool) {
        if shown { hiddenTiles.remove(tile) } else { hiddenTiles.insert(tile) }
    }

    /// A drag in the Edit sheet's card rows (`editableSections` index space). A section whose feature is
    /// off keeps its prior place, by the rule the in-list reorder already uses.
    mutating func moveSections(from source: IndexSet, to destination: Int, gates: TodayFeatureGates) {
        sections = DashboardSectionOrder.reordered(full: sections, visible: editableSections(gates: gates),
                                                   from: source, to: destination)
    }

    /// A drag in the Edit sheet's tile rows (`editableTiles` index space), with the same merge rule.
    mutating func moveTiles(from source: IndexSet, to destination: Int, available: TodayTileAvailability) {
        var moved = editableTiles(available: available)
        moved.move(fromOffsets: source, toOffset: destination)
        var merged = moved
        for tile in tiles where !moved.contains(tile) {
            merged.insert(tile, at: min(tiles.firstIndex(of: tile) ?? merged.count, merged.count))
        }
        tiles = merged
    }

    mutating func reset() { self = .standard }

    /// The layout without hidden flags on cards whose feature is off. Applied whenever a feature is seen
    /// off (at launch, when its switch changes, and on Done), so a card hidden while its feature was on
    /// comes back shown when the feature is turned on again, instead of staying hidden with no hint.
    func droppingHiddenFlags(gatedOffBy gates: TodayFeatureGates) -> TodayLayout {
        var copy = self
        copy.hiddenSections = hiddenSections.filter { gates.allows($0) }
        return copy
    }

    // MARK: Decode / encode

    /// An order: unknown and duplicate ids dropped in place, missing ids appended in canonical order.
    static func decodeOrder<ID: CaseIterable & RawRepresentable & Hashable>(_ raw: String) -> [ID]
    where ID.RawValue == String {
        var result: [ID] = []
        var seen = Set<ID>()
        for part in raw.split(separator: ",") {
            if let id = ID(rawValue: String(part)), seen.insert(id).inserted { result.append(id) }
        }
        for id in ID.allCases where !seen.contains(id) { result.append(id) }
        return result
    }

    /// A hidden set: unknown ids dropped. An id absent from the set is shown, so a new one is visible.
    static func decodeSet<ID: RawRepresentable & Hashable>(_ raw: String) -> Set<ID> where ID.RawValue == String {
        Set(raw.split(separator: ",").compactMap { ID(rawValue: String($0)) })
    }

    /// A hidden set in canonical order, so the stored string doesn't churn between launches.
    static func encodeSet<ID: CaseIterable & RawRepresentable & Hashable>(_ set: Set<ID>) -> String
    where ID.RawValue == String {
        ID.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

extension TodayTiles {
    /// All six tiles from a trends load: what Your Numbers draws from and what the sentence reads.
    static func build(trends: TrendsData, tempUnit: TemperatureUnit, now: Date = Date()) -> [TodayTile] {
        build(points: trends.points, restingHR: trends.restingHR, tempUnit: tempUnit, now: now, scope: .from(trends))
    }
}

/// One Edit Today session: the layout the sheet opened on and the draft it changes. Done applies the
/// draft; Cancel (or swiping the sheet away) keeps the original.
struct TodayLayoutEdit: Equatable {
    enum Outcome { case done, cancel }

    let original: TodayLayout
    var draft: TodayLayout

    init(_ layout: TodayLayout) {
        original = layout
        draft = layout
    }

    func result(_ outcome: Outcome) -> TodayLayout {
        switch outcome {
        case .done:   return draft
        case .cancel: return original
        }
    }
}
