// The app's side of the Today scores widget (#398, decision 95c): turn the card's own model into the
// snapshot the widget draws, and write it to the App Group container.
//
// Every value and word comes from `TodayScores` and `TodayScoresCopy`, the same calls the card makes,
// so the widget can only ever show what the card shows. A missing value stays missing (no `value`
// in the file), never 0.

import Foundation
import WidgetKit
import OpenCircuitKit

extension TodayScores {
    /// The rings' fills, shared by the card and the widget snapshot.
    var sleepFill: Double? {
        if case let .scored(score, _) = sleep { return Double(score) / 100 }
        return nil
    }

    var recoveryFill: Double? { recovery.result.map { Double($0.score) / 100 } }

    var strainFill: Double? {
        if case let .scored(reading) = strain { return reading.gaugeFraction }
        return nil
    }
}

enum ScoresWidgetSnapshotBuilder {
    /// The snapshot for these scores, or nil while Strain is still loading (the card shows a
    /// placeholder then, and the file keeps the last complete snapshot rather than a half one).
    static func snapshot(_ scores: TodayScores, at date: Date) -> ScoresWidgetSnapshot? {
        guard scores.strain != .loading else { return nil }
        return ScoresWidgetSnapshot(
            version: ScoresWidgetSnapshot.currentVersion, writtenAt: date,
            sleep: dial(TodayScoresCopy.sleepValue(scores.sleep), fill: scores.sleepFill,
                        status: TodayScoresCopy.sleepStatus(scores.sleep), tint: .sleep, dashed: false,
                        spoken: TodayScoresCopy.sleepAccessibility(scores.sleep)),
            recovery: dial(TodayScoresCopy.recoveryValue(scores.recovery), fill: scores.recoveryFill,
                           status: TodayScoresCopy.recoveryStatus(scores.recovery),
                           tint: recoveryTint(scores.recovery), dashed: scores.recovery.isLowConfidence,
                           spoken: TodayScoresCopy.recoveryAccessibility(scores.recovery)),
            strain: dial(TodayScoresCopy.strainValue(scores.strain), fill: scores.strainFill,
                         status: TodayScoresCopy.strainStatus(scores.strain), tint: .strain, dashed: false,
                         spoken: TodayScoresCopy.strainAccessibility(scores.strain)))
    }

    /// The card's Recovery colour: its tier's, or the brand colour when there is no score.
    static func recoveryTint(_ recovery: TodayScores.Recovery) -> ScoresWidgetSnapshot.Tint {
        switch recovery.result?.tier {
        case .excellent?:        return .recoveryExcellent
        case .good?:             return .recoveryGood
        case .needsImprovement?: return .recoveryNeedsImprovement
        case nil:                return .recoveryNone
        }
    }

    private static func dial(_ text: String, fill: Double?, status: String, tint: ScoresWidgetSnapshot.Tint,
                             dashed: Bool, spoken: String) -> ScoresWidgetSnapshot.Dial {
        let value = text == TodayScoresCopy.missing ? nil : text
        return .init(value: value, fill: value == nil ? nil : fill.map { min(max($0, 0), 1) },
                     status: status, tint: tint, dashed: dashed, spoken: spoken)
    }
}

/// Writes the snapshot when Today's scores change, and asks WidgetKit to redraw. Without a provisioned
/// App Group (an unsigned build) there is no container and nothing is written.
@MainActor
enum ScoresWidgetPublisher {
    private static var lastWritten: ScoresWidgetSnapshot?
    /// Re-write an unchanged snapshot after this long, so an open app keeps the widget from going stale.
    static let rewriteAfter: TimeInterval = 3600

    static func publish(_ scores: TodayScores, now: Date = Date()) {
        guard let snapshot = ScoresWidgetSnapshotBuilder.snapshot(scores, at: now) else { return }
        if let last = lastWritten, last.sameContent(as: snapshot),
           Calendar.current.isDate(last.writtenAt, inSameDayAs: now),
           now.timeIntervalSince(last.writtenAt) < rewriteAfter { return }
        guard let url = ScoresWidgetAppGroup.snapshotURL, let data = ScoresWidgetCodec.encode(snapshot),
              (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        else { return }
        lastWritten = snapshot
        for kind in ScoresWidgetKind.all { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }
}

// MARK: - Deep links

/// The Today tab's navigation route (`ContentView`'s `Route`), named apart from `ScoresQuickLink.Route`.
typealias TodayNavigationRoute = Route

/// Where a widget tap lands: the Sleep tab, or Today with this stack pushed (replacing whatever was
/// open there), the same screens the card's dials and footer open.
enum ScoresLinkDestination: Equatable {
    case sleepTab
    case today(path: [TodayNavigationRoute])
}

extension ScoresQuickLink {
    static func destination(_ route: Route) -> ScoresLinkDestination {
        switch route {
        case .today:    return .today(path: [])
        case .sleep:    return .sleepTab
        case .recovery: return .today(path: [.recovery])
        case .strain:   return .today(path: [.strain])
        case .sources:  return .today(path: [.sources])
        }
    }
}
