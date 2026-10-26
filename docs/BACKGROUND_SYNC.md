# Background Sync — how RingConn does it, and how OpenCircuit does it

**The question this answers:** can a RingConn-class app sync ring data to Apple Health
*without the user ever opening it*, and by exactly what mechanism? Answer: **yes** — and
the official RingConn app leans on a stack of overlapping background mechanisms. This doc
records their approach (reverse-engineered from the shipped iOS app) and maps each piece
to OpenCircuit's own implementation, calling out where we deliberately diverge.

> Source: static analysis of the official **RingConn iOS app v4.2.1** (Flutter,
> `com.gdjztech.ringconn`) downloaded to an Apple-Silicon Mac as a native `.app`
> (2026-07-12). The main `Runner` binary is FairPlay-encrypted (`cryptid 1`), so evidence
> comes from the **unencrypted** plugin frameworks (`Frameworks/*.framework`, `cryptid 0`),
> the Dart AOT snapshot (`App.framework/App`), `Info.plist`, and the entitlements.
> Confidence tags follow the project convention: 🟢 confirmed · 🟡 probable · 🔴 guess.

---

## Part A — How the official RingConn app does it

RingConn stacks **five overlapping background mechanisms**. Only some are load-bearing;
several are redundant or belt-and-braces. The confirmed end-to-end chain is:

```
WAKE  ──►  HOLD / REOPEN BLE LINK  ──►  DRAIN RING HISTORY  ──►  WRITE HEALTHKIT
```

### A.1 Wake sources (redundant)

| Wake source | Evidence | Grade |
|---|---|---|
| **BGTaskScheduler** — `workmanager_apple` BGProcessingTask + statically-linked transistorsoft `background_fetch` BGAppRefreshTask | `registerBGProcessingTaskWithIdentifier:`/`submitTaskRequest:error:`; Dart channels `com.transistorsoft/flutter_background_fetch/{methods,events,headless}`, `[BackgroundFetch] Event received`; ids `com.transistorsoft.fetch` + `app-periodic-task-identifier` in `BGTaskSchedulerPermittedIdentifiers` | 🟢 the strongest-proven wake |
| **CoreBluetooth state restoration** — iOS relaunches the app into the background on a ring BLE event | `flutter_blue_plus_darwin`: `willRestoreState` reads `CBCentralManagerRestoredStatePeripheralsKey`, calls `connectPeripheral:options:` then `invokeMethod:` to wake Dart; `RestoreIdentifierKey` gated on `restoreState.boolValue` | 🟡 fully wired in the plugin; hinges on Dart passing `restore_state:true` (AOT-inlined, unprovable statically) |
| **Silent remote push** — Tencent TPNS/XGPush, server-triggered | statically linked in `Runner`: `XGPush`, `startXGWithAccessID:accessKey:`, `isSilentMessage:`, `application:didReceiveRemoteNotification:fetchCompletionHandler:` → `SilentPushTaskService` → `SilentPushAwakeType`. `aps-environment=production` + `remote-notification` mode. (Firebase present but **Sign-In only** — no FirebaseMessaging.) | 🟡 components wired; push→sync edge unproven (some awake-types are UI-only) |
| **Silent-audio keep-alive** — a 300 s silent `empty.mp3` (the only audio asset in the bundle) looped under the `audio` background mode to hold residency for a `SyncTaskHandler` NSTimer | `audioplayers` `ReleaseMode.loop`; `allowBackgroundAudioPlaying` flag; notification-nudge fallback | 🟡 real subsystem; decisive unknown = whether it uses `AVAudioSession.playback` (the only category granting residency) |
| **HealthKit background *delivery*** (entitlement `healthkit.background-delivery=true`) | entitlement present, but `health.framework` has **no** `HKObserverQuery`/`enableBackgroundDelivery`; Dart only references a channel name | 🔴 **not** the ring-sync mechanism — background delivery is the *reverse* direction (Health waking the app when *other* sources change data), not writing ring data out |

### A.2 Hold the BLE link, drain, write

- **Hold/reopen:** `bluetooth-central` background mode + `BleBackgroundFetchMixin` (a first-class
  mixin on the BLE base chain) + `autoReconnect`/`_startReconnect`; the background routine
  `syncDataOnBackground` → `waitConnectedAndSynced` waits for the ring to (re)connect. 🟢
- **Drain:** `_syncAll` under `syncDataOnBackground`, bounded by tunable
  `backgroundSyncTimeout` / `backgroundSyncHrSpo2Timeout` / `backgroundSyncActivityTimeout`;
  distinct `workManagerFullSyncTask` (full drain) vs `workManagerUploadOnlyTask` (flush only). 🟢
