import SwiftUI

struct CalibrationSessionView: View {
    @ObservedObject var manager: CalibrationSessionManager
    let session: RingSession?
    @Environment(\.dismiss) private var dismiss

    @State private var spO2Input = ""
    @State private var sbpInput = ""
    @State private var dbpInput = ""
    @State private var selectedDuration: TimeInterval = 90

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch manager.step {
                    case .idle:
                        idleView
                    case .spO2Reference:
                        spO2View
                    case .bloodPressure:
                        bloodPressureView
                    case .ppgCapture(let remaining):
                        ppgCaptureView(remaining: remaining)
                    case .appleWatchECG:
                        appleWatchECGView
                    case .uploading:
                        ProgressView("Uploading calibration session...")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .complete(let id):
                        completeView(sessionID: id)
                    case .failed(let message):
                        failureView(message: message)
                    }

                    if !manager.statusMessage.isEmpty {
                        Text(manager.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(manager.step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .ppgCapture = manager.step {
                        EmptyView()
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            infoBox(title: "What this session does", items: [
                "Records a reference SpO2 reading",
                "Collects 1 to 3 cuff blood-pressure readings",
                "Captures 60 to 180 seconds of raw ring PPG",
                "Optionally reads a recent Apple Watch ECG",
                "Uploads calibration inputs to the local server",
            ])

            VStack(alignment: .leading, spacing: 6) {
                Text("Capture duration")
                    .font(.caption.weight(.medium))
                Picker("Duration", selection: $selectedDuration) {
                    Text("60 s").tag(TimeInterval(60))
                    Text("90 s").tag(TimeInterval(90))
                    Text("120 s").tag(TimeInterval(120))
                    Text("180 s").tag(TimeInterval(180))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal)

            Button {
                manager.beginSession(duration: selectedDuration)
            } label: {
                Label("Begin calibration session", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Text("Keep the ring connected, worn snugly, and make sure the local calibration server is reachable before you start.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private var spO2View: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(number: 1, title: "SpO2 reference", detail: "Use the most recent Apple Health blood-oxygen value or type the ring reading manually.")

            if let ref = manager.session.refSpO2 {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("SpO2: \(ref)%").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Change") {
                        spO2Input = "\(ref)"
                        manager.session.refSpO2 = nil
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)

                Button {
                    manager.recordSpO2Reference(ref)
                } label: {
                    Label("Use \(ref)% and continue", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            } else {
                HStack(spacing: 10) {
                    TextField("SpO2 %", text: $spO2Input)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("Confirm") {
                        if let value = Int(spO2Input), (70...100).contains(value) {
                            manager.recordSpO2Reference(value)
                            spO2Input = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(Int(spO2Input).map { !(70...100).contains($0) } ?? true)
                    Button("Re-fetch") {
                        Task { await manager.autoFetchSpO2FromHealthKit() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                .padding(.horizontal)
            }
        }
    }

    private var bloodPressureView: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(number: 2, title: "Cuff blood pressure", detail: "Sit quietly, keep the same posture, and enter one to three cuff readings before capturing PPG.")

            infoBox(title: "Protocol", items: [
                "Rest quietly for 5 minutes before the first reading",
                "Take reading 1, wait 1 minute, then readings 2 and 3 if available",
                "Keep the same posture for the following PPG capture",
            ])

            if !manager.session.bpReadings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.session.bpReadings.indices, id: \.self) { index in
                        let reading = manager.session.bpReadings[index]
                        HStack {
                            Text("Reading \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 74, alignment: .leading)
                            Text("\(reading.sbp) / \(reading.dbp) mmHg")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                            Spacer()
                            Button {
                                manager.removeBPReading(at: index)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .padding(.horizontal)
            }

            if manager.session.bpReadings.count < 3 {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Systolic", text: $sbpInput)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Text("/")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    TextField("Diastolic", text: $dbpInput)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        if let sbp = Int(sbpInput), let dbp = Int(dbpInput),
                           (70...250).contains(sbp), (40...150).contains(dbp), sbp > dbp {
                            manager.addBPReading(sbp: sbp, dbp: dbp)
                            sbpInput = ""
                            dbpInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddBloodPressure)
                }
                .padding(.horizontal)
            }

            Button {
                manager.startPPGCapture(session: session)
            } label: {
                Label("Start raw PPG capture", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .disabled(session?.ready != true || manager.session.bpReadings.isEmpty)
        }
    }

    private func ppgCaptureView(remaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(number: 3, title: "Raw PPG capture", detail: "Keep still. The ring is streaming raw optical frames for calibration.")

            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: Double(max(remaining, 0)), total: selectedDuration)
                HStack {
                    stat(title: "Time left", value: "\(remaining)s")
                    stat(title: "Frames", value: "\(manager.ppgFrameCount)")
                    stat(title: "Samples", value: "\(manager.ppgFrameCount * 25)")
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }

    private var appleWatchECGView: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(number: 4, title: "Apple Watch ECG", detail: "Optional. Record a 30-second ECG on the watch, then import it for pulse-transit-time calibration.")

            infoBox(title: "Why add ECG?", items: [
                "PPG morphology alone can estimate blood pressure",
                "ECG R-peaks provide a stronger timing signal for the DBP path",
                "If you do not have a recent watch ECG, you can skip this step",
            ])

            if let hr = manager.session.appleWatchHRBpm {
                Text("Apple Watch HR during capture: \(Int(hr.rounded())) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if !manager.ecgAvailable {
                Label("Apple Watch ECG not available on this device", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Button {
                manager.fetchAppleWatchECGAndUpload()
            } label: {
                Label("Read ECG from Health and upload", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .disabled(!manager.ecgAvailable)

            Button {
                manager.skipAppleWatchECG()
            } label: {
                Label("Skip ECG and upload PPG only", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
        }
    }

    private func completeView(sessionID: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Calibration session uploaded", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .padding(.horizontal)
            infoBox(title: "Collected inputs", items: summaryItems)
            VStack(alignment: .leading, spacing: 6) {
                Text("Next on desktop")
                    .font(.caption.weight(.medium))
                Text("python spo2_calibrator.py --all-sessions")
                Text("python bp_estimator.py \(sessionID)")
                Text("python bp_calibration.py --all")
            }
            .font(.caption.monospaced())
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
            Text("PPG session: \(sessionID)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private func failureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Calibration failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .padding(.horizontal)
            Text(message)
                .font(.subheadline)
                .padding(.horizontal)
            // #138: if the user already entered cuff readings (i.e. they failed at/after PPG capture),
            // offer a "Try again" that returns to the capture step with those readings intact instead
            // of forcing a full restart. "Start over" (fresh session) stays available as a secondary.
            if !manager.session.bpReadings.isEmpty {
                Button("Try again") {
                    manager.retryCapture()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                Button("Start over") {
                    manager.step = .idle
                    manager.statusMessage = ""
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            } else {
                Button("Start over") {
                    manager.step = .idle
                    manager.statusMessage = ""
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
        }
    }

    private var canAddBloodPressure: Bool {
        guard let sbp = Int(sbpInput), let dbp = Int(dbpInput) else { return false }
        return (70...250).contains(sbp) && (40...150).contains(dbp) && sbp > dbp
    }

    private var summaryItems: [String] {
        var items: [String] = []
        if let spO2 = manager.session.refSpO2 { items.append("SpO2 reference: \(spO2)%") }
        if !manager.session.bpReadings.isEmpty {
            items.append("BP readings: " + manager.session.bpReadings.map { "\($0.sbp)/\($0.dbp)" }.joined(separator: ", "))
        }
        items.append("PPG frames: \(manager.ppgFrameCount)")
        if let hr = manager.session.appleWatchHRBpm {
            items.append("Apple Watch HR: \(Int(hr.rounded())) bpm")
        }
        if manager.session.ecgVoltages != nil {
            items.append("Apple Watch ECG imported")
        }
        return items
    }

    private func stepHeader(number: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func infoBox(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(item)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
