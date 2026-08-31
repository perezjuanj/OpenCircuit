# RingConn Gen 2 — BLE Protocol (living spec)

This is the primary deliverable of Phase 1. Everything here is an **observation**,
not vendor documentation. Mark each fact with a confidence level and the capture it
came from. Treat unconfirmed entries as hypotheses to disprove.

Confidence legend: 🟢 confirmed (reproduced) · 🟡 probable · 🔴 guess / unverified

**Reference capture:** Android btsnoop, FW **FR02.018**, ring `RingConn Gen2-03AD`
(MAC `F8:79:99:F7:03:AD`), 2026-06-13 21:51. 326 ATT events: identity reads, a live
measurement (`0x95` poll loop), and a bulk history/PPG download. Pin observations
below to this FW until re-confirmed on another version.

**Gen 3 reference capture (§5.9/§5.10):** iPhone `idevicebtlogger` snoop, FW **FR05.011**,
RingConn app **4.3.1**, 2026-08-27. 20 943 HCI packets / 1 962 ATT events over 14 m 44 s, driven
by `docs/RUNBOOK_GEN3_BP_HAPTIC.md` §4.2 (vibration test taps, workout, HR + SpO2 spot
measurements, 3 blood-pressure assessments, one paired with a cuff). Gen 3 speaks the same
framing and reuses the Gen 2 opcodes; `0x0b` (motor) and mode `06 05` are Gen-3-only additions.

---

## 0. Encryption gate — ANSWERED 🟢

**The BLE application layer is NOT encrypted.** ATT payloads in the capture are
plaintext: readable identity strings, monotonic counters, and a checksum that
validates (§3). No app-layer key exchange or challenge/response precedes data
access. Offline decoding is viable → the iOS app is unblocked.

**BUT data commands are gated behind an LE bond** 🟢 (live test, 2026-06-14). An
*unbonded* central (macOS bleak) connects, subscribes, and gets replies to the `0x01`
status handshake (`81 00 …`, `81 01 …`) — but the ring **silently drops every data
command**: `0x02` sync-open (even the known-good real cursor `0c2298c3` that returns
`82 00 00 82` on the bonded phone), `0x07` fetch, `0x95` poll — zero response. So:
- The **bonded phone** (Android btsnoop) is the only way to pull real data; this is why
  all metric RE here uses phone captures, and why the iPhone app works (iOS bonds).
- The **desktop `opencircuit` workbench can scan/enumerate/handshake but NOT pull data**
  — CoreBluetooth/bleak can't initiate pairing (`pair()` → NotImplementedError on macOS).
  `listen`/`replay` of data commands will see nothing. Active probing from the Mac is a
  dead end; capture the phone instead.

**Resolved on iOS 🟢 (2026-06-14): bonding unlocks data, and it's shared across apps.**
Our iPhone app first hit the same wall (live HR poll → only the `81 01` handshake, no
`0x15` frames). The fix: **bond the iPhone to the ring once** — installing the official
RingConn iOS app and signing in establishes the device↔ring LE bond. BLE bonds are
**per device, not per app**, so OpenCircuit then inherits it: `02`/`07`/`95` go through
and **live HR decoded 68 bpm** + history sync started. The ring supports multiple paired
phones, so this doesn't disturb the Android pairing.
> **Operational requirement:** any device running OpenCircuit must already be bonded to
> the ring (pair via the official app once). This is the make-or-break unknown — answered:
> offline decode works, *direct ring access* just needs a one-time bond.

## 1. Connection & GATT layout

> ⚠️ Reported as not fully GATT-compatible. The capture confirms the app drives the
> ring almost entirely through two value handles (`0x0802` write, `0x0804` notify)
> rather than discrete per-metric characteristics.

### Identity (Device Information Service `0x180a`)
| Item | Value | Conf. | Source |
|---|---|---|---|
| Advertised name (GAP `0x2a00`, val handle `0x0003`) | `RingConn Gen2-03AD` (suffix = last 2 MAC bytes) | 🟢 | capture + scan |
| Manufacturer (`0x2a29`, val `0x0032`) | `JZ_Tech` | 🟢 | capture + scan |
| Serial (`0x2a25`, val `0x0034`) | `RCA1F252311002B09` | 🟢 | capture + scan |
| Firmware (`0x2a26`, val `0x0036`) | `FR02.018` | 🟢 | capture + scan |
| System ID / MAC (`0x2a23`, val `0x0038`) | `F8:79:99:F7:03:AD` | 🟢 | capture + scan |
| Hardware rev (`0x2a27`, val `0x003a`) | `00010001` | 🟢 | capture + scan |

### Primary data service `8327ad99-2d87-4a22-a8ce-6dd7971c0437` (handle `0x0800`) 🟢
The ring is driven entirely through this notify/command pair (not per-metric chars).
iOS addresses by UUID; the value handle = characteristic declaration handle + 1.

| Role | Characteristic UUID | Decl. | **Value** | Props | Conf. |
|---|---|---|---|---|---|
| **Write / commands** | `8327ad98-2d87-4a22-a8ce-6dd7971c0437` | `0x0801` | `0x0802` | write | 🟢 |
| **Notify (all responses + data)** | `8327ad97-2d87-4a22-a8ce-6dd7971c0437` | `0x0803` | `0x0804` | notify | 🟢 |
| Notify CCCD (enable w/ `01 00`) | `0x2902` | — | `0x0805` | — | 🟢 |

### Secondary service `1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0` (handle `0x0900`) 🔴
Two **write** characteristics; role unobserved in the capture (likely OTA/firmware
or bulk transfer). Not used by the main protocol. Decode if needed later.

| Characteristic UUID | Handle | Props |
|---|---|---|
| `f7bf3564-fb6d-4e53-88a4-5e37e0326063` | `0x0901` | write |
| `984227f3-34fc-4045-a5d0-2c581f81a153` | `0x0903` | write, write-without-response |

> Corrections now confirmed by `scan`: (1) GB #4506's char UUIDs were right
> (🟡→🟢). (2) GB #4506 mislabeled `f7bf3564`/`984227f3` as *services* — they are
> *characteristics* inside service `1d14d6ee`; the real data service is `8327ad99`.
> (3) value handle = decl + 1, which ties the scan to the capture's `0x0802`/`0x0804`.

## 2. Authentication / handshake

**No app-layer handshake observed.** After enabling notifications (`0x0805 ← 01 00`)
the app immediately issues data commands and the ring responds — no token, no
challenge, no key derived from MAC/serial. History sync uses the same channel as
live data with no extra *app-layer* auth.

**The skipped step is the LE bond itself** 🟢 (§0, live test): on an already-bonded
phone the app needs no further auth, but an unbonded central gets only the `0x01`
handshake — data commands (`0x02`/`0x07`/`0x95`) are silently dropped until the link
is bonded. So the "no auth" above is conditional on a bonded link.

## 3. Framing 🟢 (verified live on the Mac)

**Commands and responses use DIFFERENT trailers — this corrects an earlier error.**

**Responses (RX, ring → host):** `[respid][payload…][xor]`
- **respid = command id XOR 0x80**: `01→81 · 02→82 · 06→86 · 07→87 · 95→15 · c7→47 · cc→4c · d0→50` (10 cmds reproduced).
- **xor trailer** = XOR of all preceding bytes. Validates on 86/88 RX frames. (The two `0x50` status frames lack it — see §5.)

**Commands (TX, host → ring):** `[cmd][sub][payload…][00]` — **NOT checksummed.**
- Sent **verbatim**; the last byte is a literal `0x00`, not an XOR. ⚠️ The GB #4506
  keepalive `95 00 95` is **wrong**; the real command is `95 00 00`. Building command
  frames by appending an XOR trailer produces invalid bytes the ring ignores.
- The ring ATT-acks any write but only *acts* on commands whose contents are valid.

Bulk frames (`0x47`/`0x4c`) pack fixed-size records, each prefixed by delimiter
`0x0c` + a **3-byte BE counter** in the sync-cursor space (`0x47` steps `+0x0384`,
`0x4c` steps `+0x96`; see §5.2/§5.3). Continue a page by ACKing: `0x47` → `c7 00 00`,
`0x4c` → `cc 00 00`; the page header byte[2] counts remaining records, `0x00` on the last.

## 4. Commands (request → response) 🟢

| Command | Write (hex) | Resp | Role | Conf. |
|---|---|---|---|---|
| Status read | `01 00 00` | `81 00 ..` | works unauthenticated; only cmd that replies cold | 🟢 |
| Status read 2 | `01 01 31 82 67 00` | `81 01 ..` (38B) | record/config table | 🟢 |
| **Sync open** | `02 00 <cursor:4> 00 01 00` | `82 ..` | opens data session; **cursor, not wall-clock** | 🟢 |
| Fetch / stream | `07 00 00` | `87`/`15`/`47`/`4c` | pulls next data per current mode | 🟢 |
| Live-HR mode | `06 01 00` | `86 00 86` | switch session to live HR | 🟢 |
| Poll | `95 00 00` | `15 ..` | one live sample per poll | 🟢 |
| Page ACK | `c7 00 00` / `cc 00 00` | `47`/`4c` | continue bulk transfer | 🟢 |
| Status query | `d0 00 00` | `10`/`50` | session/record status | 🟡 |
| **Vibrate motor** | `0b 03 <pattern> 64 00` | `8b 00 8b` | **drive the Gen 3 haptic motor** (§5.9) | 🟡 |
| **BP / dense-PPG mode** | `06 05 00` | `86 00 86` | mode 5 → pushes 100 Hz `0x12` raw PPG (§5.10) | 🟢 |
| Sensor/temp readout | `29 00 00` | `a9 ..` (10B) | descriptor `[6:14]` slice; app sends it before every BP run | 🟡 |

**The `02` arg is a sync CURSOR, not a timestamp** (🟢, this was the key unlock). The cursor
is *seconds since 2019* (§5.6). ⚠️ **`02 00 FF FF FF FF 00 01 00` does NOT mean "sync
everything"** — `FF FF FF FF` is a far-FUTURE position that does not pull history (see the
load-bearing caveat below).

**How the official app pulls history** (🟢 *for the app's observed behaviour*,
`ppg_align_20260616` capture, 23 sync-opens via `desktop/analyze_cursor.py`): **the app opens
at cursor ≈ NOW on every sync** — *never* `FF FF FF FF` — and that open **triggers a drain of
everything the ring hasn't handed off, up to the ring's current time.** The cursor acts as a
"drain up to ≈now" trigger, **NOT a hard bound**:
- Records routinely **overshoot** the open cursor — in 11/23 syncs the last returned record is
  *above* the open (by up to ~39 min): the drain takes minutes and epochs created *during* it
  keep streaming past the frozen cursor. So this is **not** "counter ≤ C"; the cursor only has
  to look like a plausible recent time to trigger the drain (an absurd-future cursor does not).
- Each sync resumes where the previous ended: open `0c22bbf7` → `0c22a16b..0c22bb60`; next open
  `0c233d95` → `0c22bbf6..0c233cdf`. The FIRST open (`0c2298c3`) drained ~19 days in one shot
  (`0c099dbf..0c2299cd`). The ring tracks its **own** resume pointer; the app persists none.
- The 23 opens increase monotonically and are **never** equal to the previous `0x50 to` →
  consistent with "open at ≈now," not "resume from the last reported cursor." (The Δ between
  opens is read from the cursor values, not measured against packet wall-clock.)
- The `0x50` end-of-history `to` cursor **trails the last delivered record** (e.g. `to=0c2299c8`
  vs last record `0c2299cd`), so consecutive syncs re-deliver a small overlap — hence the
  cross-sync **dedup** in `LocalStore`/`SyncCursor` and `extract_last_night.py`.
- The app **drains even when entering live HR** (`btsnoop_hr`: live entry opens `0c2298c3`,
  cursor≈now, draining a 19-day backlog *before* HR mode). It has **no** "skip-backlog" open —
  our `FF FF FF FF` live path (below) is a deliberate, *unverified* divergence.

⚠️ **Load-bearing and NOT ground-truthed (🟡): what `FF FF FF FF` actually does.** The official
app never sends it in any capture, so this is inferred:
- **New 🟡 signal (2026-06-24, on-device iOS log, FW unspecified): the `0x82` sync-open ACK's
  `byte[2]` differs by cursor.** Every real-cursor open (`syncUpToNow`, `ch=sleep`/`ch=all-day`)
  in that session ACKed `82 00 00 82` (byte[2]=`0x00`), reproduced 3×. Every `syncAll`
  (`FF FF FF FF`) open in the SAME session ACKed `82 00 01 83` (byte[2]=`0x01`), also reproduced
  3×, on the live-HR and live-SpO2 entry sequences. `PROTOCOL.md` previously documented every
  `0x82` example as `82 00 00 82` with byte[2] unexamined — this is the first evidence it's not
  constant. Plausible reading: byte[2] flags whether the open actually had backlog to hand off
  (`0x00`) vs the skip-backlog/empty case (`0x01`) — which would make it a cheap, synchronous way
  to confirm `FF FF FF FF` does NOT drain history, independent of the A/B test below. Still 🟡:
  one session, no confirmation of what byte[2] means when a REAL cursor returns genuinely empty
  (only ever observed non-empty real-cursor opens so far).
