import XCTest
@testable import OpenCircuitKit

/// Golden vectors exported from the validated desktop pipeline
/// (`desktop/opencircuit/osa_ppg.py` + `osa_spo2_fd.py`), so the Swift port is provably
/// equivalent. Real `0x48` frames are from `captures/osa4_decoded.txt`.
final class OSASpO2Tests: XCTestCase {

    func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real 0x48 frame (full notification = opcode 0x48 + 196 B). counter 88940, cursor 0x0c43adeb.
    let frame0 = "48" +
        "c100015b6c0c43adeb004650005b056740046446042c12056bb90465dd042e880555c70462d1042c8c05" +
        "4ce504636a042d4a054a1d0463a7042e1d054a8f04645e042f40054d0c0465580430b6054dad04640404" +
        "3047052b09045fe0042c08052b63045fe8042c6d5c052a78045fb0042c96052eb704606a042dcc05324a" +
        "0460e9042f7305164f045c03042b240517c6045abc042a9c05196f045a27042a92052014045ae3042bd6" +
        "052774045c0e042dc5051726045829042aad05179e0456580428c3fd"
    let frame1 = "48" +
        "c100015b580c43adeb00465fa05e051ef80455ee04291405282f04563c042a0105334b0456f4042b5b05" +
        "28530452150426f0052f8704506e0425d20536d4044fa50425be054005044fcc0426f80545c2044e0a04" +
        "26db05397b0449090423740540670447fe0424e95d05464c0447f70426a1054dbc0448e0042904053d3a" +
        "0443f104259a0538a904416e0424e505399204419a0425f1053d5c04438c0427a80540e0044517042926" +
        "05254f0440340423710521d7043f0f04229305214d043ead0422755b"

    // MARK: frame decode (GOLDEN 1)

    func testFrameDecodeChannels() {
        let ch = OSAWaveform.channels(from: [hex(frame0)])
        XCTAssertEqual(ch[0].count, 20)   // 20 samples/channel/frame
        XCTAssertEqual(Array(ch[0].prefix(6)), [354112, 355257, 349639, 347365, 346653, 346767]) // IR
        XCTAssertEqual(Array(ch[1].prefix(6)), [287814, 288221, 287441, 287594, 287655, 287838]) // Red
        XCTAssertEqual(Array(ch[2].prefix(6)), [273426, 274056, 273548, 273738, 273949, 274240]) // Green
    }

    func testDedupeByCounterAndChronologicalOrder() {
        // frame0 counter 88940 > frame1 counter 88920; chronological = descending counter,
        // so frame0's samples come first. Duplicate frame0 is dropped.
        let ch = OSAWaveform.channels(from: [hex(frame0), hex(frame1), hex(frame0)])
        XCTAssertEqual(ch[0].count, 40, "two unique frames × 20 samples/ch (dup dropped)")
        XCTAssertEqual(ch[0][0], 354112, "higher counter (earlier) first")
    }

    func testRejectsWrongOpcodeAndShortFrames() {
        XCTAssertTrue(OSAWaveform.channels(from: [hex("4c00")]).allSatisfy(\.isEmpty))
        var short = hex(frame0); short.removeLast(50)
        XCTAssertTrue(OSAWaveform.channels(from: [short]).allSatisfy(\.isEmpty))
    }

    func testSessionCursor() {
        XCTAssertEqual(OSAWaveform.sessionCursor(of: hex(frame0)), 0x0c43adeb)
    }

    func testDominantSessionFilterIsolatesOneNight() {
        // frame0 + frame1 share cursor 0x0c43adeb; forge one frame of a different night.
        var other = hex(frame0)
        other[6] = 0x0c; other[7] = 0x44; other[8] = 0xf9; other[9] = 0x2a   // cursor 0x0c44f92a
        let kept = OSAWaveform.dominantSessionFrames([hex(frame0), hex(frame1), other])
        XCTAssertEqual(kept.count, 2, "modal cursor 0x0c43adeb wins; the lone other-night frame is dropped")
        XCTAssertTrue(kept.allSatisfy { OSAWaveform.sessionCursor(of: $0) == 0x0c43adeb })
    }

