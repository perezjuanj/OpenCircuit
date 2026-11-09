// The walk over the strap's own workout records (ZEPP_PROTOCOL.md §22.1, decision 91a) as a pure state
// machine, run after `ZeppHistoryFetch` has fetched every other type.
//
// One pass per record: `01 05 <since>` → the summary round, then `01 06 <the same since>` → the detail
// round, then the next pass from the record's start + 1 s, until a zero-length summary reply. *since*
// carries its SECONDS here (§22.1: a minute-precision *since* would re-deliver the record just read);
// every other type keeps §6.2's second `00`, and nothing here touches them.
//
// EVERY ROUND IS ACKED `03 09` (keep, decision 8 / 91a). There is no policy to change that and no code
// path that sends `03 01`: §22.1 saw `03 01` leave the records on the strap anyway (🟡), but nothing
// is gained by finding out on a real strap. A round that fails (refused, short, CRC mismatch, no CRC,
// a parse failure) delivers nothing for its record, which a later sync fetches again.

import Foundation

public struct ZeppWorkoutWalk {

    public enum Failure: Equatable {
        /// The round itself failed, as a `ZeppHistoryFetch` round would.
        case round(ZeppRoundFailure)
        /// The transfer done carried no CRC (the 3-byte form), so nothing proves the record arrived intact.
        case noCRC
        /// The round arrived intact but is not a record (§22.2, §22.3).
        case parse(ZeppWorkoutRecordError)
        /// The detail round answered with a different start than its summary (§22.1 step 4: the same start).
        case detailStartMismatch(summary: Date, detail: Date)
        /// The strap had a summary but no detail for it.
        case emptyDetail
    }

    public enum End: Equatable {
        /// A zero-length summary reply: no record at or after the last *since* (§22.1 step 7).
        case noMoreRecords
        /// `Configuration.maxRecords` passes ran.
        case cap
        /// The next *since* would be after `now`.
        case reachedNow
        /// The strap refused the summary type, or its start reply gave no usable start.
        case refused
        /// The caller couldn't store a record: nothing more is fetched this sync.
        case storeFailed
    }

    public enum Action: Equatable {
        /// Write these bytes as a control command (Path A: `…0004`; Path B: endpoint 0x004B).
        case sendControl([UInt8])
        /// Both rounds of one record arrived intact and parsed. Persist it, then call
        /// `commit(recordID:stored:)`.
        case recordReady(id: Int, record: ZeppWorkoutRecord)
        /// A round failed; its record (`recordStart`, when the start reply named one) delivers nothing.
        case roundFailed(type: ZeppWorkoutFetchType, failure: Failure, recordStart: Date?)
        case finished(End)
    }

    public enum Phase: Equatable {
        case idle
        case awaitingStartReply
        case receivingData
        case awaitingCommit
        case awaitingAckReply
        case finished
    }

    public struct Configuration: Equatable {
        /// Decision 91a: at most 40 records per sync, so the walk is bounded however many the strap holds.
        public var maxRecords = 40
        public var timeZone: TimeZone = .current

        public init(maxRecords: Int = 40, timeZone: TimeZone = .current) {
            self.maxRecords = maxRecords
            self.timeZone = timeZone
        }
    }

    public private(set) var phase: Phase = .idle
    public let configuration: Configuration
    /// The *since* of the first pass.
    public let since: Date
    private let now: Date

    /// Records the strap named this walk (delivered or failed).
    public private(set) var passes = 0
    private var nextRecordID = 1

    // Per-pass state.
    private var passSince: Date
    private var type: ZeppWorkoutFetchType = .summary
    /// The record this pass is reading: the summary's start reply.
    private var recordStart: Date?
    private var summary: ZeppWorkoutSummary?
    private var expectedLength = 0
    private var buffer: [UInt8] = []
    private var nextCounter: UInt8 = 0
    private var pendingID: Int?
    private var afterAck: AfterAck = .end(.noMoreRecords)

    private enum AfterAck: Equatable {
        case detail
        case nextPass
        case end(End)
    }

    /// - Parameters:
    ///   - since: the first pass's *since* (the walk's cursor, `HelioWorkoutWalkPlan`).
    ///   - now: no pass asks for a *since* after this.
    public init(since: Date, now: Date, configuration: Configuration = Configuration()) {
        self.since = since
        self.passSince = since
        self.now = now
        self.configuration = configuration
    }

