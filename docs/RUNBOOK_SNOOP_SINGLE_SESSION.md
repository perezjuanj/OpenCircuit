# Runbook: Single-Session Android HCI Snoop — Maximum-Coverage Capture

One clean daytime snoop of the **official RingConn Android app** advances **10 open
issues at once**. Turn on HCI snoop logging *once*, drive the app top-to-bottom through
the checklist below, pull one `btsnoop_hci.log`, and we decode everything from that
single reading.

Generated from an issue-triage sweep (2026-07-05). Companion to
`docs/REVERSE_ENGINEERING.md`, `docs/RUNBOOK_CAPTURE_SESSION.md`, and `docs/PROTOCOL.md`.

---

## Which issues this covers

| Issue | Needs snoop | Covered by section | What we're after |
|---|---|---|---|
| **#9** decode per-metric semantics (§5 🟡→🟢) | ✅ yes | B, C | activity-record layout + 0x47 PPG identity |
| **#10** iOS history-sync → HealthKit | 🟡 partial | C | 0x47 PPG identity + sync-open A/B (rest is iOS impl) |
| **#38** 0x47 PPG / daytime HRV | 🟡 partial | C, D | auto-measure trigger cadence + live PPG (rest is analytics) |
| **#88** device-config WRITE channel | ✅ yes | F, H | find-ring / 24h / airplane / threshold write opcodes |
| **#90** sport-mode start/stop/pause | ✅ yes | G | SportStart/pause/resume/stop + SportHrModel stream |
| **#93** 0x4c activity-epoch decode | ✅ yes | B | byte[6] activity selector + step/intensity records |
| **#94** all-day stress | 🟡 partial | E | online-vs-offline probe: is stress on-wire or cloud? |
| **#95** daily Activity Score | 🟡 partial | B | 4-level intensity band ground truth (decode belongs to #93) |
| **#96** ring write actions (iOS) | ✅ yes | F, H | same write opcodes as #88 (this is the iOS consumer) |
| **#106** any-owner gate (fresh ring) | 🟡 fallback | — | only if OpenCircuit standalone test fails (see Notes) |

**Excluded / cannot fold into this session** — see Notes:
- **#87** temp / waking-RR fetch — overnight-only (separate night capture).
- **#91** OSA 5 Hz PPG — overnight-only + firmware/battery gated (separate night capture).
- **#92** OTA firmware — documented non-goal, bricking risk, **do not trigger**.
- **#97** wellness capstone, **#119** overnight-drain bug, **#129** BP re-auth — pure
  iOS/analytics, **no snoop needed at all**.

---

## Before you start

Standard setup lives in `docs/REVERSE_ENGINEERING.md` §Track A and
`docs/RUNBOOK_CAPTURE_SESSION.md`. Short version:

- Official app pkg: **`com.gdjztech.ringconn`**. OpenCircuit pkg:
  **`com.standardsoftwaresolutions.opencircuit`**. Write handle **`0x0802`** / notify
  **`0x0804`**.
- Get your **ring MAC** from the official app (Device Info) or
  `adb shell dumpsys bluetooth_manager | grep -i ringconn`; you'll pass it as `--addr`
  when decoding. *(The exact MAC is not committed to the repo — grab it live.)*
- Developer options → **Enable Bluetooth HCI snoop log (Full)** → toggle Bluetooth
  **off/on** so the log starts clean.
- Force-stop OpenCircuit so only the official app owns the link:
  `adb shell am force-stop com.standardsoftwaresolutions.opencircuit`.
- Confirm snoop is live:
  `adb shell dumpsys bluetooth_manager | grep -iE "ringconn|snoop"`.
- Ring worn, snug, **off charger**, bonded to this phone only. Note firmware, battery %,
  wall-clock start.
- Pull at the end:
  `adb bugreport ~/Documents/Git/OpenRingConn/desktop/captures/session_YYYYMMDD.zip`
  → extract `FS/data/log/bt/btsnoop_hci.log` into `desktop/captures/`.
- Decode: `python -m opencircuit decode-log captures/<log> --addr <ring-mac>`.

**Log ground-truth notes for every action: wall-clock time + on-screen values.** The
decode is byte-aligned against these numbers.

---

## In-session checklist (do top to bottom)

Passive reads first, live measurements next, config toggles after, link-dropping actions
(airplane mode, sport-stop) **last**. Idle ~30 s between distinct actions so frames
separate in the log.

