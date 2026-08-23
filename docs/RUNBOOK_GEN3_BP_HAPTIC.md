# Runbook — Gen 3 vibration motor + blood pressure, for a first-time helper

**Goal:** one recorded session on a **RingConn Gen 3**, from an **iPhone plugged into a Mac**,
that captures the official app talking to the ring while it (a) **buzzes** and (b) runs a
**blood-pressure assessment**. That one recording teaches OpenCircuit to drive the ring's
motor, and collects the raw pulse data our own blood-pressure research needs.

**Status:** written for a helper with **no development experience**. Everything you type is
copy-paste. Nothing here modifies your ring's settings or firmware. Budget **~90 minutes**
the first time, most of it waiting.

**Who this is for:** you have a Gen 3 ring, an iPhone with the official RingConn app, and a
Mac you can plug the iPhone into. If you're missing the Mac, stop here and tell us — there is
no iPhone-only path that produces what we need.

---

## ⚠️ Read this first — what is and isn't winnable (added 2026-08-22)

We checked before asking you to spend an evening on this. The two halves have very
different odds, and you deserve to know that before you start.

| Target | Verdict | Why |
|---|---|---|
| **Vibration motor** | 🟢 **Winnable.** This is the real prize. | The buzz is a command your **phone sends to the ring** over Bluetooth. Your capture records exactly those bytes. Once we can read them, OpenCircuit can send them too. |
| **Blood pressure** | 🟡 **Our own, eventually — not RingConn's.** | RingConn computes their number on their servers, so there's nothing to copy off the wire. But the **raw pulse data it's computed from does travel over Bluetooth**, and that's what we want. Paired with real cuff readings it's the raw material for our own estimate. §7. |

So the BP half of this session is **data collection for our own research**, and it doubles
as the vibration trigger: in the current app the ring buzzes when a BP assessment finishes.
One BP run feeds both targets.

---

## 1. What you need

Tick these off before starting. Missing any one of them wastes the session.

- [ ] **RingConn Gen 3** (not Gen 2 or Gen 2 Air — only Gen 3 has a motor 🟢)
- [ ] **Ring charged above 20%.** Below 20% the ring **refuses to vibrate at all** 🟢 — the
      app's own words are *"Vibration can't start. Battery must be above 20%."* A flat ring
      makes the whole session look like a failure for the wrong reason. **Charge it first.**
- [ ] **iPhone** with the official **RingConn app, version 4.3.0 or newer.** The on-demand
      buzzes were added in 4.3.0 (published 13 Aug 2026) 🟢. Check in the App Store and
      update if needed — on an older version the ring will not buzz on demand.
- [ ] **Mac**, with a **USB cable** to the iPhone
- [ ] **The ring's own Do-Not-Disturb window must not cover the time you're testing.**
      In the RingConn app: **Me ▸ App Settings ▸ Notification Settings ▸ Vibration**. This
      is the *ring's* DND schedule, set inside the app — **not** the iPhone's Focus 🟢.
      Turning off iOS Focus does nothing here, and this is an easy way to spend an
      evening getting no buzz for a reason you never see.
- [ ] A **blood-pressure cuff**, if you have one. Not needed for the vibration half, but if
      you do have one it roughly doubles the value of the session — see §7. An ordinary
      home upper-arm monitor is fine.
- [ ] Somewhere to **write down times** — paper, Notes, anything. §5 explains why this matters
      more than it sounds.
- [ ] Your **free Apple account** (the ordinary one you use on the iPhone). You do **not**
      need the paid $99/yr developer programme 🟡.

---

## 2. Phase 1 — let the iPhone record Bluetooth (~20 min)

iPhones don't log Bluetooth by default. Apple publishes an official profile that turns it on.
This is Apple's own tool, used for bug reports.

**Do these in order. Step 4 is the one everybody gets wrong.**

1. **On the Mac** (not the phone), open Safari and go to:
   `https://developer.apple.com/bug-reporting/profiles-and-logs/`
