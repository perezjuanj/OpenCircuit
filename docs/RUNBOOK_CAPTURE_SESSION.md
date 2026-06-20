# Runbook — one Android-snoop session that captures everything still blocked

Goal: a SINGLE Android HCI-snoop session (workout day) that yields the frames needed to close
the remaining capture-blocked tickets at once. An HCI snoop records ALL BLE traffic, so we just
script a sequence of actions with the **official RingConn app** driving the ring while the snoop
runs, and write down the ground-truth the app shows.

Closes / advances in one session: **#90** (ring sport-mode cmds + live HR stream), **#93** (daytime
activity-history: steps/distance/intensity), **#8/#38** (0x47 realtime PPG), **#87** (skin-temp /
waking-RR fetch), **#88** (config-write opcodes), **#61** (charging/worn state byte), **#89**
(charging-case battery). Separate sessions: **#91** OSA (overnight, see end). Skip: **#92** OTA (non-goal).

> Two rules: OpenRingConn must be **disconnected/closed** the whole time (one BLE link at a time — we
> want the OFFICIAL app's traffic). Never commit raw captures — `desktop/captures/` is gitignored
> (real health data); we commit decoded findings only.

---

## 0. Setup (once, ~2 min)

1. Android → Settings → **Developer options → Enable Bluetooth HCI snoop log** (set to **Full** if offered). Toggle Bluetooth off/on so it takes effect.
2. Close/force-stop **OpenRingConn**; make sure only the **official RingConn app** (`com.gdjztech.ringconn`) will talk to the ring.
3. Note up front: **ring firmware version** (app → device info), **battery %**, **wall-clock time**, today's date. (FW matters: OSA needs ≥ FR02.005.007.)
4. Wear the ring.

The snoop is a ring buffer — it can overflow on a long session. So we grab an `adb bugreport` after EACH high-value phase (each bugreport snapshots the current btsnoop). Name them as you go.

```
adb bugreport bugreport_<phase>.zip      # contains FS/.../btsnoop_hci.log
# or, if your build exposes it directly:
adb pull /data/misc/bluetooth/logs/btsnoop_hci.log btsnoop_<phase>.log
```

---

## 1. P0 — first-of-day TEMP fetch (#87)   ~3 min, do this FIRST

Temp/RR are NOT in the passive drain; the app fetches them with a separate command, likely first-of-day.

1. Snoop is on, OpenRingConn closed. Open the official app **fresh** (force-stop then open).
2. Open the **Temperature / Trends** screen; let it sync.
3. **Ground truth:** screenshot the temp value(s) + any waking respiratory-rate it shows, with timestamps.
4. `adb bugreport bugreport_temp.zip`

What I'll look for: a sync-open with a NEW `byte[6]` flag (`01`/`02`/`04`) or a new opcode that returns the temp/RR record.

---

## 2. P0 — ring-side WORKOUT (#90, #8, #38)   ~20 min

If the official app has an **Exercise / Workout** feature that runs on the ring (not just phone GPS), use it — that's #90.

1. In the official app, **start a workout** (sport mode). Note the exact **start time**.
2. Do **varied intensity**: ~5 min easy → ~5 min brisk/hard → ~5 min easy. (The intensity field steps through its 4 bands; a clear HR ramp cross-checks the HR byte.)
3. **Pause** once for ~30 s, then **resume** (captures the pause/resume opcodes).
4. Mid-workout, if the app has a **live HR / measure** view, open it for ~1 min, and briefly **slip the ring off the finger and back on** (finger-on/off marks the PPG channel for #8/#38).
5. **Stop** the workout. Note the **stop time**.
6. **Ground truth:** screenshot the workout summary — avg/max HR, the **per-segment HR graph**, duration, and (if shown) distance/steps/intensity.
7. `adb bugreport bugreport_workout.zip` **immediately** (before the buffer rolls).

Captures: `SportStart`/pause/resume/stop command bytes, the live `SportHrModel{utc,hr,conf}` stream, and 0x47 PPG over a window with a known HR + finger-on/off edge.

---

## 3. P0 — ACTIVITY-HISTORY sync + the ONLINE/OFFLINE test (#93)   ~5 min

This resolves the open question: are daytime **steps / distance / activity-intensity** pulled from the
ring, or computed in the cloud? (Our mining showed `byte[6]` is only ever `00`/`03` → leans cloud.)

1. Put the phone in **Airplane mode**, then turn **Bluetooth back ON** (BT on, Wi-Fi/cell OFF — the ring sync works, the cloud doesn't).
2. Force-stop + reopen the official app; let it **sync the ring** (still offline).
3. **Observe + screenshot:** do today's **steps, distance, the 2.5-min activity-intensity bars, and the workout** populate while OFFLINE?
   - **Populate offline → it's on the wire** — we capture the `历史活动响应` record and decode it.
   - **Stay blank until you go back online → it's cloud-computed** — we compute it locally from `acti_counts` (already decoded) + steps, no further capture needed.
4. `adb bugreport bugreport_activitysync.zip`
5. Re-enable Wi-Fi/cell.

---

## 4. P1 — CONFIG writes (#88)   ~3 min  (read-only-default caveat: capture only, we gate writes behind opt-in later)

In the official app's settings, toggle each (snoop running) — every toggle is a write opcode on `0x0802`:

1. **24-hour time format** on→off→on.
2. **Find my ring / LED blink** (the ring's light should flash).
3. **Airplane mode** for the ring (if present) on→off.
4. One **reminder / threshold** (e.g. high-HR alert, move reminder) — set a value.
5. `adb bugreport bugreport_config.zip`

---

## 5. P1 — CHARGING / WORN state + CASE battery (#61, #89)   ~12 min, do LAST (ring comes off)

A/B across known transitions, official app open for ground truth. Note the app's charging/wear UI + battery % at each step.

1. Ring **worn, idle** on finger — ~2 min.
2. **Take it off, put it on the charger / in the case** — ~5 min (battery should tick up). This is also where the **AMb charging-case notification (#89)** should fire — keep it in the case.
3. **Off the charger, on a table** (off-wrist, not charging) — ~2 min.
4. **Back on the finger** — ~2 min.
5. `adb bugreport bugreport_charger.zip`

What I'll map: the `0x10/0x87 [2]` state enum (idle/measuring/charging/worn) and the AMb fields
(`power/volt/state/chargingCasePower/chargingCaseCharging`).

---

## 6. Teardown / handoff

1. Drop each `bugreport_*.zip` (or extracted `btsnoop_hci.log`) into `desktop/captures/` with the phase in the name (e.g. `workout_20260618_btsnoop.log`).
2. Paste me your **ground-truth notes** (the screenshots / values + timestamps from each phase).
3. I'll `decode-log` each, align against ground truth, and decode the records — same byte-by-byte method that cracked `[4]`=HR.

I decode with: `python -m openringconn decode-log captures/<file> --addr <ring-mac>` → `desktop/decode_bulk.py`.

---

## Separate sessions (not tomorrow)

- **#91 OSA sleep-apnea** — overnight, high-freq (5 Hz) PPG mode. Needs FW ≥ **FR02.005.007** and battery ≥ 30%. Enable the app's OSA/sleep-apnea monitoring at bedtime with snoop on, and capture an app OSA report night for ground truth. Heavy RE; schedule after the above.
- **#92 OTA** — documented non-goal; do not capture.

---

## Sleep-staging validation night (for the HR-aware onset/offset model)

Goal: a normal overnight snoop + **ground truth** to calibrate `SleepStaging` (the HR-aware
onset/offset + wake model, and the still-rough Deep/REM split). One ordinary night, no special ring
mode.

1. **Bedtime:** snoop ON, wear the ring as usual; let the official RingConn app sync in the morning
   (OpenCircuit closed overnight — one BLE link at a time).
2. **Write down the truth** (this is what makes the night usable):
   - **Lights-out** time, your best estimate of **actual sleep onset**, every **awakening** you
     remember (≈ time + how long), and **final wake** + **out-of-bed** time.
   - The morning **RingConn app** totals: asleep, awake, deep, light, REM, efficiency, bedtime→wake.
   - The **Zepp** (or other reference) sleep totals for the same night.
3. **Capture:** `adb bugreport bugreport_sleep_<date>.zip` after the morning sync → `desktop/captures/`.
4. **Decode to a full timeline:** `python3 desktop/extract_last_night.py captures/<file>_decoded.txt`
   → `captures/last_night_extracted.csv`. This CSV now carries motion **and** all-day HR on `activity`
   epochs too (not just `sleepVitals`), so the awake/active epochs needed for onset/offset validation
   are present — it feeds straight through `SleepStaging.classify`.

What I'll calibrate from it: the **wake margin** (`wakeHRMarginBPM`, default 18 bpm over the night's
floor — deliberately conservative to avoid eating REM; your real bed/wake times set it), and the
**Deep/REM split** (the percentile design currently pins REM ≈ top quartile and taxes Deep with a
3-epoch consolidation, so Deep reads low / REM high vs the app — needs the app+Zepp totals to fix
without overfitting).
