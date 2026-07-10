# Runbook — OSA sleep-apnea assessment → local AHI/ODI (#91)

**Status: PARKED (capture banked, decode not started).** The overnight snoop on
2026-07-08 captured a full sleep-apnea assessment — the start command and the dense
PPG stream are in hand. What remains is a genuine signal-processing + RE project
(decode the PPG → SpO₂ → apnea/desaturation scoring). This doc records exactly what
we have and the directions to take it forward so anyone can pick it up cold.

See also: [`PROTOCOL.md`](PROTOCOL.md) §5, issue #91, and memory `osa-capture-cracked`,
`snoop-write-opcodes`, `apk-decompile-sqlite-schemas`, `ring-device-access`.

## Why this can't be a quick decode
- The ring does the apnea reading **only when the user explicitly starts a "Sleep Apnea
  Assessment"** in the official app. A passive overnight snoop with no assessment shows
  only the normal `0x4c` sleep vitals + `0x47` PPG (confirmed by a null capture the night
  before).
- The **AHI / event count is computed by the app/cloud from the raw PPG — it is NOT a
  value the ring sends** (same as BP and "circulation stress"). So there is no "32 events"
  record to read; a local number has to be *derived* from the raw waveform.
- The app itself needs **3 nights (one assessment/night)** for its "comprehensive
  assessment."

## What we have (🟢 confirmed, 2026-07-08 FR02.018)

Device facts (memory `ring-device-access`):
- Ring BLE MAC: `F8:79:99:F7:03:AD`
- Official app package: `com.gdjztech.ringconn`
- Data characteristic: notify `0x0804` (ring→host), write `0x0802` (host→ring)

Opcodes (all obey resp = cmd ^ 0x80):
- **OSA start = `05 22 01`** (sent at assessment start, 23:49 in the capture). `05 22 02`
  = stop/mode. Same `05 2x` detection-control family as the `05 23` toggles.
- **Dense PPG stream = `0x48`** — the raw apnea waveform.
- **Per-epoch record = `0x4d`** — only a brief burst at assessment *start* in this
  capture (~per-10 s records); may carry per-epoch HR/SpO₂/event flags in a fuller run.

