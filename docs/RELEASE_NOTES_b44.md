# OpenCircuit 1.0 (build 44) — 2026-08-16

Sleep-accuracy and reminder-honesty release, driven end-to-end by one Gen 2 Air tester's
morning (thank you — your export made every fix below replayable).

## Sleep

- **Split mornings are one night again.** If you briefly stir near the end of a night and
  fall back asleep, the later bout could be filed as a separate "nap" and vanish from the
  sleep headline (one real 6¾ h night showed as 4 h). Night scoping now absorbs a
  same-morning continuation (gap ≤ 30 min) back into the night, with guards so a genuine
  daytime nap — hours after you get up — stays a nap.
- **The sleep editor stops fighting you.** The "edits are limited to the period your ring
  recorded" clamp could refuse a wake time the ring *did* record — evening data spent the
  editable budget and starved the morning side. The clamp math is fixed, the one-night
  limit is now enforced on the window you pick (max 14 h) instead of by squeezing the
  edges, and on nights you've already edited the clamp now **grows** as fuller data syncs
  in instead of freezing at the first truncated guess.
- **No more double-counted sleep.** When the night grows over a previously detected "nap"
  (or your edit covers it), the nap is removed — from daily totals and, on the next sync,
  from Apple Health — instead of counting the same sleep twice.
- Diagnostics exports now label edited nights with both the edited and the recorded
  windows, so a shared bundle can't show an impossible-looking row.

## Reminders

- **Charging is not sitting still.** The ring counts no steps and locks no reading while
  it's off your finger, so a charge used to read as "inactivity" (Move reminder) or a
  vanished ring ("Ring not detected"). Both reminders now know where the ring is: they
  pause while it's docked or reading off-finger, restart their clock when you put it back
  on, and the wear nag returns only once a charge could plausibly have finished (~4 h).

## Honest limits

- On Gen 2 Air rings the very end of a long lie-in can still read a little early — the
  Air's motion channel drifts in level while you're still, and fixing that properly needs
  more labelled nights, not a hand-tuned threshold. The editor now lets you correct it.
- The staging changes were validated by byte-exact replay of a real tester night plus the
  full regression suite (1,460 tests), not yet on-device overnight.

If a night still looks wrong: Profile ▸ Device Info ▸ Diagnostics, and send us the text —
that's exactly how this release happened.
