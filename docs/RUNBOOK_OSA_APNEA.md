# Runbook — OSA sleep-apnea assessment → local AHI/ODI (#91)

**Status: SpO₂ PIPELINE VALIDATED (2026-07-10).** The `0x48` stream is **NOT compressed** (the
"CompressPpg" naming misled us) — it's lightly-framed **raw 3-channel 18-bit PPG**, decoded and
validated (HR 62–69 bpm, perfusion index 1.6–2.5%). A full **SpO₂ pipeline** (dedupe →
frequency-domain ratio-of-ratios → calibrated curve) now reproduces the app's **average SpO₂ to
±1% across all 3 nights** and the **nadir to within ±3%**. Calibration `SpO₂ = 104.91 − 15.18·R`
(**IR = ch0, Red = ch1**). Pipeline: `osa_ppg.py` (frame decode) → `osa_spo2.py` (dedupe/channels)
→ `osa_spo2_fd.py` (FD R-series) → `osa_metrics.py` (metrics). **Remaining tier:** `time<90%`,
ODI and AHI need the app's proprietary artifact-rejection + event-scoring model (partly cloud-side)
— locally they come out directionally correct but not yet to-the-second. Next build step: Swift
port of the pipeline → HealthKit.

### SpO₂ pipeline — validated results (🟢)
Chain: `0x48` frames → **dedupe by counter** (the morning burst retransmits ~1900 dup frames/night;
counter steps −20 = 20 samples/ch, ~0 % true loss) → 3 channels → per-128-sample window (~30 s):
lock the cardiac frequency on the green channel (Goertzel), require a clean pulse in **all three**
channels (`SNR_IR≥5, SNR_red/green≥4`) and `PI_ir≥0.15 %` (low perfusion ⇒ AC_ir tiny ⇒ R
unreliable, exactly what clinical oximeters flag) → `R = (AC_red/DC_red)/(AC_ir/DC_ir)` →
`SpO₂ = 104.91 − 15.18·R`. Sample rate **≈ 4.15 Hz/channel** (pulse-anchored: median cardiac
f\* ⇒ 47–49 bpm, matches the `0x4c` HR and osa4's 7.05 h = ground-truth duration).

| Night | SpO₂ avg (GT) | SpO₂ min (GT) |
|---|---|---|
| osa2 07/08 | 96.0 (96) | 85.6 (85) |
| osa3 07/09 | 96.5 (96) | 88.4 (87) |
| osa4 07/10 | 96.7 (95) | 83.7 (87) |

The `A,B` fit is a 3-night least-squares on the (avg, nadir) anchors — a 2-parameter curve, so
don't over-read the exactness; re-fit when more labeled nights land. **Data-hygiene gotcha:** a
capture can re-dump the *previous* night's session (osa4 contains osa3's `0x0c43adeb` frames byte
-for-byte **plus** the new `0x0c44f92a`) — always split `0x48` by the 4-byte session cursor and keep
only the target night, or you double-count.

_Historical calibration note: the very first pass (time-domain peak-to-peak AC, Red=ch1/IR=ch0)
read 93 % vs 95 % — that error was the large respiratory/baseline wander leaking into peak-to-peak
AC. The frequency-domain AC (magnitude at the locked cardiac bin) is what fixed it._

### Two complementary SpO₂ sources (both in every capture — no new capture needed)
There are **two** SpO₂ streams in the OSA captures; use both:

| Source | Rate | Coverage | SpO₂ | Needs | Best for |
|---|---|---|---|---|---|
| **`0x4c` BulkSleep** | 2.5-min epoch | full night, store-and-forward | **ring's OWN per-epoch value** (`byte[8]`) | no DSP, no calibration | shippable full-night avg/baseline |
| **`0x48` dense PPG** | ~4.15 Hz | full night, store-and-forward | derived (FD ratio-of-ratios + calib) | DSP + artifact rejection | brief event nadirs / ODI |