- **New 🟡 signal (2026-06-28, on-device iOS log): `0x82 byte[1]` appears to flag
  pointer-at-end (history already consumed).** All-day channel (`0x03`) ACKed `82 ff 00 7d`
  (byte[1]=`0xff`) in a session where the sleep channel had already been drained by a prior sync.
  Every prior real-cursor ACK with actual pages to deliver had byte[1]=`0x00` (e.g. `82 00 00 82`).
  Pattern: **byte[1]=`0x00` → pages will follow; byte[1]=`0xff` → pointer already at end, nothing
  to stream.** The app now captures this as `sawEmptyHistorySignal` and exits the drain loop after
  3 s of quiet instead of waiting the full 45 s cap — a ~42 s saving per empty channel. Still 🟡:
  single session; confirmed for `0x03` (all-day), not yet for `0x00` (sleep).
- "`FF FF FF FF` → empty" comes only from our `livehr.py` replay — which *also* reused a stale
  `01 01` nonce (§ session-open nuances), a confound, so "empty" might be the nonce, not the
  cursor. (The iOS broken-vs-fixed paths use the **same** hardcoded nonce and differ *only* in
  the cursor, so the nonce does not confound the iOS fix itself.)
- Whether `FF FF FF FF` **advances the ring's resume pointer** is unknown, and it matters:
  `autoMeasure` fires `syncAll` (`FF FF FF FF`) every ~10 min all day, so a pointer-advancing
  `syncAll` would shred the backlog before the overnight `syncUpToNow` runs. The 3-week backlog
  *surviving* in this capture is *weak* evidence it does NOT advance (an all-day pointer-advancing
  `syncAll` would have kept the ring empty) — weak because we can't confirm the app was connected
  throughout. **TODO (ring required): A/B test — `syncAll`, then immediately `syncUpToNow`, and
  confirm the backlog still drains.** Safest alternative: drop `syncAll` from the live path too and
  open at cursor≈now with a short drain cap (app-faithful; removes the dependency entirely).

**Contention (🟢 behaviourally — overnight data reached the official app, not us; the
single-shared-pointer *mechanism* is inferred, not two-client tested):** the ring holds only
UN-synced data behind what is almost certainly ONE shared resume pointer; whoever
opens at ≈now first (the official app OR us) drains the backlog and advances it, leaving the other
with nothing. (This is why overnight sleep "vanished" — even after the cursor fix, a competing
official-app sync can still win the one-time backlog.)

> **🟢 SELF-contention confirmed on-device (night of 2026-06-21→22, device unified log).** The other
> contender does NOT have to be the official app — it can be **us**. With OpenCircuit the sole syncer
> (no official app running), our own keepalive `periodic history drain` opened at cursor≈now every
> ~90 min ALL NIGHT; each open advanced the shared resume pointer past the night, so the morning had
> no backlog to hand off. The whole night drained as **~12 epochs total** (1–3 per drain), every sync
> `sleepSegs=0`, and the Sleep card silently held the prior night's value. The earlier "~4.75 h buffer
> overflow" rationale for draining overnight is **wrong for the sleep channel** — §3 above shows the
> first open drained a **19-day** backlog in one shot, so the ring buffers history for days, not hours.
> **Fix (2026-06-22):** OpenCircuit now goes quiet inside the user's sleep window — NO history drains and
> NO `syncAll` live reads (it keeps only the `07 00 00` fetch heartbeat, which doesn't touch the
> history pointer, so skin temp + the wear gate still stream) — and does ONE big drain after the window
> ends, mirroring the official app's morning sync. See `RingSession.isInSleepWindow`.

**The fix in OpenCircuit:** (1) history/overnight opens use `Command.syncUpToNow()`
(cursor = `floor(now) − epoch`), exactly the app's history behaviour — this part is solid (the
capture proves cursor≈now drains, and lower-bound is ruled out, so it can't return empty). (2)
The live/quick path still uses `Command.syncAll` (`FF FF FF FF`) to skip the drain for a fast HR
lock — **pending the A/B test above**; until verified, treat this as the one residual risk. (3)
Be the **sole** syncer — stop running the official app, which races us for the one-time backlog.
**No cursor is persisted on our side; the ring self-tracks.**

**Verified live-HR sequence (from the Mac, `desktop/livehr.py`):**
```
01 00 00                  -> 81 ..        (wake/status)
01 01 31 82 67 00         -> 81 01 ..     (config table)
02 00 FF FF FF FF 00 01 00 -> 82 ..       (open sync; FFFFFFFF → empty/skip-backlog 🟡, §3 caveat)
07 00 00 + c7/cc acks     -> 87,47,4c ..  (empty under FFFFFFFF 🟡; history uses cursor≈now)
06 01 00                  -> 86 00 86     (enter live-HR mode)
07 00 00                  -> 15 ..        (first live sample)
95 00 00  (repeat)        -> 15 00 <hr> 0a b0 <xor>   (one HR sample per poll)
```
Caveats (🟡): live `15` frames require the ring **worn with good skin contact** and
a few seconds of PPG warm-up; and the ring sleeps/stops advertising seconds after
disconnect (wake via charger contact or motion). Metric-specific sync commands
(sleep/HRV/SpO2/steps/temp) not yet isolated.

> **Session-open nuances (🟡), from the HR-only capture.** Two args are
> **per-session, not fixed** — replaying captured values fails:
> - `01 01 <3 bytes>` carries a per-session **nonce** (`31 82 67`, then `f0 1e 88`,
>   `9c 61 91` across sessions). Our replays reused a stale nonce, so the session
>   never opened — this, not just the cursor, is why Mac live-HR replay stalled.
> - `02 00 <cursor:4> …` cursor ≈ now is a "drain up to now" trigger (NOT a hard bound; §3), advancing each sync
>   (`0c 22 98 c3` → `0c 22 bb f7`). `FFFFFFFF` (far-future) returns an empty stream
>   (skip-backlog); pull history at cursor ≈ now (§3).
> The HR DECODE is confirmed (above); reproducing the live stream on demand from the
> Mac needs the nonce + cursor derived correctly (source of the nonce still 🔴 —
> likely from an `81` response field). Not required for Phase 1.

## 5. Decoded metric formats

Structure below is from parallel structural RE of `captures/btsnoop_hr.log`
(FW FR02.018): 11× `0x47`, 3× `0x4c`, 6× `0x81`, ~40 `0x10`/`0x87`, 3× `0x50`,
3 sync-opens. **Structure is 🟢/🟡; semantic VALUES are mostly 🔴 pending
ground-truth captures (§6).**

> **Refines §3's bulk-record prefix.** The delimiter is a single byte `0x0c`; the
> bytes after it are a **3-byte big-endian counter** (the `09`/`0a`/`22` is its high
> byte — it rolls cleanly `0c 09 ff 9a → 0c 0a 00 30`). This counter shares the
> **same value space as the `0x02` sync cursor** (§5.6): late records sit at
> `0c 22 xx xx`, matching cursor `0c 22 98 c3`. The `+0x0384`/record step is the
> `0x47` rate; `0x4c` steps `+0x96`.

### 5.1 Heart rate (live) 🟢 CONFIRMED
`0x95` poll → `0x15`: **`15 00 <hr> 0a b0 <xor>`**, byte[2] = HR bpm (61 bpm resting
in the HR-only capture). First sample is a warm-up sentinel (byte[2] ≈ 8); treat
< ~30 as "not locked".

**Poll cadence matters** 🟢 (btsnoop_hr.log): the ring emits one HR sample **~every
2 s**, and the windowed average needs undisturbed time to climb off the warm-up `8`.
The official app waits ~10 s after `06 01 00`, then polls `95 00 00` **request/response
at ~2 s**. Polling faster (e.g. ~700 ms, 3×/sample) keeps **resetting** the HR window so
byte[2] stays pinned at `8` — the cause of "stuck warming up". SpO2's byte[14] is robust
to fast polling, so only HR exhibits this. Poll HR no faster than ~2 s.

