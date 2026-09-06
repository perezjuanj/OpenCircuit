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
                      nightWindowEnd: Date? = nil,
                      resumeHint: HistoryDrainPlan.Step? = nil) -> [String] {
        labels(HistoryDrainPlan.steps(inBackground: inBackground,
                                      allDayOnly: allDayOnly,
                                      sportEnabled: sportEnabled,
                                      now: now,
                                      nightWindowEnd: nightWindowEnd,
                                      resumeHint: resumeHint))
    }

    /// A wake instant that puts `now` squarely inside the morning catch-up window.
    private var inCatchUp: Date { now.addingTimeInterval(-1800) }

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

    // MARK: resuming — one-shot resume for a channel cut off by session replacement (#reconnect)

    func testResumingMovesTheHintedStepToTheFront() {
        let base = [HistoryDrainPlan.sleepStep, HistoryDrainPlan.allDayStep, HistoryDrainPlan.sportStep]
        let resumed = HistoryDrainPlan.resuming(HistoryDrainPlan.allDayStep, in: base)
        XCTAssertEqual(labels(resumed), ["all-day", "sleep", "sport"])
    }

    func testResumingIsANoOpWhenTheHintedStepIsAlreadyFirst() {
        let base = [HistoryDrainPlan.sleepStep, HistoryDrainPlan.allDayStep]
        XCTAssertEqual(labels(HistoryDrainPlan.resuming(HistoryDrainPlan.sleepStep, in: base)),
                       ["sleep", "all-day"])
    }

    func testResumingIsANoOpWhenTheHintedStepIsNotInThePlan() {
        // The allDayOnly workout prime's plan is `[allDayStep]` only — a stale sleep/sport hint
        // left over from a churn that happened to land during the prime must not inject a channel
        // the prime deliberately excludes (#119).
        let primePlan = [HistoryDrainPlan.allDayStep]
        XCTAssertEqual(labels(HistoryDrainPlan.resuming(HistoryDrainPlan.sleepStep, in: primePlan)),
                       ["all-day"])
        XCTAssertEqual(labels(HistoryDrainPlan.resuming(HistoryDrainPlan.sportStep, in: primePlan)),
                       ["all-day"])
    }

    // MARK: The resume hint is GATED to the plain foreground plan (#reconnect)
    //
    // These are the regression that would otherwise have shipped. The hint was originally applied by
    // `RingSession` to EVERY plan. Because `sleep` goes first in the FOREGROUND plan, `sleep` is the
    // channel most often in flight at teardown, so the hint is `sleep` far more often than not — and
    // an ungated hint therefore turned the next background pass into `[sleep, all-day]`, inverting
    // the device-observed all-day-first order commit `39f3e43` shipped ("sleep no-ack added=0, then
    // all-day added=173") inside a ~30 s BGTask window.

    func testResumeHintReordersThePlainForegroundPlan() {
        // Positive control for the three no-op tests below: the gate must not be vacuous.
        XCTAssertEqual(plan(resumeHint: HistoryDrainPlan.allDayStep), ["all-day", "sleep"])
        XCTAssertEqual(plan(sportEnabled: true, resumeHint: HistoryDrainPlan.sportStep),
                       ["sport", "sleep", "all-day"])
    }

    func testResumeHintIsANoOpForTheBackgroundPlan() {
        // The bounded ~30 s window exists to land today's vitals; all-day must stay first (39f3e43).
        XCTAssertEqual(plan(inBackground: true, resumeHint: HistoryDrainPlan.sleepStep),
                       ["all-day", "sleep"])
        XCTAssertEqual(plan(inBackground: true, sportEnabled: true,
                            resumeHint: HistoryDrainPlan.sleepStep),
                       ["all-day", "sleep"])
    }

    func testResumeHintIsANoOpForTheMorningCatchUpPlan() {
        // The morning catch-up is deliberately sleep-first for #119 — the night accumulated untouched
        // under overnight-quiet and must land before the user opens the app.
        XCTAssertEqual(plan(inBackground: true, nightWindowEnd: inCatchUp), ["sleep", "all-day"])
        XCTAssertEqual(plan(inBackground: true, nightWindowEnd: inCatchUp,
                            resumeHint: HistoryDrainPlan.allDayStep),
                       ["sleep", "all-day"])
    }

    func testResumeHintIsANoOpForTheAllDayOnlyPrime() {
        // #119: the workout prime touches 0x03 and nothing else. A hint must not inject the sleep
        // channel into it and walk the overnight resume pointer.
        for hint in [HistoryDrainPlan.sleepStep, HistoryDrainPlan.allDayStep, HistoryDrainPlan.sportStep] {
            XCTAssertEqual(plan(allDayOnly: true, resumeHint: hint), ["all-day"],
                           "prime admitted a resume hint: \(hint.label)")
            XCTAssertEqual(plan(inBackground: true, allDayOnly: true, resumeHint: hint), ["all-day"])
        }
    }

    func testResumeHintNeverChangesWHICHChannelsAPassOpens() {
        // Whatever the gate does, it may only ever permute — never add, drop or duplicate a channel.
        let wakes: [Date?] = [nil, inCatchUp, now.addingTimeInterval(-99_999), now.addingTimeInterval(3600)]
        let hints: [HistoryDrainPlan.Step?] = [nil, HistoryDrainPlan.sleepStep,
                                               HistoryDrainPlan.allDayStep, HistoryDrainPlan.sportStep]
        for inBackground in [true, false] {
            for allDayOnly in [true, false] {
                for sportEnabled in [true, false] {
                    for wake in wakes {
                        let baseline = plan(inBackground: inBackground, allDayOnly: allDayOnly,
                                            sportEnabled: sportEnabled, nightWindowEnd: wake).sorted()
                        for hint in hints {
                            let hinted = plan(inBackground: inBackground, allDayOnly: allDayOnly,
                                              sportEnabled: sportEnabled, nightWindowEnd: wake,
                                              resumeHint: hint).sorted()
                            XCTAssertEqual(hinted, baseline,
                                           "hint changed the channel SET: bg=\(inBackground) prime=\(allDayOnly) sport=\(sportEnabled) hint=\(hint?.label ?? "nil")")
                        }
                    }
                }
            }
        }
    }

    func testOnlyThePlainForegroundPlanIsEverReorderedByAHint() {
        // The exhaustive statement of the gate: for every input where the hint changes anything at
        // all, `inBackground` is false and `allDayOnly` is false.
        let wakes: [Date?] = [nil, inCatchUp, now.addingTimeInterval(-99_999)]
        for inBackground in [true, false] {
            for allDayOnly in [true, false] {
                for sportEnabled in [true, false] {
                    for wake in wakes {
                        let baseline = plan(inBackground: inBackground, allDayOnly: allDayOnly,
                                            sportEnabled: sportEnabled, nightWindowEnd: wake)
                        for hint in [HistoryDrainPlan.sleepStep, HistoryDrainPlan.allDayStep,
                                     HistoryDrainPlan.sportStep] {
                            let hinted = plan(inBackground: inBackground, allDayOnly: allDayOnly,
                                              sportEnabled: sportEnabled, nightWindowEnd: wake,
                                              resumeHint: hint)
                            if hinted != baseline {
                                XCTAssertFalse(inBackground, "a hint reordered a BACKGROUND plan")
                                XCTAssertFalse(allDayOnly, "a hint reordered the allDayOnly prime")
                            }
                        }
                    }
                }
            }
        }
    }

    func testNoResumeHintIsByteIdenticalToTheUnhintedPlan() {
        // The parameter is additive: with no hint, `steps` produces exactly what it did before.
        let wakes: [Date?] = [nil, inCatchUp, now.addingTimeInterval(-99_999)]
        for inBackground in [true, false] {
            for allDayOnly in [true, false] {
                for sportEnabled in [true, false] {
                    for wake in wakes {
                        let withParam = HistoryDrainPlan.steps(inBackground: inBackground,
                                                               allDayOnly: allDayOnly,
                                                               sportEnabled: sportEnabled,
                                                               now: now, nightWindowEnd: wake,
                                                               resumeHint: nil)
                        let withoutParam = HistoryDrainPlan.steps(inBackground: inBackground,
                                                                  allDayOnly: allDayOnly,
                                                                  sportEnabled: sportEnabled,
                                                                  now: now, nightWindowEnd: wake)
                        XCTAssertEqual(withParam, withoutParam)
                    }
                }
            }
        }
    }

    // MARK: TeardownReason — WHICH teardowns may capture a resume hint (#reconnect)
    //
    // The hint used to be captured unconditionally inside `RingScanner.teardownSession()`, which has
    // six callers; three of them are not session churn. This table is that fix.

    func testOnlyGenuineChurnTeardownsCaptureAResumeHint() {
        XCTAssertTrue(HistoryDrainPlan.TeardownReason.linkDropped.capturesResumeHint)
        XCTAssertTrue(HistoryDrainPlan.TeardownReason.sessionReplaced.capturesResumeHint)
    }

    func testUserDisconnectDoesNotCaptureAResumeHint() {
        // `disconnect()` / `forgetActiveRing()` — a deliberate stop must not queue a reorder for a
        // future connect.
        XCTAssertFalse(HistoryDrainPlan.TeardownReason.userDisconnected.capturesResumeHint)
    }

    func testRingSwitchDoesNotCaptureAResumeHint() {
        // The in-app picker moving to a DIFFERENT ring: ring A's in-flight channel is not evidence
        // about ring B.
        XCTAssertFalse(HistoryDrainPlan.TeardownReason.switchingRing.capturesResumeHint)
    }

    func testBoundedBackgroundReadEndDoesNotCaptureAResumeHint() {
        // The normal end of EVERY bounded background read — nothing was cut off.
        XCTAssertFalse(HistoryDrainPlan.TeardownReason.backgroundReadEnded.capturesResumeHint)
    }

    func testExactlyTwoTeardownReasonsCapture() {
        // Pins the whole table, so a NEW reason cannot default into capturing by being forgotten.
        let capturing = HistoryDrainPlan.TeardownReason.allCases.filter(\.capturesResumeHint)
        XCTAssertEqual(Set(capturing.map(\.rawValue)), ["linkDropped", "sessionReplaced"])
    }

    // MARK: ResumeHint identity + TTL (#reconnect)
    //
    // Before these existed the hint had neither: it was cleared only when a new session was created,
    // so it could survive indefinitely and be applied to a different ring days later.

    private let ringA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let ringB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func hint(_ step: HistoryDrainPlan.Step = HistoryDrainPlan.allDayStep,
                      from ring: UUID,
                      at capturedAt: Date) -> HistoryDrainPlan.ResumeHint {
        HistoryDrainPlan.ResumeHint(step: step, peripheralID: ring, capturedAt: capturedAt)
    }

    func testAFreshHintFromTheSameRingIsAccepted() {
        let h = hint(from: ringA, at: now)
        XCTAssertEqual(h.step(forPeripheral: ringA, at: now.addingTimeInterval(5)),
                       HistoryDrainPlan.allDayStep)
    }

    func testAHintFromRingAIsRefusedByASessionOnRingB() {
        let h = hint(from: ringA, at: now)
        XCTAssertNil(h.step(forPeripheral: ringB, at: now.addingTimeInterval(1)),
                     "ring A's interrupted channel must never be applied to ring B")
    }

    func testAnExpiredHintIsRefused() {
        let ttl = HistoryDrainPlan.ResumeHint.timeToLive
        let h = hint(from: ringA, at: now)
        XCTAssertNotNil(h.step(forPeripheral: ringA, at: now.addingTimeInterval(ttl)),
                        "the TTL boundary itself is inclusive")
        XCTAssertNil(h.step(forPeripheral: ringA, at: now.addingTimeInterval(ttl + 0.001)))
        XCTAssertNil(h.step(forPeripheral: ringA, at: now.addingTimeInterval(86_400)),
                     "a day-old hint must not land on the next connect")
    }

    func testAHintFromTheFutureIsRefused() {
        // A backwards clock step (NTP correction / manual set) makes the age un-trustworthy.
        let h = hint(from: ringA, at: now.addingTimeInterval(60))
        XCTAssertNil(h.step(forPeripheral: ringA, at: now))
    }

    // MARK: afterTeardown — the whole capture/clear/keep policy (#reconnect)

    private func afterTeardown(_ reason: HistoryDrainPlan.TeardownReason,
                               inFlight: HistoryDrainPlan.Step? = HistoryDrainPlan.allDayStep,
                               ring: UUID? = nil,
                               standing: HistoryDrainPlan.ResumeHint? = nil,
                               at when: Date? = nil) -> HistoryDrainPlan.ResumeHint? {
        HistoryDrainPlan.ResumeHint.afterTeardown(reason,
                                                  inFlight: inFlight,
                                                  peripheralID: ring ?? ringA,
                                                  at: when ?? now,
                                                  standing: standing)
    }

    func testAChurnTeardownCapturesTheInFlightChannel() {
        let captured = afterTeardown(.linkDropped)
        XCTAssertEqual(captured?.step, HistoryDrainPlan.allDayStep)
        XCTAssertEqual(captured?.peripheralID, ringA)
        XCTAssertEqual(captured?.capturedAt, now)
    }

    func testACapturingTeardownWithNothingInFlightKEEPSTheStandingHint() {
        // THE REGRESSION THIS PINS. The ordinary reconnect is two teardowns: `didDisconnect`
        // (.linkDropped) captures from the live session, then `didConnect` (.sessionReplaced) runs
        // with `session` already nil — nothing in flight. If that second teardown cleared, it would
        // erase the hint the first just took and the resume path would be dead, silently, because
        // the fallback is just the normal plan order.
        let standing = hint(from: ringA, at: now)
        let after = afterTeardown(.sessionReplaced, inFlight: nil, standing: standing,
                                  at: now.addingTimeInterval(2))
        XCTAssertEqual(after, standing, "didConnect's teardown erased didDisconnect's hint")
    }

    func testANonChurnTeardownCLEARSAStandingHint() {
        let standing = hint(from: ringA, at: now)
        for reason: HistoryDrainPlan.TeardownReason in [.switchingRing, .userDisconnected, .backgroundReadEnded] {
            XCTAssertNil(afterTeardown(reason, inFlight: HistoryDrainPlan.sleepStep, standing: standing),
                         "\(reason.rawValue) left a hint standing")
            XCTAssertNil(afterTeardown(reason, inFlight: nil, standing: standing),
                         "\(reason.rawValue) left a hint standing")
        }
    }

    func testARingSwitchCannotHandRingAsHintToRingB() {
        // End to end for defect 2: the picker moves to ring B while ring A had all-day in flight.
        let standing = hint(from: ringA, at: now)
        let afterSwitch = afterTeardown(.switchingRing, inFlight: HistoryDrainPlan.allDayStep,
                                        ring: ringA, standing: standing)
        XCTAssertNil(afterSwitch)
        // …and even if a hint somehow survived, the identity guard refuses it on ring B.
        XCTAssertNil(standing.step(forPeripheral: ringB, at: now))
    }

    func testACapturingTeardownWithNoTargetedRingKeepsTheStandingHint() {
        // `target` is nil (the ring was already released): there is nothing to stamp an identity
        // with, so capture is impossible — but that is not a reason to destroy what we hold.
        let standing = hint(from: ringA, at: now)
        XCTAssertEqual(HistoryDrainPlan.ResumeHint.afterTeardown(.linkDropped,
                                                                 inFlight: HistoryDrainPlan.sleepStep,
                                                                 peripheralID: nil,
                                                                 at: now,
                                                                 standing: standing),
                       standing)
    }

    func testAFreshCaptureSupersedesAnOlderStandingHint() {
        let stale = hint(HistoryDrainPlan.sleepStep, from: ringA, at: now.addingTimeInterval(-300))
        let fresh = afterTeardown(.linkDropped, inFlight: HistoryDrainPlan.allDayStep, standing: stale)
        XCTAssertEqual(fresh?.step, HistoryDrainPlan.allDayStep)
        XCTAssertEqual(fresh?.capturedAt, now)
    }

    func testTheTimeToLiveCoversTheWorstReconnectBackoffWithMargin() {
        // BASIS for the 120 s constant: it must outlast the longest single backoff step so a hint
        // survives a real reconnect, and expire well inside a drain cadence so it cannot become a
        // standing reorder.
        let worstBackoff = ReconnectBackoff.delays.max() ?? 0
        XCTAssertGreaterThan(HistoryDrainPlan.ResumeHint.timeToLive, worstBackoff)
        XCTAssertLessThan(HistoryDrainPlan.ResumeHint.timeToLive,
                          HistoryDrainPlan.defaultMorningCatchUpWindow)
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
