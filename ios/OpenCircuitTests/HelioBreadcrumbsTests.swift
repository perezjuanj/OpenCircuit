import XCTest
@testable import OpenCircuit

// The strap's link and wake breadcrumbs (#233): their volume rules, what a line may contain, and the
// Diagnostics export's section. Every time is synthetic.

@MainActor
final class HelioBreadcrumbsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_862_400)
    private var suite: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "HelioBreadcrumbsTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Budget

    /// One 12 h window holds at most 20 link lines; the last one says the budget is spent, the rest are
    /// counted, and the count is reported on the next window's first line. Each category has its own
    /// budget: a spent link budget leaves the sync lines alone.
    func testEachCategoryIsCappedPerWindowAndTheOverflowIsReportedNextWindow() {
        var budget = HelioBreadcrumbBudget()
        var lines: [String] = []
        for i in 0..<30 {
            if let line = budget.admit("link \(i)", kind: .link, now: t0.addingTimeInterval(TimeInterval(i * 60))) {
                lines.append(line)
            }
        }
        XCTAssertEqual(lines.count, HelioBreadcrumbBudget.Kind.link.linesPerWindow)
        XCTAssertTrue(lines.last?.contains("link line budget spent") == true)
        XCTAssertFalse(lines.dropLast().contains { $0.contains("budget") })
        XCTAssertEqual(budget.admit("sync", kind: .sync, now: t0.addingTimeInterval(3600)), "sync")
        XCTAssertEqual(HelioBreadcrumbBudget.linesPerWindow, 48)
        let next = budget.admit("next window", kind: .link, now: t0.addingTimeInterval(HelioBreadcrumbBudget.window + 1))
        XCTAssertEqual(next, "next window [10 line(s) over budget in the previous 12 h]")
        XCTAssertEqual(budget.admit("after", kind: .link, now: t0.addingTimeInterval(HelioBreadcrumbBudget.window + 2)), "after")
    }

    /// Strap messages: one line per endpoint per 10 minutes, carrying how many arrived; at most four
    /// lines per endpoint per window, so a chatty endpoint can't starve another one.
    func testStrapMessagesAreRateLimitedPerEndpointWithACount() {
        var budget = HelioBreadcrumbBudget()
        XCTAssertEqual(budget.due(key: "0x0015", perWindow: 4, now: t0), 1)
        XCTAssertNil(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(60)))
        XCTAssertNil(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(599)))
        XCTAssertEqual(budget.due(key: "0x001d", perWindow: 4, now: t0.addingTimeInterval(599)), 1, "endpoints are independent")
        XCTAssertEqual(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(600)), 3, "the two counted ones plus this one")
        XCTAssertEqual(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(1200)), 1)
        XCTAssertEqual(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(1800)), 1)
        XCTAssertNil(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(2400)), "four lines for this endpoint in this window")
        XCTAssertNil(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(3000)))
        XCTAssertEqual(budget.due(key: "0x001d", perWindow: 4, now: t0.addingTimeInterval(3000)), 1, "another endpoint still gets its lines")
        XCTAssertEqual(budget.due(key: "0x0015", perWindow: 4, now: t0.addingTimeInterval(HelioBreadcrumbBudget.window + 600)), 3,
                       "the next window reports what was counted meanwhile")
    }

    /// A whole night of a strap pinging every minute and flapping its link every 30 minutes, then one
    /// woke-up event, stays within 48 lines, and the woke-up event and the morning's sync line still
    /// make it.
    func testAChattyNightStaysBoundedAndKeepsTheMorningLines() {
        let observability = ObservabilityStore(suite)
        var now = t0
        let breadcrumbs = HelioBreadcrumbs(observability: observability, defaults: suite, clock: { now })
        for minute in 0..<(10 * 60) {
            now = t0.addingTimeInterval(TimeInterval(minute * 60))
            breadcrumbs.strapMessage(endpoint: 0x0015, opcode: [0x03], length: 1)
            if minute % 30 == 0 {
                breadcrumbs.linkDown(errorCode: 6, expected: false, standingConnectArmed: true)
                breadcrumbs.linkUp("connected", appActive: false)
            }
        }
        now = t0.addingTimeInterval(10 * 3600 + 30)
        breadcrumbs.strapMessage(endpoint: 0x001D, opcode: [0x06, 0x00], length: 2)
        breadcrumbs.syncStarted(wake: .strapEvent, detail: "kind=cbWake")
        let lines = observability.metricRecords().filter { $0.source == HelioBreadcrumbs.source }
        XCTAssertLessThanOrEqual(lines.count, HelioBreadcrumbBudget.linesPerWindow)
        XCTAssertEqual(lines.filter { $0.detail.hasPrefix("link") }.count, HelioBreadcrumbBudget.Kind.link.linesPerWindow)
        XCTAssertEqual(lines.filter { $0.detail.hasPrefix("strap sent 0x0015") }.count, HelioBreadcrumbBudget.messageLinesPerKey)
        XCTAssertTrue(lines.contains { $0.detail.hasPrefix("strap sent 0x001d 06 00") }, "the woke-up event isn't starved by the pings")
        XCTAssertTrue(lines.contains { $0.detail == "sync start wake=strapEvent (kind=cbWake)" })
    }

    // MARK: What a line says

    /// Link lines carry CoreBluetooth's error code and the standing connect; restoration lines carry
    /// states only; strap lines the endpoint and opcode only.
    func testLinesCarryStatesAndCodesNeverIdentifiersOrValues() {
        let observability = ObservabilityStore(suite)
        let breadcrumbs = HelioBreadcrumbs(observability: observability, defaults: suite, clock: { self.t0 })
        breadcrumbs.linkDown(errorCode: 7, expected: false, standingConnectArmed: true, upFor: 3 * 3600 + 12 * 60 + 40)
        breadcrumbs.linkDown(errorCode: nil, expected: true, standingConnectArmed: false)
        breadcrumbs.restored(peripheralStates: ["connected", "disconnected"], savedStrapState: "connected")
        breadcrumbs.strapMessage(endpoint: 0x001D, opcode: [0x06, 0x00], length: 2)
        breadcrumbs.strapNotification(characteristic: "heartRateMeasurement")
        XCTAssertEqual(observability.metricRecords().map(\.detail), [
            "link down (unexpected, CBError 7, after 3h12m up); standing connect armed",
            "link down (we dropped it, no error); standing connect NOT armed",
            "restoration relaunch: 2 peripheral(s) [connected,disconnected]; saved strap connected",
            "strap sent 0x001d 06 00 (2 B) (1 since this endpoint's last line)",
            "strap sent a heartRateMeasurement notification (1 since this endpoint's last line)",
        ])
        XCTAssertTrue(observability.metricRecords().allSatisfy { $0.source == "helio-link" })
    }

    /// The rate limit survives a relaunch (a restoration relaunch is a new process).
    func testTheRateLimitIsPersistedAcrossInstances() {
        let observability = ObservabilityStore(suite)
        HelioBreadcrumbs(observability: observability, defaults: suite, clock: { self.t0 })
            .strapMessage(endpoint: 0x0015, opcode: [0x03], length: 1)
        HelioBreadcrumbs(observability: observability, defaults: suite, clock: { self.t0.addingTimeInterval(60) })
            .strapMessage(endpoint: 0x0015, opcode: [0x03], length: 1)
        XCTAssertEqual(observability.metricRecords().count, 1)
    }

    // MARK: Diagnostics export

    /// The export's strap section: only `helio-link` lines, newest first, capped; absent when there are none.
    func testTheDiagnosticsSectionListsTheStrapsBreadcrumbsNewestFirst() {
        let fmt: (Date?) -> String = { $0.map { String(Int($0.timeIntervalSince1970) - 1_789_862_400) } ?? "—" }
        XCTAssertNil(DiagnosticsReport.strapLinkSection([MetricRecord(date: t0, source: "bgphase", detail: "ring")], format: fmt))
        var records = [MetricRecord(date: t0, source: "bgphase", detail: "not this")]
        for i in 0..<(DiagnosticsReport.strapLinkLimit + 5) {
            records.append(MetricRecord(date: t0.addingTimeInterval(TimeInterval(i)), source: HelioBreadcrumbs.source, detail: "line \(i)"))
        }
        let section = DiagnosticsReport.strapLinkSection(records, format: fmt) ?? []
        XCTAssertEqual(section.first, "# Strap link and wakes (latest 100 of 105)")
        XCTAssertEqual(section[2], "  104  line 104")
        XCTAssertEqual(section.last, "  5  line 5")
        XCTAssertEqual(section.count, 2 + DiagnosticsReport.strapLinkLimit)
        XCTAssertFalse(section.contains { $0.contains("not this") })
    }

    /// The strap's bundle carries the section and says it holds no health values.
    func testTheStrapBundleCarriesTheBreadcrumbs() {
        let observability = ObservabilityStore(suite)
        HelioBreadcrumbs(observability: observability, defaults: suite, clock: { self.t0 })
            .linkUp("connected", appActive: false)
        let report = DiagnosticsReport.buildForStrap(firmware: "1.2.3.4", hardware: nil, observability: observability,
                                                     timeZone: TimeZone(identifier: "UTC")!, now: t0)
        XCTAssertTrue(report.contains("# Strap link and wakes (latest 1 of 1)"))
        XCTAssertTrue(report.contains("link up (connected; app in background)"))
        XCTAssertTrue(report.contains("It holds no health values and no device identifiers."))
    }

    // MARK: Decision 87d (#352)

    /// The woke-up event's skip line is outside the budget: logged with the sync lines spent, and it
    /// spends none of them.
    func testTheWokeUpSkipLineSurvivesASpentSyncBudget() throws {
        let crumbs = HelioBreadcrumbs(observability: ObservabilityStore(suite), defaults: suite, clock: { [t0] in t0 })
        for i in 0..<(HelioBreadcrumbBudget.Kind.sync.linesPerWindow + 3) { crumbs.wakeNote(.reconnect, "line \(i)") }
        crumbs.wokeUpSkipped("no catch-up: a background run started under 30 min ago; refresh requested in 20 min")
        crumbs.wokeUpSkipped("no catch-up: a background run started under 30 min ago; an earlier refresh is pending")
        let lines = ObservabilityStore(suite).metricRecords().filter { $0.source == HelioBreadcrumbs.source }.map(\.detail)
        XCTAssertEqual(lines.count, HelioBreadcrumbBudget.Kind.sync.linesPerWindow + 2)
        XCTAssertTrue(lines.contains("wake=strapEvent: no catch-up: a background run started under 30 min ago; refresh requested in 20 min"))
        XCTAssertTrue(lines.contains("wake=strapEvent: no catch-up: a background run started under 30 min ago; an earlier refresh is pending"))
        let budget = try JSONDecoder().decode(HelioBreadcrumbBudget.self, from: try XCTUnwrap(suite.data(forKey: HelioBreadcrumbs.budgetKey)))
        XCTAssertEqual(budget.suppressed, 3, "only the budgeted lines were counted")
    }
}

