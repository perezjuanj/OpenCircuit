# RingConn Gen 2 — BLE Protocol (living spec)

This is the primary deliverable of Phase 1. Everything here is an **observation**,
not vendor documentation. Mark each fact with a confidence level and the capture it
came from. Treat unconfirmed entries as hypotheses to disprove.

Confidence legend: 🟢 confirmed (reproduced) · 🟡 probable · 🔴 guess / unverified

**Reference capture:** Android btsnoop, FW **FR02.018**, ring `RingConn Gen2-03AD`
(MAC `F8:79:99:F7:03:AD`), 2026-06-13 21:51. 326 ATT events: identity reads, a live
measurement (`0x95` poll loop), and a bulk history/PPG download. Pin observations
below to this FW until re-confirmed on another version.

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
- The **desktop `openringconn` workbench can scan/enumerate/handshake but NOT pull data**
  — CoreBluetooth/bleak can't initiate pairing (`pair()` → NotImplementedError on macOS).
  `listen`/`replay` of data commands will see nothing. Active probing from the Mac is a
  dead end; capture the phone instead.

**Resolved on iOS 🟢 (2026-06-14): bonding unlocks data, and it's shared across apps.**
Our iPhone app first hit the same wall (live HR poll → only the `81 01` handshake, no
`0x15` frames). The fix: **bond the iPhone to the ring once** — installing the official
RingConn iOS app and signing in establishes the device↔ring LE bond. BLE bonds are
**per device, not per app**, so OpenRingConn then inherits it: `02`/`07`/`95` go through
and **live HR decoded 68 bpm** + history sync started. The ring supports multiple paired
phones, so this doesn't disturb the Android pairing.
> **Operational requirement:** any device running OpenRingConn must already be bonded to
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

**The `02` arg is a sync CURSOR, not a timestamp** (🟢, this was the key unlock).
Real-time values are *rejected* (no `82`); only a cursor **≥ the ring's last-synced
position** is accepted. `02 00 FF FF FF FF 00 01 00` (max) always works and means
"sync everything". The capture's `0c 22 98 c3` was the app's then-current cursor;
replaying it now fails because the ring has since advanced past it.

