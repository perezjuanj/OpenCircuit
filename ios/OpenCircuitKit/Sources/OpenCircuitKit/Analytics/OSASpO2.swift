import Foundation

/// OSA dense-PPG SpO₂ analyzer (#91) — the Swift port of the desktop pipeline
/// (`desktop/opencircuit/osa_ppg.py` + `osa_spo2_fd.py` + `osa_metrics.py`), which
/// reproduces the RingConn app's 3-night comprehensive-assessment SpO₂ **average to
/// ±1 %** and the **nadir to ±3 %** (see `docs/RUNBOOK_OSA_APNEA.md`).
///
/// This is the HIGH-FIDELITY tier: the ring's own per-epoch SpO₂ from the coarse `0x4c`
/// BulkSleep stream already reaches HealthKit (`BulkSleep.samples`), but its 2.5-min
/// sampling misses the brief desaturation nadirs that drive ODI/AHI. The `0x48` dense
/// waveform (~4.15 Hz/channel) is the substrate for real event detection.
///
/// Chain: `0x48` frames → dedupe by counter → 3 PPG channels (IR=ch0, Red=ch1, Green=ch2)
/// → per-window frequency-domain ratio-of-ratios → `SpO₂ = A − B·R`.
///
/// Everything here is pure/deterministic and unit-tested on macOS against golden vectors
/// exported from the desktop pipeline. It writes nothing and touches no I/O.
///
/// ⚠️ Event metrics (`timeBelow90`, `odi`) are ESTIMATES: reproducing the app's exact
/// numbers needs its proprietary artifact-rejection + event-scoring (partly cloud-side).
/// Label them EXPERIMENTAL at every display/write site. `averageSpO2` is the validated one.
public enum OSAWaveform {

    /// Full `0x48` notification length: `[0x48]` opcode + 13-B header + 182-B payload + XOR.
    public static let frameLength = 197
    public static let opcode: UInt8 = 0x48

    /// Samples per channel in one frame (60 samples / 3 channels).
    public static let samplesPerChannelPerFrame = 20

    /// Decode `0x48` frames into 3 continuous PPG channels `[ch0(IR), ch1(Red), ch2(Green)]`.
    ///
    /// - Dedupes by the 4-byte counter (`frame[2..5]`): the morning store-and-forward burst
    ///   retransmits ~1900 duplicate frames/night (counter steps −20 = 20 samples/ch, ≈0 %
    ///   true loss). First occurrence of each counter wins.
    /// - Orders by descending counter = chronological (the counter counts DOWN over the night).
    /// - Payload = `[marker][30 samples][marker][30 samples]`; samples are 3-byte big-endian,
    ///   3 LEDs interleaved by `index % 3`. Markers at `frame[14]` and `frame[105]`.
    ///
    /// Frames from a different night's session (a re-dumped backlog) are the caller's concern —
    /// filter by session cursor (`frame[6..9]`) upstream before calling if mixing is possible.
    public static func channels(from frames: [[UInt8]]) -> [[Int]] {
        var byCounter = [UInt32: [[Int]]]()
        for f in frames {
            guard f.count >= frameLength, f[0] == opcode else { continue }
            let counter = UInt32(f[2]) << 24 | UInt32(f[3]) << 16 | UInt32(f[4]) << 8 | UInt32(f[5])
            if byCounter[counter] != nil { continue }
            var ch: [[Int]] = [[], [], []]
            for blk in [15, 106] {                       // first-sample index of each 30-sample block
                for s in 0 ..< 30 {
                    let i = blk + s * 3
                    ch[s % 3].append(Int(f[i]) << 16 | Int(f[i + 1]) << 8 | Int(f[i + 2]))
                }
            }
            byCounter[counter] = ch
        }
        var out: [[Int]] = [[], [], []]
        for c in byCounter.keys.sorted(by: >) {          // descending counter = chronological
            let ch = byCounter[c]!
            for k in 0 ..< 3 { out[k].append(contentsOf: ch[k]) }
        }
        return out
    }

    /// The 4-byte session cursor of a `0x48` frame (`frame[6..9]`) — distinct per night; use it
    /// to drop a re-dumped previous-night backlog before `channels(from:)`.
    public static func sessionCursor(of frame: [UInt8]) -> UInt32? {
        guard frame.count >= frameLength, frame[0] == opcode else { return nil }
        return UInt32(frame[6]) << 24 | UInt32(frame[7]) << 16 | UInt32(frame[8]) << 8 | UInt32(frame[9])
    }

