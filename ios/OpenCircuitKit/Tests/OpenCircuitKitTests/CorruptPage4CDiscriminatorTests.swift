import XCTest
@testable import OpenCircuitKit

// The 0x4c page-corruption discriminator used by `RingSession`'s frame handler.
//
// The ack for a 0x4c page (`Command.pageAck4C`) is UNCONDITIONAL and advances the ring's single
// shared resume pointer, so a page we cannot decode is permanently lost history. Until now that loss
// was completely silent on the 0x4c path: the 0x4d path logs `invalid page (acked, not decoded)`,
// but 0x4c logged only `records=<unchanged>` — and `records=<unchanged>` is ALSO what a perfectly
// valid page carrying no whole record produces.
//
// So `pageRecords.isEmpty` is NOT a corruption test. This suite pins the Kit-side behaviour the
// app's counter depends on: `BulkSleep.records(fromPage:)` collapses "corrupt" and "valid but
// record-less" onto the same `[]`, while `Frame.parse` separates them. If that ever stops being
// true, the session's `corruptPage4CCount` starts lying and this suite fails first.
//
// Fixture provenance: `realPage` is the same real, XOR-valid 0x4c frame `BulkSleepTests` uses —
// 2026-06-13 overnight sync, FW FR02.018 (desktop/captures/sleep_sync_btsnoop.log). 🟢
final class CorruptPage4CDiscriminatorTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Real, XOR-valid 0x4c page: header `4c 00 26`, then 6 × 23-byte records, then the XOR trailer.
    private let realPage = "4c00260c22a16b55210a7d120a010101010100000402400400000c22a20155000300"
        + "120a010101010100003c00000d01200c22a297540001005f0a010101010100001101b00f"
        + "00440c22a32d6027077b120a010101010100402501c02235a00c22a3c351260577120b01"
        + "0101010108a01000000401300c22a459502d0378120a01010101010160200000040ff0cc"

    /// Append the correct XOR trailer to a header-only body, so the frame is genuinely valid.
    private func sealed(_ body: [UInt8]) -> [UInt8] { body + [Frame.xorTrailer(body)] }

    /// EXACTLY the predicate `RingSession` applies inside `case 0x4C`.
    private func isCorrupt(_ page: [UInt8]) -> Bool {
        BulkSleep.records(fromPage: page).isEmpty && Frame.parse(page) == nil
    }

    // MARK: The ambiguity that makes the discriminator necessary

    func testEmptyRecordsIsNotEvidenceOfCorruption() {
        // `4c 00 26` + trailer: a structurally sound page whose body carries no record at all.
        let recordless = sealed([Frame.responseID(Opcode.page4C), 0x00, 0x26])
        var corrupted = hex(realPage); corrupted[corrupted.count - 1] ^= 0xFF   // break the XOR trailer

        // Both decode to nothing — so `isEmpty` alone cannot tell a lost page from an empty one.
        XCTAssertTrue(BulkSleep.records(fromPage: recordless).isEmpty)
        XCTAssertTrue(BulkSleep.records(fromPage: corrupted).isEmpty)

        // `Frame.parse` is what separates them, and it is the only thing that does.
        XCTAssertNotNil(Frame.parse(recordless), "a record-less page is still a VALID frame")
        XCTAssertNil(Frame.parse(corrupted), "a broken XOR trailer must not parse")

        XCTAssertFalse(isCorrupt(recordless), "an empty-but-valid page must NOT be counted as lost")
        XCTAssertTrue(isCorrupt(corrupted), "a page acked with a broken trailer IS lost history")
    }

    func testValidPageWithRecordsIsNeverCounted() {
        let page = hex(realPage)
        XCTAssertEqual(BulkSleep.records(fromPage: page).count, 6)
        XCTAssertFalse(isCorrupt(page))
    }

    /// A valid page whose body ends in a chunk shorter than one 23-byte record. `records(fromStream:)`
    /// drops the partial chunk by design — that is a decode policy, not a transport failure, and it
    /// must not inflate the corruption count (which would make a firmware quirk look like link loss).
    func testValidPageWithOnlyAPartialRecordIsNotCorrupt() {
        let partial = sealed([Frame.responseID(Opcode.page4C), 0x00, 0x26] + [UInt8](repeating: 0x00, count: 10))
        XCTAssertTrue(BulkSleep.records(fromPage: partial).isEmpty, "10 B < one 23-byte record")
        XCTAssertNotNil(Frame.parse(partial))
        XCTAssertFalse(isCorrupt(partial))
    }

    /// The session only reaches this predicate from `case 0x4C`, i.e. `bytes[0]` is already
    /// `Frame.responseID(Opcode.page4C)`. Pin that mapping so the guard can't silently start
    /// inspecting a different opcode's frames.
    func testHandlerCaseMatchesThePageResponseOpcode() {
        XCTAssertEqual(Frame.responseID(Opcode.page4C), 0x4C)
        XCTAssertEqual(hex(realPage).first, 0x4C)
    }
}
