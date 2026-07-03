"""
Stage 1 PPG Signal Processing Pipeline — RingConn RSP 0x13.

This module handles everything between raw BLE bytes and clean, analysis-ready
PPG signal. It is designed for both real-time streaming and batch post-processing.

Public API:
    PPGFrame        — one decoded RSP 0x13 frame (raw ADC values)
    ProcessedWindow — one frame's output from the pipeline
    PPGPipeline     — feed_frame() per frame; returns ProcessedWindow list
    BandpassFilter  — reusable causal IIR filter (also has zero-phase class method)
    channel_guess() — returns best available channel identity guess from AC/DC data

Ring-specific constants:
    FS = 25 Hz, FRAME_SIZE = 25 samples, SAT_THRESHOLD = 60000 (uint16 AGC event)
    BP band = 0.5–8 Hz (clinical PPG standard)
"""
from __future__ import annotations
import math
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
from scipy.signal import butter, sosfilt_zi, sosfilt, filtfilt

# ── Ring constants ──────────────────────────────────────────────────────────
FS: float = 25.0
FRAME_SIZE: int = 25
SAT_THRESHOLD: int = 60_000   # chA uint16 values above this → AGC event
CONTACT_MIN_AC_DC_PCT: float = 1.0  # below this AC/DC% → ring not properly worn

# ── Filter constants ────────────────────────────────────────────────────────
BP_LOW_HZ: float = 0.5
BP_HIGH_HZ: float = 8.0
BP_ORDER: int = 4             # 4th-order Butterworth (24 dB/oct rolloff)

# ── SpO2 empirical calibration ──────────────────────────────────────────────
# SpO2 ≈ SPO2_A - SPO2_B * R   where R = (AC_red/DC_red) / (AC_ir/DC_ir)
# chB=RED (660nm), chC=IR (940nm)
#
# Calibration history (Apple Watch Ultra 2 as reference):
#   2026-06-26: AW=98% @ R=0.63 (clean seqs 141-171, chB_DC≈810) → B fitted = 19.05
#   2026-06-27 15:33: AW=97% @ stable seqs 58-86 → ring reported ~100% (formula +3%)
#   2026-06-27 15:35: AW=98% @ seqs 199-203 (contact YES) → ring reported 95-96% (formula -3%)
#   2026-06-27 17:21: AW=98% @ seqs 171-173, chB_DC=683 → ring reported 96.0% (formula -2%)
#                     Note: buffer ~10 frames into recovery; stabilised estimate ≈97% (-1%)
#   2026-06-27 17:35: AW=98% @ seq 151, chB_DC=334, chC_DC=219, ratio=0.65 → ring 97.6% (-0.4%)
#   2026-06-27 18:32: AW=98% @ seqs 104-117, chB_DC=777-780, chC_DC=513-525, ratio≈0.67
#                     ring=98.3-99.7% (mean ≈ +1% above AW). AGC state: RED trending up,
#                     IR trending down, SpO2 reading was rising toward formula overflow.
#
# Observed accuracy: ±0.4-3% across all sessions and AGC states. R is NOT truly AGC-
# independent — chB and chC LED gains are adjusted anti-correlated (boosting one
# suppresses the other), so R shifts with LED balance even at fixed SpO2.
# Constants (A=110, B=19.05) calibrated at chB_DC≈810; accuracy degrades ≈±1%/100-unit
# shift in chB_DC. Two-point SpO2 calibration (at two different SpO2 levels) needed for
# per-AGC-state correction.
SPO2_A: float = 110.0
SPO2_B: float = 19.05


# ── Data structures ─────────────────────────────────────────────────────────

@dataclass
class PPGFrame:
    """One raw RSP 0x13 frame decoded from BLE bytes."""
    seq: int
    chA: list[int]          # uint16, DC positive (~190-540), ~7% AC/DC → GREEN LED (confirmed)
    chB: list[int]          # int16, DC varies with AGC (189-810) → RED 660nm (confirmed by SpO2: R=0.63 → 94%)
    chC: list[int]          # int16, DC varies with AGC (558-936) → IR 940nm (confirmed by SpO2 exclusion)
    wall_time: float = 0.0
    saturated: bool = False  # True if AGC event detected


