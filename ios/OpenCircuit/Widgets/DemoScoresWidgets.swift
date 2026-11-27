// `-OCDemoScreen widgets` (#398): the Today scores widgets at their home- and lock-screen sizes, so a
// simulator screenshot shows them without adding them to a home screen by hand. DEBUG only, SYNTHETIC
// inputs only. Each state goes through the real pipeline: `TodayScores.build` → snapshot → encode →
// decode → the widget's display model.

#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import OpenCircuitKit

struct DemoScoresWidgets: View {
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(Self.samples().enumerated()), id: \.offset) { _, sample in
                        Text(sample.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 12) {
                            tile(ScoresWidgetSmallView(display: sample.display), width: 170, height: 170)
                            tile(ScoresWidgetMediumView(display: sample.display), width: 364, height: 170)
                        }
                        HStack(spacing: 12) {
                            lock(ScoresWidgetRectangularView(display: sample.display), width: 172, height: 76)
                            ForEach(ScoresWidgetDial.Kind.allCases, id: \.self) { kind in
                                lock(ScoresWidgetCircularView(dial: sample.display.dial(kind),
                                                              stale: sample.display.freshness == .stale),
                                     width: 76, height: 76)
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(width: geo.size.width / Self.scale, height: geo.size.height / Self.scale)
            .scaleEffect(Self.scale, anchor: .topLeading)
        }
        .background(Theme.pageBackground)
    }

    private static let scale: CGFloat = 0.72

    private func tile(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content.padding(16).frame(width: width, height: height)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func lock(_ content: some View, width: CGFloat, height: CGFloat) -> some View {
        content.frame(width: width, height: height)
            .padding(4)
            .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
    }

    private struct Sample {
        let title: String
        let display: ScoresWidgetDisplay
    }

    private static func samples(now: Date = Date()) -> [Sample] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func night(score: Int, stress: Int, asleep: Int) -> TodayScores.Night {
            let wake = today.addingTimeInterval(6.75 * 3600)
            return .init(nightKey: today, inBedStart: wake.addingTimeInterval(-Double(asleep + 40) * 60),
                         inBedEnd: wake, sleepScore: score, stressScore: stress, asleepMin: asleep)
        }
        func strain(_ value: Double?, minutes: Int) -> DailyStrain.Reading {
            DailyStrain.Reading(strain: value, coveredSeconds: minutes * 60, latestSampleAt: now,
                                maxHR: 185, restingHR: 54)
        }
        let viewNow = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        func display(_ s: TodayScores, writtenAt: Date) -> ScoresWidgetDisplay {
            let data = ScoresWidgetSnapshotBuilder.snapshot(s, at: writtenAt).flatMap(ScoresWidgetCodec.encode)
            return .make(data.flatMap(ScoresWidgetCodec.decode), now: viewNow, calendar: cal)
        }
        let scored = TodayScores.build(night: night(score: 81, stress: 40, asleep: 430),
                                       strain: strain(12.4, minutes: 600), trendsLoaded: true,
                                       now: viewNow, calendar: cal)
        let noNight = TodayScores.build(night: nil, strain: strain(nil, minutes: 4), trendsLoaded: true,
                                        now: viewNow, calendar: cal)
        return [
            Sample(title: "Current: all three scored", display: display(scored, writtenAt: viewNow - 600)),
            Sample(title: "Current: no night yet, strain needs minutes", display: display(noNight, writtenAt: viewNow - 600)),
            Sample(title: "Stale: written 5 hours ago", display: display(scored, writtenAt: viewNow - 5 * 3600)),
            Sample(title: "Expired: written yesterday", display: display(scored, writtenAt: viewNow - 86_400)),
        ]
    }
}
#endif
