import Foundation
import UIKit
import OpenCircuitKit

// ExportBuilder — the ONE place a data export is assembled (#80, rich schema v3).
//
// The row collection used to be inlined in `ExportView.runExport()`. It moved here the moment a
// SECOND caller appeared (`ExportRingDataIntent`): a Shortcuts automation is the path a user sets
// up once and then never eyeballs again, so a second copy of this logic would drift silently and
// the automated export would stop matching the one the user sees on screen — with nobody there to
// notice. One implementation, two callers.
//
// Strictly READ-ONLY over already-stored data: no BLE, no HealthKit, no network. Everything here
// reads the SwiftData store that the ordinary sync already filled.
//
// WHY THIS RUNS ON THE MAIN ACTOR, AND WHAT BOUNDS IT
// ---------------------------------------------------
// `LocalStore` wraps a `ModelContext` that is not `Sendable`, and every one of its ~90 methods is
// main-actor-isolated; the app has exactly one container, published at launch, whose creation path
// carries the #40/#131 wipe-and-recover scars. Handing the export a second, background context is a
// real refactor of the store's isolation, not a local change — and this project has already paid
// for "large change to fix an orthogonal concern" once (F12/PR #121). So the export stays on the
// main actor and is BOUNDED instead, because an unbounded main-thread pass is the same shape as the
// 0x8BADF00D scene-update watchdog kill this app has already shipped once.
//
// The bound, per table, measured against what the store can actually hold:
//   • StoredSample (the big one: HR/HRV/SpO2/RR/temp), StoredStepSample, StoredDaytimeTemp —
//     bounded at `LocalStore.sampleRetentionDays` (30) by `pruneExpiredSamples`, which runs at
//     launch. A range wider than 30 days cannot fetch more raw rows than a 30-day one.
//   • historySyncEvidence — 24 entries / 3 days (`ObservabilityStore.historySyncEvidenceLimit`).
//   • StoredSleepSummary / StoredDaily — one row per night/day and kept LONG-TERM, so these are the
//     only tables that grow with install age. Each night additionally decodes a hypnogram blob and
//     emits one CSV row per segment, so `hypnogramCSV` is the one section whose size is O(nights).
//     `maxExportDays` caps that at a year; the file's own `meta.rangeStart`/`rangeEnd` then state
//     the window actually exported, so a clamped file can never misrepresent itself.
//
// v3 is a SUPERSET of v2: every section the previous schema emitted is still collected the same
// way, in the same order, and the new sections are appended after it — so a consumer that split
// the CSV on blank lines and indexed the sections positionally still finds every old section at
// its old index.
@MainActor
enum ExportBuilder {

    // MARK: - Inputs

    /// Serialisation format. Lives here rather than on the View so the App Intent can name the same
    /// two cases without importing SwiftUI.
    enum Format: String, CaseIterable, Sendable {
        case csv  = "CSV"
        case json = "JSON"

        var fileExtension: String {
            switch self {
            case .csv:  return "csv"
            case .json: return "json"
            }
        }
    }

    /// What an export covers.
    enum Mode: Equatable {
        /// Everything stored in `[startOfDay(start), startOfDay(end) + 1 day)` — the original #80
        /// behaviour and still the default.
        case dateRange(start: Date, end: Date)
        /// Exactly one recorded night, addressed by its stored `night` bucket.
        case singleSession(night: Date)
        /// Only the nights that have not been exported yet, per the forward-only export watermark.
        case newSessions
    }

    // MARK: - Output

    /// A finished export: the bytes, the name to give them, and the bookkeeping the caller owes the
    /// store once those bytes have actually been delivered somewhere.
    struct Payload {
        let content: String
        let fileName: String
        let format: Format
        /// How many sleep sessions the file describes — the honest thing to show the user, and the
        /// number the Intent's confirmation dialog reports.
        let sessionCount: Int
        /// The night bucket to hand `LocalStore.markExported(through:)`, or nil when this mode does
        /// not consume the watermark. Deliberately NOT applied by `build`: the watermark may only
        /// advance after the file exists, never merely because it was assembled (see
        /// `commitWatermark`).
        let watermarkAdvance: Date?
        /// The instant this payload's rows were READ, committed alongside `watermarkAdvance` as the
        /// content watermark. Nil for the modes that do not consume the watermark.
        let contentAsOf: Date?
        /// Set when the requested date range was longer than `maxExportDays` and was clamped. The
        /// screen shows it: a file that silently covered less than the user asked for would be the
        /// worse failure, and `meta.rangeStart` alone is only discoverable by opening the file.
        var rangeNotice: String? = nil

        var data: Data { Data(content.utf8) }
    }

    enum Outcome {
        case file(Payload)
        /// `.newSessions` found nothing past the watermark. Handing the user an empty file would
        /// look like a failed export of real data; saying "nothing new since X" is the honest
        /// answer. `since` is nil when nothing has ever been exported.
        case nothingNew(since: Date?)
    }

