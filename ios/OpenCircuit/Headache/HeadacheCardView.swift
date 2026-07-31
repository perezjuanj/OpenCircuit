import SwiftUI
import SwiftData

// The dashboard's headache-log card + the shared Apple Health import control.
//
// Phase 1 is a LOG, not a detector: this card exists to make logging a headache a two-tap job, and
// to get the labels the user already keeps in Apple Health into the same series. It shows a count
// and nothing else — there is no score, band or forecast to show, and a placeholder for one would
// imply a capability that doesn't exist.
//
// Visibility is the CALLER's job (`HeadacheDefaults.enabled`), mirroring how the dashboard hides
// the cycle card behind `womensHealthEnabled`.

struct HeadacheCardView: View {
    /// Push the headache history/detail route. The dashboard SUPPLIES this — it does not wrap the
    /// card in its own `Button` the way `cycleCalendarCard` does.
    ///
    /// That difference is deliberate and load-bearing: unlike the passive cycle card, this card
    /// carries its own controls ("Log a headache", the Apple Health import prompt), and a `Button`
    /// nested inside another `Button`'s label does not receive its own taps — the outer hit area
    /// swallows them, which would break the feature's primary action. So the `NavigationStack` path
    /// still lives in ContentView, but it reaches this view as a closure and is fired from the
    /// card's own header button.
    ///
    /// `nil` means non-navigating (previews, or an embedded use with no route): the header is plain
    /// text and no chevron is drawn. Either way it is a `Button`, never a `NavigationLink` — a
    /// `NavigationLink` in the Today list draws the List's own disclosure chevron on top of ours.
    let onOpenDetail: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    /// This month's entries. Bounded: the card only ever renders a count, so it must not drag the
    /// whole table through the render path on every SwiftData invalidation.
    @Query private var monthEntries: [StoredHeadacheEntry]

    @State private var showLogSheet = false

    private static let monthFetchLimit = 100

