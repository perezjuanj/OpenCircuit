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

**Ground truth for the captured night** (app-reported): **32 apnea events / 7h25m sleep →
AHI 4.3, "no abnormalities"** (AHI < 5 = normal; 32 ÷ 7.42 h = 4.3 ✓). This is the number
a local computation must reproduce.

Raw capture (gitignored — real health data, never commit):
- `desktop/captures/osa2_extract/FS/data/log/bt/btsnoop_hci.log`
- `desktop/captures/osa2_decoded.txt` (decoded via `opencircuit decode-log`)

## `0x48` frame envelope (decoded) — sample encoding still UNKNOWN

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

**Step 1 — crack the 182-byte sample encoding (APK-assisted; the long pole).**
Pure guessing is unlikely to be efficient. Use the decompiled app:
- Decompiled APK / blutter output: `/private/tmp/ringconn_apk/old321_out`;
  `pp.txt` has the app's `CREATE TABLE` schemas = semantic field names
  (memory `apk-decompile-sqlite-schemas`).
- `strings libapp.so | grep -iE "osa|apnea|ahi|odi|spo2|desat|0x48|keyOSA"` — find the
  OSA model + the PPG/`0x48` parser and its field widths.
- Cross-check widths on the real bytes: try 7/13/14-byte strides on a mid-stream frame and
  look for 2–3 slowly-varying channels (PPG DC) with a pulsatile AC component.

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