@dataclass
class ProcessedWindow:
    """Output of PPGPipeline.feed_frame() — one frame's processed data."""
    seq: int
    wall_time: float

    # Raw ADC values (float for uniformity)
    chA_raw: list[float]
    chB_raw: list[float]
    chC_raw: list[float]

    # Bandpass-filtered values (0.5–8 Hz causal IIR)
    chA_filtered: list[float]
    chB_filtered: list[float]
    chC_filtered: list[float]

    # Per-frame statistics
    chA_dc: float
    chA_ac: float           # max - min within 25 samples (heartbeat pulsation)
    chB_dc: float
    chB_ac: float
    chC_dc: float
    chC_ac: float

    hr_fft_bpm: Optional[float]    # None until ≥75 samples accumulated (3s)
    spo2_pct: Optional[float]      # None until ≥10 valid frames; needs channel ID
    contact: bool                  # chA AC/DC ≥ CONTACT_MIN_AC_DC_PCT
    saturated: bool                # True = AGC event; values are interpolated


# ── BandpassFilter ──────────────────────────────────────────────────────────

class BandpassFilter:
    """Causal 4th-order Butterworth bandpass IIR filter.

    Uses SOS (second-order-sections) form for numerical stability.
    Maintains internal state → safe for sample-by-sample or batch real-time use.
    Call feed_batch() for each RSP 0x13 frame; state carries across frames.

    Initialization: on the first call, zi is scaled by x[0] so the filter starts
    at the initial signal level rather than 0 — avoids the large startup transient.
    After that, state is carried forward unchanged between frames.

    For offline batch analysis, use the class method zero_phase().
    """

    def __init__(self, low: float = BP_LOW_HZ, high: float = BP_HIGH_HZ,
                 order: int = BP_ORDER, fs: float = FS):
        self._sos = butter(order, [low, high], btype='band', fs=fs, output='sos')
        self._zi_template: np.ndarray = sosfilt_zi(self._sos)  # shape (n_sections, 2)
        self._zi: Optional[np.ndarray] = None  # None until first feed_batch call

    def feed_batch(self, samples: list[float]) -> list[float]:
        """Filter a batch of samples, maintaining state for continuity across frames."""
        x = np.array(samples, dtype=np.float64)
        if self._zi is None:
            # First call: initialize state to match the current signal level (suppress startup transient)
            self._zi = self._zi_template * x[0]
        y, self._zi = sosfilt(self._sos, x, zi=self._zi)
        return y.tolist()

    def reset(self) -> None:
        """Reset filter state — call after a BLE reconnect to avoid stale state."""
        self._zi = None

    @staticmethod
    def zero_phase(samples: list[float], low: float = BP_LOW_HZ,
                   high: float = BP_HIGH_HZ, order: int = BP_ORDER,
                   fs: float = FS) -> list[float]:
        """Zero-phase filtfilt — NOT causal. Use only for batch/offline analysis."""
        b, a = butter(order, [low, high], btype='band', fs=fs)
        return filtfilt(b, a, np.array(samples, dtype=np.float64)).tolist()


# ── AGCHandler ──────────────────────────────────────────────────────────────