- **Write:** `HealthManager`/`RCHealthDataType` → `flutter_health` channel `writeData`/`writeHealthDatas`
  → `health.framework` `saveObjects:withCompletion:` / `requestAuthorizationToShareTypes:readTypes:`.
  HealthKit writes succeed from *any* executing context, so once a wake fires and the drain
  completes, the write is the easy part. 🟢

### A.3 What is proven vs what needs a device log

- **Proven statically (🟢):** the HealthKit write path, the BGTask scheduling machinery, a
  dedicated background-sync routine on the live BLE chain, a fully-implemented CB-restoration
  handler, and the TPNS silent-push plumbing all exist in unencrypted code.
- **NOT provable statically (needs one on-device log):** that any wake actually *fires and
  completes drain+write while the app is closed* (the arrows between nodes are inferred from
  co-resident symbols, not a recovered Dart call graph); whether `restore_state:true` is
  passed; whether the silent audio uses `.playback`; which `SilentPushAwakeType` means "sync";
  whether per-account feature flags (`isEnableWorkManager`, `basic_tpns_enable`, …) are on.

---

## Part B — How OpenCircuit does it

OpenCircuit implements the **legitimate subset** of the above and deliberately omits the
tricks that are either App-Store-risky or incompatible with our local-first / no-cloud
contract. This is the work that shipped as **#119** (background-sync root cause: *no BGTask
had ever run*, because the submit point lived in `applicationDidEnterBackground`, which a
scene-based SwiftUI app never receives). The wake chain below is now live.

```
BGTask grant OR CB state-restoration relaunch
        │
        ▼
reconnect ring (connect-by-identifier, no scan)   ← RingScanner
        │
        ▼
drain BOTH history channels (0x00 sleep + 0x03 all-day)   ← captureForBackground → syncHistory
        │
        ▼
flush pending metrics to Apple Health (watermark-gated)   ← HealthKitWriter.flushToHealth
```

### B.1 Mechanism mapping

| Blueprint element | OpenCircuit implementation | Where |
|---|---|---|
| BGAppRefreshTask + BGProcessingTask (two ids) | Both registered at launch; the app-refresh path carries a ~28 s budget, the processing path ~150 s so the optical-HR poll can clear its warm-up | `AppDelegate.swift` `didFinishLaunching`; `Background/BackgroundRefreshScheduler.swift` (`identifier`, `processingIdentifier`, `makeRequest`, `makeProcessingRequest`); `Background/RingBackgroundSyncService.swift` (`defaultTimeout`, `processingTimeout`) |
| **Re-submit every run** (one-shot requests) | Re-submitted in the launch bootstrap, the scene `.background` handler, AND at the top+end of every task handler (success, error, and expiration) | `AppDelegate.swift` `handle(_:)`; `App.swift` `scenePhase == .background` |
| Aim the discretionary grant at the valuable moment | By day: plain interval. Near/inside the sleep window: aim just before the window's end so the grant lands on the morning drain (typically while charging) | `OpenCircuitKit/Sources/OpenCircuitKit/BackgroundSyncPolicy.swift` |
| CoreBluetooth state restoration | `CBCentralManager` created with `CBCentralManagerOptionRestoreIdentifierKey`; `willRestoreState` re-adopts the ring as target + rebuilds the session; launch path arms a connect-by-identifier for a returning user AND wires the process-wide `LocalStore` into the scanner (G1) so a restored session persists + flushes, not just reconnects | `BLE/RingScanner.swift` `ensureCentral()` (restore id `com.opencircuit.central.restore`), `centralManager(_:willRestoreState:)`; `AppDelegate.swift` `didFinishLaunching` (store wiring + `reconnectKnownPeripheral()` gate) |
| Reconnect → drain → write, bounded | `captureForBackground(timeout:)` reconnects (by identifier, else service-filtered scan), runs the same two-channel `syncHistory()` the foreground uses, snapshots, then flushes to Health | `BLE/RingScanner.swift` `captureForBackground`; `Background/RingBackgroundSyncService.swift` `syncVitals` |
| Watermark-gated HealthKit write | `flushToHealth` mirrors pending metrics, each metric watermark-gated so nothing double-writes | `Health/HealthKitWriter.swift` |
| Post-sync alert evaluation | Body-vital alerts + silent-failure alerts evaluated after each background run | `AppDelegate.swift` `evaluateAlerts()`; `HealthNotificationCenter` |

### B.2 Deliberate divergences (do NOT "fix" these)