    enum Failure: Error {
        /// `.singleSession` was pointed at a night that is not in the store.
        case sessionNotStored
        /// `JSONSerialization` refused the bundle (should not happen in practice).
        case serializationFailed
    }

    // MARK: - Build

    /// Longest window a single `.dateRange` export covers, in whole days.
    ///
    /// NOT a new guess: `ExportRingDataIntent.days` already ships bounded to `(1, 365)` with the
    /// reason "a stray value can't ask the store for a century of rows on a background launch with
    /// a short execution budget". The screen's date pickers had no such bound, so the same request
    /// that Shortcuts refuses was reachable by dragging a DatePicker back — on the MAIN ACTOR, with
    /// no execution budget and a watchdog watching. Same number, same reason, now enforced in the
    /// one place both callers go through.
    static let maxExportDays = 365

    static func build(store: LocalStore,
                      mode: Mode,
                      format: Format,
                      now: Date = Date()) throws -> Outcome {
        let calendar = Calendar.current
        var rangeNotice: String?

        // Resolve the mode into (a) the nights this export is ABOUT and (b) the [from, to) window
        // the v2 sections are collected over.
        // `var`: `.dateRange` widens it backwards after its clamp, so a night bucketed on the day it
        // ENDS still carries the pre-midnight samples its own hypnogram covers.
        var from: Date
        let to: Date
        let nights: [StoredSleepSummary]
        let fileStem: String
        let watermarkAdvance: Date?
        var contentAsOf: Date?

        switch mode {
        case .dateRange(let start, let end):
            let requestedFrom = calendar.startOfDay(for: start)
            to = calendar.date(byAdding: .day, value: 1,
                               to: calendar.startOfDay(for: end)) ?? end
            // Clamp the START forward, never the end: the recent nights are the ones a user is
            // acting on, and clamping the other way would hand them a file of only old data.
            let earliest = calendar.date(byAdding: .day, value: -maxExportDays, to: to) ?? requestedFrom
            if requestedFrom < earliest {
                from = earliest
                rangeNotice = "Ranges longer than \(maxExportDays) days are exported one year at a "
                    + "time. This file covers \(ExportEngine.dayStamp(from)) onwards — export an "
                    + "earlier range separately for the rest."
            } else {
                from = requestedFrom
            }
            nights = (try? store.sleepSummaries(from: from, to: to)) ?? []
            // Widen AFTER the maxExportDays clamp, and only backwards: a night is bucketed on the day
            // it ENDS (`SleepNightKey`), so the oldest night in range began the previous evening and
            // its pre-midnight samples — sleep onset among them — sit before `from`. Without this the
            // file carries a hypnogram for hours it has no raw data for.
            if let oldest = nights.first,
               let onsetDay = effectiveInBedStart(oldest).map({ calendar.startOfDay(for: $0) }) {
                from = min(from, onsetDay)
            }
            fileStem = "opencircuit-export-\(ExportEngine.dayStamp(now))"
            watermarkAdvance = nil

        case .singleSession(let night):
            let bucket = calendar.startOfDay(for: night)
            // `try?` flattens the method's own Optional (SE-0230), so "fetch failed" and "no such
            // night" arrive as the same nil — and they mean the same thing to the caller.
            guard let session = try? store.sleepSummary(night: bucket) else {
                throw Failure.sessionNotStored
            }
            nights = [session]
            // A night is bucketed on the day it ENDS (`SleepNightKey`), so it BEGAN on day D-1
            // whenever bedtime was pre-midnight. Anchoring the raw-sample window on the bucket day's
            // midnight would silently drop every sample before it — the evening hours including
            // sleep onset — from a file whose session row still claims that bedtime. Anchor on the
            // night's real span instead, and keep the bucket as the floor for a row with no
            // recorded in-bed start.
            from = min(bucket, effectiveInBedStart(session).map { calendar.startOfDay(for: $0) } ?? bucket)
            // …and run to the end of the day the session ENDED on, so a post-midnight wake is not
            // clipped either.
            let sessionEnd = effectiveInBedEnd(session) ?? bucket
            to = calendar.date(byAdding: .day, value: 1,
                               to: calendar.startOfDay(for: sessionEnd)) ?? bucket
            fileStem = "opencircuit-\(ExportEngine.sessionID(night: session.night))"
            watermarkAdvance = nil

        case .newSessions:
            let watermark = store.lastExportWatermark()
            // `sleepSummaries(from:)` is inclusive, and the watermark names a night that HAS been
            // exported, so start one second past it. Nights are midnight-aligned, so this excludes
            // exactly the watermark night and nothing else.
            let after = watermark.map { $0.addingTimeInterval(1) } ?? .distantPast
            let today = calendar.date(byAdding: .day, value: 1,
                                      to: calendar.startOfDay(for: now)) ?? now
            // ALSO re-offer an already-exported night whose stored row has CHANGED since the export
            // that consumed it. A night keeps growing long after it settles — the ring hands the
            // rest off hours later (#187/#188), the diagnostics repair can widen one days later, and
            // a manual sleep edit rewrites it whenever the user says so — and the night watermark is
            // forward-only and single-valued, so on `night` alone the fuller version could never be
            // offered again and the automated archive would keep only the truncated one. `updatedAt`
            // is bumped by every write path that rewrites a summary, so comparing it to the content
            // watermark (the instant the last committed export READ its rows) catches all of them.
            let contentWatermark = store.lastExportContentWatermark()
            let changed = contentWatermark.map { since in
                ((try? store.sleepSummaries(from: .distantPast, to: after)) ?? [])
                    .filter { $0.updatedAt > since }
            } ?? []
            // Bound the UNEXPORTED backlog the same way `.dateRange` is bounded (see
            // `maxExportDays`). The steady state is one night, but the FIRST run on an install that
            // has never exported takes EVERY stored night at once — each decoding a hypnogram blob
            // and emitting a CSV row per segment, on the main actor.
            //
            // Trimmed from the OLDEST end so the backlog drains FORWARD across runs: keeping the
            // newest instead would leave the older nights behind a forward-only night watermark,
            // permanently — the exact failure `.newSessions` exists to avoid.
            //
            // The bound is applied ONLY to the post-watermark backlog, never to `changed`. Two
            // reasons. `changed` is already bounded in practice — it is the rows rewritten since the
            // last export READ its rows, not a table scan's worth. And including it in the window
            // would deadlock the whole mode: one repaired night from two years ago would put the
            // horizon two years in the past, trim away every recent night, advance NO watermark (the
            // night cursor is forward-only and that night is already behind it), and re-offer the
            // same file forever while today's nights never exported. Bounding only the new nights
            // guarantees progress: the oldest unexported night is always inside its own window, so
            // every run that finds a settled night moves the cursor.
            var newNights = (try? store.sleepSummaries(from: after, to: today)) ?? []
            if let firstNew = newNights.first {
                let horizon = calendar.date(byAdding: .day, value: maxExportDays,
                                            to: calendar.startOfDay(for: firstNew.night))
                    ?? .distantFuture
                let withinWindow = newNights.filter { $0.night < horizon }
                if withinWindow.count < newNights.count {
                    newNights = withinWindow
                    rangeNotice = "More than \(maxExportDays) days of sessions are waiting. This "
                        + "file carries the oldest \(maxExportDays) days; run the export again for "
                        + "the rest."
                }
            }
            let fresh = (changed + newNights).sorted { $0.night < $1.night }
            guard let oldest = fresh.first, let last = fresh.last else {
                return .nothingNew(since: watermark)
            }
            nights = fresh
            // Same reasoning as `.singleSession`: a night bucketed on the day it ENDS began the
            // evening before, so anchor on its real span. This mode compounds the cost — the night
            // watermark is forward-only, so hours omitted here are never re-offered.
            from = min(calendar.startOfDay(for: oldest.night),
                       effectiveInBedStart(oldest).map { calendar.startOfDay(for: $0) }
                        ?? calendar.startOfDay(for: oldest.night))
            let sessionEnd = effectiveInBedEnd(last) ?? last.night
            to = calendar.date(byAdding: .day, value: 1,
                               to: calendar.startOfDay(for: sessionEnd)) ?? today
            fileStem = "opencircuit-new-sessions-\(ExportEngine.dayStamp(now))"
            // Every row in this file was read at `now`; anything rewritten after this instant is
            // content this export does not contain, so it must be re-offered. Safe to commit even
            // when the backlog was trimmed, because the trim only ever drops nights the NIGHT
            // watermark still guards — every `changed` row is in this file by construction.
            contentAsOf = now
            // Consume through the last SETTLED night, not simply the last one in the file.
            //
            // A night keeps GROWING while the ring hands off the rest of it, so a night exported at
            // 08:00 and extended by the 10:00 drain would already be behind a forward-only watermark
            // and would never auto-export again — the file would be the only copy, and a partial one.
            // `SleepHealthGate.isSettled` is the project's existing answer to exactly this question
            // for the Health mirror (SleepHealthGate.swift:16-19, 20-minute quiet margin), so the
            // export uses the same definition rather than inventing a second one. Nights past the
            // settled point still go INTO the file; they are simply re-offered next run, and a
            // duplicate export is the safe direction.
            watermarkAdvance = fresh.last {
                SleepHealthGate.isSettled(latestSegmentEnd: effectiveInBedEnd($0), now: now)
            }?.night
        }

        // ── v2 sections, unchanged ────────────────────────────────────────────────────────────
        // Collect samples for all mirrored kinds
        var sampleRows: [ExportEngine.SampleRow] = []
        for kind in LocalStore.healthMirroredKinds {
            let samples = (try? store.samples(kind: kind, from: from, to: to)) ?? []
            sampleRows += samples.map {
                ExportEngine.SampleRow(kind: $0.kind.rawValue,
                                       start: $0.start, end: $0.end, value: $0.value)
            }
        }
        sampleRows.sort { $0.start < $1.start }

        // Collect sleep summaries + sleep-side extras
        let sleepRows = nights.map { summaryRow($0) }

        // Collect daily rollups + timestamped step deltas
        let dailyRows = ((try? store.dailies(from: from, to: to)) ?? [])
            .map { ExportEngine.DailyRow(day: $0.day, steps: $0.steps) }
        let stepSampleRows = ((try? store.stepSamples(from: from, to: to)) ?? [])
            .map { ExportEngine.StepSampleRow(start: $0.start, end: $0.end, delta: $0.delta) }

        // Collect naps + daytime temperatures
        let napRows = ((try? store.naps(from: from, to: to)) ?? [])
            .map {
                ExportEngine.NapRow(start: $0.start, end: $0.end,
                                    asleepMin: $0.asleepMin, isLongNap: $0.isLongNap)
            }
        let daytimeTemperatureRows = ((try? store.daytimeTemperatures(from: from, to: to)) ?? [])
            .map { ExportEngine.DaytimeTemperatureRow(time: $0.time, celsius: $0.celsius) }

        // Recent sync-forensics whose capture time falls in the export window
        let allEvidence = ObservabilityStore().historySyncEvidence()
        let evidence = allEvidence.filter { $0.date >= from && $0.date < to }
        let evidenceRows = evidence
            .map {
                ExportEngine.HistorySyncEvidenceRow(
                    capturedAt: $0.date,
                    ringID: $0.ringID,
                    trigger: $0.trigger,
                    sleepCommitted: $0.sleepCommitted,
                    stagedSleepSegments: $0.stagedSleepSegments,
                    mergedRecordCount: $0.mergedRecordCount,
                    historySampleCount: $0.historySampleCount,
                    rawRecordBlobBase64: $0.rawRecordBlob.base64EncodedString(),
                    channels: $0.channels,
                    nightRowOutcome: $0.nightRowOutcome
                )
            }

        // Every ring whose ~30 h epoch archive could still speak for a night in this file, loaded
        // ONCE and shared by the two consumers below.
        //
        // Keyed off the UNFILTERED evidence list on purpose, unlike `archiveRows`. The evidence ring
        // buffer is already bounded to 24 entries / 3 days (`ObservabilityStore`), so this can name
        // at most the rings that synced in that window — but a `.singleSession` export of last night
        // narrows `from`/`to` to the night itself, which can easily contain no evidence row while the
        // archive still holds every epoch of it. Scoping the coverage witness to the window-filtered
        // set would then silently drop the witness on exactly the export a triager asks for first.
        //
        // BOUNDED, per the main-actor rule in this file's header. One read per DISTINCT ring named
        // by the 24-entry evidence buffer, and each archive is capped by `EpochArchive.retention` at
        // ~30 h ≈ 720 records × 23 B ≈ 17 KB. So the cost is O(distinct rings), and it grows with
        // neither install age nor the export's date range.
        //
        // ⚠️ Stated as a bound, not as a saving, because review pushed on an earlier wording that
        // claimed this is "strictly LESS work than the previous per-section reload". It is not:
        // multi-ring pairing SHIPPED (this file's own `notes["ringIdentity"]` contemplates an
        // install that paired more than one ring), so on a two-ring install this is two decodes
        // where the old path did one. Two 17 KB decodes is still bounded and still trivial; the
        // honest claim is the bound, not a comparison.
        let archivesByRing: [String: [BulkRecord]] = Dictionary(
            uniqueKeysWithValues: Set(allEvidence.map(\.ringID)).sorted()
                .map { ($0, EpochArchiveStore(namespace: $0).load()) })
        // Deterministic order so the witness's tie-break (see `ExportCoverageWitness`) is stable
        // across runs rather than following a Dictionary's hash order.
        let archivesForCoverage = archivesByRing.keys.sorted().map { archivesByRing[$0] ?? [] }

        // The app's OWN epoch archive, per ring, plus a statement of what the per-drain blobs
        // above MISS of it (#203). The evidence list is a bounded ring buffer, so its blobs are a
        // LOSSY view of the record set staging actually ran on — and a replay that assumes otherwise
        // reads a phantom data hole as lost sleep. Ring-scoped exactly as `RingSession` scopes it,
        // so a two-ring household exports two archives instead of one corrupted union.
        //
        // Still keyed off the WINDOW-FILTERED evidence: this section pairs each archive with the
        // drain blobs captured in the same window, so widening it would emit an archive next to an
        // empty evidence set and change what `ArchiveEvidenceCoverage` is reporting about.
        let archiveRows: [ExportEngine.EpochArchiveRow] = Set(evidence.map(\.ringID)).sorted().compactMap { ringID in
            // `?? []` cannot fire: `evidence` is a filtered subset of `allEvidence`, so every ring
            // named here was already loaded above. Reading through the map is what keeps this
            // section on ONE archive read per ring instead of two.
            let archive = archivesByRing[ringID] ?? []
            guard !archive.isEmpty else { return nil }
            let blobbed = evidence.filter { $0.ringID == ringID }
                .flatMap { EpochArchive.decode($0.rawRecordBlob) }
            let dates = archive.map { $0.date() }.sorted()
            return ExportEngine.EpochArchiveRow(
                ringID: ringID,
                recordsBase64: EpochArchive.encode(archive).base64EncodedString(),
                recordCount: archive.count,
                firstEpoch: dates.first,
                lastEpoch: dates.last,
                coverage: ArchiveEvidenceCoverage.report(archive: archive, evidence: blobbed))
        }

        // ── v3 sections ───────────────────────────────────────────────────────────────────────
        let meta = metadata(rangeStart: from, rangeEnd: to, now: now)
        let sessionRows = zip(nights, sleepRows).map { night, summary in
            sessionRow(night, summary: summary, store: store,
                       archives: archivesForCoverage, now: now)
        }

        let content: String
        switch format {
        case .csv:
            content = [
                ExportEngine.samplesCSV(sampleRows),
                "",
                ExportEngine.sleepCSV(sleepRows),
                "",
                ExportEngine.dailyCSV(dailyRows),
                "",
                ExportEngine.stepSamplesCSV(stepSampleRows),
                "",
                ExportEngine.napsCSV(napRows),
                "",
                ExportEngine.daytimeTemperatureCSV(daytimeTemperatureRows),
                "",
                ExportEngine.historySyncEvidenceCSV(evidenceRows),
                // Appended, never interleaved — see the file header on positional compatibility.
                "",
                ExportEngine.metadataCSV(meta),
                "",
                ExportEngine.sleepSessionsCSV(sessionRows),
                "",
                ExportEngine.hypnogramCSV(sessionRows),
                // The honesty apparatus, in the format that is the screen's DEFAULT. Emitting it
                // only in JSON meant the file most people actually hand to a clinician carried the
                // stage minutes, `osaODI` and an `hrvSDNN` column with nothing in it saying the
                // stages are our own estimate, that only the average SpO2 is validated, or that
                // `hrvSDNN` holds RMSSD — while the screen said every section was labelled.
                "",
                ExportEngine.provenanceCSV(includesSleepSessions: !sessionRows.isEmpty),
                "",
                ExportEngine.unitsCSV(),
                "",
                ExportEngine.notesCSV()
            ].joined(separator: "\n")
        case .json:
            guard let json = ExportEngine.toJSON(samples: sampleRows, sleep: sleepRows,
                                                 daily: dailyRows,
                                                 stepSamples: stepSampleRows,
                                                 naps: napRows,
                                                 daytimeTemperatures: daytimeTemperatureRows,
                                                 historySyncEvidence: evidenceRows,
                                                 now: now,
                                                 metadata: meta,
                                                 sleepSessions: sessionRows,
                                                 epochArchives: archiveRows) else {
                throw Failure.serializationFailed
            }
            content = json
        }

        return .file(Payload(content: content,
                             fileName: "\(fileStem).\(format.fileExtension)",
                             format: format,
                             sessionCount: sessionRows.count,
                             watermarkAdvance: watermarkAdvance,
                             contentAsOf: contentAsOf,
                             rangeNotice: rangeNotice))
    }

