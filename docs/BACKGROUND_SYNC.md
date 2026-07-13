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
