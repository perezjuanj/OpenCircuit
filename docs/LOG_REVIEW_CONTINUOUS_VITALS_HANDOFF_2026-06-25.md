# Continuous Vitals Logging Review Handoff

Date: 2026-06-25

Scope: review of the supplied Xcode/device log for OpenCircuit's RingConn integration, focused on whether frequent or near-continuous capture is possible, why some readings were not durably recorded, and what should change next.

This document is based on:

- the supplied device log excerpt from the physical-phone run
- the current OpenCircuit code in this repo
- prior protocol notes already present in the repo

It is not based on a simulator run.

## Executive Summary

The supplied log shows that the ring is already capable of providing frequent readings for at least:

- heart rate
- SpO2
- skin temperature
- steps/status snapshots

The main current blockers are not raw measurement capability. The blockers are in OpenCircuit's session control, BLE state handling, and persistence observability:

1. commands are being sent while CoreBluetooth is not ready or the peripheral is disconnected/connecting
2. quick live reads still open sync sessions as part of measurement entry
3. some successfully decoded samples are not being durably stored, and the app does not record why
4. the in-app observability layer is too coarse to reconstruct metric-by-metric capture vs store vs Health outcomes after the fact
5. sleep/night staging is still too fragile under reconnect/sync churn to support dependable overnight interpretation

For the next development session, the highest-value work is:

1. harden BLE state gating before writes
2. decouple frequent live measurement from sync-open behavior
3. make sample rejection reasons durable and visible
4. add first-class timestamped storage lanes for dense local trend capture where the ring already provides data often enough

## Source Log Signals

The following lines are the most important evidence from the supplied log.

### 1. CoreBluetooth misuse and command loss

Observed repeatedly:

- `API MISUSE: <CBCentralManager ...> can only accept this command while in the powered on state`
- `API MISUSE: <CBPeripheral ... state = disconnected> can only accept commands while in the connected state`
- `API MISUSE: <CBPeripheral ... state = connecting> can only accept commands while in the connected state`

These appear interleaved with actual writes such as:

- `→ write 07 00 00`
- `→ write 01 00 00`
- `→ write d0 00 00`

Interpretation:

- OpenCircuit is attempting ring commands while the Bluetooth stack is not yet fully usable.
- Some measurement/snapshot/sync attempts are therefore being dropped before they can succeed.
- This is a reliability problem independent of the ring's sensor capability.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1448)

Current issue in code:

- `write(_:)` checks only whether `writeChar` exists.
- It does not also guard on actual peripheral/central readiness at the time of write.

### 2. Reconnect churn and repeated discovery

Observed:

- `rediscover: link up but not ready (notify=false, write=false) — re-running discovery`
- `ready=false (notify=false, write=false)`
- later several `ready=true (notify=true, write=true)`
- repeated `notify subscribed=true`

Interpretation:

- The reconnect/discovery path is noisy and can temporarily leave the session half-ready.
- This interacts badly with queued status/sync/live commands.
- The app eventually becomes ready, but commands may already have been attempted in bad states.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1461)
- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1494)

### 3. Quick live measurement still opens sync sessions

Observed repeatedly before live measurement:

- `→ write 02 00 ff ff ff ff 00 01 00`

Interpretation:

- This is `Command.syncAll`.
- It is still being used in the quick live read path.
- Frequent measurement therefore still depends on a sync-open sequence, which is undesirable for dense daytime sampling and risks interference with history behavior.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:548)
- [ios/OpenCircuitKit/Sources/OpenCircuitKit/Opcodes.swift](<repo-root>/ios/OpenCircuitKit/Sources/OpenCircuitKit/Opcodes.swift:34)

Important protocol note already in code:

- `syncAll` is explicitly documented as not fully ground-truthed and potentially risky for backlog behavior.

### 4. HR live measurement succeeds

Observed:

- `live HR warmup: byte2=8 ...`
- `live HR LOCKED: 78 bpm`

Interpretation:

- The live HR path is working.
- The ring can be polled successfully.
- The sensor can converge to a valid HR lock under current protocol handling.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1787)

### 5. SpO2 live measurement succeeds

Observed:

- `live SpO2: 98%`
- `live SpO2: 96%`
- `live SpO2: 99%`
- `live SpO2: 100%`

Interpretation:

- The live SpO2 path is also working.
- The ring can produce repeated spot values at a useful cadence when in SpO2 mode.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1797)

### 6. Status snapshots succeed often enough for temp and steps

Observed many times:

- `status frame: stepsRaw=... total=... batt=82% charging=false ... temp=35.55`
- temperature changing through values like `35.45`, `35.70`, `35.75`, `34.90`, `33.55`, `32.95`

Interpretation:

- The ring is already surfacing repeated status snapshots.
- These snapshots contain:
  - step counter
  - battery
  - charging state
  - skin temperature
- Skin temperature and steps therefore already have a credible dense acquisition path while connected.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1582)
- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1622)

### 7. Some history epochs are decoded and persisted

Observed:

- `← 0x4c sleep page ... → records=1`
- `← 0x4c sleep page ... → records=3`
- `hr-diag: bulkRecords=3 decodedHR=3 hrSamplesPreIngest=3`
- `hr-diag: persist call hrIn=3 hrIngested=3`

Interpretation:

- The history path is not completely failing.
- OpenCircuit can decode HR from history epochs and store them in at least some cases.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1348)
- [ios/OpenCircuitKit/Sources/OpenCircuitKit/BulkSleep.swift](<repo-root>/ios/OpenCircuitKit/Sources/OpenCircuitKit/BulkSleep.swift:354)

### 8. Some successfully decoded HR samples are not ingested

Observed more than once:

- `hr-diag: bulkRecords=1 decodedHR=1 hrSamplesPreIngest=1`
- followed by `hr-diag: persist call hrIn=1 hrIngested=0`

Interpretation:

- The ring produced a valid raw HR sample.
- `BulkSleep.samples(...)` produced a `QuantitySample`.
- `persist(_:)` handed that sample to `LocalStore.ingest(...)`.
- `LocalStore.ingest(...)` did not return it as newly stored.

This is the strongest evidence for the user's reported issue:

- capture happened
- recording did not always happen

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:903)
- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:274)

Likely reasons:

- duplicate rejection by `SyncCursor`
- plausibility rejection
- timestamp ordering/watermark issue
- save failure

Current problem:

- the app does not emit durable structured reasons for rejection
- `persist(_:)` uses `try?`, so failures can be swallowed silently

### 9. Sleep staging still fails in these runs

Observed repeatedly:

- `sleep-diag: union=7 nightRecords=7 temps=0 mainSleep=nil`

Interpretation:

- The archive contains some records.
- They are insufficient for `BulkSleep.mainSleep(...)` to identify an overnight block.
- Therefore sleep interpretation remains fragile under the current reconnect/sync pattern.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1341)

Why this matters:

- The user's goal is not only denser vitals logging.
- They also want sleep determination to benefit from the denser data.
- The current session pattern is still too unstable for that.

### 10. Activation watchdog emits false-looking warnings during unstable sessions

Observed:

- `activation: subscribed but no data frame in 10.000000s — ring likely not activated/bonded (#54)`

But the same overall log also contains:

- status frames
- 0x47 pages
- 0x4c pages
- HR locks
- SpO2 values

Interpretation:

- This warning is too coarse under reconnect churn.
- It may be accurate in some cases, but in this run it appears alongside successful data exchange later.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:629)

### 11. Step counter resets occur mid-day

Observed:

- `steps: mid-day counter reset 1→0 — counting 0 as new (handoff/reboot/wrap)`
- `steps: mid-day counter reset 51→0 — counting 0 as new (handoff/reboot/wrap)`

Interpretation:

- The session/ring can reset the raw day counter during the day.
- OpenCircuit preserves the total-day interpretation, which is acceptable for the home screen.
- But this confirms that steps are still modeled only as a daily rollup, not as a robust timestamped time series.

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1598)
- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:789)