    /// Advance the export watermarks past the nights (and the content) this payload actually
    /// contains.
    ///
    /// Split out of `build` on purpose: I2/I3 says a watermark advances only after a DURABLE write,
    /// so the caller has to have delivered the bytes first. Calling it twice is harmless — both
    /// watermarks are forward-only. `.distantPast` for the night watermark is a guaranteed no-op, so
    /// a payload that consumed no settled night can still record what content it carried.
    static func commitWatermark(_ payload: Payload, store: LocalStore) throws {
        guard payload.watermarkAdvance != nil || payload.contentAsOf != nil else { return }
        try store.markExported(through: payload.watermarkAdvance ?? .distantPast,
                               contentAsOf: payload.contentAsOf)
    }

    // MARK: - Session rows

    private static func summaryRow(_ row: StoredSleepSummary) -> ExportEngine.SleepRow {
        ExportEngine.SleepRow(
            night: row.night, asleepMin: row.asleepMin,
            deepMin: row.deepMin, lightMin: row.lightMin,
            remMin: row.remMin, awakeMin: row.awakeMin,
            efficiency: row.efficiency,
            // THE MINUTES AND THE WINDOW MUST COME FROM THE SAME NIGHT.
            //
            // `applySleepEdit` (LocalStore.swift) rewrites `asleepMin`/`deepMin`/… to the POST-edit
            // staging but deliberately leaves `inBedStart`/`inBedEnd` frozen — those two columns ARE
            // the recorded window (`sleepEditRecordedInBed*` is defined as them). Pairing the two
            // published a row that could not exist: 🟢 measured on the tester export of 2026-08-24,
            // `asleepMin: 434` (+ `awakeMin: 45`) inside an in-bed window of 20:45:19 → 00:44:47 Z,
            // which is 14368 s = 239.5 minutes. 479 minutes of sleep inside 239.5 minutes of bed is
            // not a rounding disagreement, it is arithmetically impossible, and it is a large part of
            // why the tester read the export as proof her edit never stuck. Present on a second
            // tester's 2026-08-22 night too (533 + 16 min against a 607.6-minute recorded window,
            // which happens to fit and so reads as merely wrong rather than impossible) — so it is
            // not a one-off, and the milder presentation is the more dangerous one.
            //
            // Emit the EFFECTIVE (edit-aware) window instead: the same pair `sessionRow` already
            // publishes, so the two sections of one file now agree. Nothing is lost — the untouched
            // recorded window is exported next to it as `recordedInBedStart`/`recordedInBedEnd`, and
            // on an UNEDITED night these accessors return the identical values this line used to,
            // so every unedited row is byte-identical to before.
            inBedStart: effectiveInBedStart(row),
            inBedEnd: effectiveInBedEnd(row),
            skinTempC: row.skinTempC, sleepScore: row.sleepScore, stressScore: row.stressScore,
            feelScore: row.feelScore, hrDeep: row.hrDeep, hrLight: row.hrLight,
            hrRem: row.hrRem, hrAwake: row.hrAwake, movementLevels: row.movementLevels)
    }

