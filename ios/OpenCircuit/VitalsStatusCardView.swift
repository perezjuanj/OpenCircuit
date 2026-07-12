import SwiftUI
import SwiftData
import OpenCircuitKit

/// Vitals Status panel (#72). Compares the latest day's resting HR, overnight SpO₂, overnight HRV
/// and skin temperature to the user's PERSONAL 7–30 day baseline and shows a normal / watch /
/// anomaly status with the contributing signals — including the HR+temp suspected-fever flag.
///
/// Everything is derived from already-decoded data and judged against the user's OWN history (no
/// hardcoded "healthy" ranges, no fabricated values). It's an on-device estimate, labeled as such,
/// and carries the medical disclaimer. Empty until enough nights/days of history accrue.
struct VitalsStatusCardView: View {
    /// ~32 days of readings — enough to fill the 30-day baseline window plus today.
    @Query private var hrSamples: [StoredSample]
    @Query private var spo2Samples: [StoredSample]
    @Query private var hrvSamples: [StoredSample]
    /// Trailing nights for the canonical skin-temp baseline/offset (#69).
    @Query private var sleepNights: [StoredSleepSummary]
    private let healthBaselineReader = HealthKitVitalsBaselineReader()
    @State private var healthBaselineReport: HealthKitVitalsBaselineReader.Report?

    /// The assembled report, held as STATE and recomputed off the render path in `.task(id:)` below.
    /// It was a computed `var` read TWICE per `body` pass, so the full 32-day baseline analysis (incl.
    /// the resting-HR derivation) ran ~2× on every SwiftUI invalidation — and, fatally, SYNCHRONOUSLY
    /// inside the background scene-update layout when a workout's `stop()` batch-ingest invalidated the
    /// @Query. That blew the 10 s scene-update watchdog (0x8BADF00D). As @State it renders instantly and
    /// the analysis runs once per data change, OFF the main actor (snapshot → `Task.detached`, below).
    @State private var report: VitalsBaseline.Report?

    /// Identity for the recompute `.task`: changes only when an input that affects the report changes,
    /// so the analysis re-runs on new data (not on every unrelated re-render).
    private var reportInputsKey: String {
        "\(hrSamples.count)|\(spo2Samples.count)|\(hrvSamples.count)|"
        + "\(sleepNights.first?.night.timeIntervalSince1970 ?? 0)|\(healthBaselineReport == nil ? 0 : 1)"
    }

    /// User's temperature-unit preference (#83), so the skin-temp delta matches the rest of the app.
    @AppStorage("units.temperature") private var tempUnitRaw = TemperatureUnit.localeDefault.rawValue

    private static let historyDays = 32