class AGCHandler:
    """Detects AGC saturation events and linearly interpolates over them.

    Observed pattern: ring adjusts LED power ~5× per minute. Each event saturates
    chA (uint16 near 65535) for 1-3 frames. Strategy: buffer saturated frames,
    then linearly interpolate between last-valid and first-post-saturation frame.
    """

    def __init__(self, sat_threshold: int = SAT_THRESHOLD, max_gap_frames: int = 6):
        self._sat_threshold = sat_threshold
        self._max_gap = max_gap_frames
        self._pending: list[PPGFrame] = []
        self._last_valid: Optional[PPGFrame] = None

    def feed(self, frame: PPGFrame) -> list[PPGFrame]:
        """Accept one raw frame. Returns 0–N frames (may flush interpolated batch)."""
        is_sat = any(s > self._sat_threshold for s in frame.chA)
        frame.saturated = is_sat

        if not is_sat:
            if self._pending:
                result = self._flush(frame)
                self._pending.clear()
                self._last_valid = frame
                return result + [frame]
            self._last_valid = frame
            return [frame]
        else:
            self._pending.append(frame)
            # Safety valve: if the ring is in a constant-saturation state (LED gain
            # stuck at maximum, chA > 60000 every frame), _pending grows forever and
            # the pipeline returns 0 frames. Emit the oldest batch as-is once we
            # exceed max_gap so the CSV still gets data and the console shows output.
            if len(self._pending) > self._max_gap:
                result = list(self._pending)
                self._pending.clear()
                self._last_valid = None
                return result
            return []

    def _flush(self, after: PPGFrame) -> list[PPGFrame]:
        n = len(self._pending)
        if n > self._max_gap or self._last_valid is None:
            # Gap too large or no prior reference → emit raw (caller marks as saturated)
            return list(self._pending)
        before = self._last_valid
        result = []
        for k, orig in enumerate(self._pending):
            alpha = (k + 1) / (n + 1)
            result.append(PPGFrame(
                seq=orig.seq,
                chA=[round(a + alpha * (b - a))
                     for a, b in zip(before.chA, after.chA)],
                chB=[round(a + alpha * (b - a))
                     for a, b in zip(before.chB, after.chB)],
                chC=[round(a + alpha * (b - a))
                     for a, b in zip(before.chC, after.chC)],
                wall_time=orig.wall_time,
                saturated=True,   # mark as interpolated, not real data
            ))
        return result


# ── FFTHREstimator ──────────────────────────────────────────────────────────

class FFTHREstimator:
    """Rolling FFT HR estimator over a fixed buffer of chA_filtered samples.

    Requires ≥75 samples (3s) to give any estimate; 250 samples (10s) is reliable.
    Updates every `update_every` frames to amortize compute cost.

    Key insight: per-frame zero-crossing HR fails at these AC/DC levels (3-6%).
    FFT over 10+ seconds integrates away noise and gives stable 1-bpm precision.
    """

    def __init__(self, buffer_size: int = 250, update_every: int = 10, fs: float = FS):
        self._buf: list[float] = []
        self._size = buffer_size
        self._every = update_every
        self._fs = fs
        self._n_fed = 0
        self.last_hr: Optional[float] = None
        self._hr_history: list[float] = []  # last 3 estimates for median smoothing

    def feed(self, filtered_samples: list[float]) -> Optional[float]:
        self._buf.extend(filtered_samples)
        if len(self._buf) > self._size:
            self._buf = self._buf[-self._size:]
        self._n_fed += 1
        if self._n_fed % self._every == 0 and len(self._buf) >= 75:
            self.last_hr = self._compute()
        return self.last_hr

    def _compute(self) -> Optional[float]:
        arr = np.array(self._buf, dtype=np.float64)
        # Cubic detrend to remove slow DC drift from AGC events
        t = np.arange(len(arr))
        arr -= np.polyval(np.polyfit(t, arr, 3), t)
        # Hanning window
        arr *= np.hanning(len(arr))
        # FFT
        freqs = np.fft.rfftfreq(len(arr), d=1.0 / self._fs)
        mags = np.abs(np.fft.rfft(arr))
        # Search 0.8-2.5 Hz (48-150 bpm). Lower bound raised from 0.5 Hz to suppress
        # respiratory artifact leaking through the bandpass edge (~0.25-0.33 Hz).
        mask = (freqs >= 0.8) & (freqs <= 2.5)
        if not np.any(mask):
            return None
        masked_mags = mags[mask]
        masked_freqs = freqs[mask]
        peak_idx = int(np.argmax(masked_mags))
        peak_hz = float(masked_freqs[peak_idx])
        peak_mag = float(masked_mags[peak_idx])
        # Harmonic dealiasing: PPG systolic peaks are non-sinusoidal; harmonics can
        # dominate the fundamental. Check sub-harmonic whenever it falls in the valid
        # HR range (≥0.8 Hz). Previously only checked >2.0 Hz, missing 1.8 Hz (108 bpm)
        # which is the 2nd harmonic of 0.9 Hz (54 bpm) — observed 2026-06-27 session.
        sub_hz = peak_hz / 2.0
        if sub_hz >= 0.8:
            sub_mask = (freqs >= sub_hz - 0.15) & (freqs <= sub_hz + 0.15)
            if np.any(sub_mask) and float(np.max(mags[sub_mask])) >= 0.3 * peak_mag:
                peak_hz = sub_hz
        hr = float(peak_hz * 60)
        # Median smooth over last 3 estimates to damp inter-harmonic jumps.
        self._hr_history.append(hr)
        if len(self._hr_history) > 3:
            self._hr_history.pop(0)
        return float(np.median(self._hr_history))