    /// `01 <05|06> <since with seconds>` (§22.1).
    public static func startCommand(_ type: ZeppWorkoutFetchType, since: Date, timeZone: TimeZone) -> [UInt8] {
        [ZeppFetchCommand.startMarker, type.rawValue]
            + ZeppFetchTimestamp.encode(since, timeZone: timeZone, includeSeconds: true)
    }

    public mutating func start() -> [Action] {
        guard phase == .idle else { return [] }
        guard configuration.maxRecords > 0 else { return finish(.cap) }
        guard passSince <= now else { return finish(.reachedNow) }
        return beginRound(.summary)
    }

    // MARK: Inputs

    public mutating func receiveControl(_ bytes: [UInt8]) -> [Action] {
        guard bytes.count >= 2, bytes[0] == 0x10 else { return [] }
        switch (phase, bytes[1]) {
        case (.awaitingStartReply, 0x01): return handleStartReply(bytes)
        case (.receivingData, 0x02): return handleTransferDone(bytes)
        case (.awaitingAckReply, 0x03): return afterAckReply()
        default: return []
        }
    }

    public mutating func receiveData(_ bytes: [UInt8]) -> [Action] {
        guard phase == .receivingData, let counter = bytes.first else { return [] }
        guard counter == nextCounter else {
            return failRound(.round(.packetCounterGap(expected: nextCounter, got: counter)))
        }
        nextCounter &+= 1
        buffer += bytes.dropFirst()
        guard buffer.count <= expectedLength else {
            return failRound(.round(.dataOverflow(expected: expectedLength, received: buffer.count)))
        }
        return []
    }

    /// After a `recordReady`: `stored` means the record is persisted (or judged and deliberately not
    /// kept). The ack is `03 09` either way; a record the caller couldn't store ends the walk.
    public mutating func commit(recordID: Int, stored: Bool) -> [Action] {
        guard phase == .awaitingCommit, pendingID == recordID else { return [] }
        pendingID = nil
        afterAck = stored ? .nextPass : .end(.storeFailed)
        phase = .awaitingAckReply
        return [.sendControl(ZeppFetchCommand.ack(.keep))]
    }

    /// Stops the walk. A round in progress gets `03 09`; one already acked gets nothing more.
    public mutating func abort() -> [Action] {
        var out = [Action]()
        switch phase {
        case .receivingData, .awaitingCommit:
            out.append(.roundFailed(type: type, failure: .round(.aborted), recordStart: recordStart))
            out.append(.sendControl(ZeppFetchCommand.ack(.keep)))
        default:
            break
        }
        pendingID = nil
        buffer = []
        phase = .finished
        return out
    }

    // MARK: Round steps

    private mutating func handleStartReply(_ bytes: [UInt8]) -> [Action] {
        guard bytes.count >= 3 else { return failRound(.round(.malformedStartReply)) }
        guard bytes[2] == 0x01 else {
            // Refused: no round was opened, so nothing is acked. A refused summary ends the walk; a
            // refused detail fails its record and the walk moves on.
            let failed = Action.roundFailed(type: type, failure: .round(.startRefused(status: bytes[2])), recordStart: recordStart)
            return [failed] + (type == .summary ? finish(.refused) : nextPass())
        }
        var reader = ZeppByteReader(bytes, offset: 3)
        guard bytes.count == 15 || bytes.count == 16, let length = reader.u32() else {
            return failRound(.round(.malformedStartReply))
        }
        buffer = []
        nextCounter = 0
        if length == 0 {
            // §22.1 step 7: a zero-length summary ends the walk, whatever its start holds (§6.2).
            // SPEC-GAP: a summary without a detail is unseen; its record is fetched again later.
            phase = .awaitingAckReply
            if type == .summary {
                afterAck = .end(.noMoreRecords)
                return [.sendControl(ZeppFetchCommand.ack(.keep))]
            }
            afterAck = .nextPass
            return [.roundFailed(type: .detail, failure: .emptyDetail, recordStart: recordStart),
                    .sendControl(ZeppFetchCommand.ack(.keep))]
        }
        guard let start = ZeppFetchTimestamp.decode(bytes[7..<15]) else {
            return failRound(.round(.malformedStartReply))
        }
        if type == .summary {
            recordStart = start
            passes += 1
        } else if let summaryStart = recordStart, start != summaryStart {
            return failRound(.detailStartMismatch(summary: summaryStart, detail: start))
        }
        let limit = type.maxRoundBytes
        guard Int(length) <= limit else {
            return failRound(.round(.announcedLengthTooLarge(announced: Int(length), limit: limit)))
        }
        expectedLength = Int(length)
        phase = .receivingData
        return [.sendControl(ZeppFetchCommand.fetchData)]
    }