**Enter-live sequence** 🟢 (FR02.018 capture): after the connect-time history drain,
the app sends **`d0 00 00` → `06 01 00` → `07 00 00`**, then polls `95 00 00` ~1/s. The
`d0 00 00` is required — without it the ring stays in bulk mode and emits no `15 00` HR
frames. **`06 01 00` = HR mode** (short `15 00 <hr>` frames); **`06 02 00` = SpO2 mode**
→ long **`15 01 … <spo2> …`** frames where **byte[14] = SpO2 %** 🟡 (matches `0x60`/`0x61`
= 96/97 in the live capture; byte[2] is `00`, so don't read HR from these).

### 5.2 `0x47` — bulk PPG / waveform page (ACK each with `c7 00 00`)
Page: `[0]`=`0x47` · `[1]`=`00` · **`[2]`=remaining-RECORD countdown** (−5/full page,
0 on last; e.g. `1c 17 12 0d 08 03 00`) · body = N×**47-byte records** · `[last]`=XOR
(valid 11/11). 🟢
Record (47 B): `[0]`=`0x0c` · `[1:4]`=BE counter **+0x0384/rec = 900 s** (cursor space) 🟢 ·
`[4:6]`=16-bit BE **optical baseline/DC** (`[4]`∈{`02`,`03`}, **not const**; `[5]` drifts) 🟡 ·
`[6:9]`=usually `00 00 00`, else per-record flag/quality (`[8]`∈{0,5,10,15,20}) 🟡 ·
`[9:47]`=**38 B = 30 × 10-bit big-endian samples** (300 bits + 4 zero pad-bits) 🟢.

> **2026-06-16 offline RE pass (issue #8, `desktop/analyze_0x47_bitwidth.py`, run over 5
> captures — `ppg_align`/`walk`/`steps`/`btsnoop_hr`/`sleep_sync`).** These all drain the **same
> ~21-day history backlog** (counters share `0x0c099faa…`), so they are *sparse stored history*,
> not a worn realtime window — but the findings below reproduce identically across all five.

**Bit-width = 10-bit BE — 🟢 (offline-proven 3 independent ways; was 🟢-but-ambiguous, now firm).**
Decoding `[9:47]`:
- **Sample jitter** (mean|Δ|/σ): 10-bit = **0.03–0.04**; 8/12/16-bit = **1.12–1.23** (white-noise ≈ √2).
  A ~30× gap — only 10-bit yields a smooth physical signal; the others are bit-misalignment noise.
- **Byte-stream autocorrelation** peaks at **lag 5** (r ≈ +0.5–0.7) with a harmonic at lag 10. A run of
  near-constant W-bit samples repeats every lcm(8,W)/8 bytes: **10→5 B**, 12→3, 16→2, 8→1. The observed
  5-byte period (= 4×10-bit = 40 bits) is *structural* proof of 10-bit packing (12/16-bit are ruled out).
- **Range**: 10-bit values span **0–664** inside the 0–1023 full scale (never rails); 12/16-bit rail to
  full scale (0–4072 / 0–65154) — the signature of decode noise.

**Channel = ONE smooth optical channel, NOT two interleaved red+IR — ⚠️ the earlier "two interleaved
channels (red+IR)" claim is RETRACTED.** Sample-domain autocorrelation over the dynamic records:
**lag-1 (+0.81) ≈ lag-2 (+0.81)**, and only **3 %** of records alternate (lag1<0). A genuine A,B,A,B
interleave gives lag1 ≪ lag2 with frequent alternation; instead adjacent samples are as correlated as
2-apart → a single channel. mean(even)−mean(odd) ≈ −0.5 LSB and unstable — no two-channel DC offset.
The prior "de-interleaving lowers jitter ⇒ 2 channels" was just decimation of a smooth-signal-plus-dither.
**Which LED this single channel is (red / IR / green) and whether it is AC- or DC-coupled is UNPROVABLE
offline 🔴** — needs the app's labelled/exported trace.

**Cadence / counter time-unit:** step **+900 s = 15 min per record** 🟢 (161/175 steps = 900; outliers are
multi-day gaps between sparse bursts). 30 samples per 15-min record. If evenly spread → **1 sample / 30 s
= 0.033 Hz** 🟡 (exact within-record spacing — even-spread vs a fast burst — is unprovable offline). **Either
way this is NOT pulse-resolution** 🟢: 0.033 Hz is ~50× below a 0.7–3 Hz pulse, so **no heartbeat is
recoverable from `0x47`.** Two confirmations: (a) within a record the signal is a slow smooth drift/ramp —
one record starts with **14 exact `0` samples then ramps monotonically to ~655**, a sensor-on *settling*
curve (an absolute optical level, not a pulse); (b) the `walk`/`steps` captures carry the **concurrent live
HR as `0x15`** frames (resting 61–66, rising to **82–88 bpm** on the walk) — a separate product — and that
HR is nowhere in the 15-min `0x47` trend. So **`0x47` is a sparse perfusion / optical-amplitude trend**
(one 30-sample snapshot per 15 min), not a fiducial waveform.

**`[4:6]` baseline 🟡:** 16-bit BE, range **650–1192** (`0x028a–0x04a8`), **positively correlated** with the
per-record sample mean (corr **+0.40…+0.82** across captures; baseline ≈ 1.4× sample-mean) → an
optically-coupled per-record **DC/baseline (or gain)** field, not a flag. Exact relationship unresolved.

**Issue #8 status — PARTIAL (offline ceiling reached).** Settled offline: bit-width (🟢), record cadence
(🟢), single-channel + not-pulse-resolution (🟢/🟡). Still requires the app's **exported PPG trace** for
#8's full acceptance (1:1 alignment): (1) channel IDENTITY — which LED, AC vs DC 🔴; (2) exact within-record
sample spacing 🟡; (3) absolute physical units. Evidence/decoders: `desktop/analyze_0x47_bitwidth.py`
(stats) and `desktop/decode_0x47.py` (both widths → CSV).

### 5.3 `0x4c` — bulk activity/sleep page (ACK each with `cc 00 00`)
Page: `[0]`=`0x4c` · `[1]`=`00` · **`[2]`=remaining-RECORD countdown** (−6/page) ·
body = 6×**23-byte records** · `[last]`=XOR. 🟢
Record (23 B): `[0]`=`0x0c` · `[1:4]`=BE counter **+0x96/rec** (cursor space) 🟢 ·
`[4]`=HR · `[5]`=HRV · `[6]`=confidence · `[7]`=RR×8 · `[8]`=SpO2-or-wake-flag ·
`[9]`=item2p5 · **`[10:20]`=`acti_counts`** (activity blob) · `[20]`=info · `[21:22]`=trailer
(all per the APK reconciliation below). Idle/unworn template:
`[4:7]=05 00 0c 00`, `[9]=0a`, `[10:14]=01×5`, `[15:21]=00×7` 🟢.

> **This is the `历史测量响应` ("history MEASUREMENT response") record — NOT the
> activity record (issue #93 reconciliation, 2026-06-17).** The decompiled app
> (`pp.txt`, blutter) ships an explicit per-2.5-min offset map whose `utc` field
> sits at loc `0x3`; our wire counter is at byte `[0:4]` (top byte = the `0x0c`
> delimiter), so **`wire_index = APK_loc − 3`**. Under that convention the
> MEASUREMENT map (`utc·pr·hrv·conf·resprate·spo2·item2p5·acti_counts·info`)
> reproduces **byte-for-byte** the §5.3 fields already ground-truthed to the app's
> 2026-06-13 night — **five independent fields agree**, which is a second,
> independent source confirming the HR/HRV/RR/SpO2 decode AND naming the rest:
>
> | APK field (`历史测量响应`) | APK loc·len | wire idx | meaning | conf |
> |---|---|---|---|---|
> | `utc` | 0x3·4 | `[0:4]` | BE counter / cursor (top byte `0x0c`) | 🟢 |
> | `pr` | 0x7·1 | `[4]` | **HR (bpm)**; <30 = unmeasured sentinel | 🟢 |
> | `hrv` | 0x8·1 | `[5]` | **HRV / RMSSD (ms)** | 🟢 |
> | `conf` | 0x9·1 | `[6]` | **confidence / signal quality** 0..~12 (was "[6] quality? 🟡") | 🟢 |
> | `resprate` | 0xa·1 | `[7]` | **RR × 8** (÷8 → brpm) | 🟢 |
> | `spo2` | 0xb·1 | `[8]` | **SpO2 %** asleep; `0x12`/`0x13`/`0x11` = "no SpO2" sentinels | 🟢 |
> | `item2p5` | 0xc·1 | `[9]` | 2.5-min marker (~`0x0a`) | 🟡 |
> | `acti_counts` | 0xd·0xa | **`[10:20]`** | **10-B activity-magnitude blob** (motion/intensity) | 🟢 role |
> | `info` | 0x17·1 | `[20]` | per-epoch flag | 🟡 |
>
> The V2 measurement map bit-packs `acti_counts` as **length 7.5** (`info` = 0.5 B) —
> **now resolved, see "The `[15:23)` sub-layout" below**: that 7.5 + 0.5 = 8 bytes is
> `[15]…[22]`, five 12-bit magnitudes plus a 4-bit `info` nibble. (The old "`[10:15]`
> = 5× motion" remains the blob's first 5 bytes.) Confirmed in data: on worn epochs `[4]`
> reads as physiological HR (median 53, max 96), while decoding `[4:6]` as the
> *activity* map's `steps` gives non-monotonic garbage (median ~13600). Reproduce
> with `desktop/decode_activity.py`.

> **⚠️ Correction to the old `[15:22]` "7-byte activity payload" claim (#93).** Those
> bytes are simply the **tail of `acti_counts`** (`[15:20]`) + `info` (`[20]`) +
> trailer (`[21:22]`). They carry a per-epoch **activity-INTENSITY** signal —
> non-zero iff moving, zero at the idle template — **not** steps / distance /
> activeSeconds / powerLevel / per-epoch battery / dailyActiveFlag. `decode_activity.py`
> shows the differential: worn-active epochs `Σacti_counts−5` ranges 1→1254, idle is a
> flat 0 (walk & steps captures). The genuine activity fields live in a **separate**
> record (next subsection) that our `byte[6]=0x00` syncs never pull.

**The `[15:23)` sub-layout: five 12-bit magnitudes + a 4-bit `info` flag** 🟢 (2026-08-09, #195).
The 8 bytes `[15]…[22]` are **five 12-bit big-endian magnitudes, nibble-packed, followed by a
4-bit flag** — 60 + 4 = 64 bits. Magnitude *k* is nibbles 3*k*, 3*k*+1, 3*k*+2 counting from the
high nibble of `[15]`; `info` is the **LOW nibble of `[22]`**. This is exactly the APK V2 map's
`acti_counts` length **7.5** + `info` **0.5** — the open item at the top of this section.

Measured over the **5648 unique non-idle records** of the local corpus (5 rings), reproduce with
`decode_tail()` in `desktop/decode_bulk.py`:

| test | this phase | phase +1 nibble | phase +2 nibbles |
|---|---|---|---|
| **CARRY TEST** `P(v ≡ 0 mod 256 \| v > 0)`, per field | **0.0017–0.0030** | 0.0172–0.0317 | 0.1491–0.1627 |
| the same, per ring (5 rings, n = 360…3431) | **0.0000–0.0029** | 0.0117–0.0253 | 0.1377–0.2560 |

A genuine 12-bit integer whose low byte is ~uniform predicts **1/256 = 0.0039**; a window
straddling a field boundary has a "low byte" built from one field's LAST nibble and the next
field's FIRST, both zero about half the time, so it must be far larger — and is, by 6–10× at one
nibble off and 50–65× at two. Two model-free corroborations of the same 1.5-byte period: the mean
nibble value over the 16 nibble positions repeats **1.21 / 3.37 / 3.97** five times (the
most-significant nibble lands on positions 0, 3, 6, 9, 12 and nowhere else), and the mean BYTE
value repeats **22.5 / 65 / 57** with a 3-byte period. The flag is at the END, not the start: the
low nibble of `[22]` is categorical — `0` (66.3 %) and `4` (31.6 %) cover 97.9 % of records, 9
distinct values against 15–16 for every magnitude nibble — and a LEADING flag would put the
magnitudes at phase +1, which the carry test rejects.

🔴 **What the five numbers physically are is NOT established.** They are **not** a
higher-precision copy of `[10:15]`'s five 30-s slots: over the 3021 records whose primary channel
is not a placeholder, magnitude *k* vs motion byte *j* is +0.13…+0.19 for **every** pair with no
diagonal, and Σmagnitudes vs Σmotion is only +0.20. Range 0…4095 (the full 12-bit span), p50 10,
p90 1302, 46.9 % exactly zero. The section's existing 🟢 claim — the region is non-zero iff moving
— is untouched; only its internal boundaries are now known.

⚠️ **Consequence for the byte-aligned `[15:20]` predicate.** `BulkRecord.motionIntensityTailIsZero`
reads five BYTES, so it covers magnitudes 0–2 in full and only the top nibble of magnitude 3, and
cannot see magnitudes 3 and 4 at all. 🟢 Of the 1950 corpus epochs it calls quiet, **253 (13.0 %)
carry a non-zero magnitude**, and all 253 are a magnitude 3 (97) or 4 (194). It is nevertheless
**left exactly as it is**: `primaryMotionIsDegenerate`'s 0.50 / 0.75 constants, `measuredHRVRMSSD`'s
quiet gate and `hrvPoolingNoiseFloorMs` = 9.0 are all fitted to *that* population. The correct
decode is exposed alongside it as `BulkRecord.activityMagnitudes` / `activityInfoNibble` /
`activityMagnitudesAreZero`; migrating the three calibrations is a separate, measured job.

**+0x96 counter step = exactly 150 s** (the counter is seconds, §5.6) → **each record
is a 150 s / 2.5-min epoch.** 🟢 Confirmed by `captures/sleep_sync_btsnoop.log`
(FR02.018, full multi-day history sync, 470 records over 3 stored sessions). The last
session decodes to **2026-06-13 23:09 → 06-14 09:32** and its end matches the bugreport
pull time (09:38) to <6 min — counter→wall-clock is right and lands on **device-local**
time (no 12 h offset in this capture; bears on §5.6/§6.6). Reassemble + decode with
`desktop/decode_bulk.py`.

**Two record layouts**, distinguished by `[8]`:
- **Activity/awake epoch** `[8]=0x12`/`0x13`: **`[4]` = HR bpm 🟢 — this is the ALL-DAY HR.**
  The activity epoch shares the sleep-vitals HEAD (`[4]`=HR, `[5]`=HRV), differing only at `[8]`
  (activity tag vs SpO2). Confirmed 2026-06-17 by mining every capture's worn `0x4c` epochs: across
  204 sleep↔activity transitions, activity `[4]` tracks the neighbouring sleep HR to within 4.6 bpm
  (Pearson +0.76) and forms ONE continuous series across layout boundaries (e.g. the `walk_decoded`
  11:02–12:14 run: 61–85 bpm tracking motion, and the `login_activate` 08:41–11:56 run, smooth across
  every SLEEP↔ACTIV change). 🟢 NEGATIVE result from the same mining: the official app NEVER uses a
  distinct `byte[6]` sync-open selector for HR (only `0x00`/`0x03` across all captures) — there is no
  separate `HrSync`/`0x0a` stream on the wire; all-day HR is the activity-epoch `[4]` we had been
  discarding (`BulkSleep.heartRate` was gated to sleep-vitals). Resolves the daytime/workout-HR gap
  (#45/#38). On these epochs `acti_counts` `[10:20]` is elevated and `[15:20]` is its **intensity
  tail** — not a separate activity payload (corrected by the #93 reconciliation above; the real
  steps/activeSeconds record is the uncaptured `历史活动响应` stream in §5.3.1).
  - 🟢 **HRV `[5]` and RR `[7]` ARE present and valid on activity epochs** (#185, corrected
    2026-08-02 — the earlier "HRV/SpO2 stay sleep-vitals-only, motion corrupts them" claim was
    half wrong and cost us ~half of both metrics). Measured over 6 independent archives (5
    Gen-2/Gen-3 + 1 Gen-2-Air FR04; 3679 distinct records after de-duplicating four contained
    captures): matching each activity epoch's `[5]` to its nearest sleep-vitals neighbour within
    300 s gives a **median delta of −1.5…+2.5 ms** on every Gen-2/Gen-3 archive — ordinary
    epoch-to-epoch RMSSD variation.
  - 🟢 What motion *does* corrupt is the **upper tail of `[5]`, not its centre**, and `[15:20]`
    is the discriminator. Pooled: QUIET activity epochs (`[15:20]` all zero) run p50 58 / p90 86 /
    p99 111 / max 142 ms — the same population as sleep-vitals (p50 60 / p90 88 / p99 119) —
    while MOVING epochs run p90 98 / p99 196 / **max 200**. An RMSSD of 200 ms on a moving awake
    wrist is PPG artifact, so HRV is emitted from an activity epoch only while `[15:20]` is zero.
  - 🟢 **RR `[7]` is motion-insensitive** and needs no such gate: sleep-vitals p50 15.125 / p99
    16.875, activity p50 15.25 / p99 17.0 (every `[7] > 0` byte in the corpus lands in 101…141).
  - 🟢 **SpO2 genuinely is absent** on these epochs and always will be — `[8]` **IS** the
    `0x12`/`0x13` activity tag, so there is no SpO2 there to recover.
  - 🟡 **OPEN:** the FR04 Gen-2-Air alone runs ≈ **−11…−15 ms** against its sleep-vitals
    neighbours (the exact median moves with the neighbour tie-break; the sign and scale do not).
    Recorded, deliberately **not** "corrected" — a per-generation offset would need ring-generation
    knowledge `OpenCircuitKit` refuses to carry.
  - 🟡 **Watch item:** the quiet gate trusts firmware to populate `[15:20]`. Firmware that stopped
    would make every activity epoch read "quiet" and let the artifact tail through; `DecodeAnomaly`
    does not currently watch for an all-zero `[15:20]` across a whole capture.
- **Sleep-vitals epoch**: per-epoch vitals in `[4:9]`, motion `[10:15]` at `01` baseline,
  `[15:22]` ≈ zero. `[8]` is the **SpO2 %** (typically `0x57–0x63` = 87–99, but lower on a real
  desaturation). ⚠️ Layout is decided **structurally** (#39), NOT by this band: classify as
  sleep-vitals = "not the idle template AND `[8]` ∉ {`0x12`,`0x13`,`0x11`}", so a sub-87 %
  desaturation still keeps its HR/HRV/SpO2 (the old value-gate dropped the whole epoch — see
  `BulkSleep.swift`).
- **`0x11` is a THIRD "no SpO2 here" sentinel** 🟢 (2026-08-09, #195) — a "nothing measured"
  block terminator, not a 17 % saturation and not a desaturation #39 must protect. Measured over
  the 5648 unique non-idle records of the 5-ring local corpus, 13 occurrences:
  - **13 of 13 carry `[4] == 0x04`**, the ring's own `<30` "PR unmeasured" sentinel, and 12 of 13
    carry the whole dead head `04 00 00 00` (HR/HRV/conf/RR all unmeasured). **No** record with a
    real SpO2 byte ever carries `[4] == 0x04` (0 of 1750); 14 of 3869 `0x12` epochs do. There are
    no vitals here for the fall-through to preserve.
  - **13 of 13 sit at the tail of a contiguous run** — 11 are the last record before a
    multi-epoch hole, the other 2 are immediately followed by another `0x11` that is — and every
    one is preceded by an ACTIVITY epoch, never a sleep-vitals one. None sits in an SpO2 slot of
    the duty cycle below.
  - ⚠️ The corpus's other impossible-SpO2 bytes — **`0x00`/`0x0a`/`0x0e`, 16 records — are the
    OPPOSITE shape and stay `.sleepVitals`.** 12 of the 16 sit in an SpO2 slot with an activity
    epoch on both sides, and 14 of 16 carry a plausible `[4:8]` head. They are sleep-vitals
    epochs whose SpO2 byte failed — exactly the case #39's fall-through exists for. The
    `70…100` guard on the emitted value already stops the impossible number becoming a sample.
    (🟡 open: 2 of the 16 `0x00` records carry the same dead head + `[9]==0x22` and terminate a
    run, i.e. they look like the `0x11` family under a different tag. 2 records is not a rule.)

**The SpO2 DUTY CYCLE — the ring's own "I am measuring sleep" witness** 🟢 (2026-08-09, #190).
While the ring runs its sleep-measurement program it takes an SpO2 reading every **300 s**. Epochs
are 150 s, so consecutive `0x4c` records ALTERNATE sleep-vitals / activity **1:1**, and the
alternation stops when the program exits — which is at, or just after, final wake. Measured over
5650 unique records / 4 rings, re-derived independently from raw frames by a second decoder with
**0 byte conflicts**:

| observation | value |
|---|---|
| sleep-vitals inter-arrival, modal bin | **300 s** on every ring (AD 68.3 %, 9F 63.1 %, u3 83.6 %, u4 78.1 %) |
| consecutive same-template pairs, ring AD | activity-activity 1305 vs sleepVitals-sleepVitals **24** — the ring essentially never emits two SpO2 reads in a row |
| same-template ("violation") rate | **6.0 %** inside the staged sleep window vs **43.6 %** outside |
| split at the user-reported wake | 3.9 % → 23.8 % (08-09); 1.6 % → 34.8 % (08-05) |
| Mann-Whitney AUC vs wake | **0.819–1.000**, far above SpO2 (0.44/0.41), RR (0.61/0.59), HRV (0.79/0.50) or the confidence byte (0.42/0.27) |

Confounds are REFUTED, not assumed: 20 sync, drain and BLE-reconnect events sit strictly INSIDE
violation-free runs (including four successful drains inside one 5.7 h run, and a BLE
teardown+reconnect inside a 191-epoch run), and the apparent 3.2× page-boundary enrichment goes to
**0.0 %** under regime control (147 cross-page pairs inside the quiet regime, zero violations).

⚠️ **Name it correctly.** This is a rule about **`[8]`, the SpO2 byte** — `BulkRecord.layout` is a
discriminator *computed* from it (`0x12`/`0x13`/`0x11` ⇒ activity), not a device mode tag. Any
change to that discriminator's fall-through silently moves this signal. #195 added `0x11` to that
set, and MEASURED the consequence rather than assuming it: 20 of the corpus's 6788 epoch-to-epoch
steps flip from "alternating" to "violation" (2577 → 2597) — every one of them a step INTO a
`0x11` record, i.e. at the tail of a contiguous run — and all 18 corpus nights stage
**byte-identically**, including both ground-truthed wakes (08-09 575 min / 09:08:51 and 08-05
485 min / 08:10:14). The direction is the one the wire demands: reading `0x11` as an SpO2 read made
`activity → 0x11` look like a continuation of the duty cycle and could only ever push a trusted run
LATER.

⚠️ **Two caveats before building on it.** (1) It is **jitter- and gap-sensitive**: 91 of 3432 steps
on ring AD are 151–221 s with no record missing, so an exact `dt == 150` test suppresses 57 genuine
violations; and dropping ONE interior epoch makes its neighbours same-template in 90.5 % of
positions by construction. Use `round(dt/150)` and bridge a single hole by parity. (2) It does **not**
hold for a whole night on every ring: `9F`/Air fragments into 1.3–3.8 h pieces (two per night), and
`u4` holds the cadence for a continuous **11.96 h**, which no timezone makes a night — most likely
continuous SpO2 enabled. Consumed by `SleepStaging.cadenceSteps` / `markCadenceWakeOffset`.

**Sleep-vitals fields — confirmed against the RingConn app's readout for the
2026-06-13 night** (avg HR 68 / HRV 65 ms / SpO2 98 %, low 93 % ~02:30–03:00):
- **`[4]` = heart rate (bpm)** 🟢. Sleep-window mean ~60, dips to 56–57 in deep-sleep
  hours, rises to 66 at wake; evening (active) epochs read 83 — physiologically correct.
  (Sleep mean < app's all-night avg 68 because the app average includes daytime.)
- **`[5]` = HRV / RMSSD (ms)** 🟢. Mean 69, median 70 vs app 65; high beat-to-beat
  spread (36–114) as expected for RMSSD.
- **`[8]` = SpO2 (%)** 🟢. Mean 96, and the low cluster (89–93) lands at **02:32–03:07**,
  matching the app's "lowest 93 % around 2:30–3 am" — the decisive temporal anchor.
- **`[7]` = RESPIRATORY RATE × 8** 🟢 (ground-truthed 2026-06-15). On the asleep epochs,
  `[7]/8` gives mean 15.2 vs the app's nightly **15.1**, and p5–p95 **14.6–16.0** vs the
  app's reported low/high **14.5–16.1** — near-exact. RR IS per-epoch and single-night (no
  model needed); earlier captures missed it only because the value (~120) was mistaken for
  signal quality. Exact divisor ≈8.07; 8 is the natural 1/8-brpm fixed point. Decoded by
  `BulkRecord.respiratoryRate`.
- `[6]` (1–10, ~9) unresolved 🟡 — candidate signal quality. `[9]`≈`0x0a` and `[22]`
  (low-nibble `4`, high-nibble varies) flags 🟡.
- **Respiratory rate (15 bpm) and skin temp are NOT in ANY frame this sync captured** 🔴.
  Verified exhaustively: every byte and 16-bit field of the `0x4c`/`0x47`/`0x10`/`0x87`/
  `0x81`/`0x15` frames (no stable `0x0f` RR; no temp value at `358`/`359`=0.1 °C,
  `3588`=0.01 °C, `360`/`3597`, `966`/`9658`=°F, nor a small signed deviation), **and**
  every BLE handle — all traffic was on `0x0804`/`0x0802`/`0x0805`, nothing on the
  secondary service `0x0900`. Per-epoch `[6]` (1–10, quality?) and `[7]` (swings 64→120
  over the night — too volatile for temp) are not it either.
  - RR is most likely **app-derived** (PPG/HRV respiratory sinus arrhythmia), not on the wire.
  - **Skin temp is measured only at night** (per the ring owner) yet is absent from BOTH a
    full morning sync (2026-06-13 night) AND a capture taken **while the app's Temperature
    screen was open** — that screen showed cached data and issued **no BLE fetch** (only a
    normal recent-activity re-sync followed). So temp never rides the activity/sleep/PPG
    drain; it needs a **dedicated command the app sends on its own schedule** (e.g. first
    sync of the day / background), which neither capture triggered.
  - **Sync-open `0x02` flag byte** (byte[6]) observed as `00` and `03`; **both return the
    same activity/sleep `0x4c`+`0x47` data** (flag=03 segments carried fewer `0x4c`, more
    `0x10`/`0x87`). ⚠️ The earlier "flag is NOT a stream selector" conclusion is **not load-
    bearing**: that probe used `FF FF FF FF` (no `0x82` for any flag) and predated the auth crack.
    The decompiled `DataSyncType` enum makes byte[6] the prime suspect for the all-day HR/SpO₂
    (`HrSync`/`Spo2Sync`) stream selector — re-probed correctly (real cursor, post-auth, full
    candidate set incl. `off_2c` `0x0a`/`0x0b`) in **§5.6.1 / #99**.
  - **Ground truth for when we capture it:** RingConn reports temp Oura-style as a signed
    **deviation from a personal baseline** plus an absolute reading — observed `−0.16`
    deviation and `96.75 °F` (35.97 °C); the 2026-06-13 night showed `96.58 °F` (35.88 °C).
    Baseline ≈ 36.1 °C. Expect a small signed value (≈ `−16` if 0.01 °C, or `−0.16` scaled)
    alongside an absolute near `3588`–`3597` (0.01 °C) or `9658`–`9675` (0.01 °F).
  - **Capture needed:** snoop on → open the app's **Temperature / Trends screen** (which
    should trigger the fetch) → sync / `adb bugreport`.

**`[10:15]` = 5× per-30 s motion/activity counts** 🟢(role)/🟡(unit). Over a real night
they decay from `~14 15 15 14` (≈20, awake/settling at 23:09) to the `01 01 01 01 01`
baseline (still/asleep) and spike at arousals/turns — the per-epoch **stillness signal**
Phase 5 `SleepDetection` needs (likely the IMU stream; no separate `0x47` accel needed).
Baseline `01` = "still", not "unworn".

> **Sleep stages (Awake/Light/Deep/REM) are not stored per-epoch** — no stage label byte
> found. The ring streams raw HR/HRV/SpO2/motion and the **app computes** the hypnogram,
> matching openwhoop's approach and our Phase 5 plan: compute stages in Swift from these
> signals, don't expect them on the wire.

> **Status:** HR `[4]`, HRV `[5]`, conf `[6]`, RR `[7]`, SpO2 `[8]`, `acti_counts` `[10:20]`
> and the 150 s cadence are 🟢 (app-aligned §6.2 + APK-map cross-confirmed, #93). Resolved
> the old "`[6]`/`[7]` semantics, `[15:22]` payload" opens: `[6]`=confidence, `[7]`=RR×8,
> `[15:22]`=`acti_counts` tail (intensity, not steps). #195 closed the bit-layout of the tail
> (`[15:23)` = 5 × 12-bit BE + a 4-bit `info` nibble 🟢) and added `0x11` to `[8]`'s sentinel set
> 🟢. Open: the bit-layout of `[10:15]` inside the blob, what the five 12-bit magnitudes each
> MEAN 🔴, `item2p5` `[9]`; skin temp + RR-summary (not in this stream).

#### 5.3.1 `历史活动响应` — the per-epoch ACTIVITY record (steps/distance/…) — 🔴 NOT YET CAPTURED (#93)
The decompiled app has a **second** per-2.5-min offset map, `历史活动响应`
("history ACTIVITY response"), that carries the step/activity fields #93 wants —
**steps, deviceState, powerLevel, Temp1-4, item5p0_1..3, activeSeconds,
dailyActiveFlag** (matches the `HistoryActivitySyncInfo` SQLite table). It is a
**different record from the `0x4c` measurement record above**, and **it does not
appear in any capture we have**: a full opcode census of walk/steps/sleep/battery/
morning/login (`0x10`/`0x47`/`0x4c`/`0x15`/`0x81`/`0x82`/`0x86`/`0x50`/`0x11` only)
finds no record matching this layout — every worn `0x4c` epoch decodes as a
measurement record (physiological HR at `[4]`), none as an activity record.

**Why it's missing:** `step`/`stand` are `DataSyncType.ringData` selected by the
sync-open `byte[6]` (§5.6.1) — but every capture used `byte[6]=0x00`, which returns
the sleep/measurement+PPG drain. The activity/step stream needs the **step
selector** (enum-idx 2 → likely `byte[6]=0x02`), the same gap as the all-day
HR/SpO2 probe (#99). So #93 is **blocked on a capture**, not on decoding.

**Predicted wire layout (via the §5.3-validated `wire_index = APK_loc − 3`)** —
all 🔴 until a `byte[6]`-activity capture confirms; `decode_activity_record_PREDICTED()`
in `desktop/decode_activity.py` implements it:

| APK field (`历史活动响应`) | APK loc·len | pred. wire idx | meaning / HealthKit | conf |
|---|---|---|---|---|
| `utc` | 0x3·4 | `[0:4]` | BE counter / epoch start | 🟢 (counter is 🟢) |
| `steps` | 0x7·2 | `[4:6]` LE | **per-epoch steps** → HK `stepCount` history | 🔴 |
| `DeviceState` | 0x9·1 | `[6]` | wear/charge state enum | 🔴 |
| `powerLevel` | 0xa·1 | `[7]` | **per-epoch battery %** → battery curve | 🔴 |
| `Temp1..4` | 0xb/d/f/11·2 | `[8:16]` | 4× per-epoch skin temp (≠ §5.4 live descriptor temp) | 🔴 |
| `item5p0_1..3` | 0x13/14/15·1 | `[16:19]` | unknown (3 small ints) | 🔴 |
| `active_seconds` | 0x16·2 | `[19:21]` LE | **active seconds (0..150)/epoch** → HK `AppleExerciseTime` | 🔴 |
| `dailyActiveFlag` | 0x18·1 | `[21]` | **stand/active flag** → HK `AppleStandHour` | 🔴 |

- **distance is NOT on the wire** — the app computes it `steps × ~0.248 m`
  (`pp.txt` L102573, `distCal`); reproduce client-side, don't expect a wire field. 🟢
- **4-level activity intensity** (Inactive/Low/Moderate/Vigorous, one dot per
  2.5-min, `pp.txt` L45207) is **app-computed from `acti_counts`** — no stored band
  byte. We CAN derive an intensity proxy now from the measurement record's
  `acti_counts` `[10:20]` (present); the exact band thresholds are 🔴 (need an app
  export). `decode_activity.py` ships a `Σacti_counts` proxy classifier.
- **Temp1-4 reconciliation (#93 ask):** these 4 per-epoch temps belong to the
  *activity* record and are a **different record class** from the §5.4 skin-temp
  finding (which reads two channels from the live `0x10`/`0x87` descriptor `[6:8]`/
  `[8:10]`). They do not contradict — descriptor temp is the *live* stream; Temp1-4
  would be the *per-epoch history* in the un-captured activity stream.

**Capture to close #93 (ground truth):** a `btsnoop` sync with the sync-open
`byte[6]` set to the step/activity selector (start with `0x02`; sweep via the #99
`DataSyncProbe`), taken after a known walk, plus the official app's per-day step /
active-minutes / stand readout for that day. Then confirm `[4:6]` rises monotonically
within the day and `active_seconds` ≤ 150/epoch.

#### 5.3.2 HealthKit mapping addendum (#93, design-only)
| Source (decoded) | Confidence | HealthKit type | Notes |
|---|---|---|---|
| `acti_counts` `[10:20]` intensity (this record) | 🟢 role | `HKWorkout` / `appleExerciseTime` (heuristic) | active-epoch detector; band thresholds 🔴 |
| descriptor `[4:6]` steps (§5.4) | 🟢 | `HKQuantityType stepCount` | **quarter-hour bucket, NOT a running daily total** (#192) — the day total is the sum of the buckets we were connected for; unobserved quarters are unrecoverable |
| activity `steps` `[4:6]` (predicted) | 🔴 | `stepCount` (per-epoch history) | needs the §5.3.1 capture |
| derived `distance = steps×0.248` | 🟡 (formula) | `distanceWalkingRunning` | client-computed, not wire |
| activity `active_seconds` (predicted) | 🔴 | `appleExerciseTime` | 0..150 s/epoch |
| activity `dailyActiveFlag` (predicted) | 🔴 | `appleStandHour` | per-epoch stand flag |
| activity `powerLevel` (predicted) | 🔴 | (none — internal battery curve) | per-epoch battery telemetry |
| activity `Temp1-4` (predicted) | 🔴 | `appleSleepingWristTemperature`/`bodyTemperature` | per-epoch temp history |

> **2026-06-15 first-morning sync, ground-truthed (`captures/morning_temp_20260615`).**
> Captured the official app's first sync of the day via `adb bugreport`. App readout for the
> 2026-06-14 night (ground truth): asleep **7:37**, in bed **9:33**, efficiency **80 %**,
> awake **43 m**, REM **1:42**, light **4:45**, deep **1:10**, temp avg **96.40 °F**
> (35.78 °C), baseline **96.73 °F** (35.96 °C), deviation **−0.32 °F**, RR **15.1 bpm**.
> - **Temp + RR still absent from the wire**, now tested against the *exact* ground-truth
>   values: searched every frame/handle for 96.40/96.73 °F and 35.78/35.96 °C in ×1/×10/×100
>   (both scales) and RR 15.1 (`00 97`/`0f`) → **0 genuine matches**. A per-byte and BE-16
>   scan of all 190 `0x4c` epochs found **no temp-like field** (`byte[1]=0x24` is just the
>   counter high byte). So temp/RR are not in the passive activity/sleep/PPG drain. 🔴
> - **New frames this capture:** opcode **`0x91`** (app→ring, `91 00 00`) ACKs a ring-pushed
>   notification **`0x11`** (`11 00 0N 55`, N increments) — an event-counter handshake, no
>   payload. `0x0805` carries only `01 00` control writes. Neither is temp.
> - Ring owner confirms **temp does come over BLE** → it rides a command/flag the normal
>   sync never sends (prime suspect: untried sync-open flag `02 00 <cursor> 01|02|04 01 00`),
>   or a separate fetch outside the snoop ring-buffer window. **Resolved only by active
>   probing** (in progress). HR/HRV/SpO2 decode re-confirmed (sleep window low-HR 48–58 bpm,
>   SpO2 dip to 89 %). Sleep stages remain app-computed (no stage byte) — Phase-5 classifier.

> **2026-06-15 active probe from the Mac — BLOCKED at session-open (auth/nonce 🔴).**
> Connected to the ring from the Mac (name-based discovery — macOS bleak can't match by MAC,
> must scan by name prefix). Status works: `01 00 00`→`81`, `01 01 <x>`→`81 01`. But
> **`02 00 FFFFFFFF <flag> 01 00` returns NO `82`** for any flag (`00/01/02/04/05/08`), and
> `06 01 00`+`95 00 00` returns no `15` — the sync session never opens, no data flows. This
> held even with a **previously-accepted** `01 01 31 82 67` (seen working at 21:52 and 10:33
> the same day), so the `01 01` value **rotates/expires**; a stale one poisons the open. The
> value never appears in any ring response (app-generated, not handed out) yet `31 82 67`
> repeated across two sessions → likely a derived key, not random. **Conclusion:** Mac-side
> metric probing (incl. the temp-flag hunt) is gated by the §4 session-open auth — must crack
> the `01 01` derivation first, OR capture the official app's temp fetch (the app holds valid
> auth). Temp is confirmed BLE-delivered but absent from the normal sync drain.
> **RESOLVED 2026-06-15 (see §5.4):** temperature is in the `0x10`/`0x87` **descriptor**
> `[6:8]`/`[8:10]` as 0.1 °C, streamed live while connected — not in the bulk sync. So it
> needs neither the session-open auth nor active flag-probing; just read the descriptor.

### 5.4 `0x10` / `0x87` — fixed 19-byte descriptor
`0x10` ← `d0 00 00` (also spontaneous ~30–60 s); `0x87` ← `07 00 00`. **Identical
layout** (only `[0]` respid differs; `0x87` body == `0x10` body) → shared descriptor,
XOR-valid. **`[1]`=BATTERY %** 🟢 (ground-truthed 2026-06-15: `0x4c`=76 matched the app's
76% exactly at capture time; the buffer showed a clean 92→86→85→84→78→77→76 discharge
curve — it is NOT a per-session marker) · **`[2]`=CHARGE/STATE/WORK-MODE: `0x04`=ON CHARGER** 🟢
(`0x02`/`0x03`=idle worn-streaming toggle, `0x01`=startup/settle, **`0x06`=NATIVE SPORT MODE ACTIVE**
🟢 #174 — see below) ·
**`[4:6]`=STEP COUNT (16-bit BE), a QUARTER-HOUR BUCKET — not a daily total** 🟢 (#192) ·
**`[6:8]`/`[8:10]`=SKIN TEMPERATURE, two channels, 0.1 °C BE** 🟢 (each prefixed `01`=
valid; see below) · **`[14:16]`=BATTERY VOLTAGE mV (16-bit BE)** 🟢 (#89, see below) ·
**`[17]`=CASE BATTERY: low 7 bits = case %, bit `0x80` = case charging, `0xff` = not in case** 🟢
(#89; corrects the earlier "`0x46`=charging witness" / "data-follows" reads — see below).

**`[2]` = charge/state byte; `0x04` = ON CHARGER · `[14:16]` = battery voltage mV** 🟢
(resolved 2026-06-19, **#61** + **#89**; `captures/charger66b`, labelled A/B
finger→charger→off→finger). Over a 6-min charge the battery rose **66→74 %** and skin temp
fell **31.4→26.6 °C**; against that ground truth:
- **`[2]` read `0x04` for 100 % of charging frames (30/30) and never** during the worn or
  off-wrist-idle phases. Buffer-wide, `[2]==0x04` is ~30× enriched for a rising-battery
  window vs `0x02`/`0x03` (65 % vs 2 %); the worn stream just toggles `0x02`↔`0x03` every
  frame, and `0x01` is a brief connect/settle transient. The earlier brief test (06-19
  10:31) that *looked* like it falsified this was just too-short charger taps — they still
  flipped `[2]`→`0x04`, but never moved battery/temp.
- **`[17]` = CHARGING-CASE BATTERY** 🟢 (resolved 2026-06-19, **#89**; `captures/case89`,
  in-case A/B). Byte `[17]` packs both app fields: **low 7 bits = case battery %**
  (`chargingCasePower`), **bit `0x80` = case charging** (`chargingCaseCharging`), and **`0xff` =
  ring not docked in the case**. Ground truth matched exactly: ring placed in case → `0x46` (70 %,
  app showed case 70 %); case plugged in to charge → `0xc6` (70 % **+ charging**); ring re-docked
  later → `0xda` (90 %, app showed 90 %); `0xff` whenever the ring was out of the case. This
  **corrects** the earlier reading of `[17]==0x46` as a "charging witness" — it was simply the
  case sitting at 70 % while the ring was docked in it (the real charging signal is `[2]==0x04`),
  and it also supersedes the old "non-`ff` = data-follows" guess. Decoded by
  `OpenCircuitKit.DeviceStatus.caseBattery`. (Matches the app's device-status model field order:
  `power, state, step, volt, …, chargingCasePower, chargingCaseCharging` — APK `dMb`/`AMb`.)
- **`[14:16]` = battery voltage in mV** (16-bit BE): `4001` mV worn → climbs monotonically
  to `4384` mV peak charge → relaxes to `4196` mV off-charger — a textbook single-cell Li-ion
  curve. This is **#89's "ring raw voltage."** (Supersedes the old `[14]` "declines over days"
  / `[15]` "declines over an evening" notes — both are just bytes of the slowly-moving voltage.)
- The ring **stays BLE-connected and keeps streaming the descriptor while on the charger**
  (the whole charge is in-band), so charging is readable live — no need for the battery-%-rising
  proxy when a frame is in hand. Decoded by `OpenCircuitKit.DeviceStatus.isOnCharger` /
  `.batteryVoltageMillivolts`.
- **`[2]==0x06` = NATIVE SPORT MODE ACTIVE** 🟢 (#174, `captures/workout_yoga_20260709` — 1-hour
  Gentle Yoga btsnoop). `[2]` is a **work-mode** byte: the instant the ring accepted `SportStart`
  (`06 03 07 04 00` → `86 00 86`) the very next descriptor flipped `0x03`→`0x06`, held `0x06` for the
  whole workout (streaming `0x4e` HR+steps ~every 10 s), and returned to `0x02`/`0x03` at `SportStop`
  (`06 00 00`). **Enter rule:** the ring accepts `06 03` **only from idle** (`[2]`=`0x02`/`0x03`); the
  app enters sport from post-sync idle and never sends `06 00` before a start. `07 00 00` (fetch)
  returns a fresh descriptor carrying this byte even mid-session, so it is pollable — the sport-enter
  "reach idle" fast path watches `[2]` for `0x02`/`0x03` before `06 03`. Surfaced as
  `RingSession.lastDescriptorMode`.

**`[6:8]` / `[8:10]` = skin temperature in 0.1 °C** 🟢 (ground-truthed 2026-06-15,
`captures/morning_temp_20260615`). Two near-equal 16-bit BE values (e.g. `01 64 01 65` =
356/357 → **35.6/35.7 °C = 96.1/96.3 °F**); likely skin + reference/object channels. Proof:
- **Donning curve** — ring put on at 14:04 read **28.7 °C** (cold) and climbed steadily
  28.7→30→32→**34.5 °C** over ~25 min, cooled when removed, re-warmed on re-don. A thermistor
  equilibrating on skin; step counts never decrease, so this is not activity. 🟢
- **App-aligned** — morning value 35.6/35.7 °C sits right on the app's nightly **avg
  96.40 °F (35.78 °C)** / baseline 96.73 °F; pair difference (~−0.1…−0.2 °C) ≈ the app's
  deviation **−0.32 °F**. The app samples this **live over the night** (descriptor is sent
  spontaneously ~30–60 s while connected) to compute avg/baseline/deviation — temp is **NOT**
  in the `0x4c` sleep sync, which is why value-searches of the drain failed.
- **Encoding note:** the wire carries the *raw reading* (355–357), not the displayed nightly
  *average* (358) — earlier exact-358 searches missed it by 1–3 LSB.
- **Implication:** readable **live, no sync session / nonce needed** — poll `d0 00 00`→`0x10`
  (or listen for spontaneous descriptors) and parse `[6:8]`/`[8:10]`. Sidesteps the §4 auth wall.
- ⚠️ **COUNTER-OBSERVATION 🟡 (2026-08-28, Gen 3 FW FR05.011, `verify_vibrate.py` session).**
  In an authenticated session with **no sync-open**, the ring returned **no descriptor at all**:
  `d0 00 00` drew no reply, and **65 s** of listening produced no spontaneous `0x10` either.
  The link was demonstrably healthy — notifications were enabled and every `0x0b` write in the
  same session was answered `8b 00 8b`. So the "streams spontaneously every 30–60 s / pollable
  with no session" claim above does **not** hold universally. Candidate explanations, untested:
  (a) telemetry only flows once a sync session is open (the reference captures all had one),
  (b) a Gen 3 / FR05 behaviour change, (c) `d0 00 00` answered `0x50` rather than `0x10` and the
  tool's 19-byte `0x10`/`0x87` filter discarded it.
  **REFINED 2026-08-30 — it is INTERMITTENT, not absent.** A third session on the same ring,
  same tool, still with no sync-open, *did* receive one: `10 45 03 00 00 00 01 38 01 37 00 00
  00 00 0f 2b 4a ff 00 c8` — XOR-valid and parsing cleanly on the **Gen 2 schema** (battery
  69 %, state `0x03` idle, skin temp 31.2/31.1 °C, 3883 mV, `[17]=0xff` not in case), further
  evidence that Gen 3 reuses the Gen 2 descriptor byte-for-byte. So the claim to retire is not
  "descriptors need a session" but the **cadence**: "~30–60 s" is unreliable here, and a client
  must tolerate 65 s+ of silence rather than treat it as a fault. **Consequence for tooling:** any battery,
  skin-temp or state-byte read must treat "no descriptor" as an expected outcome and say so,
  never silently skip a safety check that depends on it.

**`[4:6]` = the ring's onboard step count** 🟢 (live test 2026-06-14). After clearing
the official app and forcing a from-scratch ring re-sync, the app showed **81 steps** and
`[4:6]` in the descriptor frames read **exactly 81** (`00 51`); it is `0` overnight (no
steps) and climbs (6→24→35→79→80→81). NOTE this is the **ring's own
count**, which differs from the app's normal display (cloud-aggregated daily total, e.g.
917 earlier same day) — search for the *ring's* value, not the app's. Decoded by
`OpenCircuitKit.DeviceStatus.steps`.

**…and it is a QUARTER-HOUR BUCKET, not a running day total** 🟢 (**#192**, re-derived
2026-08-09 from the local diagnostics corpus: **10,327 descriptor frames**, **two rings** —
`RingConn Gen2-03AD` FR02.018 America/New_York and `RingConn Gen2 Air-2F9F` FR04.009
Europe/Paris — across 11 bundles, 06-26…08-09). `[4:6]` counts steps since the last
wall-clock `:00`/`:15`/`:30`/`:45` and is cleared to 0 at each boundary:
- **268 drops, every one bracketing a quarter boundary.** Nothing else explains any of them.
  Only 5 sit near local midnight, and those are simply the `00:00`/`00:15` boundaries.
  Sharpest brackets: `Gen2 Air-2F9F` 07:14:24 = 66 → 07:15:06 = 0 (42 s);
  `Gen2-03AD` 08-08 17:14:52 = 98 → 17:16:41 = 0.
- **The day-count reading is refuted arithmetically too.** The field never exceeds **746** in
  any capture, while the app's own folded day totals for those same days are **2,611–4,566**.
  A daily counter cannot be 4–6× smaller than the day it counts.
- **Clear lag:** a descriptor arriving within ~2 min after a boundary can still carry the
  PREVIOUS bucket — measured max **108 s** (06-27 bundle: the 13:15 bucket cleared at
  13:16:49; 08-05 bundle: the 09:00 bucket cleared at 09:01:05). Two consecutive frames one
  second apart can straddle the clear.
- The 2026-06-14 ground truth above is untouched — 81 was a partial bucket. Reading a *day*
  count into it was the over-reach.
- **Consequence:** the ring keeps **no cumulative step counter anywhere on this wire**, so a
  quarter-hour nobody was connected for is unrecoverable — steps are the one metric with no
  ring-side backlog to heal a gap. `OpenCircuitKit.StepAccumulator` folds the observed buckets
  (increment while climbing, credit the raw value whole on a drop = "sum the buckets"); see its
  header for why a wall-clock boundary rule measures **+4.9 %/+8.2 % OVER** and must not be
  reintroduced.
- **Zero is normal and means nothing about wear.** On 2026-08-09 the field read 0 on ~40
  consecutive frames from 08:41 to 10:04 with the ring plainly worn (skin temp 34–36 °C,
  battery 70–71 %) — i.e. no steps *in each of those quarters*. Steps therefore **cannot bound
  an in-bed / wake window** (#190).

### 5.5 `0x50` — end-of-history cursor report (NO XOR trailer) 🟡
Spontaneous after the last bulk page. Distinct class: **no XOR trailer** (last byte
is the low byte of the final cursor). `[0:3]`=`50 00 00`, then 6-byte entries
`[type=15][sub][cursor:4 BE]` — decodes as a **from/to cursor pair** bracketing the
synced range, e.g. `50 00 00 | 15 12 0c22aae4 | 15 12 0c22acb5`. A 21-byte variant
is undecoded 🔴.

### 5.6 `0x02` sync cursor — TIMESTAMP 🟢 CONFIRMED (issue #3 + #5 closed)
Host write `02 00 <cursor:4 BE> <flag:1> 01 00` → `82 00 00 82`.
**cursor = 4-byte BE seconds since epoch `1577793600` (2019-12-31 12:00:00 UTC)** —
3 (time,value) pairs + 2 in-frame cross-checks agree to <0.34 s; 1/sec, monotonic;
same epoch as the record counters. Build current: `floor(unix_utc) − 1577793600`,
BE, into `02 00 <BE4> 00 01 00`. ⚠️ `FF FF FF FF` is **not** "everything" — it's a far-future
cursor that does not pull history (the live-HR "skip history" open; 🟡, see §3 "Load-bearing").
A plausible-recent cursor acts as a **"drain up to ≈now" trigger, not a hard bound** (§3): open
at cursor **≈ now** and the ring streams everything un-delivered up to its current time (records
can overshoot the cursor by minutes), then self-advances its resume pointer.

**No 12 h offset in decoded data 🟢 (issue #5 closed, `morning_temp_20260615`).**
The epoch `1577793600` is 2019-12-31 **12:00:00** UTC (noon, not midnight): the 12 h
"offset vs 2020-01-01" is simply the epoch constant value, NOT a decode error. Verified
across **20 independent sync-open events** spanning 2026-06-13 21:52 UTC through
2026-06-15 09:11 UTC: decoded cursor time matches capture wall-clock to < 0.5 s in
every case (max observed delta 0.5 s, median 0.2 s). No timezone-dependent offset.
`flag` byte[6] (`00`/`03`) is the **history-channel selector** (🟢 from captures, verified on-device) — see §5.6.1.

#### 5.6.1 `byte[6]` = history-CHANNEL selector — TWO channels, `0x00` + `0x03` (#99 — 🟢 RESOLVED + verified on-device 2026-06-21)
**Confidence: 🟢 end-to-end.** The mechanism was proven by channel-aware mining of the EXISTING captures
(no new capture needed), and OUR drain is now **verified on-device**: a pull-to-refresh with `byte[6]=0x03`
at cursor≈now returned **8 all-day epochs** (Debug card readout "sleep 0 · all-day 8"), confirming the ring
answers our ≈now open and streams the daytime pages — not just the official app's own-cursor open (§3).
Across all 14 captures the official app sends **only two** `byte[6]` values,
`0x00` and `0x03`, and they are **two parallel history channels** — each with its own advancing resume
cursor, interleaved over the same time span, both delivering `0x4c` epoch + `0x47` PPG pages. The app
drains **both** every sync; we had hardcoded `0x00`, so we missed everything `0x03` carries.
- **`0x00`** — sleep/overnight log (+ idle epochs). Overnight-weighted SpO₂. (What we always pulled.)
- **`0x03`** — awake/all-day log: activity-HR epochs (`[8]=0x12/0x13`) **plus a periodic (~10 min)
  daytime SpO₂ reading** (sleep-vitals layout, `[8]`=SpO₂). **0 % timestamp overlap with `0x00`** —
  genuinely additional data. Decodes with the SAME 23-byte §5.3 schema, e.g. 06-14 ch `0x03`:
  09:52→98 %, 10:12→97 %, 10:42→92 %, 11:02→89 %, 11:22→90 % (waking hours, HR swinging 57–90).

So all-day SpO₂ was on the wire all along — in channel `0x03`, which our `0x00`-only syncs never
requested. That is the whole cause of "daytime SpO₂ stale for hours" while overnight SpO₂ and on-demand
work. The earlier hypothesis (`byte[6]` = a 32-member `DataSyncType` enumerator; prime candidates
`0x0a`/`0x0b`) is **REFUTED** — the app never sends those values. Channel `0x03` is also **not** the
steps/activity stream (its records fail the 历史活动响应 activity-map bounds, §5.3.1); genuine
steps/activity stay `serverData` (cloud-computed), consistent with #93. The decompiled
`HistoryHrSyncInfo`/`HistorySpo2SyncInfo` tables are the app's CLOUD-side mirrors of this `0x4c` data,
not a distinct wire stream.

**Fix (shipped, verified on-device 2026-06-21):** `syncHistory()` drains both channels via
`drainChannel(channel:)` — `0x00` then `0x03` (`Command.syncChannelSleep`/`syncChannelAllDay`,
`syncSince(channel:)`) — on EVERY sync path (button, pull-to-refresh, foreground/background auto,
periodic). The all-day SpO₂/HR
flow through the existing `BulkSleep` decode → Apple Health (same schema, no new parser).
`AllDayChannelTests` guards that daytime `0x03` SpO₂ reaches Health as samples but is kept out of sleep
staging by the `latestNightRecords` overnight gate. The on-device `byte[6]` sweep (`DataSyncProbe`,
`sweepAllDayStreams`) is **removed** — superseded by this finding.

### 5.7 `0x81` — status replies (← `0x01`)
**`81 00 XX YY`** (← `01 00 00`): `[2]` is the only varying byte, full 8-bit range,
>100 → **not battery %** 🟢; a **per-session token / nonce** 🟡 (issue #4 — see confirmation below).

**Byte[2] analysis, 20 BLE sessions, `morning_temp_20260615_btsnoop.log` 🟢:**
Values span 31–249 (range=218; full 8-bit), definitively not battery % (values >100
common: 176, 218, 216, 203, 227, 249). Non-monotonic within an hour: 7 consecutive
sessions at 13:28–13:52 UTC return 31→120→227→63→249→188→157→128 — no slow battery-like
drift. Two connections using recycled handle 0x002 (separated by >15 h) return
different values (176 vs 148). **Cross-capture confirmation (🟢, 2026-06-16, issue #4,
`desktop/analyze_0x81.py`):** byte[2] is **one value per BLE connection** — `battery76` (ring
steady at 76 %) returns `176, 218, 216, 129, 203, 163, 176, 150, …` across ~20 connections,
**constant within each** connection, full 8-bit range, recurring (`176` on two). So it is
**neither battery (would sit ≈constant near 76 %) nor a sequential counter**: a **per-session
token / nonce** — assigned once per connect — likely the same session-auth nonce family as the
`01 01` arg (the `81 01` block below + § session-open nuances in §3). **Issue #4 answer: not
battery 🟢; per-session token role 🟡.** (Battery is
the `0x10`/`0x87` descriptor `[1]`, §5.4 🟢 — already decoded.)

**`81 01 …`** (38 B, ← `01 01 <nonce>`): mostly constant; notable — `[27:32]`=
`21 49 ac <XX> f4` (4/5 const, device-id-like) · `[34:36]`=16-bit monotonic counter
≈ 1/sec (30→1475→9045 over 3 sessions) 🟡.

### 5.8 Per-connection AUTH (the activation gate) 🟢 CRACKED — issue #54
> ✅ **Standalone confirmed on-device 2026-06-16:** with the official app logged out, OpenCircuit
> activated the ring and streamed on its own. No official app needed. (+ heartbeat + bonding below.)
> ✅ **Never-activated ring confirmed 2026-08-11 🟢 (issue #106, now CLOSED):** an independent tester
> ran OpenCircuit against a factory-fresh Gen 3 (shipped on `FR05.005`) **before the official app was
> ever installed** — live HR and SpO₂ worked as expected. So there is **no first-time provisioning /
> cloud-activation step at all**: the SM3 challenge below plus the local LE-SC bond are the whole
> gate, for any owner of any ring. (They saw the `notStreaming` banner intermittently; it cleared on
> its own. Installing the official app afterwards took firmware to `FR05.010`, still fine.)
The `01 01 <…>` arg is a deterministic **challenge→response auth** — what "activates" the ring for
streaming. Sequence every connect: host `01 00 00` → ring `81 00 <chal> <xor>`; host must answer
`01 01 <r0> <r1> <r2> 00`. **🟢 ALGORITHM (RE'd 2026-06-16 from the official app's Dart AOT
`libapp.so`, capstone-disassembled; verified against 24 captured pairs + the SM3 KAT):**

```
V        = mac[3] ^ mac[4] ^ mac[5]            # XOR of the ring's last 3 BLE-MAC bytes
response = SM3( bytes([V, challenge]) )[29:32] # last 3 bytes of the 32-byte SM3 digest
```

`SM3` is the Chinese national 256-bit hash (GB/T 32905). The **only** key material is the ring's
own MAC — **no cloud key, no app secret** — so it's computable offline for any RingConn. For this
ring (`F8:79:99:F7:03:AD`): `V = F7^03^AD = 0x59`, e.g. `f(0xe5)=52 0b e1`, `f(0xb0)=31 82 67`. The
old hardcoded `01 01 31 82 67` was simply `f(0xb0)`, which is why it only worked when the challenge
happened to be `0xb0`. Impl: `RingAuth.authCommand(challenge:mac:)` (`OpenCircuitKit/RingAuth.swift`).

**MAC on iOS:** CoreBluetooth hides the MAC, but the ring exposes it via the DIS **System ID**
characteristic (`0x2a23`, §1) — read it once on connect (`RingAuth.macFromSystemID`).

**This is the "open the official app to activate" gate, now closed:** a client that answers the
challenge correctly activates the ring's stream itself; OpenCircuit now does this reactively on
`81 00` (`RingSession` `case 0x81`), so it streams standalone with no official-app dependency. (It's
per-connection auth — **not** app-startup and **not** a re-bond; see bonding below.)

**Heartbeat 🟢:** ring→host `11 00 <ctr> <tok> <xor>` (~2.5 min idle; `ctr` resets to 01 per
connection; `tok` = the session token also in `0x10[1]`; `[last]`=XOR). Host replies a constant
`91 00 00` (does not echo). `0x10` telemetry streams on its own ~40/110 s timer regardless of the
ACK. (OpenCircuit now ACKs it — `Command.heartbeatAck`.)

**Bonding 🟢 — NO CLOUD KEY (resolves the Phase-1 make-or-break unknown):** the link is **LE Secure
Connections "Just Works"** (ring IOcap=NoInputNoOutput), LTK generated **locally via ECDH** during
a one-time pairing (seen once at 17:51:58; every reconnect since is re-encryption from the stored
LTK — 25 EncryptionChange events, zero re-pairings, incl. across the 2026-06-16 login). So offline
decoding is sound and HCI-snoop ATT is plaintext. CoreBluetooth auto-bonds; there is **no app-layer
key exchange to replicate for the bond** — the replicable gate is the `f(chal)` auth above.

### 5.9 `0x0b` — VIBRATION MOTOR (Gen 3) 🟢 CONFIRMED

**Command `0b 03 <pattern> 64 00` → `8b 00 8b`.** Decoded from the Gen 3 tester capture
`ringcapture_btsnoop.log`, **FW FR05.011 / app 4.3.1**, 2026-08-27, 20 943 HCI packets over
14 m 44 s, driven by `docs/RUNBOOK_GEN3_BP_HAPTIC.md` §4.2. This is the first Gen-3-only
opcode in this file — the Gen 2/2 Air have no motor.

**🟢 REPRODUCED FROM OUR OWN CLIENT 2026-08-28** (`verify_vibrate.py`, tester's Gen 3,
FW FR05.011). A fresh session ~17 h after the capture, new auth challenge (`0xa7`), no
official app involved: `0b 03 01 64 00` written three times, **buzzed 3 of 3**, each
answered `8b 00 8b`, and the wearer reported the **short-short-long** pattern predicted in
advance from the capture. That is the full 🟡→🟢 promotion — decoded from a snoop, then
reproduced independently from a Mac with a stated prediction that held.

**Every byte of this command is now either confirmed or measured to be inert** (2026-08-30,
12/12 buzzes across 4 distinct frames, all from our own client). Details per byte below.

**The correlation (🟢).** The tester logged the wall-clock time of 8 buzzes. `0x0b` is written
**9 times in the whole capture and at no other moment**. Fitting a single global clock offset
(the capture's own wall clock is ~1 h adrift of the tester's notes, so absolute time is not
usable — only structure is):

| Tester's noted buzz | Step | Frame | Residual |
|---|---|---|---|
| 14:03:57 | 4 — vibration-settings test tap #1 | `0b 03 01 64 00` | +0.8 s |
| 14:04:14 | 4 — test tap #2 | `0b 03 01 64 00` | +1.0 s |
| *(not noted)* | 5 — 1st workout start | `0b 03 **02** 64 00` | — |
| 14:06:52 | 5 — 2nd workout start countdown | `0b 03 **02** 64 00` | +0.8 s |
| 14:09:47 | 8 — HR spot measurement done | `0b 03 01 64 00` | +0.9 s |
| 14:10:39 | 8 — SpO2 spot measurement done | `0b 03 01 64 00` | +0.7 s |
| 14:12:21 | 10 — BP attempt 1 done | `0b 03 01 64 00` | +0.4 s |
| 14:14:18 | 10 — BP attempt 2 done | `0b 03 01 64 00` | +0.0 s |
| 14:15:30 | 10 — BP attempt 3 done | `0b 03 01 64 00` | +0.3 s |

Worst residual **1.0 s**, and every residual is *positive* and inside 1 s — the signature of a
human writing the time down a moment after feeling the buzz, on top of minute-level rounding.

**The falsification test (🟢).** Every other command family was scored the same way, free to
pick its own best offset and its best-matching event per buzz. Only `0b 03` fits:

- `0b 03` (9 writes) → worst residual **1.0 s**
- `07 00` (56 writes — the 30 s fetch heartbeat, 6× more events to draw from) → worst **9.1 s**
- `95 00` (69 writes) → worst **83.8 s**; `01 00`/`02 00`/`01 01` → worst **> 207 s**
- Every remaining family has fewer than 8 writes and cannot cover the buzzes at all.

So no rival command explains the pattern, and the fit is not a pigeonhole artifact of a
frequently-repeated frame.

**Argument bytes.**
- `[1] = 0x03` — constant across all 9. Sub-command.
- `[2]` — **PATTERN selector 🟢 CONFIRMED, and NOT a count** (this corrects an earlier
  "pattern / count" hedge). **Replayed from our own client 2026-08-30: `0b 03 02 64 00` produced
  "a single long buzz", 3/3 — the pattern predicted in advance from the capture** — while every
  `[2]=0x01` frame produced short-short-long. The prediction came first, then the measurement.
  It was also confirmed on a prior independent axis: the tester was asked what the buzzes *felt*
  like, **blind to the byte values**, and his two descriptions partition the nine captured events
  exactly along the two observed values:

  | Felt pattern (tester, blind) | Events | Frame |
  |---|---|---|
  | **short-short-long** | settings toggle ×2, HR done, SpO2 done, BP done ×3 | `0b 03 **01** 64 00` (7×) |
  | **one long buzz** | workout-start countdown ×2 | `0b 03 **02** 64 00` (2×) |

  So `0x02` is *one long pulse*, not two pulses. ⚠️ **Only 2 of the value space is exercised
  here.** The app's Vibration screen carries three separate notification categories (Battery
  Reminder / Sedentary Reminder / Health Alerts), none of which fired during the capture, so
  more `[2]` values very likely exist. Sweep it only after the base replay works.
  *Mild caveat:* the question offered "two pulses / longer / stronger" as examples. He answered
  with "short-short-long", a shape never suggested to him, and independently grouped the settings
  and HR/SpO2 buzzes together against the workout one — that grouping was not hinted.
- `[3] = 0x64` = 100 — **NOT intensity, NOT duration, no observable effect at all 🟢
  (directly tested and refuted).** The obvious reading — a percentage — was wrong twice over:
  - The Vibration settings screen (tester screenshot, app 4.3.1) has **no intensity control**:
    three on/off toggles and a DND schedule, nothing more. So it is not a user-facing setting.
  - **Decisive test 2026-08-30:** we replayed the byte across a **10× range** — `0x64` (100),
    `0x32` (50), `0x0a` (10) — all with `[2]=0x01`. All three buzzed 3/3, and the wearer reported
    **"all the vibration intensities felt the same"**, with `0x32` and `0x0a` producing buzzes
    *identical* to `0x64`'s short-short-long. A 10× swing with no perceptible difference rules
    out intensity and duration alike.
  - Residual 🔴: what it *is*. Candidates — reserved/ignored, a firmware floor clamping low
    values to full power, or a field that means something outside the haptic path. Untested
    below `0x0a` and at `0x00`. **Practical guidance: send `0x64`, exactly as the app does, and
    do not vary it** — it buys nothing and is the only value with field evidence behind it.
- `[4] = 0x00` — the ordinary command terminator (§3); commands are not checksummed.

**Where the vibration SETTINGS live — phone-side, for the reminder toggles at least 🟡.**
The tester's two step-4 buzzes came from **toggling a reminder switch on/off** (app 4.3.1 has no
"tap to feel it" control — the earlier runbook's wording assumed one). Across the whole 14-minute
capture the ring received **no settings write of any kind**: the only host writes in that window
are the two `0x0b` frames and routine `07 00 00` fetches. So the three reminder toggles are
evaluated on the phone, and the ring is a dumb motor driven by `0x0b`.
- **A direct `0x0b` is NEVER gated by Do-Not-Disturb 🟢** (2026-08-28, Gen 3 FR05.011).
  Decisive positive control, with the condition documented rather than asserted: the tester
  **edited the app's DND window to 11:00–19:00** so it covered the present, screenshotted it
  enabled at **11:08**, then ran `0b 03 01 64 00` from our own Mac client at **11:09:17** —
  9 minutes inside the active window — and it **buzzed 3 of 3**.
  - The conclusion holds either way the edit went: if the app never pushed the new window the
    ring has no DND knowledge; if it did push it, the ring knew DND covered that moment and
    buzzed regardless. **So a direct vibrate command is unsuppressed no matter where the
    setting lives** — the app's caption ("the ring won't vibrate during Do Not Disturb hours")
    describes the app choosing not to send.
  - **Consequence for us: our own alerts are NOT suppressed by the user's RingConn DND
    setting**, including overnight, which is exactly when a health alert matters most. We own
    the quiet-hours policy end to end and must implement our own — a user who set quiet hours
    in the RingConn app will reasonably expect us to honour them, and nothing enforces that for
    us. See also the low-battery cut-off, which IS firmware-side and does still bind us.
  - Scope: proven for a **direct command**. Untested whether some *other* ring-initiated buzz
    path (if one exists) is gated differently — but we only ever drive the motor directly.
- The **low-battery cut-off is firmware-side** 🟢 — the same screen states "Vibration turns off
  automatically when the battery is low", matching the app's 20 % refusal message.

**Preconditions observed in this session (not isolated):** the ring was authenticated, battery
read `0x20` = 32 % from the descriptor (above the app's own 20 % refusal threshold), and the
app was foregrounded. Which of these the motor actually requires is untested.

**Next step — the 🟢 gate.** Runbook §8: `verify_vibrate.py --hex 0b03016400`. `0x0b` is not in
that tool's `DANGEROUS_PRIMARY` block-list, so it runs as-is. A buzz the wearer feels from our
own frame promotes this to 🟢; then vary `[2]` and `[3]` to settle pattern vs intensity.

### 5.10 `0x12` — 100 Hz 4-channel raw PPG (BP / dense-measurement mode) 🟢

**The densest optical stream found on this hardware, and ~4× the rate of the known `0x13`.**
Same Gen 3 FR05.011 capture. Not to be confused with the `0x4c` epoch field `[8] = 0x12`
("no SpO2" activity sentinel, §5.3) — unrelated, different layer.

**How it starts and stops (🟢).** The app runs, in order:
`29 00 00` → `a9 ..` (sensor/temp readout) · ~2–3 s later `06 05 00` → `86 00 86` (**mode 5**) ·
~0.5 s later the ring begins pushing `0x12` · ~39 s later `0b 03 01 64 00` (buzz) then
`06 00 00` → `86 00 86` stops it. Observed 3/3 times.

**Push-only — there is NO per-frame ACK (🟢).** 902 frames over 39 s of streaming with not one
host write in between. Unlike `0x47`/`0x4c`/`0x4e`, nothing has to be acked to keep it flowing.

**Frame layout (135 bytes, fixed):**
```
[0]     0x12
[1:3]   seq, 16-bit BE — session-wide, starts at 1, never resets per attempt
[3]     0x01        [4] 0x00
[5]     0x83        (length-ish; 135 - 4. NOTE: 0x13's equivalent byte is 135-3. 🔴 unreconciled)
[6:126] 10 samples x 12 bytes = 4 channels x 24-bit BE per sample
[126]   0x0a = 10   samples in this frame
[127]   0x0f/0x11   🔴      [128] 0x00      [129] 0x11..0x19, settles 🔴
[130:133]           cumulative sample counter, 24-bit BE (steps of 10/frame) 🟢
[133]   0x00
[134]   XOR trailer (§3)
```
**Integrity over the whole session: 902/902 XOR-valid, sequence 1→902 with ZERO gaps.** Nothing
was dropped; the complete assessment is recoverable from a snoop.

**Channels — measured over BP attempt 3 (38 s, 3 820 samples, fs = 100.73 Hz):**

| ch | mean | std | reading |
|---|---|---|---|
| 0 | 407 034 | 10 864 | LED, large DC + pulsatile 🟢 |
| 1 | 438 108 | 4 681 | LED, large DC + pulsatile 🟢 |
| 2 | 2 726 | 85 | small-DC channel, not pulsatile 🟡 |
| 3 | -6.5 | 112 | small **signed** value, 20-bit two's complement (99.8 % within ±1000, zero-centred) — ambient / dark-current cancellation 🟡 |

**Proof it is a real optical pulse waveform (🟢, `desktop/` FFT, cubic-detrended, Hann):**
- Attempt 3: ch0 peaks at **1.239 Hz = 74.4 bpm, SNR 30.6**; ch1 peaks at the **same** 1.239 Hz,
  SNR 28.5. Two independent channels agreeing to the FFT bin on a plausible resting HR.
- Attempt 1, a separate 37 s window: ch0 **1.252 Hz = 75.1 bpm**, ch1 **1.252 Hz** — reproduced.
- The already-known `0x13` stream over the *same* windows is far weaker and channel-inconsistent
  (SNR 2.3–3.4, peaks scattered 0.98–2.93 Hz). **`0x12` is the better BP/HRV substrate.**
- The first ~2 frames of each run are a monotone AGC/DC-cancellation settling ramp, not signal —
  discard them.

**`0x13` for comparison (already known, `stream_ppg_13.py`):** 160 B, 25 samples x 3 x int16 BE,
**25.8 Hz**, 146/146 XOR-valid. It streams *concurrently* with `0x12` in mode 5.

**Rate caveat 🟡:** attempts 1 and 3 both ran **100.6/100.7 Hz**. Attempt 2 measured 27.6 Hz —
but the BLE link dropped and re-authenticated mid-measurement in that window (a fresh `01 00 00`
challenge cycle sits inside it), so that is a transport loss, not a second sampling mode.

**RingConn's BP NUMBER is still not on the wire — reconfirmed 🟢.** The tester reported the
app's systolic/diastolic result for attempt 3 plus a same-minute cuff reading (**values held
privately — tester health data, not published**). Searching the entire capture for each of
those four numbers as adjacent byte pairs, in both orders, returns **one** hit, and it is
inside a `0x12` PPG sample payload — coincidence, not a result. Of the 31 frames after the
successful assessment completed, **zero** contain a reported pair anywhere. This is consistent with the APK evidence
(§ RUNBOOK_GEN3_BP_HAPTIC §7): the raw signal goes up, the number comes back from RingConn's
server. **What we get from the wire is the input, not their answer** — which is exactly the
calibration substrate #120/#38 need.

**Unresolved from this capture 🔴:** `05 23 01 00` → `85 00 85`, sent once, between BP attempts
1 and 2, right after a reconnect. Sibling of the OSA arm command `05 22 01` (`RUNBOOK_OSA_APNEA`),
so treat the `0x05` family as potentially mode-arming and **do not replay it speculatively**.

## 6. Ground-truth captures needed (prioritized)

Each names the single capture that converts a 🟡/🔴 field into a decoded metric.
1. **`0x47` → real PPG (issue #8 — PARTIAL):** offline RE (§5.2, `analyze_0x47_bitwidth.py`) has
   **settled bit-width = 10-bit BE 🟢, record cadence = 900 s/15 min 🟢, single-channel + not
   pulse-resolution 🟢/🟡, `[4:6]`=optical DC/baseline 🟡.** Still open and needing the app's
   **realtime/exported PPG trace over the same btsnoop window**: channel **identity** (which LED;
   AC vs DC) 🔴, exact within-record sample spacing 🟡, and absolute physical units. (`0x47` is a
   *sparse 15-min perfusion trend* — live HR rides `0x15`, not this — so finger-on/off alignment
   needs the app trace, not just a fresh capture.)
2. ✅ **`0x4c` → sleep/HR/HRV/SpO2 epochs — DECODED.** `captures/sleep_sync_btsnoop.log`
   (2026-06-13 night) aligned to the app's readout: sleep-vitals epoch `[4]`=HR,
   `[5]`=HRV(ms), `[8]`=SpO2(%) confirmed (§5.3); `[10:20]`=`acti_counts`. The APK map
   cross-confirmed these and resolved `[6]`=confidence, `[7]`=RR×8 (#93). Skin temp +
   RR-summary still not in this stream. Stages are app-computed, not on the wire. (Issue
   #7/#9.) The **steps/distance/activeSeconds/powerLevel activity record (#93) is a
   separate, un-captured stream** — see §5.3.1; blocked on a `byte[6]`-activity capture.
3. ✅ **Counter→wall-clock — PINNED.** Counter is seconds (§5.6 epoch); the bulk-record
   step `+0x96` = **150 s**, so each `0x4c` record is a 2.5-min epoch and `0x47` records
   span `0x0384`=900 s. Cross-checked: last session ends 6 min before the sync.
   `morning_temp_20260615` re-confirms: 28/29 `0x4c` steps=150 (1×151 rounding), 19/19
   `0x47` steps=900, across 752 `0x4c` and 128 `0x47` records. (Issue #3 ✅ closed.)
4. ✅ **`0x10`/`0x87` `[15]` — RESOLVED.** `[15]` is the **low byte of the 16-bit battery
   voltage `[14:16]`** (§5.4, #89), ground-truthed by the 2026-06-19 charger A/B (`4001→4384`
   mV across a charge). Its "declines over an evening/days" behaviour was just the voltage
   sagging — not a separate quantity. `[14]` likewise = voltage high byte.
5. ✅ **`0x81 00` byte[2] — NOT battery; per-session nonce 🟡.** `morning_temp_20260615`
   shows 20 sessions, byte[2] spans 31–249, non-monotonic, exceeds 100% repeatedly.
   Definitively not battery %. Likely a per-session ring-state nonce (source unknown 🔴).
   To settle: capture `01 00 00` responses across a full battery discharge cycle from 100%
   to <20% — if byte[2] shows no correlation with battery level, the nonce hypothesis is
   confirmed. (Issue #4 partially answered — battery ruled out; nonce still 🔴.)
6. ✅ **`0x02` epoch / 12 h offset — RESOLVED.** The epoch is noon UTC on 2019-12-31;
   the "12 h" is the epoch constant, not a decode error. 20 sync-open events confirm
   decoded UTC matches capture wall-clock to < 0.5 s. No 12 h offset in decoded data.
   (Issue #5 ✅ closed; see §5.6.)
7. **Auth function `f(challenge)` (issue #54 — the activation gate):** `01 01 <nonce>` is a
   deterministic challenge→response, NOT arbitrary (§5.8). 24/256 entries known from captures;
   recover the full `f` by decompiling the official APK (`com.gdjztech.ringconn`) — needed to make
   OpenCircuit stream standalone (without the official app activating the ring).
8. **Skin temp + its transport:** temp is measured only at night yet is absent from a full
   activity/sleep/PPG sync, from `0x0900`, and from a capture with the Temperature screen
   open (that screen reads cache, no BLE). **Mac active-probing is ruled out** — data
   commands need a bond (§0). Remaining lead: a **from-scratch phone resync** — `adb shell
   am force-stop com.gdjztech.ringconn`, reopen the app so it does a fresh sync (it still opens
   at cursor ≈ now per §3 — NOT cursor 0 — but drains whatever backlog accrued while stopped),
   and btsnoop that; a large fresh drain may surface the temp fetch the small incremental syncs skip.
   Ground truth: `−0.16` deviation / `96.75 °F` (and `96.58 °F`/35.88 °C for 2026-06-13);
   expect an absolute near `3588`–`3597` (0.01 °C). Unblocks the
   `bodyTemperature`/`appleSleepingWristTemperature` HealthKit write.

---

## How to extend this file

1. Capture with the official app doing one thing (e.g. only a SpO2 measurement).
2. Isolate the writes/notifications in that window (`opencircuit decode-log`).
3. Form a hypothesis about the command + response format; note it 🔴.
4. Replay the write with `opencircuit replay` and confirm the response → 🟡.
5. Reproduce across sessions / values until stable → 🟢.