**Verified live-HR sequence (from the Mac, `desktop/livehr.py`):**
```
01 00 00                  -> 81 ..        (wake/status)
01 01 31 82 67 00         -> 81 01 ..     (config table)
02 00 FF FF FF FF 00 01 00 -> 82 ..       (open sync, cursor=all)
07 00 00 + c7/cc acks     -> 87,47,4c ..  (drain any history backlog)
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
> - `02 00 <cursor:4> …` cursor advances each sync (`0c 22 98 c3` → `0c 22 bb f7`).
>   `FFFFFFFF` works only while a backlog exists.
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
`[4:6]`=16-bit baseline (`[4]`=`02` const, `[5]` drifts) 🟡 · `[6:9]`=usually `00 00 00`,
else per-record flag/event 🟡 · `[9:47]`=**38 B = 30 × 10-bit big-endian samples**
(300 bits + 4 zero pad-bits) 🟢.

**Bit-width resolved (10-bit), 2026-06-13 capture.** Decoding `[9:47]` as 10-bit BE
gives the lowest sample-to-sample jitter of all widths (0.32 vs 0.39–0.42 for 8/12/16)
and clean pulsatile waveforms on worn records (counter `0c22…`). The 30 samples are
**two interleaved channels × 15** (even/odd): splitting them lowers jitter further
(0.13–0.15) and the two tracks are near-identical (e.g. `553/553 → 629/623 → 646/647`)
— consistent with **red + IR PPG** (the pair SpO2's ratio-of-ratios needs; SpO2 itself
lands in `0x4c[8]`, §5.3). 🟢
Cadence: ~80 records span 20 days (very **sparse** — occasional optical snapshots, not a
continuous trace); 30 samples per 900 s record ≈ 1/channel/min, so this is a
perfusion/amplitude trend, not pulse-resolution waveform 🟡. Reproduce with
`desktop/decode_ppg.py`.

### 5.3 `0x4c` — bulk activity/sleep page (ACK each with `cc 00 00`)
Page: `[0]`=`0x4c` · `[1]`=`00` · **`[2]`=remaining-RECORD countdown** (−6/page) ·
body = 6×**23-byte records** · `[last]`=XOR. 🟢
Record (23 B): `[0]`=`0x0c` · `[1:4]`=BE counter **+0x96/rec** (cursor space) 🟢 ·
`[8]`=subtype tag 🟡 · `[9]`=small int (mostly `0a`) 🟡 · `[10:15]`=**5-channel motion**
(see below) 🟢 · `[15:22]`=7-B per-epoch physiology payload 🟡 · `[22]`=trailer flags 🟡.
Idle/unworn template: `[4:7]=05 00 0c 00`, `[9]=0a`, `[10:14]=01×5`, `[15:21]=00×7` 🟢.

**+0x96 counter step = exactly 150 s** (the counter is seconds, §5.6) → **each record
is a 150 s / 2.5-min epoch.** 🟢 Confirmed by `captures/sleep_sync_btsnoop.log`
(FR02.018, full multi-day history sync, 470 records over 3 stored sessions). The last
session decodes to **2026-06-13 23:09 → 06-14 09:32** and its end matches the bugreport
pull time (09:38) to <6 min — counter→wall-clock is right and lands on **device-local**
time (no 12 h offset in this capture; bears on §5.6/§6.6). Reassemble + decode with
`desktop/decode_bulk.py`.

**Two record layouts**, distinguished by `[8]`:
- **Activity/awake epoch** `[8]=0x12`/`0x13`: physiology/activity in `[15:22]`, motion
  in `[10:15]` elevated.
- **Sleep-vitals epoch** `[8]=0x57–0x63` (87–99): per-epoch vitals in `[4:9]`, motion
  `[10:15]` at `01` baseline, `[15:22]` ≈ zero.

**Sleep-vitals fields — confirmed against the RingConn app's readout for the
2026-06-13 night** (avg HR 68 / HRV 65 ms / SpO2 98 %, low 93 % ~02:30–03:00):
- **`[4]` = heart rate (bpm)** 🟢. Sleep-window mean ~60, dips to 56–57 in deep-sleep
  hours, rises to 66 at wake; evening (active) epochs read 83 — physiologically correct.
  (Sleep mean < app's all-night avg 68 because the app average includes daytime.)
- **`[5]` = HRV / RMSSD (ms)** 🟢. Mean 69, median 70 vs app 65; high beat-to-beat
  spread (36–114) as expected for RMSSD.
- **`[8]` = SpO2 (%)** 🟢. Mean 96, and the low cluster (89–93) lands at **02:32–03:07**,
  matching the app's "lowest 93 % around 2:30–3 am" — the decisive temporal anchor.
- `[6]` (1–10, ~9) and `[7]` (~120) unresolved 🟡 — candidate signal-quality / pulse
  amplitude. `[9]`≈`0x0a` and `[22]` (low-nibble `4`, high-nibble varies) flags 🟡.
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
    `0x10`/`0x87`). So flag is NOT a per-metric stream selector. Purpose still 🔴 — other
    flag values (`01`/`02`/`04`…) are untried and a candidate temp/summary selector for
    **active probing** (`replay 02 00 <cursor> 0X 01 00`).
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

> **Status:** HR `[4]`, HRV `[5]`, SpO2 `[8]`, motion `[10:15]` and the 150 s cadence are
> 🟢 (app-aligned, §6.2). Open: `[6]`/`[7]` semantics, the activity-epoch `[15:22]` payload,
> and skin temp + RR (not in this capture — see above).

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
XOR-valid. `[1]`=per-session marker (`4e`→`5c`; same value in `0x81 01`) 🟡 · `[2]`=
state enum `01–04` (not a counter) 🟡 · **`[4:6]`=STEP COUNT (16-bit BE)** 🟢 ·
**`[6:8]`/`[8:10]`=SKIN TEMPERATURE, two channels, 0.1 °C BE** 🟢 (each prefixed `01`=
valid; see below) · `[15]`=declines over an evening but **not plain battery** 🟡 ·
`[17]`=`ff` idle; **non-`ff` precedes a bulk stream → "data follows"** 🟡.

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

**`[4:6]` = the ring's onboard step count** 🟢 (live test 2026-06-14). After clearing
the official app and forcing a from-scratch ring re-sync, the app showed **81 steps** and
`[4:6]` in the descriptor frames read **exactly 81** (`00 51`); it is `0` overnight (no
steps) and climbs through the day (6→24→35→79→80→81). NOTE this is the **ring's own
count**, which differs from the app's normal display (cloud-aggregated daily total, e.g.
917 earlier same day) — search for the *ring's* value, not the app's. Decoded by
`OpenRingKit.DeviceStatus.steps`.

### 5.5 `0x50` — end-of-history cursor report (NO XOR trailer) 🟡
Spontaneous after the last bulk page. Distinct class: **no XOR trailer** (last byte
is the low byte of the final cursor). `[0:3]`=`50 00 00`, then 6-byte entries
`[type=15][sub][cursor:4 BE]` — decodes as a **from/to cursor pair** bracketing the
synced range, e.g. `50 00 00 | 15 12 0c22aae4 | 15 12 0c22acb5`. A 21-byte variant
is undecoded 🔴.

### 5.6 `0x02` sync cursor — TIMESTAMP 🟢 CONFIRMED
Host write `02 00 <cursor:4 BE> <flag:1> 01 00` → `82 00 00 82`.
**cursor = 4-byte BE seconds since epoch `1577793600` (2019-12-31 12:00:00 UTC)** —
3 (time,value) pairs + 2 in-frame cross-checks agree to <0.34 s; 1/sec, monotonic;
same epoch as the record counters. Build current: `floor(unix_utc) − 1577793600`,
BE, into `02 00 <BE4> 00 01 00`; `FF FF FF FF` = "everything" while backlog exists.
The 12 h offset vs 2020-01-01 is byte-confirmed but its **cause** (local-tz vs
firmware epoch vs AM/PM) is unresolved from one timezone 🟡. `flag` byte[6]
(`00`/`03`) meaning unknown 🟡.

### 5.7 `0x81` — status replies (← `0x01`)
**`81 00 XX YY`** (← `01 00 00`): `[2]` is the only varying byte, full 8-bit range,
>100 → **not battery %**; likely a session token 🔴.
**`81 01 …`** (38 B, ← `01 01 <nonce>`): mostly constant; notable — `[27:32]`=
`21 49 ac <XX> f4` (4/5 const, device-id-like) · `[34:36]`=16-bit monotonic counter
≈ 1/sec (30→1475→9045 over 3 sessions) 🟡. The `01 01 <3-B nonce>` arg is per-session
and **arbitrary** (ring accepts any value — see §4); the constant `21 49 ac _ f4`
block is a candidate nonce source 🔴.

## 6. Ground-truth captures needed (prioritized)

Each names the single capture that converts a 🟡/🔴 field into a decoded metric.
1. **`0x47` → real PPG:** app's realtime/exported PPG trace recorded over the *same*
   window as a btsnoop sync → confirms bit-width, channel, counter time-unit.
2. ✅ **`0x4c` → sleep/HR/HRV/SpO2 epochs — DECODED.** `captures/sleep_sync_btsnoop.log`
   (2026-06-13 night) aligned to the app's readout: sleep-vitals epoch `[4]`=HR,
   `[5]`=HRV(ms), `[8]`=SpO2(%) confirmed (§5.3); `[10:15]`=motion. Remaining 🟡/🔴:
   `[6]`/`[7]` semantics, and respiratory rate + skin temp (not in this record — likely
   a separate summary frame). Stages are app-computed, not on the wire. (Issue #7/#9.)
3. ✅ **Counter→wall-clock — PINNED.** Counter is seconds (§5.6 epoch); the bulk-record
   step `+0x96` = **150 s**, so each `0x4c` record is a 2.5-min epoch and `0x47` records
   span `0x0384`=900 s. Cross-checked: last session ends 6 min before the sync. (Issue #3.)
4. **`0x10`/`0x87` `[6:8]`/`[15]`:** sync after a known wear interval + app UI/battery
   screenshot → maps A/B to record counts and `[15]` to a real quantity.
5. **`0x81` token vs battery:** repeat `01 00 00` within a session & across battery
   levels → is `81 00 [2]` a token or battery; disambiguate `81 01 [34:36]`.
6. **`0x02` epoch cause:** a capture incl. the clock-SET command, or a sync from a
   phone set to UTC → resolves the 12 h offset.
7. **Session nonce source:** correlate `01 01 <nonce>` against prior `0x81`/`0x10`
   fields. *(Not required — nonce is arbitrary; §4.)*
8. **Skin temp + its transport:** temp is measured only at night yet is absent from a full
   activity/sleep/PPG sync, from `0x0900`, and from a capture with the Temperature screen
   open (that screen reads cache, no BLE). **Mac active-probing is ruled out** — data
   commands need a bond (§0). Remaining lead: a **from-scratch phone resync** — `adb shell
   am force-stop com.gdjztech.ringconn`, reopen the app so it re-pulls history from cursor
   0, and btsnoop that; a full resync may issue the temp fetch the incremental syncs skip.
   Ground truth: `−0.16` deviation / `96.75 °F` (and `96.58 °F`/35.88 °C for 2026-06-13);
   expect an absolute near `3588`–`3597` (0.01 °C). Unblocks the
   `bodyTemperature`/`appleSleepingWristTemperature` HealthKit write.

---

## How to extend this file

1. Capture with the official app doing one thing (e.g. only a SpO2 measurement).
2. Isolate the writes/notifications in that window (`openringconn decode-log`).
3. Form a hypothesis about the command + response format; note it 🔴.
4. Replay the write with `openringconn replay` and confirm the response → 🟡.
5. Reproduce across sessions / values until stable → 🟢.
