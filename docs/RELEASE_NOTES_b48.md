# OpenCircuit 1.0 (48) — your corrections stick

This build is almost entirely made of things testers reported. Six separate complaints,
all of them about the same underlying feeling: *the app got it wrong, and I couldn't
fix it.*

## Sleep

**Your correction now reaches Apple Health.** You could edit a night in OpenCircuit and
watch the app show the right thing while Apple Health kept showing the old, wrong night.
Corrections are now written through to Health, tagged as entered by you so Health knows
the difference between what the ring measured and what you told us.

**You can now edit a night we got badly wrong.** The editor let you move a night by up to
3 hours, widened to 6 when the ring stopped recording early — but that extra room was
being cancelled on any night longer than about 8 hours, which is most nights. If you hit
"I can't move the wake time far enough," that was this.

**A night that showed nothing should now show the night.** A short still stretch near
morning could take over as "the night" and evict the real one, leaving you with an empty
sleep card. On the tester night that prompted this, the same data now stages 500 minutes
of sleep instead of zero.

**Editing a night that crosses midnight.** Some nights couldn't be edited across the
midnight boundary at all.

## Cycle tracking

**A period ends when you say it ends.** There was no way to mark the last day, so a period
stayed open and kept extending itself day after day. You can now end one, and an open
period stops extending on its own after 8 days rather than running forever.

**No more flood of Apple Health entries.** An open period was being deleted and rewritten
in Health on every sync, every app open, and every background wake — dozens of writes a
day for one period. It now writes once and only revisits when a genuinely new day arrives.
Days already in Health are never taken back.

## What we still get wrong

**Bedtime can still read hours early on some nights.** If you were lying still but awake —
reading, on your phone, watching something — the ring's motion summary can look like sleep
and we start the night too early. We've measured this carefully and don't yet have a fix we
trust; two promising approaches were tested this cycle and both made other nights worse, so
neither shipped. Please keep correcting these nights. As of this build your correction
sticks and reaches Health, and the corrections themselves are the data we need to fix it
properly.

**If your ring stops recording mid-night, those hours are gone.** On some Gen 2 Air rings
the recorder stops a few hours in while the ring is still on your finger and still
connected. The hours simply aren't stored on the ring, so no amount of syncing recovers
them. You can now enter your real wake time by hand.

## Note on Apple Health numbers

On nights you edit, your Health sleep total may go **up** compared to build 47 — build 47
deliberately withheld time the ring never measured, and your explicit correction now counts
as sleep. Time neither measured nor corrected by you is still withheld rather than invented.

---

Gates: Kit test suite green, sleep staging scoreboard byte-identical to the pinned baseline
(`b1df0547…`), iOS build clean, no database schema change. Not device-validated.