    /// Keep only the frames of the MODAL (most frequent) session cursor — this night's burst.
    /// A morning store-and-forward dump can re-emit a previous night's session verbatim; taking
    /// the dominant cursor isolates the current night so `channels(from:)` doesn't concatenate two
    /// nights (which would corrupt the SpO₂ series). Frames without a valid cursor are dropped.
    public static func dominantSessionFrames(_ frames: [[UInt8]]) -> [[UInt8]] {
        var counts = [UInt32: Int]()
        for f in frames { if let c = sessionCursor(of: f) { counts[c, default: 0] += 1 } }
        guard let modal = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        return frames.filter { sessionCursor(of: $0) == modal }
    }
}

public enum OSASpO2 {

    // MARK: Calibration (3-night least-squares on avg+nadir anchors — RUNBOOK_OSA_APNEA.md)
    /// `SpO₂ = calA − calB · R`. A 2-parameter fit; re-fit when more labeled nights land.
    public static let calA = 104.91
    public static let calB = 15.18

    /// Nominal sample rate (Hz/channel), pulse-anchored: median cardiac f\* ⇒ 47–49 bpm,
    /// matches the `0x4c` HR and osa4's 7.05 h = its ground-truth duration. Used only for the
    /// time axis of `timeBelow90`/`odi`; SpO₂ values are rate-independent.
    public static let sampleRateHz = 4.15

    // MARK: Frequency-domain search band (cycles/sample) for the cardiac peak
    public static let fMin = 0.10
    public static let fMax = 0.40
    public static let freqCount = 60
    public static let freqs: [Double] = (0 ..< freqCount).map {
        fMin + (fMax - fMin) * Double($0) / Double(freqCount - 1)
    }

    // MARK: Windowing + gating
    public static let windowLength = 128          // ~30 s at 4.15 Hz
    public static let windowStep = 64
    public static let snrIRFloor = 5.0            // IR pulse SNR floor (kills the fake-low artifact)
    public static let snrOtherFloor = 4.0         // red & green floors
    public static let piIRFloorPercent = 0.15     // low perfusion ⇒ AC_ir tiny ⇒ R unreliable

    /// `|DFT|` amplitude at normalized frequency `f` (cycles/sample), mean-removed (Goertzel).
    public static func goertzelMagnitude(_ x: [Double], _ f: Double) -> Double {
        let n = x.count
        guard n > 0 else { return 0 }
        let mean = x.reduce(0, +) / Double(n)
        let w = 2 * Double.pi * f
        let cr = cos(w), ci = sin(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = (v - mean) + 2 * cr * s1 - s2
            s2 = s1; s1 = s0
        }
        let re = s1 - s2 * cr
        let im = s2 * ci
        return (re * re + im * im).squareRoot() * 2 / Double(n)
    }