    func testSummarizeFramesInsufficientReturnsNil() {
        XCTAssertNil(OSASpO2.summarize(frames: []))
        // two frames = 40 samples/ch < one 128-sample window -> no series -> nil
        XCTAssertNil(OSASpO2.summarize(frames: [hex(frame0), hex(frame1)]))
    }

    // MARK: Goertzel (GOLDEN 2)

    func testGoertzelMatchesDesktop() {
        // Python: A=1000, f=0.2, N=128 -> goertzel_mag = 1003.8800
        let sig = (0 ..< 128).map { 1000.0 * cos(2 * Double.pi * 0.2 * Double($0)) }
        XCTAssertEqual(OSASpO2.goertzelMagnitude(sig, 0.2), 1003.88, accuracy: 0.05)
    }

    func testGoertzelZeroOnFlat() {
        XCTAssertEqual(OSASpO2.goertzelMagnitude([Double](repeating: 500, count: 128), 0.2),
                       0, accuracy: 1e-6)
    }

    // MARK: ratio-of-ratios + calibration (GOLDEN 3)

    func testWindowRatioAnalytic() {
        // R = (AC_red/DC_red)/(AC_ir/DC_ir). Leakage at the locked fstar cancels in the ratio,
        // so R is exact: (120/8000)/(100/10000) = 1.5.
        let f = OSASpO2.freqs[20]
        let ir  = (0 ..< 128).map { 10000.0 + 100 * cos(2 * Double.pi * f * Double($0)) }
        let red = (0 ..< 128).map { 8000.0 + 120 * cos(2 * Double.pi * f * Double($0)) }
        let grn = (0 ..< 128).map { 5000.0 + 200 * cos(2 * Double.pi * f * Double($0)) }
        let R = OSASpO2.windowRatio(ir: ir, red: red, green: grn)
        XCTAssertNotNil(R)
        XCTAssertEqual(R!, 1.5, accuracy: 0.01)
    }

    func testCalibrationCurve() {
        // Desktop golden: R=0.63281 -> 104.91 - 15.18*0.63281 = 95.304
        XCTAssertEqual(OSASpO2.spo2(fromRatio: 0.63281), 95.304, accuracy: 0.005)
        XCTAssertEqual(OSASpO2.spo2(fromRatio: 1.5), 82.14, accuracy: 0.005)
        XCTAssertEqual(OSASpO2.spo2(fromRatio: 0.2), 100.0, accuracy: 1e-9, "clamped ≤ 100")
    }

    // MARK: metrics

    func testDesaturationEventCount() {
        // flat 97 with two clean dips to 85 -> 2 events
        var s = [Double](repeating: 97, count: 60)
        for i in 10 ..< 13 { s[i] = 85 }
        for i in 40 ..< 43 { s[i] = 85 }
        XCTAssertEqual(OSASpO2.desaturationEvents(s), 2)
    }

    func testMedianFilterRejectsSpike() {
        var s = [Double](repeating: 96, count: 11)
        s[5] = 70                                   // single-window artifact spike
        let f = OSASpO2.medianFilter(s, 3)
        XCTAssertEqual(f[5], 96, "median filter removes the lone spike")
    }

    func testSummarizeOnCleanDesaturatedSignal() {
        // Constant R=1.5 signal -> every window SpO2 = 82.14; all windows pass the gates
        // (PI_ir = 100/10000 = 1% > 0.15%, high SNR clean pulse).
        let f = OSASpO2.freqs[20]
        let n = 400
        let ir  = (0 ..< n).map { Int(10000.0 + 100 * cos(2 * Double.pi * f * Double($0))) }
        let red = (0 ..< n).map { Int(8000.0 + 120 * cos(2 * Double.pi * f * Double($0))) }
        let grn = (0 ..< n).map { Int(5000.0 + 200 * cos(2 * Double.pi * f * Double($0))) }
        let summary = OSASpO2.summarize(ir: ir, red: red, green: grn)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary!.averageSpO2, 82.14, accuracy: 0.2)
        XCTAssertGreaterThan(summary!.validWindows, 0)
    }
}