2. Sign in with your Apple account. Click the **search (magnifying-glass)** button on that
   page and type `bluetooth`. The profile is **only findable through that search box** 🟢 —
   it isn't in the main list. Find the row **"Bluetooth for iOS/iPadOS"** and click
   **Profile**. A file called `iOSBluetoothLogging.mobileconfig` downloads.
3. **Turn off Stolen Device Protection on the iPhone** if it's on
   (Settings ▸ Face ID & Passcode ▸ Stolen Device Protection). Apple blocks profile installs
   while it's active unless you're at a familiar location 🟢. Turn it back on when you're done.
4. **AirDrop the file from the Mac to the iPhone.** Do *not* download it directly on the phone.
   Downloading on-device is the known cause of a capture that appears to work but records
   **zero packets** 🟡.
5. On the iPhone, accept the AirDrop, then open **Settings**. A **"Profile Downloaded"** row
   appears near the top — tap it. **You have 8 minutes**: an un-installed profile is deleted
   automatically after that 🟢. If it vanishes, just AirDrop it again.
6. Tap **Install** (top right), enter your passcode, **Install** again, and once more to
   confirm.
7. **Unplug the USB cable**, then **restart the iPhone**. Rebooting with the cable
   disconnected is part of the fix for empty captures 🟡.

> **How you'll know it worked:** nothing visible changes. You'll confirm it in §4 when the
> capture actually produces packets. If §4 shows zero, come back and redo steps 4–7.

---

## 3. Phase 2 — install the recorder on the Mac (~10 min)

We use `idevicebtlogger`, a small open-source tool. It's far more reliable than Apple's
PacketLogger app, which has been recording nothing on many Macs since 2024 🟢.

Open **Terminal** on the Mac (press `Cmd`+`Space`, type `Terminal`, press Return), then
paste these one at a time:

```sh
# 1. Install Homebrew, if you don't have it. Skip if `brew --version` already works.
#    Follow the prompts; it will ask for your Mac password.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install the tool
brew install libimobiledevice

# 3. Check it exists — this MUST print 1.4.0 or higher
idevicebtlogger --version
```

> ⚠️ **`idevicebtlogger` did not exist before libimobiledevice 1.4.0** 🟢. If step 3 says
> "command not found", run `brew upgrade libimobiledevice` and try again.

Then plug the iPhone into the Mac, **tap Trust** on the phone, enter your passcode, and
**keep the phone unlocked**. Confirm the Mac sees it:

```sh
idevice_id -l
```

**PASS:** it prints a long identifier. **FAIL:** it prints nothing — unplug, replug, tap
Trust again.

### 3.1 Get our tools

You'll need two small scripts from the OpenCircuit project. It's a public repository, so
this just downloads a copy — you don't need an account:

```sh
mkdir -p ~/Documents/Git
cd ~/Documents/Git
git clone https://github.com/perezjuanj/OpenCircuit.git OpenRingConn
```

If `git` isn't installed, macOS will offer to install the developer command-line tools —
accept, wait for it to finish, then run the `git clone` line again.

Check it worked:

```sh
ls ~/Documents/Git/OpenRingConn/desktop/pcap_to_btsnoop.py
```

**PASS:** it prints the path back. **FAIL:** "No such file" — the clone didn't complete;
re-run it and watch for an error.

> Every later `cd ~/Documents/Git/OpenRingConn/desktop` in this runbook refers to what you
> just downloaded. If you put it somewhere else, use your own path instead.

---

## 4. Phase 3 — the capture session (~20 min)

This is the part that matters. Read §5 first, then come back.

