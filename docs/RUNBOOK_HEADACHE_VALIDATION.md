# Runbook — on-device validation for headache signals (#183)

Goal: prove on REAL hardware the three things the test suite cannot prove, before this reaches
testers. Phases 1–2 are committed (`7deb02f`, `00ca5d0`) with 918 Kit tests and 47 app tests green —
but **every one of those runs against synthetic fixtures**. The freeze invariant, the schema
migration and the HealthKit round-trip have never touched a real store.

## Why these three, and not a general smoke test

- **The freeze is the feature.** A day's index is written once and never recomputed, so that every
  later precision number is computed on scores that could not have seen the label. If a real device
  writes two rows for one night, or silently rewrites one, every future claim this feature makes is
  retro-fitted — and it fails *silently*, with correct-looking data. Nothing in the UI would show it.
- **The migration can destroy data.** Opening the store adds `StoredHeadacheEntry` /
  `StoredHeadacheRisk` on top of a shipped SchemaV3 install. A container-open failure lands in the
  recovery path that WIPES 30 days of un-resyncable raw history (#40, #131).
- **HealthKit is the one part with no unit-test coverage at all** — `HKHealthStore` cannot run in a
  test host, and the suite deliberately only tests the pure sample-builder seam.

> ⚠️ Do NOT reuse an existing dev install of this branch. An intermediate build wrote a `SchemaV4`
> whose shape has since changed in place (V4 is unreleased, so it is edited rather than superseded —
> see `App.swift`). Delete such a build first. Test A below deliberately starts from a **shipped**
> build instead.

## Prerequisites

- iPhone with Developer Mode ON, unlocked, USB-attached.
- The ring paired and worn for at least one night during the test window.
- `xcrun devicectl` (see `HANDOFF_MACOS_IOS.md`) and the deploy path in the
  `opencircuit-deploy-to-device` skill.

---

## Test A — migration over a shipped install (do this FIRST, once)

The only chance to catch a wipe is on a store that predates the feature.

1. Install the last **shipped** build (TestFlight 1.0(33) or `v1.0-b33`) and let it sync at least
   once, so the store holds real sleep summaries and raw samples.
2. Note what is there — Trends should show recent nights.
3. Install this branch's build OVER it (do **not** delete the app).
4. **PASS:** the app launches, previous nights are still in Trends, and
   `UserDefaults` `localHistoryWasReset` is NOT set (no "your local cache was rebuilt" notice).
5. **FAIL:** a black screen, a launch crash, or the reset notice ⇒ the migration is not lightweight.
   Capture the launch log (`idevicesyslog -u <UDID> -p OpenCircuit`) before doing anything else; the
   raw sample history is already gone by the time the notice appears.

---

## Test B — the freeze (the important one)

Runs over ≥3 consecutive nights. Enable the feature first: Settings → **Headache signals** → on.

Pull the store after each morning:

```bash
xcrun devicectl device info apps --device <DEVICE> | grep -i opencircuit   # confirm bundle id
xcrun devicectl device copy from --device <DEVICE> \
  --domain-type appDataContainer \
  --domain-identifier com.standardsoftwaresolutions.opencircuit \
  --source Library/Application\ Support/default.store --destination ./default.store
```

```sql
-- Core Data stores seconds since 2001-01-01, so add 978307200 for a Unix timestamp.
SELECT datetime(ZDAY + 978307200, 'unixepoch')       AS day,
       datetime(ZNIGHTKEY + 978307200, 'unixepoch')  AS night_key,
       ZINDEX, ZBANDRAW, ZRINGFEATURECOUNT, ZCOVERAGEFRACTION,
       ZSLEEPRESTAGED, ZPOSTUNLOCK,
       datetime(ZCOMPUTEDAT + 978307200, 'unixepoch') AS computed_at
FROM ZSTOREDHEADACHERISK ORDER BY ZDAY;
```

**PASS conditions:**
- **Exactly one row per night.** Two rows for one night is the failure this whole design exists to
  prevent. Check `night_key` as well as `day` — they should be 1:1.
- **`ZINDEX` and `ZCOMPUTEDAT` for a given day are IDENTICAL across every pull.** Re-pull the same
  day after later syncs; any drift means the row is being recomputed.
- `ZRINGFEATURECOUNT` ≥ 4 on nights you wore the ring (below that the day should not have a row at
  all — it returns `.insufficientData` instead of scoring).

**Also check the negative case:** a night you did NOT wear the ring should produce **no row**, not a
row with index 0. A fabricated 0 would enter the percentile budget and quietly bias every later band.

### B2 — the re-stage path

Nights re-stage 1–22 h after wake. On a day where that happens (compare `StoredSleepSummary`'s
`ZUPDATEDAT` against the risk row's `ZSLEEPUPDATEDAT`):

- **PASS:** `ZSLEEPRESTAGED` flips to 1 and `ZINDEX` is **unchanged**.
- **FAIL:** `ZINDEX` moved ⇒ the freeze is broken.

### B3 — timezone (only if you travel)

Change the device timezone by ≥3 h and let a wake pass run. **PASS:** still exactly one row for the
affected night — `nightKey` is what prevents a second freeze under a re-keyed `day`.

---

## Test C — Apple Health round-trip

1. First launch after upgrade: a Health permission sheet should appear asking for **Headache**
   (existing users are re-prompted only for the new type — that is `reconcileNewlyAuthorizableShareTypes`
   working, not a bug).
2. Log a headache in-app → open Apple Health → Browse → **Symptoms → Headache**. The entry is there
   with the right time and severity, sourced to OpenCircuit.
3. Edit its severity in-app → Health shows ONE entry with the new value (not two).
4. Delete it in-app → it disappears from Health.
5. Log a headache **in Apple Health directly**, then run the in-app import → it appears in the log
   exactly once. Run the import a second time → still exactly once (idempotent).
6. Delete an imported entry in-app, then import again → it must **NOT** come back. (The consumed-UUID
   tombstone outlives the row precisely so a deliberate deletion stays deleted.)

**Deny case:** decline the Headache permission → the app must keep working, the log must still store
locally, and the partial-grant banner should name **"Headache"**, never
`HKCategoryTypeIdentifierHeadache`.

---

## Test D — the Diagnostics export is actually usable

After ≥3 scored days: Device Info ▸ **Diagnostics** → export → open the text file.

Under `# Headache signals`:
- **PASS:** the per-feature presence table shows non-zero counts (e.g. `restingHRDeviation present 3/3`).
- **FAIL:** everything reads `present 0/N`, or a `WARNING: … contributionsJSON` line appears.

This table is not a nicety — per `HEADACHE_SIGNALS.md` §12 it is the artefact that retires `onsetZ`,
`zClamp`, `minRingFeaturesForScore`, `settleMarginMinutes` and the two banding percentiles from
🔴 PROVISIONAL. If it is broken, calibration is closed and every constant stays a guess.

**Privacy check while you are in the file:** confirm it contains COUNTS ONLY for the headache log —
no notes, no symptom tags, no trigger tags, no per-entry severities. Testers send this file to a
stranger to debug sync; a headache diary is sensitive personal health information.

Note `skinTempDeviation`'s presence rate specifically. Skin temp is live-descriptor-only and cannot
be back-filled, and how often it is actually captured overnight is a long-standing open question this
export answers from one tester.

---

## Test E — fast logging

- Siri: "Log a headache in OpenCircuit" → a row appears, severity **Unspecified** (never a guessed level).
- Control Center button (iOS 18+ only — the project floor is 17.0, so it is availability-gated) →
  reaches the log in one tap from the lock screen.
- "Log yesterday" → the entry lands on yesterday's date and is editable afterwards.
- Two quick-logs a minute apart must not create two rows the user would call one headache.

---

## Tester-facing: TestFlight "What to Test"

Paste as-is. It is deliberately blunt about the limits — a tester who expects a prediction will churn
when it does not arrive, and a tester who quietly stops logging is worse than one who never started.

> **New: headache log + overnight signals (opt-in)**
>
> This build adds a headache log, and an early "overnight signals" view. Both are OFF by default —
> turn them on in Settings → Headache signals.
>
> **What we need from you, and why it matters more than usual:** your logged headaches are the only
> ground truth this feature can ever be checked against, and a headache you don't log can't be filled
> in later. Please log **every** headache, including mild ones, as soon as you notice it. There's a
> Siri shortcut ("Log a headache in OpenCircuit"), a Control Centre button, and a "did you have a
> headache yesterday?" prompt on the card for ones you remember the next morning.
>
> **If you already track headaches in Apple Health**, tap Import on the card — those become useful
> immediately.
>
> **What you'll see:** an "Overnight signals" section saying whether last night looked unusual *for
> you* — how far your sleep, heart rate, HRV and skin temperature drifted from your own normal. It
> takes about a week before it says anything at all.
>
> **What it will NOT do, and we want to be straight about this:** it does not predict headaches and
> it will not notify you. It says whether a night was unusual in either direction — a genuinely great
> night looks "unusual" too, and so does a hangover, a late night out, or a hard training day. The
> published accuracy ceiling for this kind of thing is low enough that we won't turn any alert on
> until your own logged data shows it works *for you specifically*, which takes months and may never
> happen. If that sounds underwhelming, that's the honest version.
>
> **Even if you never get headaches, you're still helping** — the days with no headache are exactly
> what tells us whether the signals mean anything. Please leave it on.
>
> **After about two weeks**, please send a Diagnostics export: Device Info ▸ Diagnostics ▸ Export.
> It contains counts and signal-coverage stats only — never your notes, symptoms or severities.

---

## Exit criteria

Do not merge until A, B, B2, C and D pass. B is the one that cannot be deferred: a broken freeze is
invisible in the UI and silently invalidates every number the feature will ever report.
