// Bulk PPG / optical-trend SAMPLE decode (docs/PROTOCOL.md §5.2).
//
// `EpochRecord.parsePPGPage` already splits a `0x47` page into per-record timestamp +
// raw 38-byte payload (`EpochRecord.PPGRecord`) — this file decodes THAT payload into
// actual sample values. Settled offline (#8, closed; `desktop/analyze_0x47_bitwidth.py` /
// `decode_0x47.py`, reproduced across 5 captures): 10-bit big-endian samples, ONE smooth
// optical channel (NOT interleaved red+IR — that earlier claim is retracted), and NOT
// pulse-resolution (0.033Hz — ~50× too slow for a heartbeat). This is a sparse 15-min
// perfusion/optical-amplitude TREND, not a fiducial PPG waveform.
//
// Unconfirmed (would need the app's own exported PPG trace): channel IDENTITY
// (which LED; AC vs DC) and absolute physical units. So this is DIAGNOSTIC ONLY — do
// NOT derive HR/HRV/SpO2 from it, and do NOT write it to HealthKit.

import Foundation

public enum PPGTrend {
    /// Bits per sample (🟢 settled offline — see file header).
    public static let sampleBitWidth = 10
    /// Expected samples per 38-byte payload: 304 bits / 10 = 30, with 4 pad bits dropped.
    public static let expectedSamplesPerRecord = 30

    /// Unpack a `0x47` record's raw payload (`EpochRecord.PPGRecord.rawPayload`, 38 bytes)
    /// into consecutive 10-bit big-endian samples (a trailing partial sample is dropped).
    /// DIAGNOSTIC ONLY — see file header; values are a relative optical trend, not a
    /// calibrated physical reading.
    public static func samples(from rawPayload: Data) -> [Int] {
        var bits = [Int](); bits.reserveCapacity(rawPayload.count * 8)
        for byte in rawPayload {
            for bit in stride(from: 7, through: 0, by: -1) {
                bits.append(Int((byte >> bit) & 1))
            }
        }
        var out = [Int](); out.reserveCapacity(bits.count / sampleBitWidth)
        var i = 0
        while i + sampleBitWidth <= bits.count {
            var v = 0
            for j in 0..<sampleBitWidth { v = (v << 1) | bits[i + j] }
            out.append(v)
            i += sampleBitWidth
        }
        return out
    }

    /// Convenience: decode every record's samples, paired with its already-reconstructed
    /// timestamp.
    public static func samples(from records: [EpochRecord.PPGRecord]) -> [(timestamp: Date, samples: [Int])] {
        records.map { ($0.timestamp, samples(from: $0.rawPayload)) }
    }
}
