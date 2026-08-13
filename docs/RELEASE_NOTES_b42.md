# Build 42 — tester-reported alert & sleep-edit fixes

Everything here came from two testers' reports on 12 August, and every fix was diagnosed against
their own diagnostics exports rather than guessed at.

## What you'll notice

**Quiet hours are now ON by default, 22:00–07:00.** Health alerts no longer buzz overnight. Nothing
is lost — anything detected during the night is delivered once the window ends in the morning. If
you had already set this yourself, your choice is untouched. Change it in Settings ▸ Health alerts.
(One exception: a "ring fully charged" alert that lands inside the quiet window is skipped rather
than delayed.)

**Far fewer low blood-oxygen alerts, and the ones you get mean something.** The old rule alerted on
a single 2.5-minute reading. On one tester's night that was 1 reading out of 141, at 89 %, with its
neighbours at 97/96/95/96 — a sensor artifact, not a desaturation. An alert now needs the low
readings to persist, and it reports the lowest point of the whole episode.

**Alerts now tell you when the reading was taken.** Your ring stores data while it's out of range
and hands it over on the next sync, so an alert can legitimately arrive hours after the event. It
used to say only "6:06 PM", which read like it had just happened. It now says "yesterday at
6:06 PM" when that's the case.

**You can finally edit a sleep time that falls after midnight.** If the app said you fell asleep at
11:47 pm and you actually dropped off at 1:13 am, the editor physically would not let you enter it.
Sleep card ▸ Edit now works across midnight. The limits still apply and are shown under the pickers;
if a time is out of range, the reason appears and Save stays off.

**"Ring not detected" should stop crying wolf.** It fired after 20 minutes of Bluetooth silence,
which meant it fired hardest at the people whose connection drops most — while they were wearing the
ring. It now needs actual evidence the ring is off: it stays quiet while connected, during your
sleep schedule, and when the ring's own recorded data shows it was on your finger.

**Skin temperature: a night with only a handful of readings now says so** instead of showing a
number. Temperature is only recorded while the ring is connected, so a night that kept dropping had
been producing a "nightly average" from a few minutes of data and comparing it against nights
measured properly.

## Known limits, honestly

**Sleep onset can still read too early.** If you lie still and awake with a low heart rate, the ring
cannot tell that apart from sleep — it senses movement and heart rate, and neither says "awake" when
you're resting quietly. This is a sensor limit the official RingConn app shares, not a setting we can
turn up. Use Sleep ▸ Edit to correct the night; your correction is kept and is never overwritten by a
later sync. We have a promising lead on reading this off the ring's own behaviour and are gathering
evidence before changing anything.

**Not yet shipped:** a fix for the Elevated-HR ring filling too easily. The change we built for it
over-corrected badly in testing — it zeroed the activity ring for ordinary walking — so it is held
back until it can be re-fitted. Elevated-HR minutes and active calories are unchanged from build 41.

## Nothing on your device changes

No data migration, nothing recalculated, no re-sync needed. Nights already recorded keep their
values, including any you edited yourself.

## What to test

1. Edit a night's "Fell asleep" to a time after midnight and Save — does it stick?
2. Do you get any overnight notifications? (You shouldn't.)
3. Low blood-oxygen alerts — fewer, and plausible when they appear?
4. If you use the "Ring not detected" reminder, does it stop firing while you're wearing it?
5. Skin temperature — still shown on nights the ring stayed connected?

Please keep sending diagnostics exports (Device Info ▸ Diagnostics). If your sleep onset is wrong,
noting the time you actually fell asleep before opening the app is genuinely the most useful thing
you can send us.
