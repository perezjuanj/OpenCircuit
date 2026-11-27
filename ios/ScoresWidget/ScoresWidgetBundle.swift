// The Today scores widgets (#398, decision 95c): Sleep, Recovery and Strain on the home and lock
// screens, drawn from the snapshot the app wrote (`ScoresShared/`). This extension READS a file and
// draws it; it never computes a score and does not link OpenCircuitKit (a test checks both).

import SwiftUI
import WidgetKit

@main
struct ScoresWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayScoresWidget()
        SleepDialWidget()
        RecoveryDialWidget()
        StrainDialWidget()
    }
}

struct ScoresEntry: TimelineEntry {
    let date: Date
    let display: ScoresWidgetDisplay
}

/// Reads the stored snapshot and schedules a redraw for the moments its freshness changes (stale after
/// a few hours, empty at midnight). The app asks for a reload whenever it writes a new one.
struct ScoresProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScoresEntry {
        ScoresEntry(date: Date(), display: .make(nil, now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (ScoresEntry) -> Void) {
        let now = Date()
        completion(ScoresEntry(date: now, display: .make(Self.read(), now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScoresEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.read()
        var dates = [now]
        if let written = snapshot?.writtenAt {
            dates += ScoresWidgetFreshness.changeDates(writtenAt: written, after: now)
        }
        completion(Timeline(entries: dates.map { ScoresEntry(date: $0, display: .make(snapshot, now: $0)) },
                            policy: .never))
    }

    static func read() -> ScoresWidgetSnapshot? {
        guard let url = ScoresWidgetAppGroup.snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return ScoresWidgetCodec.decode(data)
    }
}

struct TodayScoresWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ScoresWidgetKind.today, provider: ScoresProvider()) { entry in
            TodayScoresWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today's scores")
        .description("Sleep, Recovery and Strain from the Today card. On-device estimates, not medical advice.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct TodayScoresWidgetView: View {
    let entry: ScoresEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:         ScoresWidgetMediumView(display: entry.display)
        case .accessoryRectangular: ScoresWidgetRectangularView(display: entry.display)
        default:                    ScoresWidgetSmallView(display: entry.display)
        }
    }
}

/// One score in a lock-screen circle; the tap opens that score's own screen. (`Widget` needs a plain
/// `init()`, so each score is its own type over one shared configuration.)
struct SleepDialWidget: Widget {
    var body: some WidgetConfiguration { ScoreDial.configuration(.sleep) }
}

struct RecoveryDialWidget: Widget {
    var body: some WidgetConfiguration { ScoreDial.configuration(.recovery) }
}

struct StrainDialWidget: Widget {
    var body: some WidgetConfiguration { ScoreDial.configuration(.strain) }
}

private enum ScoreDial {
    static func configuration(_ kind: ScoresWidgetDial.Kind) -> some WidgetConfiguration {
        let widgetKind: String
        let name: String
        switch kind {
        case .sleep:    (widgetKind, name) = (ScoresWidgetKind.sleep, "Sleep score")
        case .recovery: (widgetKind, name) = (ScoresWidgetKind.recovery, "Recovery")
        case .strain:   (widgetKind, name) = (ScoresWidgetKind.strain, "Strain")
        }
        return StaticConfiguration(kind: widgetKind, provider: ScoresProvider()) { entry in
            ScoresWidgetCircularView(dial: entry.display.dial(kind))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(name)
        .description("Today's \(name.lowercased()) from the Today card. An on-device estimate, not medical advice.")
        .supportedFamilies([.accessoryCircular])
    }
}
