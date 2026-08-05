// ExportDataIntent.swift — "Export Ring Data" from Shortcuts, Siri or an automation (#80 v3).
//
// The point of the intent is UNATTENDED export: a nightly automation that files the last night's
// data into iCloud Drive, mails it to a clinician, or drops it into a shared folder without anybody
// opening the app. It exists because a tester who has to remember a manual step every morning
// eventually stops doing it, and the un-exported nights are then only recoverable by hand.
//
// WHICH PROCESS RUNS THIS, AND WHY IT MATTERS
// -------------------------------------------
// Same rule as the headache intents, and for the same reason — see the long header of
// Headache/HeadacheLogIntent.swift. This type lives in the APP target ONLY, deliberately NOT in
// `Shared/`, which is also compiled into the WorkoutWidget extension. There is no App Group, so the
// extension's process cannot reach the app's SwiftData store; a copy compiled into the extension
// could perform there and export an EMPTY store — handing the user a file that looks like a
// successful export of a night that has silently gone missing. A wrong file is worse than no file.
//
// With `openAppWhenRun == false` and the intent declared in the app binary, the system launches the
// APP in the background (no UI) and performs it there, against the real store. Nothing here touches
// BLE or HealthKit: it is a pure read of already-stored data, so it cannot disturb a sleep-window
// drain (N5) and cannot hit the HealthKit authorization surface from a background launch.
//
// AUTHENTICATION. Unlike the headache intents, this one keeps the DEFAULT policy
// (`.requiresAuthentication`). Those relax it because they only WRITE a fact the speaker just
// stated; this one RETURNS the user's health history as a file, and "anything that READS the log
// stays behind the app's normal unlock-and-open path" (HeadacheLogIntent.swift:286). An export that
// a locked phone would hand over is a data-disclosure hole, not a convenience.

import AppIntents
import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Parameter enums

/// File format for the exported bundle.
enum ExportFormatChoice: String, AppEnum {
    case json
    case csv

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"
    static let caseDisplayRepresentations: [ExportFormatChoice: DisplayRepresentation] = [
        .json: "JSON",
        .csv: "CSV",
    ]

    var builderFormat: ExportBuilder.Format {
        switch self {
        case .json: return .json
        case .csv:  return .csv
        }
    }

    /// Declared on the returned `IntentFile` so Shortcuts' "Save File" / "Send Email" actions treat
    /// the attachment as text rather than an opaque blob.
    var contentType: UTType {
        switch self {
        case .json: return .json
        case .csv:  return .commaSeparatedText
        }
    }
}

/// What the automation should export.
enum ExportScopeChoice: String, AppEnum {
    /// Only nights not exported before — the automation case, and the reason the watermark exists.
    case newSessions
    /// The most recent recorded night, whether or not it was exported already.
    case lastNight
    /// A trailing window of whole days, for a periodic full-refresh backup.
    case recentDays

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Scope"
    static let caseDisplayRepresentations: [ExportScopeChoice: DisplayRepresentation] = [
        .newSessions: "New sleep sessions",
        .lastNight: "Last night",
        .recentDays: "Recent days",
    ]
}

// MARK: - Errors

/// Failures reported back to Shortcuts in words a user can act on.
enum ExportIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// The SwiftData store could not be opened — in practice a background launch before the first
    /// unlock after a restart, when Data Protection still has the store file sealed (#131).
    case storeUnavailable
    /// `.newSessions` with nothing past the watermark. Reported as an error rather than as an empty
    /// file: a Shortcut that saved a zero-row export every morning would eventually be trusted as
    /// evidence that a night contained nothing.
    case nothingNew
    /// No recorded night to export (a brand-new install, or `.lastNight` before the first sync).
    case noStoredSession
    case serializationFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable:
            return "OpenCircuit couldn’t open your data just now — if your iPhone restarted recently, unlock it and try again."
        case .nothingNew:
            return "No new sleep sessions since the last export. Choose “Recent days” if you want a file every time."
        case .noStoredSession:
            return "There’s no recorded night to export yet."
        case .serializationFailed:
            return "OpenCircuit couldn’t assemble the export file."
        }
    }
}

/// Resolve the store the export reads from.
///
/// Mirrors `quickLogStore()` in HeadacheLogIntent.swift (which is file-private there): reuse the
/// process-wide container the `App` published at launch, and fall back to the NON-destructive
/// `makeContainerOrThrow()`. `makeContainer()` is never called here — its wipe-and-recover path
/// would delete un-resyncable history on a transient open failure, with no UI present to say so
/// (#40/#131). An export must never be able to destroy the thing it is exporting.
@MainActor
private func exportStore() throws -> LocalStore {
    guard let container = try? (OpenCircuitApp.sharedContainer ?? OpenCircuitApp.makeContainerOrThrow()) else {
        throw ExportIntentError.storeUnavailable
    }
    return LocalStore(container.mainContext)
}

// MARK: - The intent