# ── SpO2Estimator ──────────────────────────────────────────────────────────

class SpO2Estimator:
    """Rolling SpO2 estimate using per-frame AC/DC ratio of chB and chC.

    R = (AC_B / |DC_B|) / (AC_C / |DC_C|)  per frame, then rolling average.
    SpO2 ≈ SPO2_A - SPO2_B * R  (empirical; requires calibration against pulse ox).

    WARNING: channel identity (chB=red, chC=IR) is UNVERIFIED.
    Run identify_channels.py first. If chB/chC are swapped, R is inverted
    and SpO2 estimate will be wrong.
    """

    def __init__(self, window: int = 20):
        self._window = window
        self._r_buf: list[float] = []
        self.last_r: Optional[float] = None

    def feed(self, frame: PPGFrame) -> Optional[float]:
        if not frame.chB or not frame.chC or frame.saturated:
            return None
        dc_B = abs(sum(frame.chB) / len(frame.chB))
        dc_C = abs(sum(frame.chC) / len(frame.chC))
        ac_B = float(max(frame.chB) - min(frame.chB))
        ac_C = float(max(frame.chC) - min(frame.chC))
        if dc_B < 1 or dc_C < 1 or ac_B < 1 or ac_C < 1:
            return None
        # Four-way optical health gate. All conditions flush the R buffer and return None.
        #   dc_B < 300       → RED suppressed (too weak)
        #   dc_B > 800       → RED overcalibrated (R too small → formula >100%)
        #   dc_C/dc_B > 4.0  → IR severely overcalibrated relative to RED
        #   dc_C/dc_B < 0.28 → IR suppressed; AC_chC dominated by noise → R→0 → SpO2 clamps to 100%
        # Evidence for lower IR bound (2026-06-27 session):
        #   dc_C=219, dc_B=334 (ratio=0.65) → SpO2=97.6% ✓
        #   dc_C=53,  dc_B=319 (ratio=0.17) → SpO2=100.0% clamped ✗
        #   Threshold 0.28 (not 0.30) to avoid oscillation at ratio≈0.30 boundary.
        if dc_B < 300 or dc_B > 800 or (dc_C / dc_B) > 4.0 or (dc_C / dc_B) < 0.28:
            self._r_buf.clear()
            return None
        # chB=RED (660nm), chC=IR (940nm) — confirmed by SpO2 ratiometry 2026-06-26
        R = (ac_B / dc_B) / (ac_C / dc_C)
        # Per-frame R gate: discard individual frames where R is physiologically impossible.
        # R < 0.525 → formula gives SpO2 > 100% (IR overcalibrated / AC_chC noise spike).
        # R > 1.5   → formula gives SpO2 < 81.4% (impossible without medical emergency).
        # Skip the frame (don't add to buffer) but DON'T flush — flushing turns one bad
        # frame into 10+ missing readings while the 20-frame buffer rebuilds from scratch.
        # Buffer is only flushed by the DC gate above (genuine AGC state transition).
        if R < 0.525 or R > 1.5:
            return None
        self._r_buf.append(R)
        if len(self._r_buf) > self._window:
            self._r_buf.pop(0)
        self.last_r = sum(self._r_buf) / len(self._r_buf)
        return max(70.0, SPO2_A - SPO2_B * self.last_r)


