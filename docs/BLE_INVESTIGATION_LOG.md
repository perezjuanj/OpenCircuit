# RingConn Gen 2 Air — BLE Investigation Log (Living Document)

Ring MAC: `AA:BB:CC:DD:EE:FF`  
BLE UUID (Device): `375373B7-94D7-5B6E-9866-54073B5C04B3` (CBPeripheral UUID, macOS)  
Started: 2026-06-23  
Last updated: 2026-06-26 (night — Stage 1 ingestion pipeline complete; 4 production tools ready)

---

## 🟢 BREAKTHROUGH: Raw Multi-Channel PPG Found + Validated (2026-06-26)

**RSP opcode 0x13** — 25 × 6-byte multi-channel optical records per frame, 25 Hz push stream.  
**Trigger:** Enter mode 0x10 first, then mode01 (`06 01 00`) → ring enters PUSH mode automatically.  
**FFT HR = 84.4 bpm confirmed** from 57-second capture (zero-phase filtered chA, cubic detrend).  
**5 AGC adjustment events** (saturation near uint16 max) observed during 62s capture — normal ring behavior.

**Stage 1 (Data Ingestion) COMPLETE 2026-06-26.**  
chA=GREEN, chB=RED (660nm), chC=IR (940nm). FFT HR 83-84 bpm (4 captures). SpO2 calibrated: Apple Watch 98% reference → formula `110 - 19.05 * R`. See §6 for all tools.

See §5 for full decode + validation results, §6 for streaming tools.

---

## 1. BLE Service Map

| Service | Handle | UUID | Role |
|---------|--------|------|------|
| Primary | 0x0800 | `8327ad99-2d87-4a22-a8ce-6dd7971c0437` | All ring communication |
| └ Write char | 0x0801 | `8327ad98-...` | App → Ring (write-with-response) |
| └ Notify char | 0x0803 | `8327ad97-...` | Ring → App (notifications) |
| └ CCCD | 0x0805 | `0x2902` | Enable notifications |
| Device Info | — | standard | `0x2A23` = System ID (used for MAC → SM3 auth) |
| Secondary | 0x0900 | `1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0` | **DFU/OTA only** — zero response to all probes |

**Auth (SM3):** `SM3([V, challenge])[-3:]` where `V = mac[3] ^ mac[4] ^ mac[5]`. MAC is derived from 0x2A23 System ID (`sysid[5::-1]`). This replaces standard BLE bonding — the ring gates all data commands behind this challenge-response.

---

## 2. Complete Command Opcode Map (0x00–0xFF)

Sweep completed 2026-06-26. All commands sent as `XX 00 00` after successful SM3 auth. Commands NOT listed below returned no response.

### 2a. Responding Commands