    private static func sessionRow(_ row: StoredSleepSummary,
                                   summary: ExportEngine.SleepRow,
                                   store: LocalStore,
                                   archives: [[BulkRecord]],
                                   now: Date) -> ExportEngine.SleepSessionRow {
        // EFFECTIVE (edit-aware) clock times, i.e. what the sleep card and Apple Health show for
        // this night. An export that disagreed with the app's own screen would be the bigger
        // surprise; `isManuallyEdited` travels alongside so a consumer can always tell an override
        // from a recording, and the untouched recorded window is still in the `sleep` section.
        let inBedStart = realDate(row.sleepEditCurrentInBedStart)
        let inBedEnd = realDate(row.sleepEditCurrentInBedEnd)

        // `osaValidWindows == 0` means no OSA assessment was drained that night. Emitting the four
        // zero-valued columns would assert an average SpO2 of 0 % — absence is not zero.
        let osa: ExportEngine.OSARow? = row.osaValidWindows > 0
            ? ExportEngine.OSARow(avgSpO2: row.osaAvgSpO2,
                                  minSpO2: row.osaMinSpO2,
                                  timeBelow90Sec: row.osaTimeBelow90Sec,
                                  odi: row.osaODI,
                                  validWindows: row.osaValidWindows)
            : nil

        // Coverage is only reportable while the raw HR rows it counts still EXIST locally.
        // `pruneExpiredSamples` deletes `StoredSample` rows older than `sampleRetentionDays` on
        // every launch (LocalStore.swift), while `StoredSleepSummary` is kept long-term — so an
        // older night measured anyway emitted `coverageFraction 0.0000 / observedSamples 0` and a
        // whole-night gap, on the same row as a fully staged night, labelled `measured`. That
        // reports routine local housekeeping as data the ring never delivered. Leave the columns
        // EMPTY instead — the file's own absence-is-not-zero rule, already applied to OSA above.
        // Measured against the EXPORT time rather than the launch-time prune cutoff, which is not
        // observable here; the cost is at most the single boundary night, suppressed rather than
        // reported with a number we cannot vouch for.
        let retentionHorizon = Calendar.current.date(
            byAdding: .day, value: -LocalStore.sampleRetentionDays, to: now) ?? now
        var coverage: ExportCoverage.Assessment?
        if let start = inBedStart, let end = inBedEnd, end > start, start >= retentionHorizon {
            // Heart rate is the coverage witness because the ring emits at most one HR value per
            // 0x4c epoch record — so the count of HR timestamps in a window IS the count of epochs
            // we hold for it. HRV/SpO2/RR are sparser by layout and would under-report coverage
            // that is genuinely complete.
            //
            // Re-queried per night rather than filtered out of `sampleRows`: a night bucketed on the
            // LAST day of a date-range export wakes after the range ends, so the in-range array is
            // missing its morning — and a missing morning would be reported as a real gap.
            //
            // …BUT THE STORE ROWS ARE NOT THE RECORD SET, AND ON THEIR OWN THEY MEASURED OUR CURSOR.
            // The persisted rows are what survived `SyncCursor.selectNew`, which is strictly
            // forward-only, so a single live auto-measure sample can strand every earlier epoch the
            // ring delivers afterwards. 🟢 Measured on the tester export of 2026-08-24: the store
            // held 143 HR rows over that night's window and the epoch archive held 205, with the
            // "gaps" bounded at 20:57:44.551 / 21:19:50.059 / 23:14:00.580 — sub-second stamps, the
            // fingerprint of a live sample rather than of a 150 s epoch stream. The row published
            // `coverageFraction 0.7333 / 4 gaps` about a window the ring had recorded end to end.
            // Union the archive in (`ExportCoverageWitness` carries the full derivation, including
            // why archive-ONLY is worse: it would turn ~30 h of retention into a reported hole).
            let hr = (try? store.samples(kind: .heartRate, from: start, to: end)) ?? []
            let witness = ExportCoverageWitness.sampleTimes(
                archives: archives, storedHeartRateTimes: hr.map(\.start), from: start, to: end)
            coverage = ExportCoverage.assess(sampleTimes: witness, from: start, to: end)
        }

        // Edge provenance — what sits just OUTSIDE each edge, which is the half `coverage` above
        // cannot see: its window is defined by the records inside it, so a night whose recording
        // stopped dead at the wake reports a coverage fraction of ~1.0.
        //
        // Measured over the RECORDED (detector) window, NOT the edit-aware one the row's
        // `inBedStart`/`inBedEnd` carry. Three reasons, in order of weight: an edit changes what the
        // app shows, never what was recorded, so the detector edge is the only one whose provenance
        // is a fact about the data; the recorded columns are populated on EVERY night (they are the
        // raw `inBedStart`/`inBedEnd`), so the column is comparable across edited and unedited
        // nights; and a corrected wake time that lands INSIDE the hole would otherwise measure its
        // own gap and shrink the very evidence the correction is proof of. `edgeProvenance.window*`
        // states which window was used so no consumer has to infer it.
        //
        // Three `fetchLimit = 1` reads per night, the same probes the sleep card runs — and, as
        // there, HEART RATE specifically: it is band-guarded to 30…220 bpm, so a charging or
        // pocketed ring yields none, while a skin-temp row keeps arriving from a docked ring and
        // would report a dead night as "still recording".
        //
        // …but only for nights whose raw rows can still EXIST, gated on the very same
        // `retentionHorizon` the coverage block above uses. Two reasons, and the second is the one
        // that made this a defect rather than a tidy-up:
        //
        //   1. CORRECTNESS, already handled but stated once here: past the horizon every probe can
        //      answer is the pruning boundary, so `SleepConfidence`'s own retention guard collapses
        //      the pair to `.unknown` anyway. Passing `coverage: nil` produces the IDENTICAL row —
        //      bedtime `unknown`, wake `unknown`, no gaps, and the duration verdict (which reads the
        //      night's two totals and is untouched by retention) still exported. Asserted by
        //      `ExportBuilderTests.testCoverageIsOmittedOnceTheRawSamplesHaveBeenPrunedAway`.
        //   2. COST. `ExportBuilder` is `@MainActor` and the build is synchronous, `maxExportDays`
        //      is 365, and `sampleRetentionDays` is 30 — so a full export probed up to 365 × 3 =
        //      1095 nights' worth of indexed fetches on the main thread, of which 335 × 3 = 1005
        //      could only ever return "unknown". That is the same unbounded-main-actor shape §5 of
        //      the tests exists to bound, in an app that has already shipped an 0x8BADF00D
        //      scene-update watchdog kill. This leaves at most 30 × 3 = 90.
        var edgeProvenance: ExportEngine.SleepEdgeProvenanceRow?
        let recordedStart = realDate(row.sleepEditRecordedInBedStart)
        let recordedEnd = realDate(row.sleepEditRecordedInBedEnd)
        if let s = recordedStart, let e = recordedEnd, e > s {
            let edgeCoverage: SleepConfidence.Coverage? = s >= retentionHorizon
                ? SleepConfidence.Coverage(
                    inBedStart: s, inBedEnd: e,
                    lastMeasurementBeforeStart: (try? store.latestSample(kind: .heartRate, before: s))?.start,
                    firstMeasurementAfterEnd: (try? store.earliestSample(kind: .heartRate, after: e))?.start,
                    earliestRetainedMeasurement: (try? store.earliestSample(kind: .heartRate))?.start)
                : nil
            let assessment = SleepConfidence.assess(
                asleep: row.asSummary.totalAsleep, inBed: row.asSummary.inBed,
                coverage: edgeCoverage)
            edgeProvenance = ExportEngine.SleepEdgeProvenanceRow(
                windowStart: s, windowEnd: e, assessment: assessment)
        }

        return ExportEngine.SleepSessionRow(
            sessionID: ExportEngine.sessionID(night: row.night),
            night: row.night,
            inBedStart: inBedStart,
            inBedEnd: inBedEnd,
            sleepOnset: realDate(row.sleepEditCurrentOnset),
            sleepWake: realDate(row.sleepEditCurrentWake),
            isManuallyEdited: row.isManuallyEdited,
            // The pre-edit values, so an edited night exports as a supervised LABEL (detector said
            // X / sleeper says Y) rather than only the corrected answer. Emitted only when the night
            // was actually edited — on an unedited night these ARE the values above, and repeating
            // them would make "the user agreed" indistinguishable from "the user never looked".
            recordedInBedStart: row.isManuallyEdited ? realDate(row.sleepEditRecordedInBedStart) : nil,
            recordedInBedEnd: row.isManuallyEdited ? realDate(row.sleepEditRecordedInBedEnd) : nil,
            recordedOnset: row.isManuallyEdited ? realDate(row.sleepEditRecordedOnset) : nil,
            recordedWake: row.isManuallyEdited ? realDate(row.sleepEditRecordedWake) : nil,
            // Decoded off the ROW already in hand, never re-fetched by day bucket.
            // `store.hypnogram(night:)` re-derives its key as `startOfDay(night)` in the CURRENT
            // timezone, but `row.night` was bucketed in the zone the night was STAGED in — so after
            // a flight the predicate misses, the fetch returns [], and the export reports every
            // night as having no recorded timeline while the blob sits intact on disk (the export's
            // own contract makes an empty hypnogram mean NOT RECORDED). This is the same value
            // `hypnogram(night:)` returns once it has found the row, minus the fragile lookup.
            hypnogram: SleepHypnogramCodec.decode(row.hypnogramData),
            summary: summary,
            osa: osa,
            coverage: coverage,
            edgeProvenance: edgeProvenance)
    }

