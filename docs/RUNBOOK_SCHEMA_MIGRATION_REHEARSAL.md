# RUNBOOK — SchemaV7 migration rehearsal on a REAL device

**Status:** MANDATORY before any build carrying `SchemaV7` (the sleep provenance/reversibility
columns) goes to TestFlight. Not optional, not replaceable by the simulator suite.

## 0. Why this runbook exists, and why the shortcuts don't work

Twice now a column was added to a live `@Model` type while a historical `VersionedSchema` still
pointed at it. Both times every phone that upgraded got
`NSCocoaErrorDomain 134504 "Cannot use staged migration with an unknown model version"`,
`makeContainer` caught it, and `wipeAndRecoverForeground` deleted every `StoredSample`,
`StoredCursor`, `StoredStepSample` and `StoredDaytimeTemp` row on the device. The ring cannot
re-supply any of it. Build 44 (2026-08-16) did this to real testers and was expired the same day.

Two rehearsals that look like this one and prove **nothing**:

| Shortcut | Why it proves nothing |
|---|---|
| Running the simulator test suite | It is a necessary gate and it now covers the b34/b43/b45 shapes — but it exercises hand-seeded stores of a handful of rows, not a real store with a year of raw samples, WAL sidecars, `.unique` collisions and a live CloudKit-free container under Data Protection. |
| Upgrading from a store the CURRENT build wrote | The current build already writes the V7 shape. There is no migration to perform, so the defect class is skipped entirely. **This is the single most common way this rehearsal is faked.** |

The rehearsal MUST start from a store written by a **pre-45 build** — ideally build 43 (the newest
pre-45 shape, `SchemaV5`) and, if a second device is available, build 45 (`SchemaV6`) as well.

## 1. What you need

- A physical iPhone with Developer Mode on. **Not a simulator.**
- A build of the app at tag `v1.0-b43` (installable via TestFlight history, or built from the tag).
- The candidate build (this branch).
- A RingConn ring paired to that phone, and **at least one night plus one full day of synced
  history already in the app** — the point is that the store has raw rows to lose.
- `xcrun devicectl` working against the phone (see the *device data-pull* notes in the repo).

## 2. Procedure

Numbered, in order. Do not skip step 3 — the "before" census is the only thing that makes step 7
falsifiable.

1. **Install build 43 on the phone and let it populate.** Fresh install is fine, but it must then
   run long enough to hold real data: at least one completed overnight sync plus one daytime
   session, so `StoredSample`, `StoredCursor`, `StoredStepSample` and `StoredDaytimeTemp` are all
   non-empty. If you are reusing a phone that already has app history from build 43 or earlier,
   that is better — skip the population wait.
2. **Add the rows that only a human can create**, because these are the ones no re-sync restores:
   - edit one night's sleep times (Sleep card ▸ Edit) so a `StoredSleepSummary` carries
     `isManuallyEdited == true` plus edited edges;
   - edit one nap's window, and manually ADD a second nap, so a `StoredNap` carries
     `isManuallyEdited` / `isManuallyAdded` / `editedStart` / `editedEnd`;
   - log one headache and one period entry.
3. **Take the BEFORE census.** Pull the store and count rows — this is the measurement everything
   else is compared against:
   ```
   xcrun devicectl device info devices                      # get the CoreDevice id
   xcrun devicectl device copy from --device <id> \
     --domain-type appDataContainer --domain-identifier com.standardsoftwaresolutions.opencircuit \
     --source Library/Application\ Support/default.store --destination ./before.store
   sqlite3 ./before.store \
     "select 'ZSTOREDSAMPLE', count(*) from ZSTOREDSAMPLE
      union all select 'ZSTOREDCURSOR', count(*) from ZSTOREDCURSOR
      union all select 'ZSTOREDSTEPSAMPLE', count(*) from ZSTOREDSTEPSAMPLE
      union all select 'ZSTOREDDAYTIMETEMP', count(*) from ZSTOREDDAYTIMETEMP
      union all select 'ZSTOREDSLEEPSUMMARY', count(*) from ZSTOREDSLEEPSUMMARY
      union all select 'ZSTOREDNAP', count(*) from ZSTOREDNAP
      union all select 'ZSTOREDHEADACHEENTRY', count(*) from ZSTOREDHEADACHEENTRY
      union all select 'ZSTOREDPERIODENTRY', count(*) from ZSTOREDPERIODENTRY;"
   ```
   Write the eight numbers down. Also record, from the app UI, the oldest date the Trends
   temperature chart reaches back to, and the edited nap's window.
   Keep `before.store` — it is the only copy of the pre-migration truth.
4. **Do NOT delete the app.** Deleting it deletes the store and voids the whole rehearsal. Install
   the candidate build straight over build 43 (`deploy.sh`, or a TestFlight update). An over-install
   is exactly what a user experiences.
5. **Launch it in the FOREGROUND and watch the first launch.** Stream the log while it starts:
   ```
   xcrun devicectl device process launch --device <id> --console \
     com.standardsoftwaresolutions.opencircuit 2>&1 | tee migration.log
   ```
   Watch for the migration. **A launch that takes noticeably longer than usual and then shows the
   dashboard is the good outcome** — that is lightweight migration doing work.
6. **Look for the failure tell immediately.** Any of these means FAIL, stop, and do not ship:
   - the string `Cannot use staged migration with an unknown model version`, or `134504`, anywhere
     in `migration.log`;
   - the in-app "local history was reset" notice appearing (that is `historyResetDefaultsKey`, and
     it is raised only by `wipeAndRecoverForeground`);
   - a black screen / launch crash.
7. **Take the AFTER census.** Repeat the step-3 pull and query into `after.store`.

## 3. The observation that means PASS

**PASS requires all five, and the first is the one that matters:**

1. `ZSTOREDSAMPLE`, `ZSTOREDCURSOR`, `ZSTOREDSTEPSAMPLE` and `ZSTOREDDAYTIMETEMP` counts in
   `after.store` are **greater than or equal to** the step-3 numbers. Not "roughly", not "most of
   them" — the migration is additive, so nothing may be lost. (Greater is normal: the app syncs on
   launch.) **Any decrease at all is the wipe, and the wipe is the defect.**
2. The "local history was reset" notice **never appeared**, and `migration.log` contains no `134504`
   and no `Cannot use staged migration`.
3. The human-created rows survived intact: the edited night still shows the edited times and still
   reads as manually edited; the edited nap still has its adjusted window; the manually added nap is
   still there; the headache and period entries are still listed.
4. The Trends temperature chart still reaches back to the same oldest date recorded in step 3.
5. Relaunch once more (cold). Second launch is fast and still clean — this catches a migration that
   "succeeded" by silently re-creating the store.

Record the eight before/after pairs in the PR. A rehearsal without the numbers is not a rehearsal.

## 4. Second arm, if a second device is available

Repeat the whole procedure starting from **build 45** instead of 43. Build 45 is the shape almost
every live phone actually has (`SchemaV6`), so it is the arm with the largest blast radius; build 43
is the arm the fix was written for. If only one device exists, do build 43 first — it is the one
that was measured broken.

## 5. If it fails

Do not "fix forward" on TestFlight. Expire the build the same day, as was done with build 44, and
re-open the question in `ShippedStoreMigrationTests`: a device failure that the simulator suite
passes means the suite's transcribed shapes have drifted from what actually shipped, and the
transcription — not the migration plan — is the first thing to re-measure against the git tag.