**Before you start:** if you have **OpenCircuit** installed, force-quit it. The ring appears
to accept **only one** Bluetooth connection at a time 🟡, so if our app is holding the link
the official app can't talk to the ring and you'll capture nothing. (§10 reminds you to
reopen it afterwards — don't skip that, it costs you your own step data.)

### 4.1 Start recording

In Terminal:

```sh
idevicebtlogger -f pcap ~/Desktop/ringcapture.pcap
```

Leave that window running and untouched. **Note the wall-clock time now.**

> ⚠️ **Keep the iPhone plugged in until §4.3.** If the cable comes out, recording stops —
> but the Terminal window carries on looking perfectly alive, and the half-length file it
> leaves still passes the size check below. That is the one way to lose the session without
> ever seeing an error.

### 4.2 Drive the app — the script

Do these **in this order**, on the iPhone, with the **RingConn app in the foreground the
whole time**. The on-demand buzzes only fire while the app is open 🟢 — if you switch away
mid-measurement, the ring will not vibrate and that step is wasted.

**Write down the time (to the minute) beside each step as you do it.**

| # | Do this | What should happen | Time |
|---|---|---|---|
| 1 | Open the RingConn app, wait for it to say the ring is connected | connected | |
| 2 | Wait **60 seconds** doing nothing | (gives us a quiet baseline) | |
| 3 | **Me ▸ App Settings ▸ Notification Settings ▸ Vibration** — find the vibration page | you see the toggles | |
| 4 | If there's a **test / "tap to feel the vibration"** control, tap it. **Wait 10 s. Tap it again.** | **ring buzzes, twice** | |
| 5 | Start a **manual exercise** (any type) and let the countdown run to the end | **ring buzzes** at "1" | |
| 6 | **End the exercise with the app's own Stop/End control, and confirm it.** Do not just swipe the app away — see the warning below | exercise shows as ended | |
| 7 | Wait **30 seconds** | | |
| 8 | Run a **heart-rate / blood-oxygen spot measurement** | **ring buzzes** when it finishes | |
| 9 | Wait **30 seconds** | | |
| 10 | **Discover ▸ Blood Pressure Trends ▸ Check Again** — run an assessment. **If you have a cuff, take a reading right before or after** (other arm — see §7) and note both numbers | **ring buzzes** when done | |
| 11 | Wait **60 seconds** | | |

Steps 4, 5, 8 and 10 are four independent chances at the same prize. **If some don't buzz,
that's fine — carry on and note which ones didn't.** That's useful information, not a failure.

> ⚠️ **Always end a workout properly (step 6).** A workout that is started and never
> stopped leaves the ring stuck in exercise mode, where it records **no** sleep or
> heart-rate history at all — indefinitely, and while still looking perfectly healthy in
> the app 🟢. This is a real bug we've measured on this hardware. If it happens, start
> another workout and stop it properly to clear the state.

### 4.3 Stop recording

Click the Terminal window and press `Control`+`C`. Your file is at
`~/Desktop/ringcapture.pcap`. Check it:

```sh
ls -lh ~/Desktop/ringcapture.pcap
```

**PASS:** the size ends in `M` (megabytes). **FAIL:** it's a few hundred bytes or `0B` —
the logging profile isn't active. Redo §2 steps 4–7.

---

## 5. Why the times matter more than you'd think

A twenty-minute capture holds **tens of thousands** of Bluetooth packets. Almost all of it is
routine chatter — battery levels, heartbeats, step counts.

The vibrate command is likely **one single packet**, a handful of bytes.

Your timestamps are how we find it. If you write *"buzzed at 21:43"*, we look at 21:43 and
read the command out directly. Without them we're searching blind through a haystack, and a
capture that would have taken ten minutes to decode can become undecodable.

**The single most valuable thing you produce is the list of times the ring buzzed.** If you
only do one thing carefully, do that one.

Don't worry about being exact to the second — to the minute is plenty.

---

## 6. Phase 4 — send it to us (~10 min)

### 6.1 Convert it

Our decoder needs a different container format than the one the recorder writes. This
converter is in the repo and needs **no installation** — it runs on the Python that ships
with macOS:

```sh
cd ~/Documents/Git/OpenRingConn/desktop      # wherever you put the repo
python3 pcap_to_btsnoop.py ~/Desktop/ringcapture.pcap
```

**PASS:** it prints `Wrote … (N packets: X sent, Y received)` with both X and Y non-zero.

**FAIL — "every packet went one direction":** tell us, don't ignore it. It means directions
got mislabelled and everything decoded from it would be backwards.

Optional — you can preview what's inside. This changes nothing on disk, so if it errors,
ignore it and send the files anyway:

```sh
python3 -m opencircuit decode-log ~/Desktop/ringcapture_btsnoop.log | head -50
```

**PASS:** screens of hex scroll past. That wall of gibberish *is* what success looks like.

### 6.2 What's actually in this file — please read

The capture contains **your health data**: heart rate, blood oxygen, sleep and activity
recorded by your ring, plus your ring's Bluetooth hardware address. It is not an anonymous
technical log.

It does **not** contain your RingConn password, your photos, your messages, or anything from
other apps — this records Bluetooth traffic only, not your phone's activity.

- ✅ **Send:** the `.pcap` and/or the converted `_btsnoop.log`, plus your list of times.
- ✅ **Send it privately** — direct message or email, to a person you've chosen to trust.
- ❌ **Do not post it publicly** — not in a GitHub issue, not on a forum, not in a public
  chat. It is genuinely your medical data.
- ❌ **We will never commit it to the repo.** Captures are gitignored precisely because they
  hold real health data; only the *findings* we decode from them are ever published.

If you'd rather not share overnight sleep data, do the session **during the day** on a ring
that synced recently — there's then far less history in the buffer for it to hand over.

### 6.3 Also send

- Your **list of times** from §4.2 (the most important part), and your **time zone** — we
  need it to line your local clock up against the capture's timestamps
- **Which steps buzzed** and which didn't
- Any **cuff / ring blood-pressure pairs** you recorded (§7), with their times
- The **ring's firmware version** and the **app version** — RingConn app ▸ Me ▸ Device
- Anything that behaved oddly

---

## 7. Blood pressure — what we're collecting and why

RingConn computes their BP number on their servers 🟢: the app uploads a raw pulse-data file
and waits for the answer to come back. So there's no number on the wire to copy — but **the
raw pulse data itself is on the wire**, and that's the useful part. It's the same signal any
cuffless BP estimate is built from, and we already have an experimental estimator that runs
on it locally.

What turns that raw signal into a reading is **calibration**: pairs of *(pulse data, real
cuff reading)* taken at the same moment. That's the one thing we can't generate ourselves,
and it's what makes your session valuable beyond the vibration work.

### If you have a cuff — the highest-value thing you can do

Around step 10 in §4.2, take a cuff reading **immediately before or after** the ring's
assessment, and write both down:

| | What to record |
|---|---|
| Time | to the minute |
| Cuff | systolic / diastolic, e.g. `128/82` |
| Ring | what the app showed, e.g. `122/83` |

A few things make these far more useful:

- **Sit still and quiet for ~5 minutes first**, feet flat, arm supported at heart height.
  Same posture every time — posture alone moves the number more than most people expect.
- **Cuff on one arm, ring on the other hand.** A cuff inflating on the same arm squeezes the
  ring's blood flow and corrupts exactly the signal we're measuring.
- **Spread readings out.** Three pairs at rest all day is worth less than pairs taken across
  a range — after coffee, after a walk, morning vs evening. Variation is the whole point;
  a model fitted to one blood pressure predicts one blood pressure.

Even three or four good pairs are genuinely useful. If you're willing to keep logging them
over following days, that's better still — but the capture session alone is a fine start.

### If you don't have a cuff

Do step 10 anyway. The assessment still triggers the buzz and still puts the raw pulse data
on the wire; we just can't calibrate against it. Don't buy a cuff on our account unless you
want one.

**One expectation to set:** this is research, not a feature waiting to be switched on. Any
estimate built this way needs validating before it's worth showing anyone a number.

---

## 8. Phase 5 — confirming the command (later, after we decode)

Once we've read the vibrate command out of your capture, we'll send you a short line to run.
It replays that exact command from the Mac, and **you tell us whether the ring buzzed.** A
buzz you caused yourself, from our own code, is the proof that it's real.

**First, two things that otherwise guarantee a false "no buzz":**

1. **Turn Bluetooth OFF on the iPhone** (or force-quit the RingConn app). The ring takes one
   connection at a time and the phone wins — the Mac simply won't find it.
2. When macOS asks whether **Terminal** may use Bluetooth, say **Allow**. If it's ever been
   denied, the Mac cannot see the ring at all: System Settings ▸ Privacy & Security ▸
   Bluetooth.

```sh
cd ~/Documents/Git/OpenRingConn/desktop
python3 -m venv .venv-probe
.venv-probe/bin/pip install --upgrade pip
.venv-probe/bin/pip install bleak
.venv-probe/bin/python verify_vibrate.py --hex "<the frame we send you>" --dry-run
```

The `--upgrade pip` line is **not optional** — without it the install fails with a wall of
compiler errors. The `--dry-run` on the end checks you've typed the command correctly and
sends **nothing** to the ring. When it says it passed, run it again **without** `--dry-run`.

Replace `<the frame we send you>` with what we send, **including deleting the angle
brackets**. Wear the ring and answer `y` or `n` when it asks.

It writes a file called `vibrate_verify_<date>_<time>.txt` **in that same
`desktop` folder** (not on your Desktop — the tool prints the full path when it finishes).
Send it back either way.

**Safety, plainly:** that tool refuses to send commands from a known-dangerous range, with no
override. One command (`0x21`) **bricked a ring** here in June 2026 and needed a charger
restart, forget-device and re-pair to recover. It also checks the battery is above 20% first,
because otherwise a "no buzz" would tell us nothing.

**Please don't send commands to your ring that we haven't given you**, and don't run the
older `sweep_opcodes.py` — that's what bricked the ring. Guessing at commands risks your
hardware for no gain; the capture gets us there safely.

---

## 9. If something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| Capture file is empty / a few hundred bytes | Logging profile not active | Redo §2 steps 4–7 — AirDrop from the Mac, reboot **unplugged** |
| `idevicebtlogger: command not found` | libimobiledevice older than 1.4.0 | `brew upgrade libimobiledevice` |
| `idevice_id -l` prints nothing | Phone not trusted / locked | Unplug, replug, tap **Trust**, keep it unlocked |
| Ring never buzzes at any step | Battery ≤20%, the **ring's in-app DND period** covers now, app below 4.3.0, or the app wasn't in the foreground | Check all four — battery is the usual one. DND is in the RingConn app, not iOS Focus |
| App says the ring won't connect | OpenCircuit is holding the link | Force-quit OpenCircuit; the ring appears to allow one connection 🟡 |
| §8: "No RingConn found" on the Mac | iPhone still holds the link, or Terminal lacks Bluetooth permission | Turn off iPhone Bluetooth; System Settings ▸ Privacy & Security ▸ Bluetooth ▸ allow Terminal |
| §8: `pip install bleak` fails with clang errors | macOS ships pip 21.2.4, which won't use the prebuilt wheel | Run `.venv-probe/bin/pip install --upgrade pip` first |
| Converter says "every ACL packet went one direction" | Directions were mislabelled | Don't trust the decode — send us the original `.pcap` and tell us |
| Converter says the file is "truncated or corrupt" | Recording was cut short (usually an unplugged cable) | Re-capture; it refuses rather than hand back a silently-shortened file |
| Capture stopped early but Terminal looked fine | USB cable came loose mid-session | Re-capture with the phone plugged in throughout |
| Profile row disappeared from Settings | The 8-minute install window expired | AirDrop it again and install straight away |
| `decode-log` prints a `ValueError` about magic | Fed it the `.pcap` instead of the converted file | Use the `_btsnoop.log` from §6.1 |

---

## 10. When you're finished

1. **Remove the logging profile** — it records Bluetooth continuously while installed:
   **Settings ▸ General ▸ VPN & Device Management ▸ Bluetooth Logging for iOS ▸
   Remove Profile**
2. **Re-enable Stolen Device Protection** if you turned it off in §2 step 3.
3. **Reopen OpenCircuit** if you use it. §4 had you force-quit it — and while it's
   swipe-closed it cannot sync in the background, so your **step count is lost for good**
   rather than catching up later 🟢. This one costs you your own data, not ours.
4. **Check no workout is still running** in the RingConn app (see the §4.2 warning).
5. **Delete the capture** from your Mac and Desktop once we confirm we've received it.

---

## Exit criteria

This session succeeded if we have **all three**:

1. A capture file that decodes to a non-trivial number of Bluetooth events 🟢
2. Your **list of times**, with at least one confirmed buzz 🟢
3. Ring firmware + app version recorded 🟢

Bonus, and the thing that unlocks the BP research: **cuff / ring reading pairs** (§7).

**Two and a half out of three is still worth sending.** A capture where nothing buzzed, with
honest times and a note saying so, genuinely narrows the search — it tells us the trigger
isn't where we thought. Send it either way.

---

## Notes for us (not the helper)

- The vibrate opcode is **not recoverable from the APK** 🟢 (established 2026-08-22, workflow
  `apk-mine-bp-vibrate-opcodes`): frames are built at runtime from integer literals inside
  compiled ARM code, and the Dart snapshot's string cluster has no locality, so no
  constant-scan or adjacency trick reaches it. `VibrationConfigSet` is a **cloud** model, not
  BLE. A capture is the only route. Don't re-run that mining.
- ⚠️ **`BleSub*RspMixin` means sub-DEVICE, not sub-command** 🟢. The full mixin chain
  `_BleBpManager&…&BleSubOmronBPRspMixin&BleSubLexinBPRspMixin&BleSubPolarRspMixin` is a
  *separate manager for third-party peripherals* — Omron/Lexin cuffs and Polar straps, used
  for BP calibration. Any plan that reads `BleSubBPRspMixin` as "BP sub-command under `0x05`"
  is chasing a phantom. The ring's own BP surface is exactly one mixin,
  `BleAutoOfflineBpMixin` — "auto offline BP", i.e. store-and-forward, the same shape as the
  OSA family. That makes `0x1f`/`0x9f` (from `desktop/probe_ppg_raw.py:52`, still 🔴) worth
  *watching for* in the capture, and still not worth blind-probing.
- **BP direction of travel:** we are not chasing RingConn's number — it is cloud-side and
  copying it would need their servers, which `docs/PRIVACY.md` rules out. The target is our
  own estimate from the on-wire PPG, which is why §7 asks the helper for *(cuff, ring)*
  pairs rather than just a capture. That feeds the existing PR #121 estimator
  (`desktop/bp_estimator.py`, `bp_calibration.py`, currently `#if DEBUG`-fenced). ⚠️ The
  calibration artefacts that pipeline references never existed in this repo — they lived on
  the contributor's Mac — so a fresh calibration set is the gating input, not a nice-to-have.
- The 2026-06-26 opcode sweep sent every candidate as `XX 00 00` — **param byte zero**
  (`sweep_opcodes.py:189`). For the LED that is literally the OFF command, which is why 0x24
  read as a bland ack and the LED was found a month later by other means. **"The sweep already
  covered this" is false for any opcode that performs an action.** 0x22/0x23/0x2a/0x2b have
  never been tried with a non-zero param.
- Expected payload shape from the app's own model: a **waveform descriptor**, not a flag —
  `vibrationPattern` + `vibrationParam` + `vibrationDurationList` + `vibrationGroupTimeList`,
  i.e. (duration, gap) groups plus a pattern id. Expect a status byte in the response; the app
  distinguishes "Vibration didn't work" from the battery refusal.
- `desktop/captures/gen3_padawer2/shot4_bp.png` is **misnamed** — it's the Sleep Apnea screen,
  not BP. The real BP evidence is `shot5.png` / `shot6.png`.
- `HealthAlerts.swift:4` still asserts "The ring has NO vibration motor". That is **wrong for
  Gen 3** 🟢 (RingConn's own product page markets vibration alerts), and its cited evidence
  never supported the claim even for Gen 2. Fix it when the vibrate work lands.

See also: [`PROTOCOL.md`](PROTOCOL.md) §4–§5, [`RUNBOOK_SNOOP_SINGLE_SESSION.md`](RUNBOOK_SNOOP_SINGLE_SESSION.md)
(the Android equivalent of this session), [`RUNBOOK_OSA_APNEA.md`](RUNBOOK_OSA_APNEA.md) (the
`05 22` capture this one is modelled on), and memory `snoop-write-opcodes`.