| RingConn does | OpenCircuit chose | Why |
|---|---|---|
| Silent-audio keep-alive under the `audio` background mode | **No `audio` mode.** We do not declare it. | Classic pattern Apple Review flags as `audio`-mode abuse. As a new app we can't risk it — and BGTask + CB-restoration achieve the same outcome legitimately. RingConn itself hedges the audio with a daily notification-nudge fallback — an admission residency isn't guaranteed. |
| Server-driven silent push (TPNS `content-available`) | **No `remote-notification`, no push backend.** | Requires our own server holding APNs tokens — violates the local-first / no-cloud contract in `CLAUDE.md`. |
| `requiresExternalPower = true` on the heavy drain (RingConn favors the charger) | **`requiresExternalPower = false`** on our BGProcessingTask | Our processing task doubles as a *daytime* optical-HR assist — a daytime read shouldn't require the charger. iOS still tends to defer processing tasks to charging/idle, so overnight coverage is preserved without mandating power. See `BackgroundRefreshScheduler.makeProcessingRequest`. |
| `HKObserverQuery` + `healthkit.background-delivery` entitlement | **Not adopted** (our entitlements carry `healthkit` only) | Background delivery is the reverse direction (Health→app), not the ring→Health write path. It would be a *legitimate additional* wake source if a use-case appears, but it is not needed for ring sync, so we don't request the entitlement. |
| `location` "Always" available as a residency crutch | `location` mode is **workout-GPS only** | We declare `location` solely to keep a *foreground-started* workout's HR recording alive and map outdoor routes (`project.yml:66-71`). It is never used as a background-sync residency trick. |

Our declared capability surface (`ios/project.yml`): `UIBackgroundModes` = `bluetooth-central`,
`location` (workout-only), `fetch`, `processing`; `BGTaskSchedulerPermittedIdentifiers` = the
two ids above; entitlement `com.apple.developer.healthkit = true`. No `audio`, no
`remote-notification`, no `healthkit.background-delivery`.

### B.3 Safety invariants that make our background path correct

