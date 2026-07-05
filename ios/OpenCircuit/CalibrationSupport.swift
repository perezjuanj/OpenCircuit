import Combine
import Foundation
import HealthKit
#if canImport(UIKit)
import UIKit
#endif

enum CalibrationDefaults {
    static let baseURLKey = "calibration.baseURL"
    static let apiTokenKey = "calibration.apiToken"
    static let autoWriteBPToHealthKey = "calibration.autoWriteBPToHealth"
    static let lastWrittenBPSessionIDKey = "calibration.lastWrittenBPSessionID"
    static let defaultBaseURL = "http://127.0.0.1:8765"
}

struct PPGRawFrame: Sendable {
    let seq: UInt8
    let wallClockS: Double
    let chA: [Int]
    let chB: [Int]
    let chC: [Int]

    func csvRows(sampleIndexOffset: Int) -> [String] {
        (0..<chA.count).map { i in
            "\(wallClockS),\(seq),\(sampleIndexOffset + i),\(chA[i]),\(chB[i]),\(chC[i]),,,,,,,"
        }
    }
}

struct BPEstimateWindow: Decodable {
    let windowStartS: Double
    let windowEndS: Double
    let sbpMmhg: Double?
    let dbpMmhg: Double?
    let nPulses: Int

    enum CodingKeys: String, CodingKey {
        case windowStartS = "window_start_s"
        case windowEndS = "window_end_s"
        case sbpMmhg = "sbp_mmhg"
        case dbpMmhg = "dbp_mmhg"
        case nPulses = "n_pulses"
    }
}

struct BPEstimateSessionResult: Decodable {
    let sessionID: String
    let nWindows: Int
    let meanSBPMmhg: Double?
    let meanDBPMmhg: Double?
    let minSBPMmhg: Double?
    let maxSBPMmhg: Double?
    let modelID: String?
    let estimatedAt: String?
    let windows: [BPEstimateWindow]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case nWindows = "n_windows"
        case meanSBPMmhg = "mean_sbp_mmhg"
        case meanDBPMmhg = "mean_dbp_mmhg"
        case minSBPMmhg = "min_sbp_mmhg"
        case maxSBPMmhg = "max_sbp_mmhg"
        case modelID = "model_id"
        case estimatedAt = "estimated_at"
        case windows
    }
}

struct CalibrationBPReading {
    var sbp: Int
    var dbp: Int
    var capturedAt: Date = Date()
    var source: String = "manual"
}

struct CalibrationSessionData {
    let sessionID: String
    let startedAt: Date
    var refSpO2: Int?
    var bpReadings: [CalibrationBPReading] = []
    var ppgFrames: [PPGRawFrame] = []
    var ppgCaptureStartedAt: Date?
    var ppgCaptureEndedAt: Date?
    var ppgSessionID: String?
    var ecgVoltages: [Double]?
    var ecgSampleRateHz: Double = 512
    var appleWatchHRBpm: Double?

    func ppgCSV() -> String {
        var lines = ["wall_clock_s,seq,sample_idx,chA_raw,chB_raw,chC_raw,chA_filt,chB_filt,chC_filt,hr_fft_bpm,spo2_pct,contact,saturated"]
        var idx = 0
        for frame in ppgFrames {
            lines.append(contentsOf: frame.csvRows(sampleIndexOffset: idx))
            idx += frame.chA.count
        }
        return lines.joined(separator: "\n")
    }
}

enum CalibrationStep: Equatable {
    case idle
    case spO2Reference
    case bloodPressure
    case ppgCapture(remainingSeconds: Int)
    case appleWatchECG
    case uploading
    case complete(ppgSessionID: String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Calibration"
        case .spO2Reference: return "Step 1 - SpO2 Reference"
        case .bloodPressure: return "Step 2 - Blood Pressure"
        case .ppgCapture: return "Step 3 - PPG Capture"
        case .appleWatchECG: return "Step 4 - Apple Watch ECG"
        case .uploading: return "Uploading"
        case .complete: return "Done"
        case .failed: return "Error"
        }
    }
}