/// Export stored ring data as a file Shortcuts can route anywhere.
struct ExportRingDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Ring Data"
    static let description = IntentDescription(
        // One literal, not a `+` concatenation: the parameter is a LocalizedStringResource, which
        // only a literal converts to — a concatenation is already a String and does not compile.
        "Exports your stored ring data as a CSV or JSON file. Nothing leaves your device unless the shortcut you build sends it somewhere. “New sleep sessions” marks nights as exported only when OpenCircuit saves the file into an export folder you picked in the app — it cannot tell whether a later Shortcuts action succeeded.",
        categoryName: "Data Export",
        searchKeywords: ["export", "backup", "csv", "json", "sleep", "data"])

    /// FALSE on purpose: an automation must be able to run while the user is asleep or the phone is
    /// in a pocket. The system launches the app in the background and performs this there.
    static let openAppWhenRun = false

    @Parameter(title: "Data", default: .newSessions)
    var scope: ExportScopeChoice

    @Parameter(title: "Format", default: .json)
    var format: ExportFormatChoice

    /// Only meaningful for `.recentDays`. Bounded so a stray value can't ask the store for a
    /// century of rows on a background launch with a short execution budget.
    @Parameter(title: "Days", default: 7, inclusiveRange: (1, 365))
    var days: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$scope) as \(\.$format)") {
            \.$days
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let store = try exportStore()

        let mode: ExportBuilder.Mode
        switch scope {
        case .newSessions:
            mode = .newSessions
        case .lastNight:
            // `try?` flattens the throwing method's own Optional (SE-0230), so "fetch failed" and
            // "nothing stored" arrive as the same nil — which is the same answer for the user.
            guard let night = (try? store.latestSleepSummary())?.night else {
                throw ExportIntentError.noStoredSession
            }
            mode = .singleSession(night: night)
        case .recentDays:
            // `days` counts whole days INCLUSIVE of today, so 7 means today plus the six before it —
            // what a person means by "the last week", not eight days.
            let end = Date()
            let span = min(max(days, 1), 365)
            let start = Calendar.current.date(byAdding: .day, value: -(span - 1), to: end) ?? end
            mode = .dateRange(start: start, end: end)
        }

        let outcome: ExportBuilder.Outcome
        do {
            outcome = try ExportBuilder.build(store: store, mode: mode, format: format.builderFormat)
        } catch ExportBuilder.Failure.sessionNotStored {
            throw ExportIntentError.noStoredSession
        } catch {
            throw ExportIntentError.serializationFailed
        }

        guard case .file(let payload) = outcome else { throw ExportIntentError.nothingNew }

        let file = IntentFile(data: payload.data,
                              filename: payload.fileName,
                              type: format.contentType)

        // The watermark may advance only after a DURABLE write (I2/I3), and returning an
        // `IntentFile` is NOT one. Everything downstream of the return — Save File, Send Email, a
        // confirmation step, the user cancelling the shortcut — can fail, and `markExported` is
        // forward-only, so a night consumed here on a morning when iCloud Drive was full could never
        // be re-offered to `.newSessions`: the automated archive would be permanently missing it and
        // the next run would cheerfully report "nothing new". AppIntents offers no delivery
        // confirmation, so this consumes the watermark ONLY when OpenCircuit itself wrote the file
        // into the folder the user chose — the same `.savedToFolder` rule the export screen follows.
        // With no folder configured there is nothing to confirm and nothing is consumed: those
        // nights are re-offered next run, and a duplicate is the safe direction (see the
        // `watermarkAdvance` note in `ExportBuilder.build`).
        //
        // The watermark write itself is swallowed deliberately: re-exporting a night is a duplicate,
        // while reporting failure would leave the user with a file they were told was invalid.
        var savedFolder: String?
        if ExportDestination.hasChosenFolder {
            switch try? ExportDestination.deliver(payload) {
            case .savedToFolder(_, let folder)?:
                savedFolder = folder
                try? ExportBuilder.commitWatermark(payload, store: store)
            case .temporaryFile(let url, _)?:
                // The chosen folder was unreachable, so `deliver` prepared a share-sheet copy — but
                // there is no share sheet on this path: the bytes already went back to Shortcuts as
                // `file` above, so that copy has no consumer at all. Reclaim it rather than leave a
                // full copy of the user's vitals, hypnograms and raw history frames in tmp on every
                // unattended run of a nightly automation.
                try? FileManager.default.removeItem(at: url)
            case nil:
                break
            }
        }

        return .result(value: file, dialog: dialog(for: payload, savedTo: savedFolder))
    }

    /// Says how many sessions the file describes, so an automation's confirmation is a fact rather
    /// than a "Done" — and so a run that produced an empty range says so out loud.
    ///
    /// `savedTo` names the folder when OpenCircuit wrote the file itself, which is also the only
    /// case in which the nights were marked exported — the dialog says so, because otherwise a user
    /// whose `.newSessions` automation keeps re-offering the same nights has no way to learn why.
    ///
    /// Built from string literals (like `quickLogDialog` in HeadacheLogIntent.swift) because
    /// `IntentDialog` takes a `LocalizedStringResource`, not a runtime `String`.
    private func dialog(for payload: ExportBuilder.Payload, savedTo folder: String?) -> IntentDialog {
        let name = payload.fileName
        if payload.sessionCount == 0 {
            return IntentDialog("Exported \(name). It contains no sleep sessions for that range.")
        }
        let count = "\(payload.sessionCount)"
        let noun = payload.sessionCount == 1 ? "sleep session" : "sleep sessions"
        if let folder {
            return IntentDialog("Exported \(count) \(noun) as \(name), saved to \(folder) and marked as exported.")
        }
        return IntentDialog("Exported \(count) \(noun) as \(name). They stay marked as not yet exported — choose an export folder in OpenCircuit if you want them marked once the file is saved.")
    }
}