    /// `.distantPast` is the store's "not recorded" sentinel for every sleep clock column; it must
    /// not reach the file as a year-0001 timestamp.
    private static func realDate(_ date: Date) -> Date? {
        date > .distantPast ? date : nil
    }

    private static func effectiveInBedEnd(_ row: StoredSleepSummary) -> Date? {
        realDate(row.sleepEditCurrentInBedEnd)
    }

    /// The night's real in-bed START (edited value when the user edited it). Anchors the raw-sample
    /// window's lower bound: a night keyed on the day it ENDS began the previous evening, so the
    /// bucket day alone would clip the pre-midnight hours out of the export.
    private static func effectiveInBedStart(_ row: StoredSleepSummary) -> Date? {
        realDate(row.sleepEditCurrentInBedStart)
    }

    // MARK: - Metadata

    /// What the export was produced BY and IN — the context a consumer needs before they can
    /// interpret a timestamp or a firmware-dependent byte offset.
    /// `schemaVersion` and `timestampPolicy` are deliberately LEFT AT THEIR KIT DEFAULTS
    /// (`ExportEngine.schemaVersion` / `.timestampPolicyDescription`) rather than restated here: the
    /// serializer is the only thing that knows what it actually emitted, so a copy on this side
    /// could only ever drift into a lie about the file it is describing.
    ///
    /// The ring fields come from a CACHE rather than from a live `RingSession`, because the ring is
    /// usually DISCONNECTED when somebody sits down to export — a block that were blank whenever
    /// the ring was off the finger would be blank almost every time. `RingMetadataStore` holds no
    /// MAC-derived bytes: `modelName` arrives as the ADVERTISED name, whose trailing `-XXXX` is the
    /// last two MAC bytes (🟢 docs/PROTOCOL.md:55), and `record` strips that suffix before it is
    /// ever cached — so the model family reaches the file and the hardware identifier does not.
    ///
    /// `ring` is a parameter (defaulted to the live cache) so the MAC-stripping guarantee this block
    /// makes can be tested end-to-end against a hostile advertised name, rather than asserted about
    /// a struct that simply has no MAC field.
    static func metadata(rangeStart: Date, rangeEnd: Date,
                         now: Date = Date(),
                         ring: RingMetadataSnapshot = RingMetadataStore().load())
        -> ExportEngine.ExportMetadata {
        let bundle = Bundle.main.infoDictionary
        return ExportEngine.ExportMetadata(
            exportedAt: now,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            appVersion: bundle?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: bundle?["CFBundleVersion"] as? String ?? "",
            deviceModel: hardwareIdentifier(),
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            ringModel: ring.modelName,
            ringFirmware: ring.version,
            ringGeneration: ring.generation,
            ringIdentifier: ring.identifier,
            // The SAME live accessor `ExportEngine`'s own device-local formatters read, so the zone
            // this block declares is by construction the zone the file's offsets are printed in. A
            // `static let` formatter used to freeze that zone for the life of the PROCESS, so a
            // resident app that changed zone or crossed a DST boundary declared one and printed the
            // other — in the export whose whole selling point is unambiguous timestamps.
            timeZoneIdentifier: ExportEngine.localTimeZone.identifier,
            timeZoneOffsetSeconds: ExportEngine.localTimeZone.secondsFromGMT(for: now))
    }

    /// Hardware model IDENTIFIER ("iPhone15,2"), never `UIDevice.name`.
    ///
    /// `UIDevice.name` is the name the USER chose ("Juan's iPhone") — personal data that would ride
    /// along in a file they hand to a stranger. The machine identifier says what the hardware is,
    /// which is the only part a consumer of the export needs.
    private static func hardwareIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

}
