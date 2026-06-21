# Runbook — capture RingConn's computed hypnogram (sleep ground truth)

Goal: capture the **per-epoch sleep stages RingConn computes on-device** so we can FIT
our staging to reproduce them. RingConn runs its hypnogram algorithm on the ring, syncs
the result to its cloud, and the app fetches it back as a `sleepPhases` JSON array. We
intercept that fetch. Once captured, hand the JSON + our decoded per-epoch CSV to
[`desktop/ringconn_sleep_fit.py`](../desktop/ringconn_sleep_fit.py) (see the bottom of
this doc).

> Why this and not PSG/HCI? The ring sends **no hypnogram on the BLE wire** (PROTOCOL.md
> §5.3) — only the raw per-epoch vitals we already decode. The stage labels exist only
> *after* RingConn's on-device classifier runs, and the only place we can read those
> labels is the app↔cloud traffic. Their thresholds are unreadable from the stripped
> `libxgVipSecurity.so`, so SUPERVISED FITTING against these captured labels is the path.

## What we're capturing

A response body from `api.ringconn.com` containing:

```jsonc
{
  // (envelope keys vary; the fitter searches recursively for "sleepPhases")
  "sleepPhases": [
    { "start": 1718841960, "end": 1718842860, "sleepType": "SLEEP_AWAKE_IN_BED" },
    { "start": 1718842860, "end": 1718844060, "sleepType": "SLEEP_LIGHT" },
    { "start": 1718844060, "end": 1718845500, "sleepType": "SLEEP_DEEP" },
    { "start": 1718845500, "end": 1718846700, "sleepType": "SLEEP_REM" }
    // …
  ]
}
```

- `start` / `end` are **unix seconds** (the fitter also accepts milliseconds).
- `sleepType` ∈ `SLEEP_AWAKE`, `SLEEP_AWAKE_IN_BED`, `SLEEP_LIGHT`, `SLEEP_DEEP`,
  `SLEEP_REM`. The fitter maps `SLEEP_DEEP→deep`, `SLEEP_LIGHT→light`, `SLEEP_REM→rem`,
  `SLEEP_AWAKE`/`SLEEP_AWAKE_IN_BED→awake`.

Device facts (memory `ring-device-access.md`): ring BLE MAC `F8:79:99:F7:03:AD`; official
Android app package `com.gdjztech.ringconn`; phone Samsung SM-G781U1.

---

## PRIMARY method — mitmproxy on the phone's traffic

You need the laptop and the phone on the **same Wi-Fi**. The laptop runs mitmproxy; the
phone is pointed at it as an HTTP(S) proxy.

### 1. Install mitmproxy (laptop)
```
brew install mitmproxy          # macOS; or: pipx install mitmproxy
```
Confirm: `mitmproxy --version`.

### 2. Start mitmproxy and note the laptop IP
```
ipconfig getifaddr en0          # laptop's LAN IP, e.g. 192.168.1.50
mitmweb --listen-port 8080      # web UI at http://127.0.0.1:8081, proxy on :8080
```
(Use `mitmproxy` for the TUI if you prefer; `mitmweb` is easier for finding one flow.)

### 3. Point the phone at the proxy
Android → **Settings → Wi-Fi → (your network) → ⚙ → Proxy → Manual**:
- Proxy hostname: the laptop IP from step 2 (e.g. `192.168.1.50`)
- Proxy port: `8080`
Save.

### 4. Install + trust the mitm CA cert (phone)
With the proxy set, open a browser on the phone to **http://mitm.it** and tap the Android
cert to download it. Then install it:
- Android → **Settings → Security → Encryption & credentials → Install a certificate →
  CA certificate** → pick the downloaded `mitmproxy-ca-cert.cer`. Confirm the warning.

> ⚠️ **Android 7+ user-CA caveat.** From Android 7, apps trust **system** CAs only, not
> user-installed ones, *unless the app opts in via `network_security_config`*. Many apps
> don't — so a user-installed mitm cert is enough to read the phone's **browser** traffic
> (use mitm.it to confirm TLS is intercepted there) but the **RingConn app may still
> refuse** it. If the app's `/sleep` flow never appears in mitmproxy (or the app shows
> network errors), you're hitting this and/or pinning — go to the **Pinning caveat**
> section. (A rooted phone or emulator can install the cert into the *system* store,
> which clears the user-CA limitation but not pinning.)
>
> **System-store install (rooted device / emulator)** — clears the Android 7+ user-CA limit
> without Frida (pinning, if present, still needs the Frida step below):
> ```
> # mitmproxy stores its CA at ~/.mitmproxy/mitmproxy-ca-cert.pem
> HASH=$(openssl x509 -inform PEM -subject_hash_old -in ~/.mitmproxy/mitmproxy-ca-cert.pem -noout | head -1)
> cp ~/.mitmproxy/mitmproxy-ca-cert.pem "$HASH.0"
> adb root && adb remount                       # emulator: `adb root`; some need `-writable-system`
> adb push "$HASH.0" /system/etc/security/cacerts/
> adb shell chmod 644 /system/etc/security/cacerts/$HASH.0
> adb reboot
> ```

