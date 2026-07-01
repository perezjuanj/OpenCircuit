# PPG Stage 1 Complete — Session Handoff 2026-06-26

**Status: Stage 1 DONE. Ready for Stage 2.**

This document captures everything confirmed during the 2026-06-26 evening session.
Pick up at Stage 2 using the Stage 2 plan in §6.

---

## 1. What Stage 1 Accomplished

Raw optical PPG from the RingConn Air 2 ring is now fully ingested, characterized,
and calibrated. The ring streams RSP 0x13 frames at 25 Hz over BLE. A complete
signal-processing pipeline runs in Python and outputs filtered waveforms, FFT heart
rate, and calibrated SpO2 in real time.

**Stage 1 sign-off checklist — all green:**

| Item | Result | Evidence |
|------|--------|----------|
| RSP 0x13 stream confirmed | 25 Hz push mode | 4 captures, 0 seq gaps |
| Sample rate verified | 25.0 Hz | 1 frame/wall-sec, confirmed |
| chA = GREEN LED | uint16 port (hardware) | Data type is definitive |
| chB = RED 660nm | Confirmed | SpO2 R=0.63 → 98% (chC=red gives 70% — impossible) |
| chC = IR 940nm | Confirmed | SpO2 exclusion |
| FFT HR validated | 83–84 bpm | 4 independent captures: 83.2, 84.0, 84.2, 84.4 bpm |
| SpO2 calibrated | Apple Watch 98% ref | Formula: `110 - 19.05 × R`, R=0.630→98.0% exactly |
| BLE stability (5 min) | 0 reconnects in 302.9s | capture_ppg.py session |
| Pipeline smoke test | 60.0 bpm from synthetic 1 Hz | ppg_pipeline.py self-test |

---

## 2. Complete Protocol Knowledge

### RSP 0x13 Trigger Sequence

```
1. TX: 06 10 00  (enter mode 0x10 — primes PPG hardware engine)
   wait 3s, drain responses
2. TX: 06 00 00  (exit mode 0x10)
   sleep 0.5s
3. TX: 06 01 00  (enter mode01 — ring starts push-streaming RSP 0x13 at ~1Hz)
   drain ACK (0x86 00 86)
```

Mode 0x10 pre-condition is REQUIRED. Without it, mode01 + any 0x96 probes return nothing.
After mode10+mode01, ring enters PUSH mode — RSP 0x13 frames arrive automatically.
Fallback pull: `96 01 00 00 00` if push stalls for >1.2s.

Keepalive: `95 00 00` every 8s (BLE supervision timeout is ~30-40s).

### RSP 0x13 Frame Format (160 bytes)

```
[13][00][seq:1][01][00][9D][25 × 6-byte records][00][00][cumulative:1][XOR:1]
```

Each 6-byte record:
```
bytes[0:2]  chA  big-endian uint16  → GREEN LED (DC ~190-540, AC/DC ~7%)
bytes[2:4]  chB  big-endian  int16  → RED 660nm  (DC varies with AGC, AC/DC ~2%)
bytes[4:6]  chC  big-endian  int16  → IR 940nm   (DC varies with AGC, AC/DC ~3%)
```

XOR: `frame[0] ^ frame[1] ^ ... ^ frame[158] == frame[159]`
Seq: 8-bit rolling counter (wraps 255 → 0).

### SM3 Auth (required before any data command)

```python
V = mac[3] ^ mac[4] ^ mac[5]   # MAC from GATT 0x2A23 System ID (sysid[5::-1])
auth_response = SM3([V, challenge_byte])[-3:]  # last 3 bytes of SM3 hash
```

Ring UUID: `375373B7-94D7-5B6E-9866-54073B5C04B3`  
Ring MAC: `F8:79:99:C1:E3:4C`

### Channel Identity (confirmed)

| Channel | Type | LED | Wavelength | DC range |
|---------|------|-----|-----------|----------|
| chA | uint16 | GREEN | ~550nm | 190–540 (AGC-dependent) |
| chB | int16 | RED | 660nm | 87–810 (AGC-dependent) |
| chC | int16 | IR | 940nm | 562–981 (AGC-dependent) |

**Warning:** Absolute DC values for chB/chC are unreliable between sessions — the ring's
per-channel AGC changes LED power independently. In one session chB=810, in another chB=87.
NEVER use absolute DC to identify channels. Use SpO2 ratiometry.

### SpO2 Formula (calibrated)