    private static func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }

    private static func median(_ x: [Double]) -> Double {
        let s = x.sorted()
        let n = s.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private static func bandAmplitudes(_ w: [Double]) -> [Double] { freqs.map { goertzelMagnitude(w, $0) } }

    /// Ratio-of-ratios `R = (AC_red/DC_red)/(AC_ir/DC_ir)` for ONE window, ungated (nil if DC≤0).
    /// Locks the cardiac frequency on the green channel. Exposed for golden-vector testing.
    public static func windowRatio(ir: [Double], red: [Double], green: [Double]) -> Double? {
        let dci = mean(ir), dcr = mean(red)
        guard dci > 0, dcr > 0 else { return nil }
        let ampg = bandAmplitudes(green)
        guard let fi = ampg.indices.max(by: { ampg[$0] < ampg[$1] }) else { return nil }
        let fstar = freqs[fi]
        let aci = goertzelMagnitude(ir, fstar)
        let acr = goertzelMagnitude(red, fstar)
        guard aci > 0 else { return nil }
        return (acr / dcr) / (aci / dci)
    }

    /// Calibrated, clamped SpO₂ for a ratio `R`.
    public static func spo2(fromRatio R: Double) -> Double { Swift.min(100.0, calA - calB * R) }

    /// Gated per-window SpO₂ series across the night (chronological). Each element is a
    /// calibrated, clamped SpO₂ at ~`windowStep`/`sampleRateHz` s spacing. Windows without a
    /// clean pulse in all three channels, or with IR perfusion below `piIRFloorPercent`, are
    /// dropped (unreliable R) — mirroring how clinical oximeters flag low-perfusion readings.
    public static func spo2Series(ir: [Int], red: [Int], green: [Int]) -> [Double] {
        let n = min(ir.count, red.count, green.count)
        guard n >= windowLength else { return [] }
        var out: [Double] = []
        var a = 0
        while a + windowLength <= n {
            defer { a += windowStep }
            let wi = ir[a ..< a + windowLength].map(Double.init)
            let wr = red[a ..< a + windowLength].map(Double.init)
            let wg = green[a ..< a + windowLength].map(Double.init)
            let dci = mean(wi), dcr = mean(wr)
            guard dci > 0, dcr > 0 else { continue }
            let ampg = bandAmplitudes(wg)
            guard let fi = ampg.indices.max(by: { ampg[$0] < ampg[$1] }) else { continue }
            let fstar = freqs[fi]
            let medg = median(ampg)
            let si = goertzelMagnitude(wi, fstar) / (median(bandAmplitudes(wi)) + 1e-9)
            let sr = goertzelMagnitude(wr, fstar) / (median(bandAmplitudes(wr)) + 1e-9)
            let sg = ampg[fi] / (medg + 1e-9)
            guard si >= snrIRFloor, sr >= snrOtherFloor, sg >= snrOtherFloor else { continue }
            let aci = goertzelMagnitude(wi, fstar)
            let pii = aci / dci
            guard pii * 100 >= piIRFloorPercent else { continue }
            let R = (goertzelMagnitude(wr, fstar) / dcr) / pii
            guard R > 0.1, R < 2.5 else { continue }
            out.append(spo2(fromRatio: R))
        }
        return out
    }

    /// Centered median filter (odd window `k`), edge-clamped. Used to reject single-window
    /// spikes before taking extremes.
    public static func medianFilter(_ x: [Double], _ k: Int) -> [Double] {
        guard k > 1, !x.isEmpty else { return x }
        let n = x.count, h = k / 2
        return (0 ..< n).map { i in median(Array(x[Swift.max(0, i - h) ..< Swift.min(n, i + h + 1)])) }
    }

    /// A night's SpO₂ summary. `averageSpO2` is the validated metric; the rest are ESTIMATES.
    public struct NightSummary: Equatable, Sendable {
        public let averageSpO2: Double
        public let minSpO2: Double
        public let timeBelow90Seconds: Double
        public let odi: Double                 // desaturation events / hour
        public let validWindows: Int
        public let durationHours: Double
    }

    /// Oxygen Desaturation Index: count dips ≥ `dropPercent` below a rolling baseline that then
    /// recover, with a refractory gap. ESTIMATE (coarse vs the app's event scorer).
    public static func desaturationEvents(_ spo2: [Double],
                                          dropPercent: Double = 3.0,
                                          baselineWindow: Int = 20,
                                          refractory: Int = 4) -> Int {
        let n = spo2.count
        guard n > 0 else { return 0 }
        let base = medianFilter(spo2, baselineWindow)
        var events = 0, i = 0
        while i < n {
            if spo2[i] <= base[i] - dropPercent {
                var j = i
                while j < n && spo2[j] <= base[i] - 1.0 { j += 1 }   // extend until near-recovery
                events += 1
                i = j + refractory
            } else {
                i += 1
            }
        }
        return events
    }

    /// Full night summary directly from a collected `0x48` burst: isolate this night's session,
    /// decode channels, summarize. Returns nil if there aren't enough clean windows. This is the
    /// single entry point the BLE handler calls once a burst completes.
    public static func summarize(frames: [[UInt8]], hz: Double = sampleRateHz) -> NightSummary? {
        let night = OSAWaveform.dominantSessionFrames(frames)
        guard !night.isEmpty else { return nil }
        let ch = OSAWaveform.channels(from: night)
        return summarize(ir: ch[0], red: ch[1], green: ch[2], hz: hz)
    }

    /// Full night summary from decoded channels. `hz` sets the time axis for the event metrics.
    public static func summarize(ir: [Int], red: [Int], green: [Int],
                                 hz: Double = sampleRateHz) -> NightSummary? {
        let series = medianFilter(spo2Series(ir: ir, red: red, green: green), 3)  // ~45 s smoothing
        guard !series.isEmpty else { return nil }
        let totalSamples = min(ir.count, red.count, green.count)
        let durationHours = Double(totalSamples) / hz / 3600
        let secPerWindow = Double(windowStep) / hz
        let below90 = series.filter { $0 < 90 }.count
        let odi = durationHours > 0 ? Double(desaturationEvents(series)) / durationHours : 0
        return NightSummary(
            averageSpO2: mean(series),
            minSpO2: series.min() ?? 0,
            timeBelow90Seconds: Double(below90) * secPerWindow,
            odi: odi,
            validWindows: series.count,
            durationHours: durationHours)
    }
}