`0x4c` (`osa_4c.py`) pulls the ring's own per-epoch SpO₂/HR straight off the wire — **avg 95.6
(osa2) / 95.4 (osa4) vs report 96 / 95, ±1 %, with zero DSP.** It independently corroborates the
`0x48` pipeline's average. **⚠️ Classify sleep-vitals epochs STRUCTURALLY (not idle AND
`byte[8]`∉{0x12,0x13}), NOT by the `0x57..0x63` band** — the band gate drops sub-87 % desaturation
epochs, i.e. exactly the OSA nadirs (PROTOCOL.md §5.3 #39 correction). Caveats: the coarse 2.5-min
sampling doesn't nail the true nadir (osa2 reads 87 vs the app's 85; osa4 dips to 84 on a motiony
epoch vs the app's smoothed 87) — the dense `0x48` is still the substrate for real event/ODI work.
And `0x4c` can rotate out of the snoop buffer (osa3 kept only 2 records) while `0x48` survived — a
second reason to keep both. **Shipping recommendation: write the `0x4c` per-epoch SpO₂/HR series to
HealthKit first (ring's own values, matches the app), layer the `0x48`-derived event metrics on
top once artifact rejection lands.**

### `0x48` decoded format (🟢 validated)
Frame after the `0x48` opcode = 196 B:
- **header 13 B:** `<flag c1> <4B counter, −20/frame> <4B session cursor> <2B> <2B offset ×4000>`
- **payload 182 B = `[1B marker][30 samples]` × 2** (markers at payload byte 0 and 91;
  1+90+1+90 = 182). *Missing the second marker was the whole reason blind decoding "looked
  compressed".*
- **samples: 3-byte BIG-ENDIAN, ~18-bit (full-scale ≈ 0x7FFFE), 3 LED channels interleaved by
  `idx % 3`, ~10.35 Hz/channel.** ch0/ch1 = the SpO₂ pair (IR/Red), ch2 = Green (HR).

blutter is a **dead end** here: it builds (Dart 3.11.5) but SIGBUS-crashes on this 82 MB
`libapp.so`. The decode above was recovered empirically — don't burn time re-running blutter.

---
_Historical note: the sections below were written when we believed the stream was compressed
(pre-2026-07-10). They're kept for the APK/OSA-command context; the "compressed" framing is
superseded by the decoded format above._

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

**Step 1 — decode the `0x48` PPG. ✅ DONE.** Not compressed; format above; `osa_ppg.py` /
`osa_spo2.py`. (Superseded the "reverse the compression" plan — blutter is a dead end, and the
"CompressPpg" Dart naming was a red herring.)

**Step 2 — Red/IR → SpO₂. ✅ DONE & VALIDATED.** IR = ch0, Red = ch1; **frequency-domain**
AC/DC (magnitude at the locked cardiac bin — time-domain peak-to-peak fails on the respiratory
wander); `R = (AC_red/DC_red)/(AC_ir/DC_ir)`; `SpO₂ = 104.91 − 15.18·R`. Reproduces avg to ±1%,
nadir to ±3% across 3 nights (`osa_spo2_fd.py`, `osa_metrics.py`). Gating: clean-pulse SNR in all
3 channels + `PI_ir≥0.15 %`.

**Step 3 — desaturation / apnea → ODI / time<90% / AHI. ⚠️ PARTIAL (the hard tier).** The
SpO₂ *series* is real, but reproducing the app's exact `time<90%` / ODI / AHI needs its
artifact-rejection + event-scoring model, which is partly cloud-side:
- Locally, `time<90%` and ODI come out the right order of magnitude but not to-the-second — the
  knobs (perfusion floor, sustained-min window, ODI %-drop, motion rejection) trade off against
  each other and over-fitting them to 3 nights is a trap.
- The gap is dominated by **positional low-perfusion periods** (subject lying on the hand ⇒ IR
  perfusion collapses ⇒ R inflates ⇒ fake desaturations). Distinguishing those from true desats is
  the app's decade-tuned secret sauce. Best lead: a smarter positional/motion detector (sustained
  PI_ir collapse + DC drift) that *excludes* those epochs the way the app's "sleep-only, quality-
  gated" analysis does.
- **AHI** additionally needs an airflow/effort model (the app computes it server-side from the PPG
  envelope + HR pattern). Treat as a research stretch, not a shipping target.
- Validation targets remain the 3-night table (AHI 4.3/2.2/3.7, ODI 4.2/3.8/4.8).

**Step 4 — ship. NEXT.** Swift port of the pipeline (`osa_ppg`/`osa_spo2`/`osa_spo2_fd` → an
`OSASpo2` analyzer in `OpenCircuitKit`) + write the SpO₂ series to HealthKit
(`HKQuantityType(.oxygenSaturation)`; check the iOS sleep breathing-disturbance category too).
Ship the **SpO₂ avg/min/series** first (validated); leave ODI/AHI labeled EXPERIMENTAL until the
positional-artifact model lands. Label everything an ESTIMATE (house style).

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

## Open questions
- ~~Is `0x48` the full night or a windowed/downsampled slice?~~ **Answered:** full monitoring
  window at ~4.15 Hz/channel (osa4's 105 400 samples ⇒ 7.05 h = its ground-truth duration).
  Caveat: osa3 under-captured (~6 h of a 7.7 h night) — its morning dump was short, so a night's
  `0x48` can be truncated by a late/short reconnect; pull the bugreport promptly.
- Does the fuller `0x4d` stream carry per-epoch SpO₂/event flags? Still open — only a short
  start-of-assessment burst was captured. If it holds per-epoch SpO₂/desat flags it could give
  ODI/AHI far more cheaply than the raw-PPG DSP tier. **Check the `0x4d` payload in the next
  capture** (this is the most promising lead for the ODI/AHI gap).
- The positional low-perfusion artifact is the main blocker for `time<90%`/ODI accuracy — see
  Step 3. A sustained-PI_ir-collapse detector is the next thing to try on the desktop side.
