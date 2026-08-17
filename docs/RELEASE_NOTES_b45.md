# OpenCircuit 1.0 (build 45) — 2026-08-16 (hotfix)

**If you installed build 44: we're sorry.** Build 44 had a store-migration defect that
deleted the app's local raw history on first launch after updating — that's why Trends
went empty. Your sleep summaries, the data already in Apple Health, and the last ~30 h of
ring history were kept, but the older local sample history (the Trends charts) is not
recoverable. Build 44 was pulled from TestFlight within the hour; this build upgrades
safely from build 43 *and* from build 44 (both paths verified in migration tests).

Trends will refill going forward as your ring syncs.

Everything else in build 44's notes still applies (and ships here):

- Split mornings count as one night again (a brief stir near the end of a night no longer
  files the rest of your sleep as a separate "nap").
- The sleep editor no longer refuses wake times your ring actually recorded, its limit
  grows as data syncs in on edited nights, and night/nap double-counting is gone.
- Move and ring-wear reminders pause while the ring is charging or off your finger.
- Diagnostics label edited nights with both edited and recorded windows.

Known limits (unchanged): Gen 2 Air long lie-ins can still end a bit early — correct them
in Edit Sleep; staging changes are replay-validated, not yet overnight-on-device.