@MainActor
final class CalibrationSessionManager: ObservableObject {
    @Published var step: CalibrationStep = .idle
    @Published var session = CalibrationSessionData(sessionID: UUID().uuidString, startedAt: Date())
    @Published var ppgFrameCount = 0
    @Published var statusMessage = ""
    @Published var ecgAvailable = false
    @Published var latestEstimate: BPEstimateSessionResult?
    @Published var latestEstimateStatus = ""
    @Published var isRefreshingEstimate = false

    private let healthStore = HKHealthStore()
    private let healthWriter = HealthKitWriter()
    private var countdownTimer: Timer?
    private var captureDuration: TimeInterval = 90
    private var lastEstimateRefreshAt: Date?

    private var baseURL: String {
        let value = UserDefaults.standard.string(forKey: CalibrationDefaults.baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : CalibrationDefaults.defaultBaseURL
    }

    private var apiToken: String? {
        let value = UserDefaults.standard.string(forKey: CalibrationDefaults.apiTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var autoWriteBPToHealth: Bool {
        UserDefaults.standard.bool(forKey: CalibrationDefaults.autoWriteBPToHealthKey)
    }

    func beginSession(duration: TimeInterval) {
        session = CalibrationSessionData(sessionID: UUID().uuidString, startedAt: Date())
        ppgFrameCount = 0
        statusMessage = "Checking Apple Health for a recent SpO2 reading..."
        captureDuration = duration
        step = .spO2Reference
        checkECGAvailability()
        Task { await autoFetchSpO2FromHealthKit() }
    }

    func recordSpO2Reference(_ value: Int) {
        session.refSpO2 = value
        step = .bloodPressure
        statusMessage = "Enter at least one cuff reading before capturing raw PPG."
    }

    func addBPReading(sbp: Int, dbp: Int) {
        session.bpReadings.append(CalibrationBPReading(sbp: sbp, dbp: dbp))
        statusMessage = "\(session.bpReadings.count) blood-pressure reading(s) recorded."
    }

    func removeBPReading(at index: Int) {
        guard session.bpReadings.indices.contains(index) else { return }
        session.bpReadings.remove(at: index)
    }

    func autoFetchSpO2FromHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "Apple Health is unavailable. Enter the SpO2 value manually."
            return
        }
        let spo2Type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [spo2Type])
        } catch {
            statusMessage = "Health access failed. Enter the SpO2 value manually."
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-4 * 3600), end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: spo2Type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
                Task { @MainActor [weak self] in
                    guard let self else { continuation.resume(); return }
                    if let sample = (samples as? [HKQuantitySample])?.first {
                        let pct = Int((sample.quantity.doubleValue(for: .percent()) * 100).rounded())
                        if (70...100).contains(pct) {
                            self.session.refSpO2 = pct
                            let ageMinutes = max(Int(Date().timeIntervalSince(sample.endDate) / 60), 0)
                            self.statusMessage = "SpO2 \(pct)% found in Apple Health (\(ageMinutes) min ago)."
                        } else {
                            self.statusMessage = "No usable SpO2 reading found. Enter it manually."
                        }
                    } else {
                        self.statusMessage = "No recent SpO2 reading found. Enter it manually."
                    }
                    continuation.resume()
                }
            }
            healthStore.execute(query)
        }
    }

    func startPPGCapture(session ringSession: RingSession?) {
        guard let ringSession else {
            step = .failed("Connect the ring before starting PPG capture.")
            return
        }
        guard !session.bpReadings.isEmpty else {
            statusMessage = "Enter at least one cuff reading first."
            return
        }

        session.ppgFrames = []
        session.ppgCaptureStartedAt = Date()
        session.ppgCaptureEndedAt = nil
        ppgFrameCount = 0
        let duration = Int(captureDuration.rounded())
        step = .ppgCapture(remainingSeconds: duration)
        statusMessage = "Keep still and let the ring stream raw PPG."
        countdownTimer?.invalidate()
        var remaining = duration
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                remaining = max(remaining - 1, 0)
                self.step = .ppgCapture(remainingSeconds: remaining)
                if remaining == 0 { timer.invalidate() }
            }
        }

        Task {
            do {
                _ = try await ringSession.startPPGCalibrationCapture(duration: captureDuration) { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.session.ppgFrames.append(frame)
                        self.ppgFrameCount += 1
                    }
                }
                countdownTimer?.invalidate()
                session.ppgCaptureEndedAt = Date()
                statusMessage = "PPG capture complete. Reading Apple Watch heart rate..."
                let end = session.ppgCaptureEndedAt ?? Date()
                let start = session.ppgCaptureStartedAt ?? end.addingTimeInterval(-captureDuration)
                await fetchAppleWatchHeartRate(start: start, end: end)
                step = .appleWatchECG
            } catch {
                // #138: stop the wall-clock countdown the instant the capture throws (a mid-capture
                // disconnect resolves the continuation immediately, so the countdown must not run on
                // to 0). The thrown calibration errors are already self-contained, user-facing
                // messages ("Ring disconnected — try again", "The ring streamed too few PPG
                // samples…"), so surface them directly rather than double-wrapping.
                countdownTimer?.invalidate()
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// #138: retry after a mid-capture failure (e.g. the ring dropped during PPG streaming) WITHOUT
    /// discarding the SpO2 reference and cuff readings the user already entered — return to the
    /// blood-pressure step, whose "Start raw PPG capture" button re-runs only the capture once the
    /// ring reconnects. A full reset stays available via "Start over" (→ `.idle`).
    func retryCapture() {
        session.ppgFrames = []
        session.ppgCaptureStartedAt = nil
        session.ppgCaptureEndedAt = nil
        ppgFrameCount = 0
        step = .bloodPressure
        statusMessage = session.bpReadings.isEmpty
            ? "Enter at least one cuff reading before capturing raw PPG."
            : "\(session.bpReadings.count) blood-pressure reading(s) recorded. Tap Start raw PPG capture to try again."
    }

    func skipAppleWatchECG() {
        session.ecgVoltages = nil
        Task { await uploadCalibrationSession() }
    }

    func fetchAppleWatchECGAndUpload() {
        Task {
            statusMessage = "Reading Apple Watch ECG from Health..."
            if let (voltages, rate) = await fetchMostRecentECG(after: Date().addingTimeInterval(-600)) {
                session.ecgVoltages = voltages
                session.ecgSampleRateHz = rate
                statusMessage = "Loaded \(voltages.count) ECG samples."
            } else {
                statusMessage = "No recent Apple Watch ECG found. Uploading PPG only."
            }
            await uploadCalibrationSession()
        }
    }

    func refreshLatestEstimate(force: Bool = false, sessionID: String? = nil) async {
        guard !baseURL.isEmpty else { return }
        guard force || shouldStartEstimateRefresh() else { return }
        isRefreshingEstimate = true
        lastEstimateRefreshAt = Date()
        defer { isRefreshingEstimate = false }
        do {
            let targetSessionID = sessionID ?? session.ppgSessionID ?? "latest"
            let estimate = try await fetchLatestBPEstimate(sessionID: targetSessionID)
            latestEstimate = estimate
            let scope = targetSessionID == "latest" ? "latest saved session" : "session \(estimate.sessionID.prefix(12))"
            latestEstimateStatus = "Updated \(scope) at \(Date.now.formatted(date: .omitted, time: .shortened))"
            await writeEstimateToHealthIfNeeded(estimate)
        } catch {
            latestEstimateStatus = describeEstimateRefreshError(error)
        }
    }

    func refreshLatestEstimateIfNeeded(minInterval: TimeInterval = 15) async {
        let shouldForce = false
        guard minInterval >= 0 else {
            await refreshLatestEstimate(force: shouldForce)
            return
        }
        guard let lastEstimateRefreshAt else {
            await refreshLatestEstimate(force: shouldForce)
            return
        }
        guard Date().timeIntervalSince(lastEstimateRefreshAt) >= minInterval else { return }
        await refreshLatestEstimate(force: shouldForce)
    }

    private func fetchAppleWatchHeartRate(start: Date, end: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [hrType])
        } catch { return }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, samples, _ in
                Task { @MainActor [weak self] in
                    guard let self else { continuation.resume(); return }
                    let unit = HKUnit.count().unitDivided(by: .minute())
                    let values = (samples as? [HKQuantitySample])?.map { $0.quantity.doubleValue(for: unit) } ?? []
                    if !values.isEmpty {
                        self.session.appleWatchHRBpm = values.reduce(0, +) / Double(values.count)
                    }
                    continuation.resume()
                }
            }
            healthStore.execute(query)
        }
    }

    private func checkECGAvailability() {
        guard HKHealthStore.isHealthDataAvailable() else {
            ecgAvailable = false
            return
        }
        let type = HKObjectType.electrocardiogramType()
        let status = healthStore.authorizationStatus(for: type)
        ecgAvailable = status == .sharingAuthorized || status == .notDetermined
    }

    private func fetchMostRecentECG(after date: Date) async -> ([Double], Double)? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let ecgType = HKObjectType.electrocardiogramType()
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [ecgType])
        } catch {
            return nil
        }

        let predicate = HKQuery.predicateForSamples(withStart: date, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: ecgType, predicate: predicate, limit: 1, sortDescriptors: [sort]) { [weak self] _, samples, _ in
                guard let self,
                      let ecg = (samples as? [HKElectrocardiogram])?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let sampleRate = ecg.samplingFrequency?.doubleValue(for: .hertz()) ?? 512
                var voltages: [Double] = []
                let ecgQuery = HKElectrocardiogramQuery(ecg) { _, result in
                    switch result {
                    case .measurement(let measurement):
                        if let voltage = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                            voltages.append(voltage.doubleValue(for: .volt()) * 1000)
                        }
                    case .done:
                        continuation.resume(returning: voltages.isEmpty ? nil : (voltages, sampleRate))
                    case .error:
                        continuation.resume(returning: nil)
                    @unknown default:
                        continuation.resume(returning: nil)
                    }
                }
                self.healthStore.execute(ecgQuery)
            }
            healthStore.execute(query)
        }
    }

    private func uploadCalibrationSession() async {
        guard !session.ppgFrames.isEmpty else {
            step = .failed("No PPG frames were captured.")
            return
        }
        step = .uploading
        statusMessage = "Uploading PPG CSV to the local server..."

        do {
            let csv = session.ppgCSV()
            guard let csvData = csv.data(using: .utf8) else {
                step = .failed("Failed to encode the PPG capture.")
                return
            }

            let ppgSessionID = try await uploadPPGCSV(csvData: csvData, filename: "calibration_\(session.sessionID).csv")
            session.ppgSessionID = ppgSessionID
            if let voltages = session.ecgVoltages {
                try? await uploadECG(voltages: voltages, sampleRateHz: session.ecgSampleRateHz, capturedAt: session.startedAt)
            }
            try? await uploadCalibrationMetadata(ppgSessionID: ppgSessionID)
            step = .complete(ppgSessionID: ppgSessionID)
            statusMessage = "Uploaded calibration session \(ppgSessionID.prefix(12)). Run the desktop estimator for this session, then refresh the estimate."
            await refreshLatestEstimate(force: true, sessionID: ppgSessionID)
        } catch {
            step = .failed("Upload failed: \(error.localizedDescription)")
        }
    }

    private func buildRequest(path: String, method: String = "GET", contentType: String? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else { throw URLError(.badURL) }
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = apiToken { request.setValue(token, forHTTPHeaderField: "X-HealthLocal-Token") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func fetchLatestBPEstimate(sessionID: String) async throws -> BPEstimateSessionResult {
        let path = sessionID == "latest" ? "/ppg/bp_estimate/latest" : "/ppg/sessions/\(sessionID)/bp_estimate"
        let request = try buildRequest(path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
        return try JSONDecoder().decode(BPEstimateSessionResult.self, from: data)
    }

    private func uploadPPGCSV(csvData: Data, filename: String) async throws -> String {
        let boundary = UUID().uuidString
        var request = try buildRequest(path: "/ppg/import", method: "POST", contentType: "multipart/form-data; boundary=\(boundary)")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: text/csv\r\n\r\n".utf8))
        body.append(csvData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["session_id"] as? String ?? session.sessionID
    }

    private func uploadECG(voltages: [Double], sampleRateHz: Double, capturedAt: Date) async throws {
        var request = try buildRequest(path: "/ecg/raw-import", method: "POST", contentType: "application/json")
        let payload: [String: Any] = [
            "source": "AppleWatchECG",
            "recorded_at": ISO8601DateFormatter().string(from: capturedAt),
            "sample_rate_hz": sampleRateHz,
            "lead": "AppleWatchSimilarToLeadI",
            "unit": "mV",
            "voltages": voltages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
    }

    private func uploadCalibrationMetadata(ppgSessionID: String) async throws {
        var request = try buildRequest(path: "/calibration/session", method: "POST", contentType: "application/json")
        var payload: [String: Any] = [
            "ppg_session_id": ppgSessionID,
            "ref_spo2_pct": session.refSpO2 as Any,
            "bp_readings": session.bpReadings.map {
                [
                    "sbp": $0.sbp,
                    "dbp": $0.dbp,
                    "captured_at": ISO8601DateFormatter().string(from: $0.capturedAt),
                    "source": $0.source,
                ]
            },
            "has_ecg": session.ecgVoltages != nil,
            "calibration_id": session.sessionID,
            "captured_at": ISO8601DateFormatter().string(from: session.startedAt),
        ]
        if let ppgStartedAt = session.ppgCaptureStartedAt {
            payload["ppg_capture_started_at"] = ISO8601DateFormatter().string(from: ppgStartedAt)
        }
        if let ppgEndedAt = session.ppgCaptureEndedAt {
            payload["ppg_capture_ended_at"] = ISO8601DateFormatter().string(from: ppgEndedAt)
        }
        if let hr = session.appleWatchHRBpm { payload["aw_hr_bpm"] = hr }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return }
        try validate(response: response)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw CalibrationHTTPError(statusCode: http.statusCode)
        }
    }

    private func writeEstimateToHealthIfNeeded(_ estimate: BPEstimateSessionResult) async {
        guard autoWriteBPToHealth else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: CalibrationDefaults.lastWrittenBPSessionIDKey) != estimate.sessionID else { return }
        guard let sbp = estimate.meanSBPMmhg, let dbp = estimate.meanDBPMmhg else { return }
        let timestamp = estimate.estimatedAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let wrote = await healthWriter.writeBPEstimate(sbp: sbp, dbp: dbp, at: timestamp)
        if wrote {
            defaults.set(estimate.sessionID, forKey: CalibrationDefaults.lastWrittenBPSessionIDKey)
        }
    }

    private func shouldStartEstimateRefresh() -> Bool {
        !isRefreshingEstimate
    }

    private func describeEstimateRefreshError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost:
                return "Calibration server unreachable at \(baseURL). Start the server first."
            case .timedOut:
                return "Calibration server timed out at \(baseURL)."
            case .userAuthenticationRequired:
                return "Calibration server rejected the request. Check the API token."
            default:
                break
            }
        }

        if let http = error as? CalibrationHTTPError {
            switch http.statusCode {
            case 401, 403:
                return "Calibration server rejected the request. Check the API token."
            case 404:
                if let ppgSessionID = session.ppgSessionID {
                    return "No BP estimate stored yet for session \(ppgSessionID.prefix(12)). Run the desktop estimator first."
                }
                return "No saved BP estimate found yet."
            default:
                return "Calibration server returned HTTP \(http.statusCode)."
            }
        }

        return localhostHint("Couldn't refresh the BP estimate.")
    }

    private func localhostHint(_ prefix: String) -> String {
        guard baseURL.contains("127.0.0.1") || baseURL.contains("localhost") else { return prefix }
#if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom != .mac {
            return "\(prefix) On a physical iPhone, replace 127.0.0.1 with your Mac's LAN IP."
        }
#endif
        return "\(prefix) Start the calibration server on this Mac."
    }
}

private struct CalibrationHTTPError: Error {
    let statusCode: Int
}
