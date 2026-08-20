# OpenCircuit 1.0 (build 46) — 2026-08-20 — bedtime on still-evening nights

## What you'll notice

**Your bedtime should stop reading hours too early.** If you sat still for a while before
bed — on the sofa, reading, watching something — then got up and moved around, then
actually went to bed, the app used to reach back across that activity and count the whole
evening as sleep. On the maintainer's own night it printed bedtime as **8:24 PM** when he
went to bed at **10:24 PM**.

It now stops at the activity. The bedtime and the time-in-bed on your Sleep card, and the
sleep window written to Apple Health, should match the night you actually had.

The rule it uses is narrow on purpose: it only refuses to bridge a gap when the ring was
**recording the whole way across it**. A gap where the ring genuinely wasn't recording —
a missed sync, a dropped connection — is still stitched back together exactly as before.
That distinction is what keeps this from eating real nights that arrived in pieces.

## What this does *not* fix

**Wake time is unchanged**, and the **total asleep figure is still too high on very still
nights.** The ring cannot sense you lying awake in bed — no movement, near-sleep heart
rate — so quiet wakefulness is still counted as light sleep.

Fixing the bedtime actually makes that show up more plainly. On the maintainer's night the
card now reads **99% efficiency**, and his sleep score went **up**, on a night he knows was
rough. Nothing got worse; a wrong bedtime was hiding how much of the *remaining* number is
still-but-awake time. Where a night reads that still, you'll now see the **"very still
night"** note explaining why.

**Nights already recorded keep their current numbers.** This changes nights recorded from
here on. Nothing in your history is rewritten and nothing is deleted.

## Tell us if a night gets *shorter* than it should

If you genuinely sleep, get up for half an hour or so with the ring on, and then go back
to sleep, this change can drop that first stretch of sleep. We have no recording of that
happening yet — which is exactly why we need yours.

If a night looks short: send a **Diagnostics export** (Device Info ▸ Diagnostics) and
correct the night in **Sleep ▸ Edit**. Both together let us measure it.

## Honest limits

- This was measured against a corpus of 21 staged nights. It changes **one** of them and
  leaves the other 20 bit-for-bit identical. That one night is the only one with a
  hand-corrected bedtime to check against.
- It has **not** been validated overnight on a device yet — only replayed against recorded
  bytes.
- Both the nights that exercise this are **Gen 2**. Gen 3 and Gen 2 Air are unmeasured for
  this specific change.
- Known limits carried over: Gen 2 Air long lie-ins can still end a bit early — correct
  them in Edit Sleep.
