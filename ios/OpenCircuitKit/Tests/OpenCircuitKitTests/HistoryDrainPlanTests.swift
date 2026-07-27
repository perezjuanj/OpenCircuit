import XCTest
@testable import OpenCircuitKit

/// Locks the channel order that was previously three inline booleans in `performHistoryDrain`.
/// The extraction is meant to be BEHAVIOURALLY IDENTICAL to those booleans, so these tests double
/// as a parity harness: `testMatchesTheReplacedInlineLogicForEveryInput` re-implements the old
/// expression verbatim and compares across the whole input space.
final class HistoryDrainPlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_030_000)
    private func labels(_ steps: [HistoryDrainPlan.Step]) -> [String] { steps.map(\.label) }

    private func plan(inBackground: Bool = false,
                      allDayOnly: Bool = false,
                      sportEnabled: Bool = false,
                      nightWindowEnd: Date? = nil) -> [String] {
        labels(HistoryDrainPlan.steps(inBackground: inBackground,
                                      allDayOnly: allDayOnly,
                                      sportEnabled: sportEnabled,
                                      now: now,
                                      nightWindowEnd: nightWindowEnd))
    }

    // MARK: Order

    func testForegroundDrainsSleepFirst() {
        XCTAssertEqual(plan(), ["sleep", "all-day"])
    }

    func testForegroundAppendsSportLastWhenEnabled() {
        XCTAssertEqual(plan(sportEnabled: true), ["sleep", "all-day", "sport"])
    }

    func testOrdinaryBackgroundDrainsAllDayFirst() {
        // The bounded ~30 s BGAppRefresh window exists to refresh today's vitals (commit 39f3e43).
        XCTAssertEqual(plan(inBackground: true), ["all-day", "sleep"])
    }

    func testBackgroundNeverDrainsSportEvenWhenEnabled() {
        XCTAssertEqual(plan(inBackground: true, sportEnabled: true), ["all-day", "sleep"])
    }

    func testBackgroundMorningCatchUpDrainsSleepFirst() {
        // Within the catch-up window after wake, the night's backlog outranks everything.
        XCTAssertEqual(plan(inBackground: true, nightWindowEnd: now.addingTimeInterval(-3600)),
                       ["sleep", "all-day"])
    }

    func testWakeWindowInTheFutureIsNotAMorningCatchUp() {
        // nightWindow.end is TONIGHT's — sinceWake is negative and must not count.
        XCTAssertEqual(plan(inBackground: true, nightWindowEnd: now.addingTimeInterval(3600)),
                       ["all-day", "sleep"])
    }

    func testWakeLongPastIsNotAMorningCatchUp() {
        XCTAssertEqual(plan(inBackground: true, nightWindowEnd: now.addingTimeInterval(-9 * 3600)),
                       ["all-day", "sleep"])
    }

    func testForegroundIsSleepFirstRegardlessOfTheWakeWindow() {
        // The replaced `morningCatchUp` required inBackground; foreground was unconditionally
        // sleep-first. Pinned because a draft that computed the wake proximity phase-independently
        // would silently change foreground ordering.
        for wake in [nil, now.addingTimeInterval(-3600), now.addingTimeInterval(3600),
                     now.addingTimeInterval(-9 * 3600)] as [Date?] {
            XCTAssertEqual(plan(nightWindowEnd: wake), ["sleep", "all-day"])
        }
    }

    // MARK: #119 — the workout prime must never walk the sleep resume pointer

    func testAllDayOnlyTouchesOnlyTheAllDayChannel() {
        for background in [true, false] {
            for sport in [true, false] {
                for wake in [nil, now.addingTimeInterval(-3600)] as [Date?] {
                    XCTAssertEqual(plan(inBackground: background, allDayOnly: true,
                                        sportEnabled: sport, nightWindowEnd: wake),
                                   ["all-day"],
                                   "allDayOnly must never schedule sleep or sport (bg=\(background) sport=\(sport))")
                }
            }
        }
    }

    // MARK: Structural invariants

    func testEveryPlanDrainsBothVitalsChannelsExactlyOnce() {
        for background in [true, false] {
            for sport in [true, false] {
                for wake in [nil, now.addingTimeInterval(-3600), now.addingTimeInterval(3600)] as [Date?] {
                    let l = plan(inBackground: background, sportEnabled: sport, nightWindowEnd: wake)
                    XCTAssertEqual(l.filter { $0 == "sleep" }.count, 1)
                    XCTAssertEqual(l.filter { $0 == "all-day" }.count, 1)
                    if sport, !background {
                        XCTAssertEqual(l.last, "sport", "sport must always be drained last")
                    } else {
                        XCTAssertFalse(l.contains("sport"))
                    }
                }
            }
        }
    }

    func testStepsCarryTheCorrectWireChannelSelectors() {
        XCTAssertEqual(HistoryDrainPlan.sleepStep.channel, Command.syncChannelSleep)
        XCTAssertEqual(HistoryDrainPlan.allDayStep.channel, Command.syncChannelAllDay)
        XCTAssertEqual(HistoryDrainPlan.sportStep.channel, Command.syncChannelSport)
    }

    /// PARITY: re-implements the exact inline logic this type replaced and compares over the whole
    /// input space, so the extraction cannot silently drift from shipped behaviour.
    func testMatchesTheReplacedInlineLogicForEveryInput() {
        let window = HistoryDrainPlan.defaultMorningCatchUpWindow
        let wakes: [Date?] = [nil,
                              now.addingTimeInterval(-1),
                              now.addingTimeInterval(-3600),
                              now.addingTimeInterval(-window),
                              now.addingTimeInterval(-window - 1),
                              now,
                              now.addingTimeInterval(1),
                              now.addingTimeInterval(3600)]
        for inBackground in [true, false] {
            for allDayOnly in [true, false] {
                for sportEnabled in [true, false] {
                    for wake in wakes {
                        // --- verbatim transcription of the old performHistoryDrain block ---
                        let morningCatchUp: Bool = {
                            guard inBackground, let end = wake else { return false }
                            let sinceWake = now.timeIntervalSince(end)
                            return sinceWake >= 0 && sinceWake <= window
                        }()
                        let sleepFirst = !inBackground || morningCatchUp
                        var expected: [String] = []
                        if sleepFirst, !allDayOnly { expected.append("sleep") }
                        expected.append("all-day")
                        if !sleepFirst, !allDayOnly { expected.append("sleep") }
                        if !inBackground, !allDayOnly, sportEnabled { expected.append("sport") }
                        // --- end transcription ---

                        XCTAssertEqual(plan(inBackground: inBackground, allDayOnly: allDayOnly,
                                            sportEnabled: sportEnabled, nightWindowEnd: wake),
                                       expected,
                                       "drift: bg=\(inBackground) allDayOnly=\(allDayOnly) sport=\(sportEnabled) wake=\(String(describing: wake))")
                    }
                }
            }
        }
    }
}