# ── PPGPipeline (orchestrator) ──────────────────────────────────────────────

class PPGPipeline:
    """Orchestrates the complete Stage 1 PPG ingestion pipeline.

    Call feed_frame(raw_frame) for each RSP 0x13 frame from BLE.
    Returns a list of ProcessedWindow objects (usually one; multiple after AGC flush).

    Processing order per frame:
      1. AGC detection + linear interpolation over saturation gaps
      2. Bandpass filter per channel (0.5–8 Hz causal IIR, state preserved across frames)
      3. Per-frame quality metrics (DC, AC, contact detection)
      4. FFT HR estimate (rolling 250-sample = 10s window, updated every 10 frames)
      5. SpO2 estimate (rolling 20-frame window from per-frame R ratio)
    """

    def __init__(self, fs: float = FS):
        self._fs = fs
        self._agc = AGCHandler()
        self._bpA = BandpassFilter(fs=fs)
        self._bpB = BandpassFilter(fs=fs)
        self._bpC = BandpassFilter(fs=fs)
        self._hr = FFTHREstimator(fs=fs)
        self._spo2 = SpO2Estimator()

    def reset_filters(self) -> None:
        """Reset filter state after a BLE reconnect (stale state causes transient artifacts)."""
        self._bpA.reset()
        self._bpB.reset()
        self._bpC.reset()
        self._hr.last_hr = None
        self._hr._hr_history.clear()

    def feed_frame(self, raw: PPGFrame) -> list[ProcessedWindow]:
        cooked = self._agc.feed(raw)
        results: list[ProcessedWindow] = []

        for f in cooked:
            chA_f = [float(s) for s in f.chA]
            chB_f = [float(s) for s in f.chB]
            chC_f = [float(s) for s in f.chC]

            # Bandpass filter each channel
            chA_filt = self._bpA.feed_batch(chA_f)
            chB_filt = self._bpB.feed_batch(chB_f)
            chC_filt = self._bpC.feed_batch(chC_f)

            # Per-frame statistics (on raw — DC/AC of the photodiode baseline)
            chA_dc = sum(chA_f) / len(chA_f)
            chA_ac = max(chA_f) - min(chA_f)
            chB_dc = abs(sum(chB_f) / len(chB_f))
            chB_ac = max(chB_f) - min(chB_f)
            chC_dc = abs(sum(chC_f) / len(chC_f))
            chC_ac = max(chC_f) - min(chC_f)

            # Contact detection from raw chA AC/DC
            contact = (chA_dc > 10 and
                       100 * chA_ac / chA_dc >= CONTACT_MIN_AC_DC_PCT
                       if chA_dc > 0 else False)

            # Transition guard: AC/DC > 50% means AGC is mid-cycle even if not
            # flagged as saturated. Don't feed these to HR/SpO2 — they carry
            # IIR ringing from the large DC step and produce garbage FFT peaks.
            ac_dc_ratio = (chA_ac / chA_dc) if chA_dc > 0 else 1.0
            is_transition = (ac_dc_ratio > 0.5) and not f.saturated

            # Feed filtered chA to HR estimator (skip saturated, transition, and weak-signal frames).
            # Below 2% AC/DC the FFT is noise-dominated and picks spurious harmonics
            # (48, 108, 114 bpm observed at 1-2% AC/DC). Stale last_hr is preferable.
            hr_quality_ok = (100 * chA_ac / chA_dc >= 2.0) if chA_dc > 0 else False
            hr = (self._hr.feed(chA_filt)
                  if not f.saturated and not is_transition and hr_quality_ok
                  else self._hr.last_hr)

            # SpO2 from raw per-frame AC/DC (filter artifacts affect AC too much)
            spo2 = (self._spo2.feed(f) if not f.saturated and not is_transition
                    else None)

            results.append(ProcessedWindow(
                seq=f.seq,
                wall_time=f.wall_time,
                chA_raw=chA_f,
                chB_raw=chB_f,
                chC_raw=chC_f,
                chA_filtered=chA_filt,
                chB_filtered=chB_filt,
                chC_filtered=chC_filt,
                chA_dc=chA_dc, chA_ac=chA_ac,
                chB_dc=chB_dc, chB_ac=chB_ac,
                chC_dc=chC_dc, chC_ac=chC_ac,
                hr_fft_bpm=hr,
                spo2_pct=spo2,
                contact=contact,
                saturated=f.saturated,
            ))

        return results


