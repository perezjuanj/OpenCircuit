# Runbook — overnight capture for skin temperature (and sleep stages / HRV)

Goal: capture the data we **can't get yet** — skin temperature, plus ground-truth
sleep stages and HRV — by recording the official app's **first morning sync** over
Android HCI snoop. See [`PROTOCOL.md`](PROTOCOL.md) §5 / issues #7, #9, #12.

## Why it has to be done this way
- **Skin temp is measured only overnight** and is **absent from the sleep/PPG frames
  we've already decoded** (`0x4c`/`0x47`) and from the cached Temperature screen. The
  official app must issue a temp-specific fetch command we haven't observed yet — so we
  capture *the official app doing the morning sync*, not our own app.
- **The ring only holds UN-synced data.** Once an app drains the night, it's gone from
  the ring. So we must stop the app from trickle-syncing overnight, then capture the one
  big first-sync in the morning.
- Decoding needs **ground truth**: the app's own numbers for that night, matched against
  the raw bytes in the log.

Device facts (from memory `ring-device-access.md`):
- Ring BLE MAC: `F8:79:99:F7:03:AD`
- Official app package: `com.gdjztech.ringconn`
- Android phone: Samsung SM-G781U1 (`RFCR81AZS4W`), HCI snoop already enabled (full).

## Bond trade-off (read first)
Logging into the official app on **Android steals the BLE bond from the iPhone**, so our
iOS app stops working until you re-pair (open the official iOS app once). If you'd rather
not disturb the iPhone, use the **PacketLogger-on-iPhone** alternative at the bottom.

---

## Tonight (before bed)
1. Confirm snoop logging is on:
   ```
   adb shell dumpsys bluetooth_manager | grep -i snoop
   ```
   (expect enabled / full)
2. Stop the app so it can't trickle-sync overnight — this keeps the whole night on the
   ring for one clean morning sync:
   ```
   adb shell am force-stop com.gdjztech.ringconn
   ```
3. Wear the ring **snug, normal finger, OFF the charger** (it doesn't measure on the
   charger). Sleep. The ring records temp onboard regardless of any app connection.

## In the morning (first thing — don't open the app until ready)
1. Open the official app; let it finish its one big first-sync of the whole night.
2. Immediately grab the log:
   ```
   adb bugreport ~/Documents/Git/OpenRingConn/desktop/captures/overnight_temp.zip
   ```
3. Write down the app's numbers for that night (these are the ground truth):
   - **Skin temperature** — the °F value **and** the deviation (e.g. `96.58°F, -0.16`).
     *Most important.*
   - Sleep: total sleep, time in bed, **deep / REM / light / awake** durations, and
     sleep / wake times.
   - Avg **HR**, **HRV** (ms), **SpO₂** (avg + lowest + when), **respiratory rate**.
   - The date of the night.

## Hand back to Claude
Provide the zip path + the ground-truth numbers. Claude will:
1. Extract `FS/data/log/bt/btsnoop_hci.log` from the zip.
2. Decode + filter to the ring:
   ```
   python -m openringconn decode-log captures/btsnoop_hci.log --addr F8:79:99:F7:03:AD
   ```
3. Search for the temp value. Working hypothesis: encoded as **0.1 °C** (so 96.58 °F =
   35.88 °C → look for `0x0166`/`0x0167`), but Claude matches against whatever number you
   give. Also look for a **new command** the app sends that we haven't catalogued, and the
   `0x06` sub-mode / dedicated fetch that precedes the temp frame.
4. Same capture aligns sleep-stage and HRV bytes against ground truth (#7, #9).

## Fallback (only if temp is missing from the log)
If decode shows the app's sync cursor had already advanced past the temp record, the next
morning escalate to a full from-scratch re-pull (wipes the cursor — same trick that
cracked steps). Note: this logs you out and re-pairs.
```
adb shell pm clear com.gdjztech.ringconn
```
Then reopen, log in, let it re-sync everything, and capture as above. Tonight's
force-stop step exists specifically to avoid needing this.

## Alternative — capture from iPhone (preserves the bond)
If you don't want to move the bond to Android: capture the **official iOS app** with
Apple's **PacketLogger** (Additional Tools for Xcode) using a Bluetooth logging
configuration profile on the iPhone, then export the `.pklg` and hand it over. More
setup than Android btsnoop, but it doesn't steal the bond. Ask Claude for the
step-by-step if you go this route.