## What the Log Proves

The log is strong evidence that OpenCircuit is beyond the stage of "it cannot measure these metrics."

Confirmed from this run:

- HR live capture works
- SpO2 live capture works
- repeated status snapshots work
- skin temperature is available frequently while connected
- steps/status data is available while connected
- some history HR epochs decode and store successfully

Therefore, for the next development session, the working assumption should be:

- the ring can already provide enough data for denser local trend capture for some metrics
- the primary issues are app-side orchestration and persistence observability

## What the Log Does Not Yet Prove

The log does not prove that OpenCircuit currently supports dense or continuous storage for every requested metric.

Still unproven from this run:

- dense HRV capture outside sleep/stillness
- dense respiratory-rate capture outside sleep/stillness
- per-hour or per-epoch historical steps archive from the ring
- durable passive continuous SpO2 history without explicit measure-mode cycling

These remain limited by current protocol coverage and storage design.

## Current Failure Boundaries

### Boundary A: BLE write attempted in invalid state

Symptoms:

- API misuse messages
- command loss during reconnect/disconnect/connecting windows

Impact:

- dropped measurement attempts
- dropped post-stop snapshots
- dropped sync open/fetch commands

### Boundary B: frequent measurement still coupled to sync-open

Symptoms:

- repeated `syncAll` open before quick live reads
- noisy `0x50` empty-history behavior around live cycles

Impact:

- frequent sampling is more disruptive than it should be
- backlog/sleep history integrity is put at risk
- measurement cadence and history cadence are unnecessarily entangled

### Boundary C: decoded sample not durably stored

Symptoms:

- `decodedHR=1 hrSamplesPreIngest=1`
- then `hrIngested=0`

Impact:

- observed readings do not reliably land in the database
- downstream trends and Health sync become sparse or misleading

### Boundary D: lack of durable audit trail

Symptoms:

- in-app activity log only knows task-level outcomes
- metric-level capture/drop/write reasons live only in transient unified logs

Impact:

- after-the-fact debugging is difficult
- next-session developers cannot determine whether loss happened at capture, decode, ingest, dedupe, or Health write

## What Needs to Change

## 1. Harden BLE write gating

Goal:

- never send ring commands unless the central is powered on, the peripheral is connected, and the session is actually ready for writes

Why:

- the current log shows real command attempts in invalid CoreBluetooth states
- denser sampling multiplies this problem

Code areas:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1448)
- the scanner/central state path that triggers reconnect attempts

Expected effect:

- fewer lost commands
- fewer false reconnect loops
- more deterministic measurement and snapshot behavior

## 2. Decouple frequent live reads from sync-open behavior

Goal:

- frequent HR/SpO2 measurement should not repeatedly open sync sessions through `syncAll`

Why:

- the current quick-read path still injects sync protocol into live sampling
- this is not a good foundation for dense or quasi-continuous measurement
- it risks interfering with history/backlog behavior

Code areas:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:531)
- [ios/OpenCircuitKit/Sources/OpenCircuitKit/Opcodes.swift](<repo-root>/ios/OpenCircuitKit/Sources/OpenCircuitKit/Opcodes.swift:34)

Expected effect:

- safer higher-frequency sampling
- less churn between measurement and history modes
- fewer empty `0x50`/mode-transition artifacts

## 3. Make ingest rejection reasons explicit and durable

Goal:

- record why a captured sample was not stored

Why:

- current `hrIngested=0` diagnostics are useful but incomplete
- future work on denser sampling will otherwise produce more unexplained drops

Code areas:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:903)
- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:274)

Minimum instrumentation to add:

- samples captured by metric
- samples decoded by metric
- samples rejected as duplicate
- samples rejected as implausible
- samples rejected because of cursor/watermark
- save failures
- samples successfully stored
- samples later written to Health

Expected effect:

