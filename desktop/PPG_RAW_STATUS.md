# How Far Are We From Getting the Raw PPG Sensor Optical Data?

## Objective

We are trying to determine whether the RingConn firmware exposes access to the raw PPG optical sensor data and, if it does, how to capture it reliably with our Python tooling.

## Why We Are Doing This

Raw PPG data is the direct optical waveform used for heart-rate and related physiological analysis. Access to that stream would let us:

- verify what the device is truly measuring at the sensor level
- distinguish between raw waveform data and derived health metrics
- build our own decoder and analysis pipeline outside the official app
- confirm whether sleep and OSA features are backed by a raw optical stream that can be captured over BLE

This matters because the firmware capability appears to exist. The current problem is not whether the ring can produce PPG-related optical data, but whether we have fully identified the BLE path that exposes it.

## Current Answer

We are close, but not finished.

The present status is:

- firmware capability for PPG-related data is considered confirmed
- raw PPG access is not yet proven end-to-end in our Python workflow
- the main blocker is incomplete command-space exploration
- the second blocker is the lack of a full overnight OSA-enabled capture using the Python tool before the mobile app consumes the sync

The practical estimate is that we are one completed opcode sweep and one overnight OSA capture away from a definitive answer.

## What We Have Already Done

### 1. Confirmed the right investigation area

We have narrowed the problem to BLE command discovery and sleep/OSA data capture rather than generic reverse engineering. The evidence suggests raw PPG is most likely exposed either:

- through an undocumented command in the opcode range we have not fully swept yet, or
- through the OSA/sleep pipeline where the ring may push optical data automatically

### 2. Tested known candidate command shapes

Based on the mixin naming convention:

- `CMD = RSP XOR 0x80`
- if raw PPG response opcode is `0x16`, the command would likely be `0x96`
- if raw PPG response opcode is `0x14`, the command would likely be `0x94`

Both `0x96` and `0x94` were already tested in a no-parameter form:

- `XX 00 00`

Those tests did not produce the needed result. However, that does **not** rule the commands out, because they may require non-zero or structured parameters.

### 3. Started an opcode sweep

We already began sweeping the command space to identify unknown responding opcodes. This is the correct approach because the likely raw PPG command may not be obvious from known decoded traffic alone.

### 4. Identified a critical failure in the sweep process

The sweep crashed at opcode `0x22` because testing `0x21` caused the ring to brick or lock up. As a result:

- the sweep never covered `0x22` through `0x7F`
- the most likely unexplored region for the PPG command remains untested

This is currently the single biggest gap in the command-discovery path.

### 5. Isolated the most promising passive capture path

The `BleOnlineOsaDataRspMixin` path appears to be the strongest lead for raw optical data. OSA monitoring likely relies on high-frequency LED sampling, which is effectively PPG under a different feature name.

This means the ring may expose the desired data only when OSA or sleep monitoring is active, rather than through a simple always-available manual command.

### 6. Connected the hypothesis to observed traffic

We are already seeing `0x4A` frames in the Healthops codebase as part of sleep-batch behavior. These may contain:

- PPG-derived metrics only, or
- a transport path related to richer optical data during sleep sync

At this stage, `0x4A` is important, but it is not yet proven to carry the raw waveform.

## What Has Been Completed or Re-Done

The following work is effectively complete or has already been repeated enough to treat as established:

- the initial direction-finding work on where raw PPG is likely to appear
- candidate-command reasoning using the opcode/mixin convention
- no-parameter tests of likely command candidates `0x94` and `0x96`
- partial opcode sweep up to the failure point
- identification of the sweep failure caused by `0x21`
- recognition that sleep/OSA data capture is not optional but a primary path to test

The following likely needs to be redone in a more controlled way:

- BLE pairing state on macOS, because the workflow now depends on a clean re-pair before continuing the sweep
- the opcode sweep itself, resuming from `0x22` onward after fixing the pairing and stability issue

## What We Have Now

Right now we have:

- a strong working hypothesis that raw PPG is accessible
- confirmed firmware-level support for the capability
- Python tooling ready to probe and observe BLE responses
- a partially completed opcode sweep
- identified high-value candidate opcodes and response families
- a likely alternate capture route through overnight OSA/sleep sync
- enough evidence to define a short, concrete validation plan

## What We Still Do Not Have

We still do **not** have:

- a confirmed command that starts or retrieves raw PPG data
- a completed sweep of the remaining opcode space
- parameterized tests for likely commands such as `0x94` and `0x96`
- a verified capture of raw optical waveform frames
- a full overnight OSA-enabled sync captured by Python before the app opens
- proof that `0x4A` contains raw waveform data instead of only derived metrics

## The Two Remaining Paths

### Path A: Complete the Opcode Sweep

This is the direct active-discovery path.

### Why it matters

The sweep has not covered `0x22` through `0x7F`, and the raw PPG command is very likely in the unexplored space. Until that range is covered, we cannot honestly say command discovery is complete.

### Required actions

1. Remove the ring from macOS Bluetooth.
2. Re-pair the ring cleanly.
3. Re-run the sweep from `0x22` through `0xFF`.
4. Analyze newly responding opcodes.
5. Re-test promising candidates with parameters, not only `XX 00 00`.

### Expected outcome

Either:

- we discover the raw PPG command directly, or
- we rule out the remaining command space enough to shift confidence toward the OSA-only path

### Path B: Overnight OSA Capture

This is the highest-probability passive-capture path.

### Why it matters

OSA monitoring is likely backed by high-frequency optical sampling. If the ring emits raw or near-raw optical data anywhere, this feature path has the best chance of triggering it naturally.

### Required actions

1. Enable sleep tracking in the RingConn app before sleep.
2. Keep the ring charged and worn overnight.
3. Immediately after waking, do **not** open the app first.
4. Connect using the Python script.
5. Run `probe_ppg_raw.py`.
6. Look for:
   - `0x4A` frames with significantly more payload than usual
   - new unknown opcodes that appear spontaneously during sync
   - `BleOfflineOsaDataRspMixin`-style frames pushed during the overnight data sync

### Expected outcome

Either:

- the ring pushes raw or richer optical data during OSA/sleep sync, or
- the capture shows that sleep sync only provides derived metrics and not the waveform itself

## Bottom Line

We are not blocked by missing firmware capability. We are blocked by incomplete testing.

The remaining unknowns are operational, not conceptual:

- we have not finished command-space exploration
- we have not captured an OSA-enabled overnight session in the right order

If Path A finds the command, we get raw PPG through explicit BLE control. If Path B succeeds, we get it through natural OSA/sleep synchronization. If neither path yields the waveform, then we will have strong evidence that the ring either does not expose raw PPG over accessible BLE or only exposes it under conditions we have not yet replicated.

## Realistic Time Estimate

The realistic estimate is still:

- `2-4 days` of testing to reach a definitive answer

That includes:

- fixing Bluetooth pairing and rerunning the sweep
- analyzing new opcode responses
- performing one overnight OSA-enabled capture
- confirming whether the result is raw waveform data, a gated stream, or only derived metrics

## Recommended Next Step

Do both paths, in this order:

1. finish the opcode sweep first because it is faster and may reveal the command directly
2. run the overnight OSA capture immediately after, because it has the highest probability if the stream is feature-gated

That combination should tell us, with high confidence, how far we really are from raw PPG access and whether the remaining gap is small, gated, or fundamental.