    init(onOpenDetail: (() -> Void)? = nil) {
        self.onOpenDetail = onOpenDetail
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date()))
            ?? cal.startOfDay(for: Date())
        var desc = FetchDescriptor<StoredHeadacheEntry>(
            predicate: #Predicate { $0.onset >= monthStart },
            sortBy: [SortDescriptor(\.onset, order: .reverse)])
        desc.fetchLimit = Self.monthFetchLimit
        _monthEntries = Query(desc)
    }

    var body: some View {
        OCCard {
            if let onOpenDetail {
                Button(action: onOpenDetail) {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Headache log. \(monthCountLine)")
                .accessibilityHint("Shows your logged headaches")
            } else {
                header
            }

            Button {
                showLogSheet = true
            } label: {
                Label("Log a headache", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HeadacheImportControl(oneTimePrompt: true)
        }
        .sheet(isPresented: $showLogSheet) {
            HeadacheLogSheet(editing: nil) { draft in
                try LocalStore(modelContext).saveHeadacheEntry(
                    onset: draft.onset, end: draft.end, severityRaw: draft.severityRaw,
                    symptoms: draft.symptoms, customSymptoms: draft.customSymptoms,
                    factors: draft.factors, notes: draft.notes,
                    originalOnset: draft.originalOnset)
            }
        }
    }

    /// Title + this month's count. The chevron is drawn in both modes because the card pushes the
    /// history either way — from our own button or from the dashboard's wrapper.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            OCSectionHeader("Headache log", systemImage: "brain.head.profile",
                            tint: Theme.accent) {
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Text(monthCountLine)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Count line. Reports the fetch cap as "100+" rather than a flat "100" — the card would
    /// otherwise understate a month it only partly fetched.
    private var monthCountLine: String {
        let count = monthEntries.count
        switch count {
        case 0:                     return "No headaches logged this month"
        case 1:                     return "1 headache logged this month"
        case Self.monthFetchLimit:  return "\(Self.monthFetchLimit)+ headaches logged this month"
        default:                    return "\(count) headaches logged this month"
        }
    }
}

// MARK: - Apple Health import

/// The "import the headaches you already log in Apple Health" control.
///
/// ONE component in two modes so the card's one-time prompt and the history screen's permanent
/// button can never disagree about what was imported or about what "none" means:
///  - `oneTimePrompt: true` — the card's first-run offer. Disappears once answered
///    (`HeadacheDefaults.importPromptShown`), either by importing or by "Not now".
///  - `oneTimePrompt: false` — the history screen's always-available button.
///
/// The result copy is deliberately careful. HealthKit does NOT tell an app when a read is denied:
/// a denied read and a genuinely empty Health store return the exact same empty set. So "none" may
/// never be phrased as "you have no headaches in Health" — it says nothing was FOUND, and names
/// permissions as a possible reason.
struct HeadacheImportControl: View {
    var oneTimePrompt: Bool = false

    @Environment(\.modelContext) private var modelContext
    @AppStorage(HeadacheDefaults.importPromptShown) private var importPromptShown = false

    @State private var running = false
    @State private var outcome: Outcome? = nil

    /// Bounded lookback. Labels older than this have no ring data to be paired with — the user
    /// didn't own the ring yet — so an unbounded scan of the Health store buys nothing.
    private static let lookbackDays = 730

    /// What one import run actually did. `nothingNew` and `nothingFound` are DIFFERENT facts and
    /// must not share copy: the first read real samples and added none of them, the second read an
    /// empty set — which is also exactly what a denied read looks like.
    private enum Outcome: Equatable {
        case imported(Int)
        case nothingNew
        case nothingFound
    }

    /// The card's one-time prompt hides once answered — but NOT while it is showing the result of a
    /// run the user just kicked off, or the count they asked for would vanish as they read it.
    private var visible: Bool {
        guard HealthKitWriter.isAvailable else { return false }
        return !oneTimePrompt || !importPromptShown || outcome != nil
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 6) {
                if let outcome {
                    Text(resultLine(outcome))
                        .font(.caption).foregroundStyle(.secondary)
                    if outcome == .nothingFound {
                        Text("Apple Health doesn't tell apps when a read is blocked, so this can also mean OpenCircuit isn't allowed to read headaches yet — check its permissions in the Health app.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(oneTimePrompt
                         ? "Already log headaches in Apple Health? Bring them across so they're all in one place."
                         : "Bring headaches you logged in Apple Health into this log.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await runImport() }
                    } label: {
                        if running {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(outcome == nil ? "Import from Apple Health" : "Check again")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(running)

                    if oneTimePrompt, outcome == nil {
                        Button("Not now") { importPromptShown = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultLine(_ outcome: Outcome) -> String {
        switch outcome {
        case .imported(1):          return "Imported 1 headache from Apple Health."
        case .imported(let count):  return "Imported \(count) headaches from Apple Health."
        case .nothingNew:           return "Nothing new to import from Apple Health."
        case .nothingFound:         return "Found no headaches in Apple Health."
        }
    }

    /// Read headache samples out of Apple Health and add the ones we don't already hold.
    ///
    /// Three things this deliberately does NOT do:
    ///  - re-import a sample already imported (`importedHKUUID`, so repeat runs are idempotent);
    ///  - overwrite an entry the user typed themselves — `saveHeadacheEntry` UPSERTS on `onset`, so
    ///    an exact onset collision would silently wipe their symptoms and notes;
    ///  - import a `notPresent` (severity 1) sample. That records the ABSENCE of a headache; filing
    ///    it as a logged headache would fabricate a label for something that didn't happen and
    ///    inflate every count this feature reports.
    @MainActor
    private func runImport() async {
        running = true
        let store = LocalStore(modelContext)
        let since = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86_400)
        let result = await HealthKitWriter().readHeadacheSamples(since: since)
        // The row's own `importedHKUUID` is not a sufficient tombstone: it dies WITH the row, so a
        // user who imports a sample and then deletes it gets it resurrected by the very next import.
        // The consumed set outlives the row, so a deletion stays a deletion.
        let consumed = Set(UserDefaults.standard.stringArray(forKey: HeadacheDefaults.consumedImportUUIDs) ?? [])
        let alreadyImported = ((try? store.importedHeadacheHKUUIDs()) ?? []).union(consumed)
        let existingOnsets = Set(((try? store.allHeadacheEntries()) ?? []).map(\.onset))

        var imported = 0
        var newlyConsumed: [String] = []
        for sample in result.external {
            guard !alreadyImported.contains(sample.uuid),
                  !existingOnsets.contains(sample.onset),
                  sample.severityRaw != 1 else { continue }
            do {
                try store.saveHeadacheEntry(
                    onset: sample.onset, end: sample.end, severityRaw: sample.severityRaw,
                    symptoms: [], source: .healthImport, importedHKUUID: sample.uuid)
                imported += 1
                newlyConsumed.append(sample.uuid)
            } catch {
                break   // stop on the first store failure; the rest retry on the next run
            }
        }
        if !newlyConsumed.isEmpty {
            UserDefaults.standard.set(Array(consumed) + newlyConsumed,
                                      forKey: HeadacheDefaults.consumedImportUUIDs)
        }

        // Only a query that returned NOTHING AT ALL may say "found none" and mention permissions —
        // that is the one case indistinguishable from a denied read. A store holding only our OWN
        // headaches proves the read worked, so it reports "nothing new" instead; saying "none found,
        // check permissions" to someone whose Health app is full of their headaches is simply false.
        outcome = imported > 0
            ? .imported(imported)
            : (result.returnedNothingAtAll ? .nothingFound : .nothingNew)
        importPromptShown = true
        running = false
    }
}
