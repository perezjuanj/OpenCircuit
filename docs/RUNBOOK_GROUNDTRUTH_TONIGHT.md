# Tonight's plan — capture RingConn's hypnogram as sleep ground truth

**Why:** sleep accuracy is blocked on labels, not ideas. We currently have **3 usable bedtime
labels**. One night of RingConn's own hypnogram is **~380 per-epoch labels**. This session is
the difference between guessing and measuring.

Companion to [`RUNBOOK_SLEEP_GROUNDTRUTH.md`](RUNBOOK_SLEEP_GROUNDTRUTH.md) — that one is the
full reference. This one is the ordered checklist for a single evening.

---

## STEP 0 — The two-minute check that decides the whole night

**Do this before installing anything.**

Open the **RingConn app** on your phone. Do **not** sync, do **not** pull-to-refresh. Just
scroll the sleep history back to **June 26** and see how far back it shows real nights.

- **If it shows nights back into June/July** → 🎉 take **Arm A**. We already hold your raw ring
  bytes for 14 of those nights, so you can produce 14 fully-paired labelled nights *tonight*,
  with no waiting and no risk to the ring's history.
- **If history is empty or only a few recent days** → take **Arm B**. One night, captured
  tomorrow morning. Still worth doing; just slower.

> **Why history might be empty:** we've deliberately kept OpenCircuit as the *sole* syncer, so
> the official app may never have received those nights. That's the whole question Step 0 answers.

---

## ARM A — harvest history (best case, ~40 min, all tonight)

### ⚠️ The one rule for Arm A
**Do NOT sync the ring in the RingConn app.** You don't need to — these nights are already in
RingConn's cloud. Syncing would drain ring history and move the ring's single resume pointer,
which is how we've previously shredded our own nights. Reading history costs nothing; syncing
costs a night.

### A1. Proxy setup (~20 min, laptop + phone on the same Wi-Fi)
```bash
brew install mitmproxy
ipconfig getifaddr en0        # note this IP
mitmweb --listen-port 8080    # UI opens at http://127.0.0.1:8081
```
Phone → **Wi-Fi → your network → ⚙ → Proxy → Manual** → hostname = the IP above, port = `8080`.

Then phone browser → **http://mitm.it** → download + install the **Android** cert via
**Settings → Security → Encryption & credentials → Install a certificate → CA certificate**.

### A2. Confirm interception works *before* touching the RingConn app
Browse to any `https://` site on the phone. It should appear in mitmweb.
- Nothing appears → the proxy isn't wired up. Fix that first.
- Browser works but **RingConn** later shows network errors or no flows → that's the Android 7+
  user-CA limit and/or certificate pinning. **Stop there and tell me** — don't burn the evening
  on Frida. There's a documented fallback and it's a separate session.

### A3. Capture the nights
Open the RingConn app and tap into the **Sleep detail** for each target night. *Opening that
screen* is what triggers the fetch — one tap per night.

In mitmweb, filter for `ringconn` and look for a request whose path contains `sleep`. Click it →
**Response** → confirm the body contains `sleepPhases`. Save each response body as:

```
desktop/captures/groundtruth_sleep_<YYYYMMDD>.json
```

`<YYYYMMDD>` = the **wake-up date** (the morning you got up), matching the list below.

**Priority list — the 14 nights we already hold your raw ring bytes for.** These pair
immediately; anything else is a bonus.

| wake date | that night you were in bed |
|---|---|
| 2026-06-26 | 22:49 → 09:01 |
| 2026-06-27 | 22:20 → 09:52 |
| 2026-06-28 | 23:30 → 09:58 |
| 2026-06-29 | 23:31 → 09:10 |
| 2026-06-30 | 23:23 → 09:05 |
| 2026-07-03 | 00:09 → 09:26 |
| 2026-07-04 | 01:04 → 06:48 |
| 2026-08-04 | 07:30 → 08:55 (short/odd — capture anyway) |
| 2026-08-05 | 22:26 → 08:59 |
| 2026-08-09 | 22:36 → 10:05 |
| 2026-08-12 | 22:51 → 08:57 |
| 2026-08-13 | 22:36 → 08:33 |
| 2026-08-15 | 22:43 → 08:01 |
| **2026-08-19** | **20:24 → 09:03** ← **most valuable single night** |

**Why 08-19 matters most:** that's the night the app stored a 20:24 bedtime and you corrected it
to 22:24. It is our clearest example of the exact defect that's still open, and today's code gets
it right by 5 minutes — so RingConn's hypnogram for it tells us whether we're right for the right
reason or by luck.

Grab whatever else the app will show you. More nights is strictly better; unpairable ones cost
nothing but a tap.

### A4. Clean up
Phone → Wi-Fi → Proxy → **None**, and remove the cert under **User credentials**.

---

## ARM B — one night (fallback, ~20 min tonight + 10 min tomorrow)

**Tonight:** do **A1** and **A2** only (proxy + cert + confirm interception). Then wear the ring
to bed as normal.

**Tomorrow morning, in exactly this order — the order is the whole point:**
1. Open **OpenCircuit** first. Let the night finish syncing.
2. **Settings ▸ Data ▸ Export (JSON)**, save it. This carries the night's raw records, and the
   archive only holds ~30 h — so it has to be the same morning.
3. *Now* start `mitmweb`, put the proxy back on the phone.
4. *Now* open the RingConn app, pull-to-refresh, open the Sleep detail, capture as in **A3**.

If step 4 shows an **empty** night, that is itself a real finding — it answers an open protocol
question about whether the official app's sync destroys our access. Tell me either way.

---

## What I do with it

Hand me the `groundtruth_sleep_*.json` files (and the export, if Arm B). From there:

1. Pair each hypnogram against our decoded per-epoch records for the same night.
2. Score today's staging per-epoch instead of per-night — first real confusion matrix we'll have
   had: where we call light vs deep, and specifically how much of our "asleep" is their "awake in
   bed". That single number is the still-but-awake defect, measured.
3. Fit `SleepStaging.Tuning` against the labels **through the Swift replay harness** — not the
   Python port in `ringconn_sleep_fit.py`, which has drifted ~2,300 lines from what we ship and
   would tune a model we don't run.

Captures stay in `desktop/captures/` (gitignored — real health data). Only findings get committed.

---

## Honest expectations

- This gives us **RingConn's** answer, not truth. It inherits their errors. What it buys is
  *density and volume* — enough labelled epochs that a change can be measured instead of argued.
- It does **not** recover nights lost to a ring-side data hole. No label recovers bytes we never
  received.
- Arm A is the jackpot but Step 0 may kill it, and that's fine — Arm B still moves us from 3
  labels to ~380.
