import SwiftUI
import OpenCircuitKit

/// "Heart Rate Zones" (decision 83, #338): where the five zones start, with the ranges shown live as
/// the choices are edited. Everything that classifies a heart rate reads the same stored choices
/// (`HeartRateZoneDefaults`); this screen only edits them.
struct HeartRateZonesSettingsView: View {
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage(HeartRateZoneDefaults.methodKey) private var methodRaw = HeartRateZoneMethod.percentOfMax.rawValue
    @AppStorage(HeartRateZoneDefaults.manualMaxHRKey) private var manualMaxHR = 0
    @AppStorage(HeartRateZoneDefaults.customBoundsKey) private var customText = ""

    /// Editing buffers. A half-typed max HR or an out-of-order custom set is never stored: the stored
    /// value is always one a zone surface can use, and the buffers drive the preview.
    @State private var useManualMax = false
    @State private var manualText = ""
    @State private var customDraft = HeartRateZoneSettings.defaultCustomLowerBounds
    @State private var restingHR: Double?
    @State private var seeded = false

    private var method: HeartRateZoneMethod { HeartRateZoneMethod(rawValue: methodRaw) ?? .percentOfMax }

    private var manualValue: Int? {
        guard useManualMax, let n = Int(manualText.trimmingCharacters(in: .whitespaces)),
              MaxHeartRate.isValidManual(n) else { return nil }
        return n
    }

    /// The max HR text is something to correct: it is typed but not a usable value.
    private var manualIsInvalid: Bool {
        useManualMax && manualValue == nil
    }

    private var customIsInvalid: Bool {
        method == .custom && !HeartRateZones.isValidCustom(customDraft)
    }

    /// What the preview shows: the buffers over the stored choices. An invalid buffer previews as the
    /// fallback it would produce, and says so.
    private var previewZones: HeartRateZones {
        HeartRateZones(
            settings: HeartRateZoneSettings(method: method,
                                            manualMaxHR: useManualMax ? (manualValue ?? storedManual) : nil,
                                            customLowerBounds: customDraft),
            age: max(age, 1), restingHR: restingHR)
    }

    private var storedManual: Int? { MaxHeartRate.isValidManual(manualMaxHR) ? manualMaxHR : nil }