### 5. Trigger the fetch and capture
1. Open the **RingConn app** and **sync the ring** (pull-to-refresh on Home; let it
   finish — this uploads the night's on-device hypnogram to the cloud).
2. Open the **Sleep detail** for the target night. Opening that screen is what makes the
   app GET the night's `sleepPhases` from `api.ringconn.com`.
3. In mitmweb, **filter the flow list** for `ringconn` (search box) and look for a request
   whose path contains `sleep` (e.g. `/v1/.../sleep`, `sleepReport`, `sleepDetail`). Click
   it → **Response** tab → confirm the body has `sleepPhases`.
4. **Save the response body** to our captures dir, named by the night's date:
   - In mitmweb: right-click the flow → *Export → Response body* (or copy the body), save to
     ```
     desktop/captures/groundtruth_sleep_<YYYYMMDD>.json
     ```
     where `<YYYYMMDD>` is the **wake-up date** (the morning you got up).
   - CLI alternative (mitmdump to a file, then extract):
     ```
     mitmdump -w desktop/captures/ringconn_<YYYYMMDD>.flows \
       '~d api.ringconn.com ~u sleep'
     # then in mitmweb/mitmproxy load the .flows and export the one /sleep response body.
     ```

`desktop/captures/` is **gitignored** (it holds real health data) — keep the JSON there;
commit only decoded findings, never the raw capture.

### 6. Turn the proxy back off
Android → Wi-Fi → network → Proxy → **None**. (And remove the mitm cert when done:
Settings → Security → Encryption & credentials → User credentials.)

---

## PINNING CAVEAT — when mitmproxy is blocked

RingConn ships **`libxgVipSecurity.so`** (Tencent/"xg" security SDK). It can do **TLS
certificate pinning**, which defeats a man-in-the-middle even with a trusted CA.

**Symptoms you're pinned (or hitting the Android 7+ user-CA limit):**
- Browser traffic *is* intercepted at mitm.it, but **no RingConn flows** appear, or only
  non-API ones (CDN images), never the `/sleep` JSON.
- The app shows "**network error**", "can't sync", spinner that never resolves, or login
  failures **only while the proxy is on**; everything works the moment you disable it.
- mitmproxy logs **TLS handshake failures** / `client closed connection` for
  `api.ringconn.com`.

**Fallback — Frida pinning bypass.** This needs either a **rooted phone / Android
emulator** (to run the `frida-server`) **or** a **frida-gadget-repackaged APK** (inject
the gadget into `com.gdjztech.ringconn`, re-sign, sideload — works on a non-rooted phone).

Concise steps (objection wraps Frida and has a one-shot pinning bypass):
```
pip install frida-tools objection

# Rooted/emulator path: push + run frida-server on the device, then:
objection -g com.gdjztech.ringconn explore
#   then at the objection prompt:
android sslpinning disable

# Non-root path: patch the APK with the gadget, then sideload it:
objection patchapk -s com.gdjztech.ringconn.apk
adb install objection-patched.apk
#   launch the app; it pauses for Frida, then run `android sslpinning disable`.
```
With pinning disabled, repeat **PRIMARY step 5** — the `/sleep` flow should now appear in
mitmproxy. (We already have a decompiled APK at `/private/tmp/ringconn_apk/old321_out`
per memory `apk-decompile-sqlite-schemas.md` if you need the exact API path/host strings
to build the mitmproxy URL filter.)

> Keep this minimal: try PRIMARY first. Only reach for Frida if the symptoms above
> confirm the app is rejecting the proxy.

---

## Aligning timestamps (so the fit lines up)

- **RingConn `sleepPhases`**: `start`/`end` in **unix seconds** (wall clock, UTC-based
  epoch). Same clock our data uses.
- **Our decoded epochs**: produced by
  [`desktop/extract_last_night.py`](../desktop/extract_last_night.py) into a CSV with
  columns `utc_iso,local,counter,layout,hr_bpm,hrv_ms,spo2_pct,rr_brpm,motion`. Each
  epoch's unix time is `counter + 1577793600` (`SYNC_EPOCH`), i.e. the **same wall clock**
  in seconds — so no offset conversion is needed; the fitter expands `sleepPhases` onto
  our `counter` grid by direct time-containment (`start ≤ epoch_time < end`).
- **One epoch = 150 s** on both sides. The fitter's grid is our epochs; RingConn segments
  (which can start/end mid-epoch) are assigned to the epoch whose time falls inside them.
- **Same night, both sources.** Capture the ground-truth JSON for the *same* night you
  decode the CSV from. To get the CSV, run a decode of that night's `0x4c` history capture
  (see [`RUNBOOK_OVERNIGHT_TEMP.md`](RUNBOOK_OVERNIGHT_TEMP.md) /
  [`RUNBOOK_CAPTURE_SESSION.md`](RUNBOOK_CAPTURE_SESSION.md) for the BLE capture, then
  `python3 desktop/extract_last_night.py <decoded.txt>` → `captures/last_night_extracted.csv`).

---

## Hand off to the fitter

```
python3 desktop/ringconn_sleep_fit.py \
  --features    desktop/captures/last_night_extracted.csv \
  --groundtruth desktop/captures/groundtruth_sleep_<YYYYMMDD>.json
```
Multiple nights (pair them positionally) lets it also test the baseline-relative variant:
```
python3 desktop/ringconn_sleep_fit.py \
  --features    captures/night1.csv,captures/night2.csv \
  --groundtruth captures/gt1.json,captures/gt2.json
```
It prints a per-stage confusion matrix + F1, night-total minute agreement, and a
ready-to-paste `SleepStaging.Tuning(...)`. No real data yet? Prove the pipeline first:
```
python3 desktop/ringconn_sleep_fit.py --synthetic
```