```
R = (AC_chB / DC_chB) / (AC_chC / DC_chC)
SpO2 = 110.0 - 19.05 × R
```

Calibration anchor: Apple Watch 98% at R=0.630 (2026-06-26 resting state).

| R value | SpO2 |
|---------|------|
| 0.577 | 99% |
| 0.630 | 98% |
| 0.682 | 97% |
| 0.787 | 95% |
| 1.050 | 90% |
| 1.312 | 85% |

SPO2_A=110.0, SPO2_B=19.05 in `ppg_pipeline.py`.
Single-point calibration (A fixed). True two-point requires a hypoxic reference.

### AGC Events

Ring adjusts LED power ~3-5× per minute (normal behavior). Events:
- chA spikes near uint16 max (>60000) for 1-3 frames → mark as `[AGC]`
- Strategy: linear interpolation over saturated frames (AGCHandler in ppg_pipeline.py)
- Transition guard: frames with AC/DC > 50% (mid-AGC-cycle) blocked from HR/SpO2 estimators

### BLE Buffering Behavior

When the Python client is disconnected, the ring buffers RSP 0x13 frames internally.
On reconnect, it delivers the backlog all at once (can be 77+ frames at one timestamp).
During the buffering period, the ring's AGC may cycle to a different LED power level,
making the post-burst data incompatible with pre-burst data (different DC levels).

**Mitigation:** When analyzing a capture CSV, use `--seq-start N --seq-end M` to isolate
stable segments before a burst. analyze_ppg_13.py recomputes zero-phase filter on the subset.

---

## 3. File Inventory

All tools in `/Users/pravinsail/OpenCircuit-master/desktop/`:

### Stage 1 Production Tools

| File | Purpose |
|------|---------|
| `ppg_pipeline.py` | Signal library: BandpassFilter, AGCHandler, FFTHREstimator, SpO2Estimator, PPGPipeline |
| `capture_ppg.py` | Production ingestion: push/pull hybrid, keepalive, CMD 0x29 poll, auto-reconnect, CSV |
| `identify_channels.py` | 3-phase wear/lift/rewear LED identity test (Phase 2 off-finger detection is expected) |
| `analyze_ppg_13.py` | Batch analysis: zero-phase filter, per-frame AC/DC, FFT HR, SpO2, 4-panel plot |
| `stream_ppg_13.py` | Interactive streaming with live per-frame stats and rolling FFT HR display |
| `debug_ppg_mode10.py` | Smoke test: mode10 pre-cond → mode01 → 5 fetches (quick go/no-go) |

### Existing Investigation Tools (complete, not needed for Stage 2)

`sweep_opcodes.py`, `probe_mode_09_plus.py`, `decode_bulk.py`, `decode_4d_4e.py`,
`decode_ppg.py`, `livehr.py`, `poll_hr_spo2.py`, `extract_last_night.py`

### Key Data Files

| File | Contents |
|------|---------|
| `ppg_20260626_211757.csv` | Original 62-frame capture (old format: chA/chB/chC raw only) |
| `ppg_capture_20260626_215226.csv` | 5-min capture (new format: raw + filtered + HR + SpO2). Clean segment: seqs 141-171 |

### Documentation

| File | Contents |
|------|---------|
| `docs/BLE_INVESTIGATION_LOG.md` | Living protocol reference — opcode map, frame formats, tool inventory |
| `docs/ppg-stage1-complete-handoff-2026-06-26.md` | This file |

---

## 4. Key Bugs Found and Fixed This Session

### Bug 1 — stream_ppg_13.py: 0 frames on first two runs
**Root cause:** Missing mode10 pre-conditioning. `probe_mode_09_plus.py` had swept
modes 10-13 before mode01, which primed the PPG engine. Going directly to mode01 produces nothing.
**Fix:** Add mode10 entry/drain/exit before mode01 in stream_ppg_13.py and capture_ppg.py.

### Bug 2 — stream_ppg_13.py: stuck >60s, never exits
**Root cause:** Ring entered PUSH mode (streaming ~1 frame/s). `drain(2.0)` used per-frame
2.0s timeout — since frames arrived within 2s, drain never saw a gap and never returned.
**Fix:** Gap-based drain: break on 0.5s of silence rather than per-frame timeout.

