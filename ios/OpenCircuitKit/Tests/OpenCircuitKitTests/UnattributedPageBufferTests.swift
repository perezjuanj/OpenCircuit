import XCTest
@testable import OpenCircuitKit

/// #188 — THE 2026-08-04 LOST NIGHTS.
///
/// Two testers lost a whole night on the same day, on different hardware, firmware and timezones,
/// through the same defect: `RingSession`'s `0x4c` handler ACKed every page unconditionally but
/// BANKED one only while `syncing || livePreparing`. Because `Command.pageAck4C` advances the ring's
/// single resume pointer, every page acked outside that gate was consumed from the ring AND thrown
/// away — silently and permanently.
///
///   • Gen 2 / FR02.018 (ET). The ring streamed 208 contiguous epoch records (08-04 00:15 → 08:53,
///     8.62 h) as 35 pages between wire-clock 08:56:16 and 08:57:02, its own remaining-counter
///     running 202,196,…,4,0 with no restart. The app's drain bookkeeping opened at 08:57:00.637 and
///     counted the last 6 pages (34 records), reporting `outcome:"complete"`. The archive gap report
///     read "08-04 00:03 --7.5h--> 08-04 07:30" and the night was shown as 1 h 25 m.
///   • Gen 2 Air / FR04.009 (Paris). 189 records (08-03 22:38 → 08-04 06:28, 7.8 h) streamed at
///     06:31:22; the first drain opened at 06:32:06.6 and banked 3 records. No summary at all.
///
/// THE INVARIANT UNDER TEST: **a page we ACK is a page we KEEP.** A page that arrives before a
/// drain's own start is retained just as surely as one that arrives after it, and the two sets union
/// into a hole-free night.
///
/// SCOPE NOTE (deliberate, do not "fix" by mocking): this covers the pure retention + union layer
/// that production uses — `UnattributedPageBuffer` is the type `RingSession` delegates to, and
/// `EpochArchive.merge` is the real archive merge. It does NOT cover `RingSession`'s wiring (which
/// lifecycle points bank and adopt), because that type is `@MainActor` + CoreBluetooth-bound and is
/// not constructible off-device. That wiring is covered by review and on-device validation.
final class UnattributedPageBufferTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// A real, XOR-valid 0x4c page from the 2026-06-13 overnight sync (FR02.018) — 6 × 23-byte
    /// records. Same fixture as `BulkSleepTests`; per the project's fixture rule we build the night
    /// from REAL record bodies and only re-stamp the 4-byte counters onto the tester's timeline.
    private let realPage = "4c00260c22a16b55210a7d120a010101010100000402400400000c22a20155000300"
        + "120a010101010100003c00000d01200c22a297540001005f0a010101010100001101b00f"
        + "00440c22a32d6027077b120a010101010100402501c02235a00c22a3c351260577120b01"
        + "0101010108a01000000401300c22a459502d0378120a01010101010160200000040ff0cc"

    private var realRecordBodies: [[UInt8]] {
        BulkSleep.records(fromPage: hex(realPage)).map(\.raw)
    }

    /// Re-stamp a real record body with `counter` (BE, bytes [0:4]). Payload bytes untouched.
    private func record(_ template: [UInt8], counter: UInt32) -> [UInt8] {
        var r = template
        r[0] = UInt8((counter >> 24) & 0xFF)
        r[1] = UInt8((counter >> 16) & 0xFF)
        r[2] = UInt8((counter >> 8) & 0xFF)
        r[3] = UInt8(counter & 0xFF)
        return r
    }

    /// Frame N records as a real 0x4c page: `[0x4c][remaining hi][remaining lo]` + N×23 + XOR
    /// trailer. 🟢 proven framing from the wire: 142 B = 6 records, 96 B = 4, 50 B = 2, 27 B = 1.
    private func page(records: [[UInt8]], remaining: UInt16) -> [UInt8] {
        var f: [UInt8] = [0x4C, UInt8(remaining >> 8), UInt8(remaining & 0xFF)]
        for r in records { f += r }
        f.append(Frame.xorTrailer(f))
        return f
    }

    /// The Gen 2 night exactly as the ring handed it over: 34 six-record pages + a 4-record terminal
    /// page = 208 records at 150 s, first epoch 08-04 00:15 ET (04:15 UTC).
    private func nightPages() throws -> [[UInt8]] {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let first = try XCTUnwrap(f.date(from: "2026-08-04T04:15:00Z"))
        let base = UInt32(Int(first.timeIntervalSince1970) - Command.syncEpoch)
        let bodies = realRecordBodies
        let all = (0 ..< 208).map { i in
            record(bodies[i % bodies.count], counter: base + UInt32(i * BulkRecord.epochSeconds))
        }
        var pages: [[UInt8]] = []
        var i = 0
        var remaining = 202
        while i < 204 {
            pages.append(page(records: Array(all[i ..< i + 6]), remaining: UInt16(remaining)))
            i += 6
            remaining -= 6
        }
        pages.append(page(records: Array(all[204 ..< 208]), remaining: 0))   // terminal, 96 B
        return pages
    }

    // MARK: - fixture sanity (a fixture that doesn't match the wire proves nothing)

    func testFixtureMatchesTheWire() throws {
        let pages = try nightPages()
        XCTAssertEqual(pages.count, 35, "35 pages, as the ring sent")
        XCTAssertEqual(pages.filter { $0.count == 142 }.count, 34, "34 × 142 B six-record pages")
        XCTAssertEqual(pages.last?.count, 96, "terminal page is 96 B = 4 records")
        for p in pages {
            XCTAssertTrue(Frame.isValid(p), "every synthesized page carries a valid XOR trailer")
        }
        let decoded = pages.flatMap { BulkSleep.records(fromPage: $0) }
        XCTAssertEqual(decoded.count, 208)
    }

    // MARK: - the regression

    /// THE TEST. 29 pages arrive with NO drain open (as they did at 08:56:16–08:57:00.6), then a
    /// drain opens mid-stream and the remaining 6 pages arrive. All 208 records must survive.
    func testStreamThatBeganBeforeTheDrainIsFullyRetained() throws {
        let pages = try nightPages()

        var buffer = UnattributedPageBuffer()
        var drainRecords: [BulkRecord] = []

        // 08:56:16 → 08:57:00.6 — no drain open. The shipped code acked and dropped these.
        for p in pages.prefix(29) {
            buffer.retain(BulkSleep.records(fromPage: p))
        }
        XCTAssertEqual(buffer.count, 174, "the 174 records the shipped code lost")
        XCTAssertEqual(buffer.pages, 29)

        // 08:57:00.637 — a drain opens and ADOPTS what the stream already delivered.
        let adopted = buffer.drain()
        XCTAssertEqual(adopted.count, 174)
        XCTAssertTrue(buffer.isEmpty, "drain() resets the buffer")
        drainRecords += adopted

        // …and the rest of the stream lands inside the drain.
        for p in pages.suffix(6) {
            drainRecords += BulkSleep.records(fromPage: p)
        }

        // 1. Nothing was dropped.
        XCTAssertEqual(drainRecords.count, 208,
                       "all 208 epochs retained, not the 34 the shipped app kept")

        // 2. The archive — the store the diagnostics gap report reads — has NO hole where the
        //    drain boundary was.
        let archive = EpochArchive.merge(existing: [], incoming: drainRecords)
        XCTAssertEqual(archive.count, 208)
        let gaps = zip(archive, archive.dropFirst()).map { $1.counter - $0.counter }
        XCTAssertEqual(gaps.max(), UInt32(BulkRecord.epochSeconds),
                       "contiguous at exactly one epoch (150 s) across the 08:57:00.637 boundary")

        // 3. The night still spans the full 8.62 h the ring measured.
        let span = archive.last!.counter - archive.first!.counter
        XCTAssertEqual(span, UInt32(207 * BulkRecord.epochSeconds))
        XCTAssertEqual(Double(span) / 3600.0, 8.625, accuracy: 0.001)
    }

    /// The Gen 2 Air shape: the drain banks almost nothing of its own, so the night exists ONLY if
    /// the adopted orphans are treated as committable. This is what `sleepHasFreshRecords ||
    /// adoptedRecordCount > 0` protects in `commitDrainedRecords`.
    func testAdoptedOnlyNightIsStillAWholeNight() throws {
        let pages = try nightPages()
        var buffer = UnattributedPageBuffer()
        for p in pages.prefix(34) { buffer.retain(BulkSleep.records(fromPage: p)) }

        let adopted = buffer.drain()
        let ownWireRecords = BulkSleep.records(fromPage: pages[34])   // the drain's own haul: 4
        XCTAssertEqual(ownWireRecords.count, 4)

        let archive = EpochArchive.merge(existing: [], incoming: adopted + ownWireRecords)
        XCTAssertEqual(archive.count, 208, "204 adopted + 4 pulled = the whole night")
        XCTAssertEqual(zip(archive, archive.dropFirst()).map { $1.counter - $0.counter }.max(),
                       UInt32(BulkRecord.epochSeconds))
    }

    // MARK: - buffer contract

    func testEmptyPageIsANoOpAndNeverTripsTheCap() {
        var buffer = UnattributedPageBuffer(cap: 1)
        XCTAssertFalse(buffer.retain([]), "an empty page must not trip the cap")
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.pages, 0)
    }

    func testCapSignalsBankNowAndNeverDrops() throws {
        let pages = try nightPages()
        var buffer = UnattributedPageBuffer(cap: 12)
        var hitCap = false
        var retained = 0
        for p in pages.prefix(3) {
            let recs = BulkSleep.records(fromPage: p)
            retained += recs.count
            if buffer.retain(recs) { hitCap = true; break }
        }
        XCTAssertTrue(hitCap, "12-record cap trips on the second 6-record page")
        XCTAssertEqual(buffer.count, retained,
                       "hitting the cap means BANK NOW — it must never discard what it holds")
        XCTAssertEqual(buffer.drain().count, retained)
    }

    func testDrainIsIdempotentOnAnEmptyBuffer() {
        var buffer = UnattributedPageBuffer()
        XCTAssertTrue(buffer.drain().isEmpty)
        XCTAssertTrue(buffer.drain().isEmpty)
    }
}

/// #188 — the diagnostic tell that identified both testers' bundles.
final class OpenedOntoLiveStreamTests: XCTestCase {

    private func trace(firstOpcode: UInt8?) -> HistoryChannelTrace {
        var t = HistoryChannelTrace(label: "sleep", channel: 0x00)
        t.firstOpcode = firstOpcode
        return t
    }

    func testFirstOpcode4CMeansWeOpenedOntoALiveStream() {
        // Both 2026-08-04 bundles: the drain's first observed frame was a DATA page, meaning pages
        // were already in flight and uncounted before the trace existed.
        XCTAssertTrue(trace(firstOpcode: 0x4C).openedOntoLiveStream)
    }

    func testHealthyHandshakesAreNotFlagged() {
        XCTAssertFalse(trace(firstOpcode: 0x81).openedOntoLiveStream, "own auth challenge")
        XCTAssertFalse(trace(firstOpcode: 0x82).openedOntoLiveStream, "own sync-open ACK")
        XCTAssertFalse(trace(firstOpcode: 0x50).openedOntoLiveStream, "end marker")
        XCTAssertFalse(trace(firstOpcode: nil).openedOntoLiveStream, "no frame seen at all")
    }
}