    init() {
        let since = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(-Double(Self.historyDays) * 86_400)
        let hr = MetricKind.heartRate.rawValue
        let spo2 = MetricKind.spo2.rawValue
        let hrv = MetricKind.hrvSDNN.rawValue
        _hrSamples = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hr && $0.start >= since && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)]))
        _spo2Samples = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == spo2 && $0.start >= since && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)]))
        _hrvSamples = Query(FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == hrv && $0.start >= since && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .forward)]))
        var nights = FetchDescriptor<StoredSleepSummary>(sortBy: [SortDescriptor(\.night, order: .reverse)])
        nights.fetchLimit = 40
        _sleepNights = Query(nights)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(statusColor)
                Text("VITALS STATUS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let report { statusBadge(report.status) }
            }

            if let report {
                if report.feverSuspected {
                    signalRow(icon: "thermometer.medium", color: .red, title: "Possible fever signs",
                              detail: "Skin temperature and heart rate are both elevated above baseline.")
                }
                ForEach(Array(report.signals.enumerated()), id: \.offset) { _, signal in
                    signalRow(icon: icon(for: signal), color: color(for: signal.severity),
                              title: title(for: signal), detail: detail(for: signal))
                }
                if report.status == .normal && !report.feverSuspected {
                    Text("All tracked vitals are within your personal baseline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Compared to your personal 7–30 day baseline. On-device estimate — not a medical device.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Building your baseline")
                    .font(.subheadline.weight(.medium))
                Text("Wear the ring overnight for about a week so OpenCircuit can learn your personal "
                     + "resting HR, SpO₂, HRV and skin-temperature ranges, then flag unusual days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .task {
            guard healthBaselineReport == nil else { return }
            healthBaselineReport = try? await healthBaselineReader.loadReport(lookbackDays: Self.historyDays)
        }
        // Recompute the report OFF THE MAIN ACTOR whenever an input changes (0x8BADF00D fix). d338484
        // moved this to `.task`, but a View's `.task` still runs on the MAIN actor — so a workout
        // `stop()` ingest that invalidated the @Query still ran the full 32-day baseline analysis (the
        // heaviest card: resting-HR derivation + per-vital stats + skin-temp baseline) on the main
        // thread during the background scene-update snapshot, and the watchdog crash recurred. Snapshot
        // the SwiftData rows + the Health fallback to Sendable value types HERE (main actor), then run
        // the pure OpenCircuitKit math on `Task.detached` and publish the result back.
        .task(id: reportInputsKey) {
            let hr = hrSamples.map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
            let spo2 = spo2Samples.map { (start: $0.start, value: $0.value) }
            let hrv = hrvSamples.map { (start: $0.start, value: $0.value) }
            let nights = sleepNights.map { (night: $0.night, skinTempC: $0.skinTempC) }
            let fbRestingHR = healthBaselineReport?.restingHR.map { (day: $0.day, value: $0.value) }
            let fbSpO2 = healthBaselineReport?.overnightSpO2.map { (day: $0.day, value: $0.value) }
            let fbHRV = healthBaselineReport?.overnightHRV.map { (day: $0.day, value: $0.value) }
            let fbSkinTempOffsetC = healthBaselineReport?.skinTempOffsetC
            report = await Task.detached {
                Self.computeReport(hr: hr, spo2: spo2, hrv: hrv, nights: nights,
                                   fallbackRestingHR: fbRestingHR, fallbackSpO2: fbSpO2,
                                   fallbackHRV: fbHRV, fallbackSkinTempOffsetC: fbSkinTempOffsetC)
            }.value
        }
    }

    // MARK: Report

    /// The Vitals Status report for the latest day, or nil until at least one vital has enough
    /// baseline history. Pure logic lives in OpenCircuitKit.VitalsBaseline; this assembles its inputs.
    ///
    /// `nonisolated static` + Sendable-snapshot parameters (no `@Query`/`@State`/`self` access) so the
    /// whole 32-day analysis runs on `Task.detached`, OFF the main actor — that's the reader-side half
    /// of the 0x8BADF00D fix. The numbers are byte-identical to the previous main-actor version: the
    /// callers below pass the exact same rows, just pre-snapshotted to value tuples on the main actor.
    nonisolated static func computeReport(
        hr: [HRSample],
        spo2: [(start: Date, value: Double)],
        hrv: [(start: Date, value: Double)],
        nights: [(night: Date, skinTempC: Double)],
        fallbackRestingHR: [(day: Date, value: Double)]?,
        fallbackSpO2: [(day: Date, value: Double)]?,
        fallbackHRV: [(day: Date, value: Double)]?,
        fallbackSkinTempOffsetC: Double?
    ) -> VitalsBaseline.Report? {
        let config = VitalsBaseline.Config()
        var inputs: [VitalsBaseline.VitalInput] = []
        if let i = vitalInput(.restingHR, localDays: restingHRDaily(hr),
                              fallback: fallbackRestingHR,
                              config: config) { inputs.append(i) }
        if let i = vitalInput(.overnightSpO2, localDays: dailyMeans(spo2, scale: 100),
                              fallback: fallbackSpO2,
                              config: config) { inputs.append(i) }
        if let i = vitalInput(.overnightHRV, localDays: dailyMeans(hrv, scale: 1),
                              fallback: fallbackHRV,
                              config: config) { inputs.append(i) }
        let offset = skinTempOffset(nights) ?? fallbackSkinTempOffsetC
        guard !inputs.isEmpty || offset != nil else { return nil }
        return VitalsBaseline.report(inputs, skinTempOffsetC: offset, config: config)
    }

    /// Build a VitalInput from local history first, falling back to Apple Health history when the
    /// local store has not yet accumulated enough baseline days.
    nonisolated private static func vitalInput(_ vital: VitalsBaseline.Vital,
                                               localDays: [(day: Date, value: Double)],
                                               fallback: [(day: Date, value: Double)]?,
                                               config: VitalsBaseline.Config) -> VitalsBaseline.VitalInput? {
        let localSeries = dailySeries(localDays)
        if let input = vitalInput(vital, series: localSeries, config: config) { return input }
        let fallbackSeries = fallback?.sorted { $0.day < $1.day }.map(\.value) ?? []
        return vitalInput(vital, series: fallbackSeries, config: config)
    }

    /// Build a VitalInput from a chronological (oldest→newest) series, requiring enough prior days.
    nonisolated private static func vitalInput(_ vital: VitalsBaseline.Vital,
                                               series: [Double],
                                               config: VitalsBaseline.Config) -> VitalsBaseline.VitalInput? {
        guard let today = series.last else { return nil }
        let prior = Array(series.dropLast())
        guard prior.count >= config.minBaselineDays else { return nil }
        return VitalsBaseline.VitalInput(vital: vital, today: today, prior: prior)
    }

    /// Chronological list of daily values (oldest→newest).
    nonisolated private static func dailySeries(_ days: [(day: Date, value: Double)]) -> [Double] {
        days.sorted { $0.day < $1.day }.map(\.value)
    }

    /// Resting HR per day = the day's sleep/low-activity HR estimate (RestingHR analytics).
    nonisolated private static func restingHRDaily(_ hr: [HRSample]) -> [(day: Date, value: Double)] {
        RestingHR.dailyValues(hr: hr).map { (day: $0.day, value: $0.bpm) }
    }

    /// Per-calendar-day mean of a sample kind (SpO₂ fraction → percent via `scale`).
    nonisolated private static func dailyMeans(_ samples: [(start: Date, value: Double)],
                                               scale: Double) -> [(day: Date, value: Double)] {
        let byDay = Dictionary(grouping: samples) { Calendar.current.startOfDay(for: $0.start) }
        return byDay.map { (day, rows) in
            (day: day, value: rows.reduce(0.0) { $0 + $1.value * scale } / Double(rows.count))
        }
    }

    /// Latest night's signed skin-temp offset from the rolling baseline (#69), or nil.
    nonisolated private static func skinTempOffset(_ nights: [(night: Date, skinTempC: Double)]) -> Double? {
        let valid = nights.filter { $0.skinTempC > 0 }
        guard let latest = valid.max(by: { $0.night < $1.night }) else { return nil }
        let cal = Calendar.current
        let tonightDay = cal.startOfDay(for: latest.night)
        let prior = valid
            .filter { cal.startOfDay(for: $0.night) != tonightDay }
            .map { SkinTempBaseline.NightlyTemp(night: $0.night, celsius: $0.skinTempC) }
        guard let baseline = SkinTempBaseline.baseline(priorNights: prior) else { return nil }
        return latest.skinTempC - baseline
    }

    // MARK: Presentation

    private var statusColor: Color {
        guard let status = report?.status else { return .green }
        switch status {
        case .anomaly: return .red
        case .watch: return .orange
        case .normal: return .green
        }
    }

    @ViewBuilder private func statusBadge(_ status: VitalsBaseline.Status) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .normal: return ("Normal", .green)
            case .watch: return ("Watch", .orange)
            case .anomaly: return ("Anomaly", .red)
            }
        }()
        Text(label.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func signalRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for severity: VitalsBaseline.Severity) -> Color {
        severity == .significant ? .red : .orange
    }

    private func icon(for signal: VitalsBaseline.Signal) -> String {
        if signal.isTemperature { return "thermometer.medium" }
        switch signal.vital {
        case .restingHR: return "heart.fill"
        case .overnightSpO2: return "lungs.fill"
        case .overnightHRV: return "waveform.path.ecg"
        case .none: return "exclamationmark.circle"
        }
    }

    private func title(for signal: VitalsBaseline.Signal) -> String {
        let dir = signal.direction == .rise ? "elevated" : "low"
        let sev = signal.severity == .significant ? "Significant" : "Minor"
        if signal.isTemperature {
            return "\(sev) skin-temperature change (\(signal.direction == .rise ? "rise" : "drop"))"
        }
        switch signal.vital {
        case .restingHR: return "\(sev) resting heart rate (\(dir))"
        case .overnightSpO2: return "\(sev) overnight SpO₂ (\(dir))"
        case .overnightHRV: return "\(sev) overnight HRV (\(dir))"
        case .none: return "\(sev) deviation"
        }
    }

    private func detail(for signal: VitalsBaseline.Signal) -> String {
        if signal.isTemperature {
            // Skin-temp delta in the user's chosen unit (a delta scales by 9/5 with no +32 offset).
            let unit = TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius
            return "\(UnitsFormatter.temperatureDelta(signal.delta, unit: unit)) vs your baseline."
        }
        guard let base = signal.baselineMean else { return "Outside your usual range." }
        switch signal.vital {
        case .restingHR: return String(format: "%+.0f bpm vs your ~%.0f bpm baseline.", signal.delta, base)
        case .overnightSpO2: return String(format: "%+.0f%% vs your ~%.0f%% baseline.", signal.delta, base)
        case .overnightHRV: return String(format: "%+.0f ms vs your ~%.0f ms baseline.", signal.delta, base)
        case .none: return "Outside your usual range."
        }
    }
}