### Bug 3 — identify_channels.py: wrong RED/IR physics (backwards)
**Root cause:** Code said "higher |DC| = more absorbed = RED" — backwards. In reflectance PPG:
more absorbed → less backscattered → lower ADC count. So LOWER |DC| = RED, HIGHER |DC| = IR.
**Fix:** Flipped comparison in conclusions section. Also removed hardcoded "chA = GREEN" that
conflicted with the dynamically computed `most_pulsatile` variable.

### Bug 4 — identify_channels.py: Phase 2 diagnostic misleading
**Root cause:** When ring is lifted, it detects off-finger and PAUSES RSP 0x13 streaming entirely
(0 frames), not just changes DC. The code printed a meaningless DC-change table comparing 0 vs 0.
**Fix:** Detect `p2.frames == 0` and print an explanation; skip the DC-change comparison.

### Bug 5 — analyze_ppg_13.py: 3985% AC/DC from mixed-DC-regime data
**Root cause:** Two separate valid frame populations (chA DC~190 and chA DC~40) merged by
zero-phase filtfilt. The 78-second DC step caused massive filter ringing, producing 3985% AC/DC
and 34.4 bpm FFT HR (actually a 0.57 Hz filter-edge artifact).
**Fix:** Added `--seq-start` / `--seq-end` args. When active, filter the DataFrame BEFORE
running zero-phase filter, so filtfilt sees only a clean, continuous segment.

### Bug 6 — ppg_pipeline.py: transition frames contaminate FFT HR
**Root cause:** Mid-AGC-cycle frames with chA at intermediate levels (e.g., 26544, 8327) have
AC/DC >100% but are below SAT_THRESHOLD. They fed garbage IIR-ringing values into the 250-sample
FFT buffer, locking HR at 192 bpm until 250 clean samples flushed them.
**Fix:** Transition guard: `if ac_dc_ratio > 0.5 and not saturated → skip HR/SpO2 estimators`.

### Bug 6 — channel_guess() in ppg_pipeline.py: wrong physics comment
**Root cause:** Comment said "higher |DC| = more absorbed = red" — backwards (same physics error
as identify_channels.py Bug 3).
**Fix:** Corrected to "lower |DC| = more absorbed = red". Note added: per-channel AGC makes
absolute DC unreliable for channel ID; SpO2 ratiometry is the authoritative method.

---

## 5. Stage 1 Confirmed Numbers (use these as ground truth)

```
Ring:          RingConn Air 2  MAC F8:79:99:C1:E3:4C
Session date:  2026-06-26
Finger:        Index finger (left hand)

Sample rate:   25.000 Hz (confirmed)
Frame size:    25 samples × 3 channels = 75 samples/frame

chA (GREEN):   DC ~190-540 (AGC-dependent), AC/DC ~6-7%
chB (RED):     DC ~87-810 (AGC-dependent), AC/DC ~1-2%
chC (IR):      DC ~562-981 (AGC-dependent), AC/DC ~3%

FFT HR:        83.2, 84.0, 84.2, 84.4 bpm (4 captures) → resting HR ~83-84 bpm
SpO2 R:        0.6277 from clean segment (seqs 141-171)
SpO2 output:   98.0% (calibrated), Apple Watch reference: 98%
Formula:       SpO2 = 110.0 - 19.05 × R
```

---

## 6. Stage 2 Plan

Stage 2 converts the raw CSV output from `capture_ppg.py` into a structured,
queryable health data layer that feeds into the existing Healthops iOS app and
longer-term blood pressure inference work.

### 6a. Immediate next step — PPG waveform quality improvement

Before Stage 2 infrastructure, one signal-quality improvement would help:

**Startup buffer flush in capture_ppg.py:** When connecting after a gap (e.g., between
tool runs), the ring delivers a backlog of buffered frames all at once. These arrive with
old AGC settings and corrupt the analysis. Fix: after `enter_ppg_mode()`, drain and discard
RSP 0x13 frames for 3 seconds before starting the recording loop.

```python
# In enter_ppg_mode() or immediately after:
print("  Flushing startup buffer (3s)...")
t0 = time.monotonic()
while time.monotonic() - t0 < 3.0:
    try:
        b = await asyncio.wait_for(q.get(), timeout=0.5)
        # discard — these are from previous session's buffer
    except asyncio.TimeoutError:
        break
print("  Ready.")
```

### 6b. Docker processing environment

Goal: run `capture_ppg.py` headlessly (not from laptop), process CSVs in a
consistent environment, serve processed data to the iOS app.