# ── Channel identity helper ─────────────────────────────────────────────────

def channel_guess(frames: list[PPGFrame]) -> dict[str, str]:
    """Return best-guess LED identity from a list of captured frames.

    Based on:
      - chA is uint16 positive DC → always the green LED output port
      - Highest AC/DC ratio → most pulsatile → green LED (confirmed: chA)
      - |DC_B| > |DC_C| at normal SpO2 → red absorbs more than IR → chB=red, chC=IR

    Returns dict with keys 'chA', 'chB', 'chC' and values 'green', 'red', 'ir'.
    Confidence is LOW until confirmed by identify_channels.py LED test.
    """
    valid = [f for f in frames if not f.saturated and f.chA]
    if not valid:
        return {"chA": "unknown", "chB": "unknown", "chC": "unknown"}

    dc_A = abs(sum(sum(f.chA) / len(f.chA) for f in valid) / len(valid))
    dc_B = abs(sum(sum(f.chB) / len(f.chB) for f in valid) / len(valid))
    dc_C = abs(sum(sum(f.chC) / len(f.chC) for f in valid) / len(valid))

    ac_A = sum((max(f.chA) - min(f.chA)) for f in valid) / len(valid)
    ac_B = sum((max(f.chB) - min(f.chB)) for f in valid) / len(valid)
    ac_C = sum((max(f.chC) - min(f.chC)) for f in valid) / len(valid)

    ratio_A = ac_A / dc_A if dc_A else 0
    ratio_B = ac_B / dc_B if dc_B else 0
    ratio_C = ac_C / dc_C if dc_C else 0

    # chA always outputs via uint16 port → green confirmed by hardware layout
    result = {"chA": "green (confirmed — uint16 output port)"}

    # For chB vs chC: LOWER |DC| = more absorbed = RED (660nm).
    # In reflectance PPG: more absorbed → less backscattered → lower ADC count.
    # At normal SpO2: red absorbs more than IR → lower DC.
    # NOTE: per-channel AGC can change absolute DC between sessions; verify with SpO2 cal.
    if dc_B < dc_C:
        result["chB"] = f"red (hypothesis — |DC|={dc_B:.0f} < |DC_C|={dc_C:.0f}, more absorbed)"
        result["chC"] = f"ir  (hypothesis — |DC|={dc_C:.0f} > |DC_B|={dc_B:.0f}, less absorbed)"
    else:
        result["chB"] = f"ir  (hypothesis — |DC|={dc_B:.0f} > |DC_C|={dc_C:.0f}, less absorbed)"
        result["chC"] = f"red (hypothesis — |DC|={dc_C:.0f} < |DC_B|={dc_B:.0f}, more absorbed)"

    print(f"\n  chA: AC/DC={100*ratio_A:.2f}%  DC={dc_A:.0f}")
    print(f"  chB: AC/DC={100*ratio_B:.2f}%  DC={dc_B:.0f}")
    print(f"  chC: AC/DC={100*ratio_C:.2f}%  DC={dc_C:.0f}")
    return result
