# OpenCircuit 1.0 (build 47) — 2026-08-22 — honest sleep, and an editor that lets you say what happened

## Read this first: some of you will see LESS sleep than before

This build stops the app filling in sleep it never measured. If your ring missed part of a
night and you corrected the times, the app used to quietly invent "core sleep" across the
gap, count it in your efficiency and score, and write it to Apple Health as if it had been
measured. On one tester's night that was **2 hours 36 minutes of sleep that never existed**,
sitting in her Health record at 99.98% efficiency.

That stops now. **Your Apple Health sleep totals may drop on affected nights** — in the worst
case we measured, from 4 h 06 m to a few minutes. Nothing has broken and nothing was deleted:
those numbers were wrong before, and the app is no longer guessing.

Across the nights we could measure, this withholds **10 h 48 m of invented sleep** from Apple
Health.

## What you'll notice

**You can now correct a night the ring got badly wrong.** The wake-time picker used to stop
exactly 3 hours after whatever the ring last recorded. A tester whose ring went silent at
2:31 a.m. was capped at 5:08 a.m. and physically could not enter her real 6:15 wake — twice,
on two different nights. The editable range is now wide enough to cover a ring that stopped
recording mid-night.

**Your times stay yours.** When you set a time we couldn't measure, we keep it and show it —
we just mark it as your account rather than a measurement. The card tells you in words:
how much of the night the ring actually recorded, and that only the measured part reaches
Apple Health.

**Efficiency and sleep score are withheld, not faked,** on a night with too little data to
compute them honestly. A dash is the correct answer to a question we can't answer.

**Your time in bed is still written to Apple Health in full.** Where your body was is your
statement to make, and we have no measurement that contradicts it. It's the *stages* —
core, deep, REM — that we now decline to invent.

## Also in this build

- A later sync that arrives with slightly *less* sleep no longer freezes the range you're
  allowed to edit. Keeping the fuller night's numbers was right; freezing the editor was not.
- Upgrading no longer risks wiping locally stored history (every past database version is now
  pinned to a frozen snapshot).

## What this does *not* fix

**The missing hours themselves.** One tester's Gen 2 Air stops writing data about four hours
into the night — four times now, lasting 4 h 03 m to 4 h 05 m — while the ring is still on her
finger and still connected. We know it's worn because it keeps sending skin temperature every
~42 seconds at 35–36 °C right through the gap. We've ruled out our workout mode and our apnea
monitoring as causes. We have not yet established whether the rest is ring firmware or
something still on our side.

**If this is happening to you, one thing would help enormously:** check the same night in the
official RingConn app and tell us what it shows. If RingConn has your full night, the data
exists and we're failing to collect it — which is ours to fix. If RingConn has the same gap,
it's the ring, and we'll say so plainly instead of letting you keep chasing it.

## Under the hood

No sleep-staging number moved. The detection pipeline produces a byte-identical result to
build 46 across all 73 nights in our test corpus — 0 differences. 1,616 automated tests pass.

Validated by replaying recorded ring data, **not** overnight on a phone. The tester nights
driving this build are Gen 2 Air; Gen 3 and Gen 2 are the least-exercised cases here.
