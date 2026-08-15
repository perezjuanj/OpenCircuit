# Build 43 — new app icon, a launch screen, and a much faster first open

**With thanks to u/Icy-Faithlessness-12, who designed the new logo for us.**

## What you'll notice

**A new app icon.** The mark was designed for us by u/Icy-Faithlessness-12 and replaces the old flat one. It's a layered icon,
so it adapts properly to light, dark, and tinted home screens on iOS 26. The same mark now appears
on the launch screen and at the bottom of the Profile tab, next to the version number — which is the
number to quote if you report a bug.

**The app should open much faster, especially while it's syncing.** This was a real bug, not a
perception. Every time the app opened, came back to the foreground, or finished a sync, it loaded
*two weeks of every raw reading* on the main thread — the thread that also draws the screen. On the
maintainer's own phone that measured **24,959 rows per load**, and a cold open that also synced paid
that cost roughly three times over. The reading itself now happens off the main thread, and the
duplicate loads at launch are gone.

Please tell us whether the difference is noticeable to you. We measured the cause precisely and the
fix is a structural one, but "does it actually feel faster on your phone" is the part we can't
measure from here.

**Sleep may now tell you when "bedtime" isn't really your bedtime.** If your ring wasn't recording
in the period before the night starts — it was charging, or off your finger, or the connection
dropped — then the time shown as bedtime is really just *the moment recording resumed*. The app used
to present that exactly like a bedtime it had watched happen. It now says so, and points you at
Sleep ▸ Edit to correct it.

The note only appears when the gap is genuine. It deliberately does **not** guess *why* the ring
wasn't recording: charging, taking the ring off, and a Bluetooth dropout are indistinguishable from
the data we keep, so claiming one would be a guess dressed up as a fact.

## Known limits, honestly

**We still have no ground truth for bedtime.** Not one night in our whole collection has a
user-confirmed "this is when I actually went to bed" label. So this build makes the app *honest*
about an uncertain number — it does not make the number more accurate, and we're not claiming it
does. Corrections you make in Sleep ▸ Edit are exactly the labels this needs.

**Sleep onset can still read too early**, and **brief mid-night wakings can still be missed.** Both
are unchanged from build 42 and both are sensor limits rather than settings — see that build's notes.

## Also in this build

Nothing else changed in how your data is read from the ring or written to Apple Health. Three older
issues (#185, #186, #187) were closed during this release: all three had already shipped in builds 35
and 36 and were simply left open by mistake.

## Under the hood

- App icon migrated to Icon Composer with light / dark / tinted layers.
- Launch screen via `UILaunchScreen`, background pinned to the app's own page colour so the handoff
  to the first frame doesn't flash.
- The trends snapshot fetch moved to a background context; a new `TrendsRefreshPolicy` debounces
  navigation-triggered reloads while never debouncing a finished sync.
- `BedtimeProvenance` classifies a night's leading edge as witnessed / resumed-after-gap /
  no-prior-measurement / unknown, derived from stored readings rather than a new stored field — so
  it required no database migration.
- 1419 package tests pass. Sleep staging is byte-identical: no file in the staging or detection path
  was touched.