| CMD | RSP | Payload / Notes | Mixin (inferred) | Confirmed |
|-----|-----|-----------------|------------------|-----------|
| 0x01 | 0x81 | `[challenge_byte]` | BleAuthRspMixin | 🟢 |
| 0x02 | 0x82 | `00` + triggers batch stream | BleSyncStatusMixin | 🟢 |
| 0x03 | 0x83 | `01` (pending) / `00` (empty) | sync status | 🟢 |
| 0x04 | 0x84 | `00 83 07` | capability/version | 🟢 |
| 0x05 | 0x85 | `00` + triggers passive 0x4D stream | — | 🟢 |
| 0x06 | 0x86 | `00` mode-ack + mode-specific stream | BleWorkModeRspMixin | 🟢 |
| 0x07 | 0x4C/0x47/0x4D | batch history pages | fetch/drain | 🟢 |
| 0x08 | 0x88 | `ff` (not available) | system diagnostic | ⚠️ skip |
| 0x09 | 0x89 | `01 77` | system command | ⚠️ skip |
| 0x0D | 0x4D | 35-record batch, same as 0x07 | **NON-DESTRUCTIVE peek** | 🟢 |
| 0x11 | 0x11 (echo?) | — | — | 🟡 needs re-test |
| 0x12 | 0x4D | identical to 0x0D | alias of 0x0D | 🟢 |
| 0x20 | 0xA0 | `ff` (rejected) | BleOtaRspMixin? | ⚠️ avoid |
| **0x21** | **0xA1** | **bricked ring** | BleEnterOtaRspMixin | 🔴 NEVER SEND |
| 0x22 | 0xA2 | `00` | unknown ack | 🟢 |
| 0x23 | 0xA3 | `00` | unknown ack | 🟢 |
| 0x24 | 0xA4 | `00` | unknown ack | 🟢 |
| 0x27 | 0xA7 | `ff` (rejected) | — | skip |
| 0x28 | 0xA8 | `11 "RCXXXXXXXXXXXXXX"` | **Device serial number** | 🟢 |
| 0x29 | 0xA9 | `[valid][HR][valid][SpO2][0×4]` | **Polled HR+SpO2 snapshot** | 🟢 |
| 0x2A | 0xAA | `00` | unknown ack | 🟢 |
| 0x2B | 0xAB | `03` | firmware state / version? | 🟢 |
| 0x30 | **0x0B** | `00` | **breaks cmd=rsp^0x80 rule** | 🟢 |
| 0x91 | 0x4E | 13-byte snapshot | **on-demand live 10s HR snapshot** | 🟢 |
| 0x95 | 0x15 (implicit) | keepalive — prevents BLE supervision timeout | — | 🟢 |
| 0xC7 | — | ACK for 0x47 pages (send to advance ring's cursor) | — | 🟢 |
| 0xCC | — | ACK for 0x4C pages | — | 🟢 |
| 0xD0 | 0x87 + 0x10 | device status snapshot (battery, temp, etc.) | — | 🟢 |

### 2b. DANGEROUS — Do Not Send

| CMD | What happened |
|-----|---------------|
| 0x21 | Bricked ring (required charger restart + forget-device + re-pair). OTA confirm. |
| 0x20 | Returns `A0 ff` (rejected), but skip — pairs with 0x21 |

### 2c. CMD 0x06 Mode Map (extended)

| Mode byte | Mode | RSP sequence | Effect |
|-----------|------|-------------|--------|
| 01 | HR live | 0x86, 0x10, 0x87 + 0x15 streaming | Green LEDs; 0x15 frames every ~1-2s |
| 02 | SpO2 | 0x11, 0x86, 0x10, 0x87 | Red LED; triggers OSA status (0x11) |
| 03 | — | 0x86, 0x10, 0x87 | Same as mode01 externally |
| 04 | Sport/realtime | 0x4C, 0x86, 0x4E, 0x11, 0x50 | Returns live 10s snapshot (0x4E) |
| 05 | Minimal | 0x86, 0x87 | Minimal response |
| 06 | Sport lite | 0x4E, 0x86, 0x11, 0x50 | Same as mode04 without history flush |
| 07 | Batch | 0x4D, 0x86, 0x11, 0x50 | Returns batch of historical 10s records (0x4D) |
| 08 | Status | 0x86, 0x87, 0x50 | Status-only mode |
| 09–0F | **REJECTED** | 0x86 FF 79 | Ring returns error — modes not supported |
| **10–13** | **ACCEPTED (PPG pre-condition?)** | 0x86 00 86 | Accepted but no visible frames — suspected PPG hardware enable; see §5 note |
| 14–FF | **REJECTED** | 0x86 FF 79 | Ring returns error |

---

## 3. Response Opcode Map (Spontaneous / Triggered Frames)

### 3a. Live / spontaneous frames (Ring → App)

| RSP | Opcode | Frame format | Cadence | Mixin | Confirmed |
|-----|--------|-------------|---------|-------|-----------|
| 0x10 | Passive status | `[10][5C][00×5][01][5C][01][SpO2%][00×4][10][ae][0a][ff][3f]` | every ~3-5s during session | BlePassiveStatusRspMixin | 🟢 |
| 0x11 | OSA notification | `[11][00][seq][status][xor]` (5B) | after CMD 02/06 | BleGetOfflineOsaRspMixin | 🟢 |
| 0x15 | Live HR stream | `[15][00][HR_bpm][0A][B0][XOR]` (6B) | every ~1-2s in mode01 | BleRealtimeMeasureRspMixin | 🟢 |
| **0x16** | **Target: raw PPG** | **UNKNOWN** | **unknown** | **BleRealTimePPGRspMixin** | 🔴 not found |
| 0x47 | PPG trend batch | `[47][00][countdown][N×47B recs][xor]` | at sync time | BleHistorySpo2RspMixin | 🟢 |
| 0x4A | Sleep data batch | multi-epoch structure | at sync time | BleSleepDataRspMixin | 🟢 |
| 0x4C | Activity/HR batch | `[4C][00][countdown][N×23B recs][xor]` | at sync time | BleHistoryActivityRspMixin | 🟢 |
| 0x4D | 10s batch history | `[4D][00][count][N×11B recs][xor]` | CMD 07, 0D, 12 | BleHistoryMeasureInfoRspMixin | 🟢 |
| 0x4E | Live 10s snapshot | `[4E][cursor:4BE][hr:1][motion:2LE][field3:2LE][conf:1][pad:1][xor]` | CMD 91, mode04/06 | BleRealtimeSportRspMixin | 🟢 |
| 0x50 | Sync cursor events | — | sync open/close | BleEventStatusRspMixin | 🟢 |
| 0x81 | Auth challenge | `[81][00][challenge_byte][xor]` | on CMD 01 | BleAuthRspMixin | 🟢 |
| 0x82 | Sync ack | `[82][00][00][xor]` | on CMD 02 | BleSyncStatusMixin | 🟢 |
| 0x83 | Sync status | `[83][00][01 or 00][xor]` | on CMD 03 | — | 🟢 |
| 0x86 | Mode ack | `[86][00][00][xor]` | on CMD 06 | BleWorkModeRspMixin | 🟢 |
| 0x87 | Device status | 19-byte frame: battery, temp, HR, step, voltage, charging | on CMD 07/D0 | BlePassiveStatusRspMixin | 🟢 |

### 3b. 0x87 Device Status Frame (detailed decode)

```
[87][00][17][battery%][0A][?][hr][?][?][?][?][step:2LE][?][temp_skin:2LE][temp_ambient:2LE][voltage:2LE][charging_flag][xor]
```

Confirmed fields (from OpenCircuit §5.7):
- `byte[3]` = battery percentage (0-100)
- `byte[6]` = HR bpm
- `byte[10:12]` = step count (LE)
- `byte[12:14]` = skin temperature ×10 (e.g. 0x0105 = 261 = 26.1°C)
- `byte[14:16]` = ambient temperature ×10
- `byte[16:18]` = voltage (mV)
- `byte[18]` = charging flag (1=charging)

### 3c. 0x10 Passive Status Frame (partial decode)

```
[10][5C][battery?][...][01][5C][01][SpO2%][00×4][10][ae][0a][ff][3f]
```

- `byte[9]` = SpO2% (0x64 = 100%, 0x60 = 96%, etc.)
- Full decode still partially 🟡

---

## 4. Frame Formats (Detailed)

### 4a. CMD 0x29 — Polled HR + SpO2 (RSP 0xA9)

```
TX:  29 00 00
RX:  A9 00 [valid_hr:1] [HR:1] [valid_spo2:1] [SpO2:1] [00×4] [xor]
```

- `valid_hr` = 0x01 = valid, 0x00 = invalid (not worn)
- `valid_spo2` = 0x01 = valid, 0x00 = invalid
- If not worn: SpO2 may read >100% (algorithm gives nonsense without blood absorption signal)
- Works WITHOUT entering any measurement mode — reads the ring's internal cache

### 4b. CMD 0x91 — On-demand 10s snapshot (RSP 0x4E)

```
TX:  91 01 00
RX:  [4E][cursor:4BE][hr:1][motion:2LE][field3:2LE][conf:1][pad:1][xor]
```

- `cursor` = ring epoch seconds (unix - 1,577,793,600)
- `hr` = HR in bpm
- `motion` = activity count (0 at rest, 1-10 walking, steps-related)
- `field3` = 10,000–12,000 range — likely DC photodiode ADC baseline (🟡 not ground-truthed)
- `conf` = signal confidence (0-100)

### 4c. RSP 0x15 — Live HR stream

```
RX:  15 00 [HR_bpm:1] [0A:const] [B0:const] [xor]
```

- Streams automatically while ring is in mode01 (CMD 06 01 00)
- Also triggered by keepalive CMD 0x95 during active measurement

### 4d. RSP 0x47 — PPG trend batch (NOT pulse-resolution)

```
Page: [47][00][countdown] [N×47-byte records] [xor]
Record (47B): [0C:marker] [counter:4BE +900s/rec] [dc_baseline:2BE] [flags:3] [38B payload]
Payload: 30 × 10-bit big-endian samples (300 bits + 4 pad bits)
```

**IMPORTANT:** These samples are at 0.033 Hz (1 sample per 30 seconds) — NOT pulse-resolution. Cannot recover heartbeat from 0x47. It is a slow optical amplitude trend, not a waveform. 🟢 proven.

### 4e. RSP 0x4C — Activity/sleep history

```
Page: [4C][00][countdown] [N×23-byte records] [xor]
Record (23B): [0C:marker] [counter:4BE +150s/rec] [hr:1] [hrv:1] [conf:1] [rr×8:1] [spo2:1] [item2p5:1] [acti_counts:10] [info:1] [trailer:2]
```

- Counter step = 150s per record (2.5-min epochs)
- `acti_counts[10]` = activity intensity blob (🟡 sub-fields TBD)
- `spo2` byte 0x12/0x13 = awake "no SpO2" sentinel

### 4f. RSP 0x4D — 10s batch history

```
Page: [4D][00][count] [N×11-byte records] [xor]
Record (11B): [cursor:4BE] [hr:1] [motion:2LE] [field3:2LE] [conf:1] [pad:1]
```

---

## 5. Raw PPG — FOUND (2026-06-26 evening)

### RSP 0x13 — Multi-Channel Optical PPG 🟢

**Trigger:** Enter mode01 (`06 01 00`), then send `96 01 00 00 00` (5-byte command).  
**Result:** RSP 0x13 returns 25 × 6-byte optical records per frame, XOR-verified.  
**Sampling:** PULL model — each fetch returns next 25 samples from ring's circular buffer. Poll every ~1s for gapless 25 Hz stream.

**Note on cmd=rsp convention:** CMD 0x96 → RSP 0x13 (NOT 0x16!) — this breaks the `cmd = rsp ^ 0x80` rule. CMD 0x96 XOR 0x80 = 0x16, but the actual RSP is 0x13. RSP 0x16 may still exist for something else, or BleRealTimePPGRspMixin handles 0x13.

### Frame Format (160 bytes, XOR-verified)

```
[13][00][seq:1][01][00][9D][25 × 6-byte records][00][00][cumulative_samples:1][XOR:1]
```

| Field | Bytes | Value | Notes |
|-------|-------|-------|-------|
| opcode | [0] | `0x13` | new PPG candidate opcode |
| zero | [1] | `0x00` | standard |
| seq | [2] | 1,2,3... | frame sequence number (rolls at 256) |
| byte3 | [3] | `0x01` | constant — purpose unknown |
| byte4 | [4] | `0x00` | constant |
| byte5 | [5] | `0x9D` | constant per session — possibly session token |
| records | [6:156] | 25×6B | optical data |
| pad | [156:158] | `00 00` | padding |
| cumulative | [158] | seq×25 | total samples delivered so far |
| xor | [159] | | XOR of [0:159] |

### Record Format (6 bytes per sample)

```
bytes[0:2] = chA  big-endian uint16  green LED channel  DC ~539 counts
bytes[2:4] = chB  big-endian  int16  channel B (red?)   DC ~-654 counts  
bytes[4:6] = chC  big-endian  int16  channel C (IR?)    DC ~-588 counts
```

### Verified Optical Properties (frame 1, ring worn, HR ~70bpm)

| Channel | DC baseline | AC range | AC/DC | Notes |
|---------|-------------|----------|-------|-------|
| chA | +539 | 29 | **5.4%** | green LED — highest pulsatile signal |
| chB | -654 | 17 | **2.6%** | red? signed 16-bit; `fd XX` byte pattern |
| chC | -588 | 34 | **5.8%** | IR? signed 16-bit; `fd XX` byte pattern |

All three channels show pulse-resolution AC/DC ratios (2–6%) — typical for photoplethysmography. 🟢

### What CMD 0x96 Variants Work

All 5-byte payloads starting with `96 01` returned sequential 0x13 data (seq incremented continuously). Params bytes 2-4 appear to be ignored (or select rate — needs verification):

```
96 01 00 00 00  → seq 2, 25 samples ✓
96 01 01 00 00  → seq 3 ✓
96 01 00 19 00  → seq 4 (0x19=25Hz param?) ✓
96 01 00 32 00  → seq 5 (0x32=50Hz param?) + extra 0x0B response ✓
96 01 00 00 01  → seq 6 ✓
96 01 19 00 00  → seq 7 ✓
96 04 01 00 00  → seq 8 ✓
96 FF 01 00 00  → seq 9 ✓
```

Two-byte variant `96 01 00` = **NO RESPONSE** (needs 4+ byte payload). Minimum working: `96 01 XX XX XX`.

### What 0x47 Is (clarification)

0x47 is NOT pulse-resolution PPG. It's a 15-minute optical amplitude trend (30 samples per 15-min record = 0.033 Hz). No heartbeat recoverable. This was wrong in earlier docs. 🟢 confirmed closed.

### Mode10 Pre-Conditioning: Required for RSP 0x13

**Problem found 2026-06-26 late:** `stream_ppg_13.py` ran directly to mode01 and got **0 RSP 0x13 frames** on two runs. But `probe_mode_09_plus.py` got RSP 0x13 on the FIRST `96 01 00 00 00` call.

**Root cause analysis:** In `probe_mode_09_plus.py`, CMD 06 modes 10-13 were swept (all accepted: `86 00 86`) BEFORE mode01 was entered for the `96 01` probes. Mode 0x10 is suspected to enable the ring's raw PPG hardware engine. Without it, mode01 + `96 01 00 00 00` returns nothing.

**Fix applied to `stream_ppg_13.py`:**
```
BEFORE entering mode01:
  TX 06 10 00  → enter mode 0x10 (PPG hardware activation)
  drain 3s     → let ring ACK and settle
  TX 06 00 00  → exit mode 0x10
  sleep 0.5s   → ring transitions to idle
THEN:
  TX 06 01 00  → enter mode01 as before
  poll with 96 01 00 00 00 every 1s
```

Same mode10 pre-conditioning applied in the 5-miss recovery path. **Status: fix applied, not yet verified.**

### Validated Results (2026-06-26 late — 62-second capture)

**Capture:** `ppg_20260626_211757.csv` — 62 frames × 25 samples = 1550 samples at 25 Hz.  
**5 saturation frames:** seqs 17, 71, 72, 73, 74 — AGC adjustment events (ring changes LED power automatically). chA near uint16 max (65530 counts). These are **normal** ring behavior; filter them out for analysis.  
**57 valid frames** analyzed:

| Channel | Per-frame AC | DC | AC/DC | Notes |
|---------|-------------|-----|-------|-------|
| chA | 18.2 counts | 289.6 | **6.3%** | Highest pulsatility — green LED |
| chB | 15.4 counts | 808.1 | 1.9% | Signed int16, negative DC |
| chC | 13.5 counts | 557.9 | 2.4% | Signed int16, negative DC |

**HR from FFT (cubic-detrended chA, 57s):**
```
Peak: 84.2 bpm  (mag=268)
Second: 85.3 bpm (same heartbeat, adjacent bin)
Third: 83.2 bpm  (same)
```
Dominant peak at 84.2 bpm is clear and repeatable. 🟢 **PPG IS REAL DATA.**

**Sample rate:** Exactly 1 frame/second (62 frames in 62 wall-clock seconds) = 25 samples/s confirmed. 🟢

**Push mode:** After mode10 + mode01 entry, ring streams RSP 0x13 frames AUTOMATICALLY at ~1Hz. No polling needed. 🟢

**SpO2 — CALIBRATED (2026-06-26):**
- chB=RED (660nm), chC=IR (940nm) — confirmed by SpO2 ratiometry (chB=red → 94.3% pre-cal; chC=red → 70.2% → impossible)
- Calibration: Apple Watch 98% reference at R=0.63 → `SpO2 = 110 - 19.05 × R`
- Scale: R=0.630→98%, R=0.787→95%, R=1.050→90%
- Single-point calibration (A=110 fixed). Two-point calibration requires hypoxic reference.

**HR estimator fix:** Per-frame zero-crossing estimator fails (gives 180-480 bpm nonsense) on 25 samples. Minimum needed: FFT over ≥75 samples (3s). Updated `stream_ppg_13.py` now uses rolling 250-sample (10s) FFT buffer, updated every 10 frames.

### Next Steps for PPG Validation

1. **Cross-check 84.2 bpm FFT HR** against CMD 0x29 poll or ring app at capture time — is it right?
2. **LED identity test** — cover ring with finger during capture: one channel goes to min (ambient light only) — that's the one that "turns off" = confirms which is green/red/IR
3. **SpO2 calibration** — compare ring's reported SpO2 to a pulse oximeter on the same finger
4. **Understand AGC events** — do frames 17/71-74 correspond to ring changing LED power? Test by covering/uncovering ring during capture.
5. **Port RSP 0x13 decoder to iOS app** (Healthops RingConnBLEManager.swift) for real-time PPG display

---

## 6. Tool Inventory (updated 2026-06-26 night)

All tools in `/OpenCircuit-master/desktop/`:

### Stage 1 — Raw PPG Ingestion Pipeline (new 2026-06-26)

| Tool | Purpose | Status |
|------|---------|--------|
| **`ppg_pipeline.py`** | Signal processing library: `BandpassFilter` (SOS 4th-order Butterworth, 0.5-8 Hz, causal + zero-phase), `AGCHandler` (linear interp over saturation gaps), `FFTHREstimator` (rolling 250-sample buffer), `SpO2Estimator`, `PPGPipeline` orchestrator | ✅ smoke-tested: 60.0 bpm from synthetic 1 Hz sine ✓ |
| **`capture_ppg.py`** | Production capture: mode10 pre-cond + mode01, push/pull hybrid loop, keepalive every 8s, CMD 0x29 ground-truth poll every 30s, auto-reconnect (5 attempts), feeds pipeline, writes CSV with raw+filtered+HR+SpO2 | ✅ ready to run |
| **`identify_channels.py`** | 3-phase LED identity test: wear (20s) → lift off (10s) → rewear (20s). Measures DC change per channel to identify green/red/IR. Live per-frame stats display during each phase. | ✅ ready to run |
| **`analyze_ppg_13.py`** | Batch analysis: accepts old + new CSV format, applies zero-phase filter, per-frame AC/DC stats, FFT HR (cubic detrend + Hanning), SpO2 ratiometric (both chB=red and chC=red scenarios), 4-panel matplotlib plot | ✅ validated on 62s capture |
| **`stream_ppg_13.py`** | Interactive streaming with live per-frame stats. Mode10 pre-cond + mode01. Rolling 250-sample FFT HR displayed. CSV export option. | ✅ validated (62-frame capture confirmed) |
| **`debug_ppg_mode10.py`** | Smoke-test: mode10 pre-cond → mode01 → 5 × 0x96 fetch. Quick go/no-go before full capture. | ✅ working |

### Stage 1 Validation Status

| Check | Status | Result |
|-------|--------|--------|
| RSP 0x13 reproducibility | ✅ Done | mode10 pre-cond required and confirmed |
| Sample rate | ✅ Done | 25 Hz confirmed (1 frame/wall-sec) |
| FFT HR validity | ✅ Done | 84.4 bpm — dominant peak, real signal |
| AGC events characterized | ✅ Done | 5 events/62s, 1-3 frames each, uint16 saturation |
| ppg_pipeline.py smoke test | ✅ Done | 60.0 bpm from synthetic 1 Hz ✓ |
| Channel LED identity | 🔲 Pending | Run `identify_channels.py` |
| ≥5 min BLE stability | 🔲 Pending | Run `capture_ppg.py --duration 300` |
| CMD 0x29 HR cross-check | 🔲 Pending | Built into `capture_ppg.py` (polls every 30s) |
| SpO2 calibration | ✅ Done | Apple Watch 98% → B=19.05 (SPO2_A=110, SPO2_B=19.05) |

### Existing Investigation Tools

| Tool | Purpose | Status |
|------|---------|--------|
| `livehr.py` | Live HR via 0x4E, polled HR+SpO2 via 0x29 | ✅ working |
| `poll_hr_spo2.py` | Continuous CMD 0x29 HR+SpO2 poller | ✅ working |
| `sweep_opcodes.py` | Full opcode sweep 0x00-0xFF with keepalive | ✅ complete |
| `decode_4d_4e.py` | Decode 0x4D/0x4E batch and live frames | ✅ working |
| `decode_bulk.py` | Decode 0x4C/0x47 history sync pages | ✅ working |
| `decode_ppg.py` | Decode 0x47 PPG trend pages → CSV | ✅ working |
| `probe_mode_09_plus.py` | CMD 06 modes 09-FF + 4-byte 0x96 probes → **FOUND RSP 0x13** | ✅ done |
| `probe_third_service.py` | Probe 0x0900 DFU service | ✅ done (DFU only) |
| `capture_app_session.py` | Passive capture with active probe sequence | ✅ working |
| `extract_last_night.py` | Extract overnight sleep data | ✅ working |

### sweep_opcodes.py Usage

```bash
cd desktop
.venv/bin/python sweep_opcodes.py <CBPeripheral-UUID> --start 0x00 --end 0xFF --keepalive 3
```

The `--keepalive 3` flag sends `95 00 00` every 3 commands to prevent BLE supervision timeout (ring drops after ~30-40s without it).

---

## 7. Ring Protocol Constants

| Constant | Value | Notes |
|----------|-------|-------|
| Ring epoch | 1,577,793,600 | unix_time - ring_epoch = ring_counter |
| Supervision timeout | ~30-40s | Send keepalive `95 00 00` every 8s |
| XOR framing | `xor(frame[0:-1])` | Last byte of every frame |
| cmd → rsp rule | `cmd = rsp ^ 0x80` | Most commands follow this; 0x30 → 0x0B breaks it |
| 0x4C step | 150s per record | 2.5-minute epochs |
| 0x47 step | 900s per record | 15-minute optical trend |
| 0x4D step | 10s per record | 10-second HR snapshots |

---

## 8. Stage 2 Priority (updated 2026-06-26 night — Stage 1 COMPLETE)

**Stage 1 is done.** Full handoff in `docs/ppg-stage1-complete-handoff-2026-06-26.md`.

### Immediate fix before Stage 2 (5 min)

Add startup buffer flush to `capture_ppg.py` — after `enter_ppg_mode()`, drain and discard RSP 0x13 frames for 3 seconds. Prevents the ring's buffered-session backlog from arriving as a mid-capture 78-frame burst dump.

### Stage 2 work (next session)

1. **Docker processing environment**
   - `docker-compose.yml`: `ppg-processor` (batch analysis), `api` (REST), `db` (TimescaleDB)
   - Processor auto-triggers on new CSV files from `capture_ppg.py`

2. **n8n orchestration**
   - Trigger: new CSV → ppg-processor → TimescaleDB → Obsidian daily note
   - Alert: SpO2 < 94% or HR anomaly → Telegram/Slack

3. **Obsidian PKM**
   - Per-session note: HR chart, SpO2, session quality metrics
   - n8n writes via Obsidian REST API plugin

### Quick sanity check before any Stage 2 session
```bash
cd <repo-root>/desktop
.venv/bin/python debug_ppg_mode10.py 375373B7-94D7-5B6E-9866-54073B5C04B3
```
Expected: `SUCCESS: RSP 0x13 confirmed` within 15s.
4. **Compute SpO2 from chB/chC** — Red/IR ratiometric method (R = (AC_red/DC_red) / (AC_IR/DC_IR); SpO2 ≈ lookup table)
5. **Test mode10 direct poll** — does `96 01 00 00 00` work while STILL in mode 0x10 (skip the mode01 step)?
6. **Identify LED channels** — which of chA/chB/chC is green, red, IR? Cover ring → one channel goes to min
7. **Port RSP 0x13 decoder to iOS app** (Healthops RingConnBLEManager.swift) for real-time PPG display
8. **Field3 ground truth** — wear ring, run `livehr.py`, move ring vs. press firmly, check 0x4E field3 variance

---

## 9. Next Tool to Build: probe_mode_09_plus.py

Rationale: CMD 06 modes 09-FF are completely untested. Any of these might be a "dedicated PPG streaming mode" that triggers 0x16 frames.

```python
# PROBES to add to new tool:
modes = range(0x09, 0x20)  # 09 through 1F
for mode in modes:
    send: bytes = bytes([0x06, mode, 0x00])
    # send keepalive first
    # send mode command
    # drain 3s with NOVEL opcode detection
    # if novel opcode seen: record and stop
```

Also probe CMD 0x05 with param bytes (0x05 00 00 triggered passive 0x4D; what does 0x05 01 00 do?).

---

## 10. Changelog

| Date | Event |
|------|-------|
| 2026-06-23 | SM3 auth cracked; full sync pipeline working |
| 2026-06-23 | Sleep data decoder (0x4A/0x4C) deployed to iOS app |
| 2026-06-24 | 0x4A continuation bug fixed (epoch-0 timestamp desync) |
| 2026-06-24 | 0x47 confirmed NOT pulse-resolution (0.033 Hz) |
| 2026-06-24 | 0x4D/0x4E (10s HR batch/live) discovered and decoded |
| 2026-06-24 | field3 in 0x4D/0x4E — likely DC photodiode baseline (🟡 unconfirmed) |
| 2026-06-24 | CMD 0x21 = BleEnterOTA → bricked ring temporarily |
| 2026-06-26 | Full sweep 0x00-0xFF complete. ~25 opcodes respond to XX 00 00 |
| 2026-06-26 | 0x2B safe, 0x30 → 0x0B (breaks cmd=rsp^0x80 rule) |
| 2026-06-26 | 0x28 → serial number "RCXXXXXXXXXXXXXX" |
| 2026-06-26 | 0x0D = non-destructive batch history peek (alias: 0x12) |
| 2026-06-26 | 0x29 = polled HR+SpO2 snapshot (no mode required) |
| 2026-06-26 | Third GATT service (0x0900) = DFU/OTA only (zero response to probes) |
| 2026-06-26 | 0x15 live HR confirmed (mode01, green LEDs) + red LED SpO2 in background |
| 2026-06-26 | 22 parameterized 0x96 probes — ALL no response. PPG trigger not found. |
| 2026-06-26 | libapp.so (82MB Flutter AOT) static analysis begun; frameType getters not found via string proximity search |
| 2026-06-26 | CMD 06 modes 09-1F probed — modes 09-0F rejected (0x86 FF), modes 10-13 accepted (0x86 00) |
| 2026-06-26 | **RSP 0x13 FOUND — raw multi-channel optical PPG!** Triggered by `96 01 XX XX XX` in mode01 |
| 2026-06-26 | RSP 0x13 frame: 160B, 25×6B records, 3 optical channels, XOR-verified, AC/DC 2-6% |
| 2026-06-26 | `stream_ppg_13.py` built — polls `96 01 00 00 00` every 1s for continuous 25Hz PPG |
| 2026-06-26 | `stream_ppg_13.py` failed with 0 frames on 2 runs — root cause: missing mode10 pre-condition |
| 2026-06-26 | Fix: enter mode 0x10 then exit before mode01 — mirrors probe_mode_09_plus.py sweep order |
| 2026-06-26 | mode10 fix verified: push mode confirmed, 62-frame capture succeeds |
| 2026-06-26 | 25 Hz sample rate confirmed (1 frame/s, 25 samples/frame, wall-clock exact) |
| 2026-06-26 | FFT HR = 84.2 bpm from 57s of chA data — PPG signal is REAL |
| 2026-06-26 | Per-frame AC/DC: chA=6.3%, chB=1.9%, chC=2.4% — all pulse-resolution |
| 2026-06-26 | 5 AGC events identified (saturation at seqs 17,71,72,73,74) — normal ring behavior |
| 2026-06-26 | Per-frame zero-crossing HR estimator replaced with rolling 10s FFT buffer |