    var body: some View {
        List {
            maxHRSection
            methodSection
            if method == .custom { customSection }
            zonesSection
            Section {
                Text("Zones are used for the live workout screen, the Live Activity, and the time-in-zone bars "
                     + "and training load in workout history. History is worked out again from each workout's "
                     + "heart-rate readings with the zones you have set now. A maximum heart rate you set "
                     + "also replaces 220 minus your age in the calorie, strain and exercise-minute estimates.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Heart Rate Zones")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: seed)
        .task { await loadRestingHR() }
    }

    // MARK: Sections

    private var maxHRSection: some View {
        Section {
            Picker("Maximum heart rate", selection: Binding(
                get: { useManualMax },
                set: { setManual($0) })) {
                Text("Automatic").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            if useManualMax {
                HStack {
                    Text("Maximum")
                    Spacer()
                    TextField("bpm", text: $manualText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .accessibilityLabel("Maximum heart rate in beats per minute")
                        .onChange(of: manualText) { _, _ in storeManual() }
                    Text("bpm").foregroundStyle(.secondary)
                }
                if manualIsInvalid {
                    Text("Enter a whole number from \(MaxHeartRate.manualRange.lowerBound) to \(MaxHeartRate.manualRange.upperBound).")
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                let defaults = ProfileDefaultsStatus.current()
                LabeledContent("220 minus your age",
                               value: "\(MaxHeartRate.automatic(age: age)) bpm")
                if defaults.age {
                    Text("Your age isn't set in Profile, so this uses a default age of \(age).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Maximum heart rate")
        } footer: {
            Text("A rule of thumb, not a measured peak. If you know your own maximum, set it here.")
        }
    }

    private var methodSection: some View {
        Section {
            ForEach(HeartRateZoneMethod.allCases, id: \.self) { option in
                Button {
                    methodRaw = option.rawValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(option)).foregroundStyle(.primary)
                            Text(Self.detail(option)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option == method { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .accessibilityAddTraits(option == method ? .isSelected : [])
            }
        } header: {
            Text("Method")
        }
    }

    private var customSection: some View {
        Section {
            ForEach(0..<5, id: \.self) { index in
                Stepper(value: customBinding(index), in: HeartRateZones.customRange) {
                    LabeledContent("Zone \(index + 1) starts at", value: "\(customDraft[index]) bpm")
                }
            }
            if customIsInvalid {
                Text("Each zone must start higher than the one before it, between \(HeartRateZones.customRange.lowerBound) and \(HeartRateZones.customRange.upperBound) bpm. Your zones keep their last valid values until this is fixed.")
                    .font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Custom zone starts")
        }
    }

    private var zonesSection: some View {
        let zones = previewZones
        return Section {
            ForEach(HRZone.allCases, id: \.rawValue) { zone in
                HStack {
                    Text(zone.displayName)
                    Spacer()
                    Text(zones.rangeText(of: zone)).monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ZoneBarRow.accessibilityLabel(zone: zone, seconds: 0, rangeText: zones.rangeText(of: zone))
                    .replacingOccurrences(of: ", no time", with: ""))
            }
            if let note = zones.fallbackNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Your zones")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum heart rate \(zones.maxHR) bpm"
                     + (zones.method == .percentOfReserve ? ", resting heart rate \(zones.restingHR ?? 0) bpm" : "") + ".")
                Text("A heart rate below Zone 1 is not counted in any zone.")
            }
        }
    }

    // MARK: Editing

    static func title(_ method: HeartRateZoneMethod) -> String {
        switch method {
        case .percentOfMax: return "% of max heart rate"
        case .percentOfReserve: return "% of heart rate reserve"
        case .custom: return "Custom"
        }
    }

    static func detail(_ method: HeartRateZoneMethod) -> String {
        switch method {
        case .percentOfMax: return "Zones start at 50, 60, 70, 80 and 90 % of your maximum."
        case .percentOfReserve:
            return "The same percentages of the range between your resting and maximum heart rate (Karvonen). Uses your resting heart rate from the active device."
        case .custom: return "You choose where each zone starts."
        }
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        useManualMax = storedManual != nil
        manualText = storedManual.map(String.init) ?? ""
        customDraft = HeartRateZoneDefaults.customBounds(customText) ?? HeartRateZoneSettings.defaultCustomLowerBounds
    }

    /// Switching to Manual starts from today's automatic value (kept inside the allowed range), so the
    /// field is never empty; switching back keeps nothing but the Automatic rule.
    private func setManual(_ on: Bool) {
        useManualMax = on
        if on {
            let start = storedManual ?? min(max(MaxHeartRate.automatic(age: age), MaxHeartRate.manualRange.lowerBound),
                                           MaxHeartRate.manualRange.upperBound)
            manualText = String(start)
            manualMaxHR = start
        } else {
            manualMaxHR = 0
        }
    }

    /// Stores the typed max HR only while it is valid.
    private func storeManual() {
        guard useManualMax, let value = manualValue else { return }
        manualMaxHR = value
    }

    private func customBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { customDraft[index] },
            set: { newValue in
                customDraft[index] = newValue
                if HeartRateZones.isValidCustom(customDraft) {
                    customText = HeartRateZoneDefaults.encode(customDraft)
                }
            })
    }

    private func loadRestingHR() async {
        guard let container = OpenCircuitApp.sharedContainer else { return }
        restingHR = await HeartRateZoneRestingHR.latest(container: container, log: LocalStore.ownershipLog())
    }
}

/// The entry point from the zone bars: opens the settings screen in a sheet, so it works wherever the
/// bars are drawn (a workout screen, a workout's detail).
struct HeartRateZonesLink: View {
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Label("Heart Rate Zones", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Shows and edits where each zone starts")
        .sheet(isPresented: $presented) {
            NavigationStack {
                HeartRateZonesSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { presented = false }
                        }
                    }
            }
        }
    }
}