```
ring → BLE → Mac mini (or dedicated Mac) → capture_ppg.py → CSV
                                         → Docker container:
                                             ppg_pipeline.py
                                             Stage 2 ML models (BP inference)
                                             REST API → iOS app
```

Components:
- `docker-compose.yml` with:
  - `ppg-processor` service: runs batch analysis on new CSV files
  - `api` service: Flask/FastAPI, serves processed HR/SpO2/BP to Healthops iOS app
  - `db` service: TimescaleDB (time-series optimized Postgres)
- Watch directory: processor auto-triggers on new CSV files from capture_ppg.py

### 6c. n8n orchestration

n8n workflow to:
1. Detect new CSV file (filesystem trigger or webhook from capture_ppg.py)
2. POST to `ppg-processor` API → trigger batch analysis
3. Store results in TimescaleDB
4. Push summary to Obsidian daily note via Obsidian REST plugin
5. Optional: alert via Telegram/Slack if SpO2 < 94% or HR anomaly detected

### 6d. Obsidian PKM integration

Goal: each capture session auto-generates an Obsidian note with:
- HR trend chart (sparkline or image embed)
- SpO2 reading
- Session metadata (duration, clean frames, AGC events)
- Link to raw CSV

Use: Obsidian REST API plugin + templater. n8n generates the markdown, writes via REST.

### 6e. Blood pressure inference (Stage 3 — deferred)

The current signal is sufficient to explore PTT (Pulse Transit Time) based BP estimation
once we have the ECG reference. PTT requires two signals with a time delay:
- Signal 1: ECG R-peak (not yet available — need ECG source or Apple Watch ECG)
- Signal 2: PPG peak (chA green channel — already have this at 25 Hz)

PTT = time from ECG R-peak to PPG peak
BP correlates with PTT (longer PTT = lower BP, empirically)

Deferred until ECG reference is available.

---

## 7. Commands to Resume Tomorrow

### Quick validation that tools still work
```bash
cd /Users/pravinsail/OpenCircuit-master/desktop
.venv/bin/python debug_ppg_mode10.py 375373B7-94D7-5B6E-9866-54073B5C04B3
```
Expected output: `SUCCESS: RSP 0x13 confirmed` within 15s.

### Full 5-minute capture (with startup buffer flush — add manually or wait for fix)
```bash
.venv/bin/python capture_ppg.py 375373B7-94D7-5B6E-9866-54073B5C04B3 --duration 300
```
Expected: HR_FFT converges to ~83-84 bpm within 10 frames, SpO2 ~97-99%.

### Analyze a specific clean segment from capture CSV
```bash
.venv/bin/python analyze_ppg_13.py ppg_capture_20260626_215226.csv --seq-start 141 --seq-end 171
```
Expected: FFT HR ~83 bpm, SpO2 R=0.63 → 98%.

### Run the pipeline smoke test (no ring needed)
```bash
.venv/bin/python ppg_pipeline.py
```
Expected: `60.0 bpm from synthetic 1 Hz sine` (self-test at bottom of file).

---

## 8. Known Limitations / Open Questions

1. **CMD 0x29 (Ring HR) doesn't respond in PPG mode**: The ring appears to gate
   polled HR/SpO2 responses when RSP 0x13 is actively streaming. The "Ring HR"
   column in capture_ppg.py will likely always show "---" during PPG capture.
   Ground-truth validation requires using the RingConn app simultaneously or
   comparing against Apple Watch HR.

2. **SpO2 calibration is single-point**: A=110 fixed, B=19.05 fitted from one
   resting measurement. True clinical accuracy requires a calibration at a lower
   SpO2 value (~85-90%). For resting-state monitoring this is sufficient.

3. **modes 11-13 untested alone**: We know mode10 + mode01 works. It's unknown
   whether mode11/12/13 also prime the PPG hardware. Not important for Stage 2
   but worth knowing for a future protocol deep-dive.

4. **RSP 0x16 still missing**: BleRealTimePPGRspMixin in the app suggests CMD 0x96
   should produce RSP 0x16, but we get 0x13 instead. Either 0x16 exists for a
   different variant/firmware, or 0x13 IS the realtime PPG opcode under a
   different naming convention.

5. **SpO2 AC computation**: The pipeline uses raw per-frame max-min as AC. This
   is sensitive to within-frame motion artifact. The Stage 2 processor should use
   filtered AC from the zero-phase batch analysis for more accurate SpO2.