    private mutating func handleTransferDone(_ bytes: [UInt8]) -> [Action] {
        guard bytes.count >= 3 else { return failRound(.round(.malformedTransferDone)) }
        guard bytes[2] == 0x01 else { return failRound(.round(.transferFailed(status: bytes[2]))) }
        guard bytes.count == 3 || bytes.count == 7 else { return failRound(.round(.malformedTransferDone)) }
        guard buffer.count == expectedLength else {
            return failRound(.round(.lengthMismatch(expected: expectedLength, received: buffer.count)))
        }
        // §22.5: every workout round is checked against its CRC; one without a CRC is not trusted.
        // SPEC-GAP: the Helio always sent the 7-byte form (§10.1); the 3-byte form is kept on the strap.
        guard bytes.count == 7 else { return failRound(.noCRC) }
        var reader = ZeppByteReader(bytes, offset: 3)
        let expected = reader.u32() ?? 0
        let computed = ZeppCRC32.checksum(buffer)
        guard expected == computed else { return failRound(.round(.crcMismatch(expected: expected, computed: computed))) }
        let data = buffer
        buffer = []
        switch type {
        case .summary:
            do {
                summary = try ZeppWorkoutSummary.parse(data)
            } catch let error as ZeppWorkoutRecordError {
                return failRound(.parse(error))
            } catch {
                return failRound(.parse(.empty))
            }
            // Nothing is stored yet, so nothing waits for a commit: keep the summary and ask for its detail.
            afterAck = .detail
            phase = .awaitingAckReply
            return [.sendControl(ZeppFetchCommand.ack(.keep))]
        case .detail:
            guard let summary else { return failRound(.parse(.empty)) }
            let detail: ZeppWorkoutDetail
            do {
                detail = try ZeppWorkoutDetail.parse(data, window: summary.window)
            } catch let error as ZeppWorkoutRecordError {
                return failRound(.parse(error))
            } catch {
                return failRound(.parse(.empty))
            }
            let id = nextRecordID
            nextRecordID += 1
            pendingID = id
            phase = .awaitingCommit
            return [.recordReady(id: id, record: ZeppWorkoutRecord(summary: summary, heartRate: detail.heartRate))]
        }
    }

    private mutating func afterAckReply() -> [Action] {
        switch afterAck {
        case .detail: return beginRound(.detail)
        case .nextPass: return nextPass()
        case .end(let end): return finish(end)
        }
    }

    /// Any failure after the strap opened a round: `03 09`, then the next record (or the end, when the
    /// strap never named this one).
    private mutating func failRound(_ failure: Failure) -> [Action] {
        buffer = []
        afterAck = recordStart == nil ? .end(.refused) : .nextPass
        phase = .awaitingAckReply
        return [.roundFailed(type: type, failure: failure, recordStart: recordStart),
                .sendControl(ZeppFetchCommand.ack(.keep))]
    }

    /// The next record's summary: from this record's start + 1 s (§22.1, 🟡), never behind this pass's
    /// own *since*, so a strap that names an earlier record can't hold the walk in place.
    private mutating func nextPass() -> [Action] {
        guard passes < configuration.maxRecords else { return finish(.cap) }
        guard let current = recordStart else { return finish(.refused) }
        let next = max(current, passSince).addingTimeInterval(1)
        guard next <= now else { return finish(.reachedNow) }
        passSince = next
        recordStart = nil
        summary = nil
        return beginRound(.summary)
    }

    private mutating func beginRound(_ type: ZeppWorkoutFetchType) -> [Action] {
        self.type = type
        phase = .awaitingStartReply
        return [.sendControl(Self.startCommand(type, since: passSince, timeZone: configuration.timeZone))]
    }

    private mutating func finish(_ end: End) -> [Action] {
        phase = .finished
        return [.finished(end)]
    }
}
