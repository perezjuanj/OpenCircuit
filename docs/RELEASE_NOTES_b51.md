# OpenCircuit 1.0 (51)

One new capability and two defects. The capability is the Gen 3 vibration motor — decoded
from a tester's capture, then confirmed by driving it 12 times out of 12 on his ring — and a
silent wake-up alarm built on it. The defects both shipped in build 50: one left every tester
in a Health-permission loop with no settled state, and one made the sleep editor tightest
exactly where detection was worst.

⚠️ **The vibration and alarm work is NOT device-validated by us.** The motor command is
confirmed on real hardware, but through our desktop client on a tester's ring — the iOS
implementation of it has never met a Gen 3. Read the alarm section's honest limits before
relying on it to wake you.

---

## Thanks to lawruhl

The vibration motor is in this build because of **lawruhl**. He captured his Gen 3 talking to
the official app, and then — over several rounds, on his own finger — described each buzz
*blind*, without being told what we had sent. That blind reporting is what let the pattern byte
be established rather than guessed: the two buzz shapes he described partitioned exactly along
one byte, and the prediction we made from it held 3 for 3 on the next round.

He also ran the falsification pass that killed our other hypothesis. We thought byte `[3]` was
intensity; he tested it across a 10× range and reported all three identical, which is why the
app pins that byte instead of offering you a slider that does nothing.

Twelve buzzes for twelve attempts, across four frames. Thank you.

---

## Your Health permissions stop being wiped

**The defect.** On a fresh launch the app asked for Workouts + Workout Routes *write*. You
allowed it, and Apple Health showed both granted. Opening the Activity tab then asked for
workout *read* — and the write grant you had just given was gone, so the next launch asked
for it again. Forever.

**The cause.** Build 50 introduced a second HealthKit authorization request.
`WorkoutHistoryReader` asked for `read: [workoutType]` with an empty `toShare`, while
`HealthKitWriter`'s request named that same type in `toShare` only — two requests disagreeing
about one type.

**The fix.** There is now exactly one request. The plain workout type sits in both halves
(the Activity card genuinely reads workouts back); `workoutRoute` stays write-only because
nothing in this app reads a route. The second call site is deleted, and the "would this
prompt?" probe now tests with the *same* two sets the request sends — it was previously
probing with a much smaller set, which is why a newly added read type was invisible to it.

**If you are already stuck**, this heals you: you should see exactly one more Health sheet on
first launch of this build, settling the workout write row and the read row together, then
silence.

**What is not claimed.** *Why* HealthKit cleared the earlier grant is not established. Apple
documents no such reset. What is established is the loop itself, from a device report, and
that the wiped status was `.notDetermined` rather than denied. The fix does not depend on the
mechanism. A new audit pins the shape so it cannot regress — it was verified to fail with the
build-50 code restored.

---

## A night the ring cut short can be corrected to the wake you actually had

**Reported** by a Gen 2 tester: *"this morning it again said I only slept for less than 2h and
then when I tried to edit it manually it had a limit on how late I could set the wake up time.
Why does it make these limits?"*

**The defect.** The editable ceiling was anchored on `recordedWake` — the very number you
opened the sheet to correct. Truncation moves the recorded wake earlier, so it moved your
ceiling earlier in exact lockstep: 30 minutes of reach lost for every 30 minutes of extra
truncation. The worse the detection, the less you were allowed to fix it.

**The fix.** The ceiling now also carries a term that a wake-side truncation cannot move — one
plausible night after the earliest bedtime the ±3 h rule already accepts. It is not a new
constant or even a new expression: it is the same cap the function applies twelve lines
earlier, promoted from a ceiling on what data coverage could buy into a floor granted outright.

**Scope.** Any night with 5 h or more of recorded sleep is byte-identical to before — this only
widens the short nights that needed it. A 2 h night gains 3 h of reach; a 30-minute one gains
4 h 30 m. Everything the wider ceiling unlocks is still tagged as asserted, and still stays out
of your stage minutes, efficiency and score.

---

## New: your Gen 3 ring can buzz

Appears under **Device info → Vibration & alarm**, and only on a Gen 3 — no other model has
ever been sent this command, so the row stays hidden rather than offering a control whose
behaviour we cannot vouch for.

### The wake-up alarm

A silent alarm: the ring vibrates on your finger instead of a sound waking the room.

**Read this before relying on it.** iPhone apps cannot run at an exact time in the background
— there is no timer that survives suspension, and a delivered notification runs no code. So
the buzz is best-effort, and the app is honest about it:

- OpenCircuit buzzes the ring at the first moment it hears from it at or after your alarm.
  In the five minutes beforehand it holds the Bluetooth link open on purpose, which normally
  brings that down to **seconds**.
- It will not buzz at all if the ring is charging, disconnected, or you have swiped the app
  closed from the app switcher.
- A buzz more than 15 minutes late is deliberately *not* delivered — being woken long after
  you needed to be is worse than not being woken — and the miss is reported to you rather
  than swallowed.
- The **backup alert** is an ordinary iPhone notification scheduled by iOS itself, so it
  always arrives. It defaults on. Leave it on unless you have another alarm you trust.

The settings screen tells you what the alarm last actually did, including how late a buzz was
and why one was skipped.

### Buzz for app alerts

Optional, off by default: adds a buzz whenever OpenCircuit sends you a notification — move and
wear reminders, bedtime, health alerts. It follows the settings those already have, quiet hours
included, so it cannot produce a buzz for a notification you were not going to get anyway.

---

## Also

The ground-truth capture script no longer hides its own progress — `mitmdump -q` was
suppressing the `✅ SAVED` confirmations, so a working capture looked like a dead terminal.

## Under the hood

The same tester capture that cracked the motor also turned up a previously unknown **100 Hz,
4-channel raw PPG stream** (`0x12`, opened by `06 05 00`) — four times denser than the stream
we knew about, and the better substrate for future blood-pressure and HRV work. Documented in
`PROTOCOL.md` §5.10. RingConn's own blood-pressure *number* was re-confirmed as never crossing
the wire; it is computed off-device.