**Store-and-forward (important):** the overnight BLE link dropped (~10.6 h gaps — Android
background-BLE suspend, same class as #119), yet **all 7,200 `0x48` frames arrived in a
single ~3-minute burst on the morning reconnect (08:10:03→08:13:19)**. The ring buffers
the whole assessment internally and dumps it on reconnect. **We do NOT need to hold a live
overnight connection — start the assessment, let the ring buffer it, drain in the morning.**

**Ground truth — complete 3-night "comprehensive assessment"** (app report, 2026-07-10),
one matched `0x48` capture per night:

| Night | Capture | 0x48 frames | AHI | ODI | SpO₂ avg | SpO₂ min | time<90% | %<90% |
|---|---|---|---|---|---|---|---|---|
| 07/08 | `osa2_*` | 7200  | 4.3 | 4.2 | 96% | 85% | 3m24s | 0.76% |
| 07/09 | `osa3_*` | 6014  | 2.2 | 3.8 | 96% | 87% | 1m50s | 0.40% |
| 07/10 | `osa4_*` | 13141 | 3.7 | 4.8 | 95% | 87% | 3m50s | 0.91% |

All internally consistent (AHI = events/hr; %<90% = seconds/duration). These are the numbers a
local computation must reproduce.

**Value chain the report reveals:** decompress `0x48` → dense **SpO₂ series** → **ODI,
time<90%, SpO₂ min/avg are then all directly computable locally** (validate against the table).
Only **AHI** needs an extra apnea-event algorithm on top (cloud-side, unseen). So SpO₂/ODI is the
achievable tier; AHI is the stretch goal. The brief nadirs (min 85 %, 1–4 min dips) likely require
the DENSE OSA SpO₂ — coarse normal-sleep sampling would miss them — so this still needs the
`0x48` decompress, not the existing `0x4c`/Spo2Sync channels.

Raw captures (gitignored — real health data, never commit):
`desktop/captures/osa{2,3,4}_extract/.../btsnoop_hci.log` + `osa{2,3,4}_decoded.txt`.

## APK findings (2026-07-09) — `0x48` is COMPRESSED PPG; AHI is cloud-side

Dug into `libapp.so` (`/private/tmp/ringconn_apk/lib/arm64-v8a/libapp.so`; the raw APK is
also at `/private/tmp/ringconn_apk/`, and the app is installed on-device to re-pull). This
reshapes the difficulty:

- **`0x48` = "offline OSA data" and it is COMPRESSED PPG.** The BLE handler mixins spell it
  out: `BleGetOfflineOsaRspMixin`, `BleOfflineOsaDataRspMixin`, `BleOnlineOsaDataRspMixin`,
  `BleAutoOsaDataRspMixin`, `BleOsaCompatibleModeMixin`, and — decisively —
  **`BleCompressPpgRspMixin` / `BleCompressPpgProgressMixin`** (+ `saveMemoryPPGData`,
  `ppgDataIncomplete`). This is why blind 3-byte extraction produced high-entropy noise: the
  payload is compressed, not raw samples. (The stride-3 signal is a weak residual, not the
  real layout.) **Step 1 is therefore DECOMPRESSION, not byte-layout guessing.**
- **AHI is computed in the CLOUD.** `osaRecordUrl` / `todayOsaData` — the app uploads the
  OSA record to a server URL; the 32-events/AHI-4.3 number comes back from there, it is not
  computed on the ring or locally in the app. So a fully-local AHI means re-implementing an
  algorithm we can't see.
- **SpO₂ derivation (field names confirmed).** `HistorySpo2BaseInfo(acIr, piIr, acRl, piRl,
  spo2, ...)` — SpO₂ is computed from AC + perfusion-index of the **IR** and **Red** channels
  (standard ratio-of-ratios). `HistoryHrSyncInfo(pr, hrv, mov, resprate, actiCount, ...)` and
  `SleepSyncModel(sleepPhases, ...)` give the rest of the on-device schema. There is a
  `PpgSample` table (`INSERT INTO PpgSample (...)`) — its columns are the decompressed-PPG
  schema worth extracting next.

**Revised difficulty:** local AHI now requires (a) reverse the PPG **compression codec**
(from Dart AOT — hard without blutter symbol reconstruction), then (b) SpO₂ via
acIr/piIr/acRl/piRl, then (c) an apnea/desaturation scorer to approximate the **cloud**
algorithm. This is a large project; the realistic near-term win is decompression + SpO₂
(local overnight SpO₂/ODI), not a validated AHI.

## `0x48` frame envelope (decoded) — payload is COMPRESSED (see APK findings above)

Each frame is **196 bytes**, one session (cursor `0x0c425adc`):

```
48 | c1 | CC CC CC CC | SS SS SS SS | 00 00 | OO OO | <182 bytes payload> | XX
op   flag  counter       session cur    ?       offset    packed samples      xor
```
- `flag` = `0xc1` (constant)
- `counter` (4B) decrements **−20 per frame** from `105900 → 0` (end-of-transfer marker)
- `session cursor` (4B) constant across the session (`0x0c425adc`; sync-epoch seconds,
  PROTOCOL.md §5.6)
- `offset` (4B incl. the `00 00`) increments **×4000 per frame** (frame sequence marker)
- **182-byte payload = packed multi-channel PPG.** The encoding is NOT a simple
  `<tag><u16>` triplet (that alignment was a coincidence). 182 = 2·7·13 → candidate sample
  widths 7 / 13 / 14 bytes. Compare to the already-decoded `0x47` PPG (5-byte sample
  groups, `PPGTrend.swift`).

7,200 frames ≈ 1.3 MB — likely **downsampled or event-windowed**, not full-night 25 Hz raw
(a full night of 3-channel 25 Hz PPG would be far larger). Verify the true time coverage by
decoding sample timestamps/rate once the layout is known.

## Directions forward (the actual work)

**Step 1 — reverse the PPG COMPRESSION (APK-assisted; the long pole).** The `0x48` payload
is compressed (see APK findings), so byte-layout guessing won't work — the codec must be
recovered first.
- Target the Dart classes named in the mixins: **`BleCompressPpgRspMixin`**,
  `BleOfflineOsaDataRspMixin`, `BleGetOfflineOsaRspMixin`. Re-run **blutter** on
  `/private/tmp/ringconn_apk` (the old `old321_out` dump is gone) to get readable Dart for
  the decompressor; without blutter, the raw ARM64 in `libapp.so` is very hard.
- Look for the codec signature: likely a delta + entropy scheme (the frame `offset` steps
  ×4000 = decompressed-chunk size; the `counter` counts down remaining compressed bytes).
- Validate a candidate decompressor by checking the output forms 2–3 slow-DC PPG channels
  (Red/IR/Green) with a ~1 Hz pulsatile AC at the true sample rate.

**Step 2 — Red/IR → SpO₂.** Standard pulse-oximetry: per channel split AC/DC, then
`R = (AC_red/DC_red) / (AC_ir/DC_ir)`, `SpO₂ ≈ a − b·R`. Calibrate `a,b` against the ring's
own overnight SpO₂ from `0x4c` (already decoded, `BulkSleep`) and the app's reported SpO₂
nadir.

**Step 3 — desaturation / apnea → AHI/ODI.** Detect ≥3–4 % SpO₂ desaturations (ODI) and
apnea events (airflow-cessation proxy from the PPG envelope / HR + SpO₂ pattern). AHI =
events ÷ sleep-hours. **Validate against 32 events / 7h25m / AHI 4.3.** Expect to need the
3-night captures for a real fit.

**Step 4 — ship.** Swift decoder in `OpenCircuitKit` + write to HealthKit. Check the iOS
breathing-disturbance category types (recent iOS exposes sleep breathing-disturbance
metrics); otherwise store as a custom metric. Label everything an ESTIMATE (house style).

## Reproduce / extend the capture

1. Android → Developer options → **Enable Bluetooth HCI snoop log**; toggle Bluetooth
   off/on so it takes effect.
2. Connect the ring to the **official app** (`com.gdjztech.ringconn`); **start a Sleep
   Apnea Assessment** before bed. Wear overnight (the link may drop — store-and-forward).
3. Morning: `adb bugreport osaN` → unzip `FS/data/log/bt/btsnoop_hci.log` →
   `python3 -m opencircuit decode-log <log> > osaN_decoded.txt`.
4. Filter: `0x48` (dense PPG), `0x4d` (per-epoch), `05 22` (control). **Record the app's
   AHI + event count as ground truth for that night.**
5. **Buffer caveat:** the snoop is a rolling buffer — pull the bugreport **soon after
   waking**, before the dense dump rotates out (this capture was 10.5 MB; a denser or
   multi-night session can overflow and lose the earliest packets, incl. the start command).
6. For the **comprehensive** assessment, capture all **3 nights**, and watch whether a
   per-night *result* record (AHI/events) ever appears over BLE after the app computes it
   (a cloud round-trip could write it back — probably not, but confirm).

## Open questions to resolve first
- Is `0x48` the full night or a windowed/downsampled slice? (Decide before building a
  scorer — it changes what "events" you can even see.)
- Does the fuller `0x4d` stream carry per-epoch SpO₂/event flags? If so it may be a far
  cheaper path than raw-PPG DSP — check in the next capture.
- Confirm the SpO₂ derivation against the ring's own `0x4c` overnight SpO₂ before trusting
  any AHI number.