### A. Connect + baseline
- [ ] Open the official app; let it connect + auth.
      → session marker (all issues). Watch: `host 01 00 00 → ring 81 00 <chal>`, then
      `host 01 01 <r0 r1 r2> 00`. Confirms `f(chal)` auth, no cloud key (**#106**).
- [ ] Let the initial history drain finish (dashboard populates).
      → so later config writes aren't drowned. Watch: baseline `0x02` sync-opens; note
      every distinct **byte[6]** value (we hold only `0x00` sleep / `0x03` all-day).

### B. Activity / steps drain — **#9 #93 #95** (partial **#94**)
*Do the FIRST full sync before the walk to reset the resume pointer.*
- [ ] Home/dashboard → **pull-to-refresh a full sync**; let it complete.
      → drains + resets the activity resume pointer. Watch: `02 00 <cursor:4> 00 01 00`
      + `82` ACK.
- [ ] **Take a KNOWN walk, ~15 min, pace slow→brisk→slow**, phone/other counter for
      reference steps. Note start/stop time + step count.
      → stages ground truth; nothing on wire yet (ring buffers to history).
- [ ] Back at phone → open app → **pull-to-refresh full sync again**; keep snoop running
      until pages stop.
      → Watch: the **byte[6] activity selector** (predicted **`0x02`**, never seen) on
      the sync-open, then activity records matching §5.3.1 — steps[4:6] LE,
      DeviceState[6], powerLevel[7], Temp1..4[8:16], active_seconds[19:21] LE,
      dailyActiveFlag[21]. ACK cadence `cc 00 00`.
- [ ] Open Activity/Steps detail for that day → **scroll back one day** (forces a
      non-empty cursor, not `FF FF FF FF`).
      → Watch: exact activity-channel cursor/selector bytes + older-history pages.
- [ ] **Screenshot**: total steps, distance, active minutes, stand hours, per-2.5-min
      intensity bars for the walk window.
      → ground truth for the 4-level intensity bands + step monotonicity
      (active_seconds ≤ 150/epoch).

### C. Live HR / PPG measurement — **#9 #10 #38**
- [ ] Open live HR / Measure screen; **hold still ~60–90 s to completion; repeat 2–3×.**
      → Watch: live `06 01 00` (HR) + any other `06 XX YY` sub-mode WRITEs; the
      accompanying `0x87`/`0x10` live-PPG frames and `0x47` PPG pages. Note on-screen HR
      + wall-clock to pin 0x47 channel identity (red vs IR), AC/DC, sample spacing,
      units.
- [ ] If an SpO2 / HRV / stress spot-check exists, **run it still ~60 s.**
      → Watch: any non-`06 01` measure command + its per-sample reply (`0x10/0x87` or
      `{utc,hrv,conf}`) + `0x47` page — candidate daytime-HRV source.

### D. Passive auto-measure cadence — **#38**
- [ ] Leave app foregrounded, ring worn, **~15–20 min idle**; note wall-clock of each
      auto-measure animation.
      → Watch: the app command that starts a passive auto-measure PPG window (precedes
      `0x87/0x10`) + its re-trigger cadence.

### E. Stress online-vs-offline probe — **#94**
- [ ] **(Online, Wi-Fi/cell ON)** Open Stress/HRV screen; let it fully populate;
      **screenshot** score + Morning/Afternoon/Night/BeforeDawn segments.
      → Watch: any BLE fetch on screen-open — a `0x02` open with **byte[6] ≠ 0x00/0x03**,
      or NO ring fetch (paints from cache → cloud-computed).
- [ ] **Enable Airplane mode, then Bluetooth back ON** (BT on, Wi-Fi/cell OFF).
      Force-stop + reopen app; let it sync the ring offline; reopen Stress/HRV.
      **Screenshot** whether score/segments populate or stay blank.
      → Watch: stress populates OFFLINE (→ on the wire; identify frame/byte[6]) vs stays
      blank (→ cloud-only; redirect #94 to in-Swift). **Re-enable Wi-Fi/cell after.**

### F. Config-write toggles — **#88 #96** (group them; ~3 s apart; repeat each on/off/on 2–3×)
- [ ] **Find My Ring / ring search** → LED blinks → stop.
      → Watch: WRITE on `0x0802` (`keyStartSearchLight`), `[cmd][sub][payload][00]`, +
      any stop write; `0x80`-XOR response on `0x0804`.
- [ ] **24-hour time format** OFF → ON → OFF.
      → Watch: two `0x0802` writes differing only in the bool payload byte
      (`0x00` vs `0x01`) — `upload24HourFormat`.
- [ ] **Set a reminder/threshold** from one distinct value to another (e.g. high-HR alert
      100 → 140).
      → Watch: config-write on `0x0802` carrying the threshold opcode + numeric payload;
      the changed byte(s) pin the field encoding.

### G. Sport / workout — **#90** (link-affecting; do after config)
- [ ] Open Exercise/Workout → **START a session** (e.g. indoor walk); note start time;
      move ~60 s.
      → Watch: `SportStart` on `0x0802` (suspected sibling of `06 01/02`, or a new opcode
      + sport-type byte); onset of live `SportHrModel{utc,hr,conf}` on `0x0804`.
- [ ] **PAUSE ~30 s, then RESUME.**
      → Watch: `app_exercise_mode_pause` / `_resume` opcodes; whether the notify stream
      halts/restarts.
- [ ] Mid-workout, **slip ring OFF finger and back ON** with measure view open ~1 min.
      → Watch: finger-on/off edge in `SportHrModel.conf` + `0x47` PPG (channel-identity
      marker vs a known HR — aids #38).
- [ ] **STOP/END workout**; note stop time; **screenshot** summary (avg/max HR,
      per-segment graph, duration, distance/steps).
      → Watch: `SportStop`/end command on `0x0802` + end-reason encoding.

### H. Airplane mode + teardown — **#88 #96** (DESTRUCTIVE / drops the link — do LAST)
- [ ] If the app has a **Ring Airplane/Flight mode** toggle: ON, confirm dialog, wait
      ~5 s, observe the ring drop BLE, then re-enable (charging case as the app
      instructs). If absent in this app/firmware, **note that**.
      → Watch: the last host→ring WRITE on `0x0802` before link loss —
      `keyRingFlightMode` / `flightModeConfig` opcode + on/off byte.
- [ ] **Force-stop app → Bluetooth OFF → pull the log**
      (`adb bugreport …session_YYYYMMDD.zip`). Record final on-screen step count, active
      minutes, live HR/SpO2 as ground truth.

---

## Notes / gotchas

- **#87 (temp / waking-RR) is overnight-only — cannot fold in.** The dedicated
  TemperatureSync/breath fetch fires on the app's *first-of-day* sync of an un-synced
  night. Recipe: `am force-stop com.gdjztech.ringconn` before bed, wear the ring
  off-charger overnight, then **open the official app first thing in the morning** and
  watch for a new `0x02` byte[6] (candidates `0x01`/`0x02`/`0x04`). Run
  `docs/RUNBOOK_OVERNIGHT_TEMP.md` as a separate night capture.
- **#91 (OSA / 5 Hz PPG) is overnight-only + gated:** firmware ≥ `FR02.005.007` and
  battery ≥ 30%, else the app refuses (`osaStartFail`). Separate night session; watch
  `keyOSAStartMonitor` write + dense page `0x15`/`0x16`. **Do not attempt in this daytime
  session.**
- **#106 fresh-ring test is a FALLBACK only** — needs a *factory-fresh, never-activated
  ring* + a phone never paired to it. Primary path is the OpenCircuit standalone test;
  only run the official-app first-time-onboarding capture if that standalone test fails.
- **#92 (OTA) is a documented non-goal — do NOT trigger a firmware update.** Bricking
  risk; excluded.
- **Bond-stealing:** run the whole session on the phone that owns the ring's bond. Do not
  log into the official app on a second phone before/during — it re-pairs and steals the
  bond.
- **Ordering matters:** airplane-mode and workout-stop drop/alter the link, so they run
  last; the activity-drain full-sync (B) must run *before* the walk to reset the resume
  pointer, and *again after* to drain the known-walk epochs.
- **Contention:** keep OpenCircuit force-stopped the entire session — a concurrent
  background drain from our app advances the ring's shared resume pointer and can eat the
  backlog.
- **Buffer roll:** pull the log promptly at the end; the snoop ring-buffer is finite and
  the 15–20 min idle window (D) plus a full workout can be large.