These are hard-won and MUST be preserved (they're why our overnight sync is more careful than
RingConn's):

- **Overnight-quiet gate (#119):** inside the sleep window a background run does *not* open the
  live-read `syncAll` (FFFFFFFF), whose resume-pointer effect is the 🟡 backlog-shredder risk in
  `PROTOCOL.md §3`. The ring is left alone to log the night for one morning drain. Enforced by
  `HistoryDrainCadence.shouldDrain` at BOTH drain entry points — `syncHistory` and
  `evaluatePeriodicDrain` (the 0x11-heartbeat wake path) — not just `captureForBackground`'s
  live-read skip. ⚠️ Code-complete, but the end-to-end effect (a full >5 h night draining intact in
  one morning pass, early hours included) still **NEEDS ON-DEVICE VALIDATION** per
  `HistoryDrainCadence.swift:26-27` before it is trusted as the #111/#119 fix.
- **Clock floor under that gate (#280, decision 60):** the sleep window can read "awake" while the
  wearer sleeps (a fresh background session before `refreshNightWindowIfNeeded`, a learned window
  poisoned by a mis-staged night), so both drain entry points also apply `OvernightQuiet`: automatic
  drains are held 21:00–07:00 always, and 07:00–11:00 until a walking bout is seen at or after 07:00
  that day. The Sleep Focus-off run (`forceHistoryDrain`) still skips the learned window but answers
  to this floor too (`RingSession.syncHistoryAfterSleepFocus`); before #280 it drained as manual.
  Manual sync is never held. The floor gates drains only: `isInSleepWindow`'s other readers
  (auto-measure, the keepalive's `0x07` fetch, device snapshots, the background live read) are
  unchanged.
- **Non-destructive container in the background (#131):** the BGTask handler never builds the
  SwiftData container via the destructive `makeContainer()` wipe-and-recover path — it reuses the
  process-wide container or the non-destructive `makeContainerOrThrow()`, so a transient open
  failure can never silently wipe un-resyncable history. (`AppDelegate.handle`, `App.swift`.)
- **Deferred Bluetooth prompt (#142):** the shared central is created lazily via `ensureCentral()`
  so merely launching never fires the BT permission prompt before onboarding; background reconnect
  is gated on a saved active ring so a fresh install never adopts a stranger's ring.
- **One-writer / no in-flight contention:** a background drain re-arms the standing reconnect on
  teardown and never holds the link open in the background.
- **Store wired at launch for the restore leg (G1):** `AppDelegate.didFinishLaunching` hands the
  shared scanner the process-wide `LocalStore` (via the non-destructive `sharedContainer ??
  makeContainerOrThrow()` — never the destructive `makeContainer()`), so a `RingSession` built by
  `willRestoreState`/`didConnect` on a scene-less relaunch actually ingests + writes to Health
  instead of draining into a `nil` store. Before this fix the CB-restoration leg silently deferred
  every wake's data to the next foreground — the leg fired, but persisted nothing.

### B.4 Observability — how we can tell whether it actually runs

Static wiring being correct does not prove iOS ever *runs* it, and the scheduling path used to
swallow every failure (a `submit()` throw hidden in a `#if DEBUG print`), so a chain that never
fired looked identical to a healthy one. The scheduler now records each step into the Diagnostics
metric log, surfaced under **`# Background scheduling`** in the export:

- `bgregister` — whether iOS accepted each task-handler registration (a `false` ⇒ identifier missing
  from `BGTaskSchedulerPermittedIdentifiers`, so that task can never run).
- `bgschedule` — `submit()` succeeded, or `SUBMIT FAILED — <named reason>` (e.g. *unavailable —
  Background App Refresh off*, or *notPermitted — identifier missing from Info.plist*).
- `bgpending` — what `getPendingTaskRequests` reports iOS actually has queued.
- `bgtask` — `handler INVOKED by iOS`, recorded the instant the handler runs, before any drain.

Reading it: submits ok + pending requests but no `handler INVOKED` line ⇒ iOS isn't granting
(throttle/conditions), not a wiring bug; a `SUBMIT FAILED` line names the cause; a `handler INVOKED`
with no matching sync outcome ⇒ the wake fired but the drain didn't finish. The Diagnostics screen
also has a **"Reschedule & probe background tasks"** button to force a submit+probe on demand.

### B.5 The Amazfit Helio Strap (#215 phase 4)

With the strap chosen (`ActiveDeviceChoiceStore`), the same wakes drive the strap instead of the
ring. **No new background modes and no new BGTask identifiers** (decision 26). #233 adds one
entitlement, `com.apple.developer.healthkit.background-delivery` (an entitlement, not a background
mode), and widens `NSHealthShareUsageDescription` for the iPhone's step count.
`BackgroundDrain` picks the chosen device's drain from UserDefaults before either driver is
touched, so a strap wake never constructs the ring's scanner or central, and a ring wake never
touches the strap's connection.

| Wake | Strap path | Where |
|---|---|---|
| BGAppRefreshTask / BGProcessingTask (the two existing ids) | `HelioBackgroundSyncService.run` (28 s / 150 s budgets, as the ring) | `AppDelegate.handleStrap`; `Background/HelioBackgroundSyncService.swift` |
| Sleep Focus ending | the same run, short window, the strap's nights finalized (skip the 20-min margin, as the ring's `sleepFinalized`): in memory by a Health flush that starts within 30 min of the Focus end (decision 31), and through the persisted Focus end by any strap flush within 6 h, per night (decision 78a, below) | `SleepFocusSyncRunner.runStrap` |
| CoreBluetooth state restoration | `HelioConnection`'s own central (restore id `com.standardsoftwaresolutions.opencircuit.helio`) re-adopts the strap. Since #233 a link that comes back in the background doesn't sync by itself: it's a `restoration` wake (below) | `Helio/HelioConnection.swift` |

**Wake sources (#233, decision 33): the strap wakes the app; BGTasks are the backstop.** Build 59's
first night synced only when the app was opened: iOS granted both BGTasks at once, right before it
predicted the app would be opened, and they fought over the strap. Each wake below runs at most one
bounded **catch-up**: the BGTask run above (28 s budget, `03 09` acks, teardown, Health flush) under
a `beginBackgroundTask` assertion (`Background/HelioWakeSync.swift`, `HelioWakeCoordinator`).

| Wake (`HelioWake`) | When it syncs (`HelioWakePolicy`) | Dependable? |
|---|---|---|
| `reconnect`: a pending connect completes in the background (out of range and back, Bluetooth back on) | last completed strap sync ≥ 4 h ago, and no background run started in the last 30 min | only when the link actually dropped |
| `restoration`: CoreBluetooth relaunches the app and hands the link back | same as `reconnect` | as above; never after a force-quit or a Bluetooth toggle (below) |
| `idleTraffic`: anything the strap sends on its own over the held, idle link (decision 35) | same as `reconnect`; looked at no more than every 5 min, never in front, during a sync or while a run holds the strap | **no**: an idle authenticated link carries no heart-rate stream (that needs `04 01` plus a `04 02` from the phone every second, `ZEPP_PROTOCOL.md` §7.1), so this fires only if the strap pings or sends a §16.2 message |
| `strapEvent`: the woke-up event `06 00` on `0x001D` | always, except within 30 min of a background run's start (review-235 S3). Not a finalization: the night still waits for its margin, and nothing is written from the event (it carries no time) | **no**: an opportunistic hint. `ZEPP_PROTOCOL.md` §16.4 (PR #235): 🔴 whether the Helio sends it at all |
| `healthDelivery`: HealthKit delivers new steps counted by the iPhone itself (device model `iPhone`, so the strap's own step writes never wake it; hourly at most), strap users who turned on "Sync in the background more reliably" on the strap's device screen (it runs the app's one Health request, which already reads step count; never a request of its own) | unless a strap sync completed in the last 10 min; HealthKit's completion handler is called on every path (`Background/HelioHealthWake.swift`) | the only wake that doesn't depend on the strap; needs the iPhone to count steps (not overnight on a nightstand) |

N = 4 h for `reconnect`/`restoration`/`idleTraffic`: a strap that briefly leaves range reconnects
many times a day; four hours is longer than those absences and shorter than any night. **Decision
35:** B.5 holds the link up after every sync, so a strap worn in range all night never disconnects
and the reconnect wake never fires; what is left overnight is the BGTasks, the woke-up hint and
whatever the strap sends on its own. Nothing here makes the strap talk: no realtime stream, no
strap setting (realtime steps, heart-rate push), no keep-alive traffic. An idle link has only
`…0017` subscribed (`…0016` is turned off after auth, `0x2A37` only for the live-HR screen in front),
and `ZEPP_PROTOCOL.md` §16.5's replies apply: the ping `03` on `0x0015` is answered `04`, unasked
`0x2A37` frames get `04 00` and an unsubscribe, unasked realtime steps get `05 00` once, anything
else gets no reply.

**Apple's rules for these wakes** (review-235 S2; developer.apple.com: Core Bluetooth Programming
Guide, "Core Bluetooth Background Processing for iOS Apps", and Technical Q&A QA1962):
- A suspended app is woken for a connection established **or torn down** (a disconnect is a wake
  too) and for a characteristic value it subscribed to.
- Each wake gets **about 10 seconds**; the catch-up's `beginBackgroundTask` assertion is what lets a
  sync run past that.
- A terminated app comes back **only through state restoration** (iOS 11+: after the system ended
  it, a crash, or a reboot after the first unlock), and only for an event it was pending on.
- **For a terminated app, a force-quit or a Bluetooth power toggle ends every strap wake** until the
  person opens the app: restoration doesn't relaunch it after either. An app that is still alive
  (suspended) is a different case: when Bluetooth comes back on, `HelioConnection` reconnects
  (`pendingAction = .reconnect`), and that connect is a wake (review-225e N-1).

**The Sleep Focus end outlives the Focus-off run** (decision 78, #332). The Focus-off run is one
bounded wake (28 s), and it can miss the night: the link is down and the run is out of time before
the sleep round, it coalesces into a run that then runs out of time, the strap was busy, or the
record was still in progress. So:
- **T is persisted** (`helio.sleepFocusEndedAt.v1`, ring and strap; only the strap reads it). Any
  strap Health flush that starts at or after T and within 6 h of it finalizes each night whose last
  segment ends at or before T + 10 min: that night skips the 20-min settle margin and decision 58a's
  3 h newest-night hold. A night ending later (the person went back to sleep, or the next night) is
  judged by the normal rules. Decided once per flush in `HelioConnection.flushStrap`
  (`SleepFocusFinalization.nights`, from the latest of decision 31's in-memory T and the persisted
  one), so the background run, the post-sync hook and the app's foreground flush all use it. T can
  only make a night that was over arrive sooner; it never finalizes one still growing.
- **The run asks again** (78b). After a strap Focus run, whatever its ending, if the newest stored
  strap night that ended by T + 10 min (and within 18 h before T) has no mirror record, or there is
  none, a refresh is recorded for T + 15 min through `StrapNightRefresh` (it survives `schedule()`),
  unless a later one is pending. The run leaves the standing connect armed on every ending but key
  needed, key rejected, no saved strap and a workout holding the strap (after a strap-busy ending the
  re-arm meets the latch the try just set, so it waits for the latch to expire).
- **Counts-only lines** (78c, source `focus`): one per strap Focus run, `ending=… night=written|
  stored-not-written|none retry=yes|no`, and at most one per T from the first later flush that writes
  a night only the persisted T finalized: `night written from the Sleep Focus end, N min after it`.

**iOS may not run the filter at all when Sleep Focus ends on its schedule** (decision 78f). The
owner's b88 bundle showed a morning with no `sleepFocus` record anywhere: `perform()` never ran.
Apple delivers Focus changes "when the system has determined that it's important", to an App
Intents extension when the app isn't running, and OpenCircuit has none. So the app notices the end
itself, at its next wake: every strap background run (at its start, before its flush), the strap's
post-sync hook and the app coming to the front read the filter's state
(`SetFocusFilterIntent.current`, `SleepFocusDetection`). A read that says the Focus is on records the
time (`helio.sleepFocusSeenActiveAt.v1`; `perform()` with Focus on does too). A read that says it is
off (the filter with its default value, or `notFound`), with a seen-on time in the last 18 h newer
than the persisted T, persists T = the time of that read and leaves one `focus` line, `Sleep Focus
end detected at a wake (filter not run by iOS), kind=…`. A read that fails another way changes
nothing, and with no seen-on time nothing is inferred. The detecting run's own flush can then write
the night. The cost: someone back asleep after the Focus ended but before that wake gets the shorter
night written first; decision 58b replaces it with the later, longer copy. Nothing here connects,
syncs or schedules by itself, and there is no extension.

**Two tasks granted together coalesce** (#233 item 3): no run sits out its window. A later run whose
deadline isn't more than 5 s later than the active run's completes at once, successfully ("helio
strap: coalesced into the processing run"); a Sleep Focus run leaves its finalization for the active
run (decision 31 bounds it). A later run with a later deadline takes the sync over: the active run
hands it over at its next turn (nothing torn down or sent; its task completes successfully, "handed
its sync to the processing run (larger budget)") and the later run finishes and flushes that one
sync. A coalesced task runs no alert passes; the run holding the strap does. A coalesced or
handed-over task reports success even if the run it deferred to then expires with nothing synced
(review-225e N-2; harmless to data, left as is).

**A night held by its margin** (#233 item 5): when a strap flush holds a night back (its last
segment ended under 20 min before the flush, and no Sleep Focus finalization applied), the next
app-refresh request is aimed at the margin's end (`BackgroundRefreshScheduler.scheduleRefresh`,
strap only; at least a minute away); after a woke-up catch-up, at least 30 min later, as the night's
record may be late (`ZEPP_PROTOCOL.md` §21.4). The pending date is persisted (strap only,
`StrapNightRefresh`) and submitted again after the app's own `schedule()` (scene → background,
`applicationDidEnterBackground`, the start of every BGTask), which would otherwise replace it within
seconds (review-225e SF-3); it is cleared once it passes or a flush finds no night waiting. A
foreground flush also counts the newest stored strap night that hasn't reached Apple Health while it
is inside its margin, even when its sync no longer carries it (decision 57b, #262). Without that, an
app opened just after a background wake stored the night cleared that wake's refresh. Every strap
flush also offers the newest stored night from the store (`LocalStore.strapNightsAwaitingHealth`,
decision 57) once 3 h have passed since its end, whatever clock time it ended at (decision 58a,
#274). The strap lets the phone read a sleep record while the sleep is still going on, so a stored
end can be minutes before the sync that read it and hours before the real wake; and a mid-night
awakening may still be stitched to a later sleep (28f). Decision 57d's faster path for an end near
the sleep schedule's wake time wrote such partial nights and was withdrawn. A sync that carries the
final night still hands it to its flush behind the settle margin, so the margin refresh writes it,
and a longer copy replaces a shorter night already written (decision 58b, `HEALTHKIT_MAPPING.md`).
The ring's requests are unchanged.

**Opening the app syncs an idle strap session** (review-225e SF-1): a link that came back in the
background (a teardown's re-arm, a reconnect or restoration inside the wake gates, a connect that
completed while the app was `.inactive`) makes a session that doesn't sync on connect. On
`didBecomeActive` the connection syncs a ready, idle session (no sync, find or live heart rate) when
the last completed strap sync is at least `ForegroundAutoSync.interval` (300 s, one constant with
the ring's foreground auto-sync) old, with the ring's throttle, so a flapping `.inactive`/`.active`
gives one sync. If the app leaves before that sync ends, the sync-end hook runs its alert pass
(review-236 S1), once per sync: the claim that keeps ContentView's foreground hook from running a
second one lives on the session (`HelioSession.alertPassClaimedSync`). Until review-225f SF-1 it was
a global keyed by the session's `ObjectIdentifier`, and a reconnect's new session (often at the freed
one's address, its sync count back at 0) had its first pass refused by both hooks.

One run: connect by identifier if the link isn't up (never a scan) → auth with the Keychain key
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) → clock → fetch, every round acked `03 09`
and committed to `LocalStore` as it arrives → Health flush → one run-log line.

Safety invariants specific to the strap:
- **Budget.** The fetch gets the task's window minus an 8 s flush reserve. Out of time, or iOS
  expires the task: the open round is acked `03 09`, committed rows stay, the link is dropped
  (a running find gets its `06` first) and the rest stays on the strap. An expiry skips the Health
  flush; the task is completed only after that teardown (or 2 s after the expiry at the latest).
  A catch-up's expiry (its `beginBackgroundTask` assertion ending) tears down inside the expiry
  handler, since iOS suspends the app when it returns (review-225e SF-2): the `03 09` is queued, the
  fetch ends, the link cancel is issued in that call, and the standing connect is armed; its
  `connect` goes out when the cancel lands (`didDisconnectPeripheral`, itself a wake). A `03 09`
  still in the write queue may be lost with the cancel, which is safe: an unacked round stays on
  the strap.
- **Key states (decision 7).** No key, a rejected key (persisted), or a strap that ended "busy" in
  the last 20 minutes end the run before any radio work; a session that turns out keyless, rejected,
  busy or unsupported ends it. No retry, no store or Health write, and the run log says why. "Busy"
  lasts 20 minutes for the background paths (decision 78d, #316: one failed auth after a restoration
  relaunch used to stop every sync until the app was opened): after that a background run, a re-arm
  or the standing connect tries once more, and a Sleep Focus run always does. A strap still busy on
  that try latches again. A new launch and opening the app clear it, as before. The `helio-link` line
  `strap busy (<reason>)` says which path set it: `auth timeout`, `notify enable failed`, `competing
  central` (the strap answered auth with a status other than `25`, §9) or `auth failed other`.
- **The link after a finished run** stays up (idle, authenticated, standing reconnect armed):
  re-arming a fresh connect, as the ring does, would reconnect a strap in range at once and fetch
  everything a second time. A strap out of range keeps its pending connect armed for restoration.
  After a run's own teardown (out of time, or expired) a standing connect is armed again (decision
  33), never after a quiet ending (decision 7); the reconnect's catch-up waits out the 30-min
  cooldown. Bluetooth turning off keeps the wish to connect: power-on reconnects. Every reconnect
  re-runs auth and setup with a fresh session (§4–§5, §9).
- **Find stop across processes.** "A find may be running" is persisted (`helio.findStopOwed.v1`),
  so a process the system ends mid-find still sends the `06` on its next connection.
- **One container.** Every background site resolves its store through
  `OpenCircuitApp.sharedOrFallbackContainer()` (#222 review Q2 + U2).

Observability (B.4): each run records `recordSyncOutcome(kind:)` with a detail starting
`helio strap:` (e.g. `helio strap: synced; 9 round(s) stored, 0 failed, 1 night(s); Health
samples=…`, `helio strap: key rejected; not retrying`, `helio strap: out of time; open round kept
on the strap (03 09), disconnected`, `helio strap: coalesced into the processing run`) and a
`bgphase` breadcrumb starting `device=helio`. Catch-ups are logged as `cbWake` (strap event,
reconnect, restoration, idle traffic) or `backgroundSync` (Health delivery). A sync handed to the app
that ends in the background is logged as `backgroundSync` with a `helio:` detail.

**Link and wake breadcrumbs** (#233 item 1): metric-log source `helio-link`
(`Helio/HelioBreadcrumbs.swift`), printed by the Diagnostics export in their own section ("Strap link
and wakes"). Link up and down (CoreBluetooth's error code, how long the link had been up, whether a
standing connect is armed), Bluetooth off, restoration relaunches (states only, never identifiers),
every message the strap sent on its own (endpoint, opcode bytes and length, never the payload; at
most one line per endpoint per 10 min, with a count; a message's time is when it arrived), and each
strap sync's wake reason (`sync start wake=…`). Bounded per 12-hour window: 20 link lines, 16 sync
lines, 12 strap-message lines (4 per endpoint), so one night uses at most 48 of the metric log's 400
entries; what's over budget is counted and reported on the next window's first line.

### B.6 Run budgets and completion (Oct 2026)

Why runs "ended early" instead of finishing, and what each budget is now. Still no `audio` mode (B.2):
these make the legitimate wakes we already get finish their work.

- **Ring app-refresh:** `syncVitals(timeout:)` bounds the WHOLE run. The capture gets
  `timeout − elapsed − flushReserve` (8 s, floor 8 s; `RingBackgroundSyncService.captureBudget`), so
  pre-flush + capture + flush fits the ~30 s window. Before, the capture alone got 28 s after the
  pre-flush.
- **Ring expiry:** the BGTask is completed `ringExpiryGrace` (2 s) after expiry unless the run
  completes first (`BackgroundTaskCompletion`, as the strap's), so the cancelled capture's teardown and
  standing-connect re-arm run before iOS suspends us.
- **Ring wake-drain delivery:** `deliverBackgroundResults` holds its own assertion
  (`ring.history.deliver`); the drain's may have expired on a long morning drain.
- **Processing request:** `scheduleProcessing()` keeps a pending request that comes due no later than
  one interval before the new aim, instead of cancel + resubmit on every run and backgrounding (which
  kept pushing the only long window an hour out). Trusted per build only.
- **Strap wake catch-up:** budget = `min(28 s, backgroundTimeRemaining − 4 s)`, floor 10 s
  (`HelioWakePolicy.catchUpTimeout`), leaving the alert passes room inside the assertion.

---

## Part C — On-device validation runbook

Static analysis proves *capability*; only a device log proves the wake actually *fires end to
end while closed*. To confirm (either app):

**Fastest proof (no tooling):** Force-quit the app (swipe away). Wear the ring 30–60 min without
opening it. Open **Health ▸ Browse ▸ Heart Rate ▸ Show All Data** — new samples timestamped
*after* the force-quit = openless sync confirmed end-to-end.

**Attribute the wake to a mechanism (OpenCircuit):** with the app force-quit and the ring worn,
```
idevicesyslog -u <UDID> -p OpenCircuit
```
and watch the observability log (`ObservabilityStore.recordScheduled` / `recordSyncOutcome`) plus:

| Signal | Proves |
|---|---|
| `bgLastScheduled` present after a wake / `recordSyncOutcome(kind:)` entry | a BGTask actually ran (the exact #119 regression: this was *absent* for weeks) |
| `willRestoreState` re-adopts the ring | CB state-restoration relaunch fired |
| `captureForBackground` drain → `recordHealthWrite` | the wake drove a real reconnect + drain + HealthKit write with the app never foregrounded |
| a `helio strap:` run-log line / `bgphase device=helio …` | the strap's run (B.5) fired; the line says how it ended |

**Read last night's strap breadcrumbs (Helio Strap, no tooling):** Profile ▸ Helio Strap ▸
Diagnostics ▸ **Export diagnostics**, and share the text file. In **"# Strap link and wakes"**
(newest first), read up from the morning:
1. **Did the link stay up?** A `link down (unexpected, CBError n, after XhYYm up)` line overnight
   means the strap (or iOS) dropped a silent link after that long; `standing connect armed` means a
   reconnect could wake the app. No `link down` line between the evening and the morning means the
   link was held all night (decision 35: then no reconnect wake can happen).
2. **Did anything wake the app?** `restoration relaunch: …` (with states), `link up (connected after a
   restoration relaunch; app in background)`, and `sync start wake=…` lines with their wake:
   `appRefresh`/`processing`/`sleepFocus` (iOS granted a task), `reconnect`/`restoration`/`idleTraffic`
   (the strap side), `strapEvent` (the woke-up event), `healthDelivery` (iPhone steps).
3. **Did the strap say anything on its own?** `strap sent 0x0015 03 (1 B) (n since …)` is the
   connection ping; `strap sent 0x001d 06 00` the woke-up event; any other endpoint is new and worth
   a note in `ZEPP_PROTOCOL.md` §10 (opcode and length only). No such line all night means the strap
   was silent, so `idleTraffic` couldn't fire.
4. **Why not?** `wake=strapEvent: no catch-up: …` names the gate that held a woke-up event back. Then
   the "# Background scheduling" section shows what iOS granted (`bgtask … handler INVOKED`) and the
   "# Sync activity log" how each run ended (`helio strap: …`).

For the official RingConn app, use `log stream --predicate 'process == "Runner"'` and watch for
`[BackgroundFetch] Event received`, `willRestoreState`, `BGProcessingTask submitted`,
`syncDataOnBackground`, `writeHealthDatas`; also
`log stream --predicate 'subsystem == "com.apple.duetactivityscheduler"'` to see iOS launch the
`com.transistorsoft.fetch` / `app-periodic-task-identifier` tasks.

---

## Related tickets

- **#119** (closed) — the umbrella background-sync fix: no BGTask ever ran; overnight drain
  stalled while suspended. This static analysis of RingConn *confirms our post-#119 architecture
  is the same legitimate stack RingConn actually relies on*, minus the audio/push/location tricks.
- **#45** (closed) — background optical-HR: the BGProcessingTask longer-window path.
- **#142 / #131 / #44 / #99** (closed) — the safety invariants in B.3.

There is no open background-sync ticket: the blueprint is already implemented. See the memory
note `ringconn-openless-sync-blueprint` for the condensed version.