- makes the recording issue diagnosable
- lets the next session verify whether denser sampling is actually landing in the DB

## 4. Stop swallowing persistence failures silently

Goal:

- failures from `LocalStore.ingest(...)` should be surfaced and recorded

Why:

- `try?` hides whether a save failed vs a sample being deduped intentionally

Code areas:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:905)

Expected effect:

- much better diagnosis of DB/store failures
- fewer "measurement happened but app did not record it" mysteries

## 5. Add first-class dense local storage lanes where data already exists

Goal:

- persist more timestamped data locally for trends and later Health mirroring

Metrics with credible existing connected paths from this log:

- HR
- SpO2
- skin temperature
- steps snapshots/deltas

Why:

- the ring already provides these frequently enough to justify richer local storage

Current limitations:

- skin temp daytime values are stored only in a separate trends-only table
- steps are stored only as daily totals
- live measurement results are not modeled as a dense metric stream with durable auditability

Relevant current storage areas:

- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:228)
- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:512)
- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:789)

Expected effect:

- better daily trend charts
- better historical analysis
- more trustworthy downstream Health mirroring

## 6. Keep Apple Health as a mirror of the local truth

Goal:

- dense local storage first, Health sync second

Why:

- the user wants better sampling for trends and app-side analysis
- Apple Health should mirror honest timestamped samples already stored locally

Current Health write path:

- [ios/OpenCircuit/Store/LocalStore.swift](<repo-root>/ios/OpenCircuit/Store/LocalStore.swift:552)
- [ios/OpenCircuit/Health/HealthKitWriter.swift](<repo-root>/ios/OpenCircuit/Health/HealthKitWriter.swift:122)

Status:

- the old shared-cursor starvation bug appears already addressed
- the bigger remaining issue is making sure the samples reach local storage first

## 7. Improve sleep robustness before claiming denser overnight interpretation

Goal:

- make overnight staging resilient enough that denser vitals logging actually helps sleep interpretation

Why:

- current logs still show `mainSleep=nil`
- if session churn prevents coherent overnight windows, denser HR alone will not fix sleep

Relevant code:

- [ios/OpenCircuit/BLE/RingSession.swift](<repo-root>/ios/OpenCircuit/BLE/RingSession.swift:1341)
- [ios/OpenCircuitKit/Sources/OpenCircuitKit/BulkSleep.swift](<repo-root>/ios/OpenCircuitKit/Sources/OpenCircuitKit/BulkSleep.swift:208)

Expected effect:

- better alignment between higher-frequency overnight data and sleep block detection

## Suggested Development Order

Recommended order for the next session:

1. fix BLE state/write gating
2. remove or redesign sync-open dependency from quick live reads
3. add structured durable observability for capture/decode/ingest/write counts and rejection reasons
4. validate that frequent HR and SpO2 measurement now land durably in local storage
5. add richer timestamped storage for skin temp and steps snapshots
6. revisit overnight sleep staging once session churn is lower

## Proposed Acceptance Checks

The next session should treat the following as concrete success criteria.

### Measurement reliability

- no CoreBluetooth API misuse warnings during ordinary connected measurement
- no writes attempted while disconnected/connecting/powered-off

### Persistence reliability

- every live HR lock increments a durable "captured HR" counter
- every successfully stored HR sample increments a durable "stored HR" counter
- if a sample is dropped, the reason is recorded

### Trend readiness

- connected status snapshots for skin temp can be seen later as a timestamped local series
- steps can be reconstructed more richly than one end-of-day total

### Health readiness

- locally stored dense samples remain pending for Health until written
- Health write statistics are visible by metric/batch, not only as one coarse "last write"

## Bottom Line

The supplied log materially supports the user's claim:

- the ring can already produce frequent measurements
- the app-side recording path is the real issue

The next development session should focus first on:

- session stability
- invalid-write prevention
- decoupling quick measurement from sync-open
- durable per-metric persistence observability

That work is a prerequisite for any credible "continuous" or denser monitoring feature in OpenCircuit.
