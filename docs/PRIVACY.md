# Privacy Policy — OpenCircuit

_Last updated: 2026-10-03_

OpenCircuit is an independent, **local-first** app that reads health metrics from a
compatible wearable (a RingConn Gen 2 or Gen 3 smart ring, or an Amazfit Helio Strap)
over Bluetooth and writes them into Apple Health on your device. This policy explains
what the app does and does not do with your data.

## The short version

- **OpenCircuit has no servers and no account.** Nothing you record is uploaded
  anywhere by this app.
- Your health data stays **on your device**: in the app's local storage and, if you
  authorize it, in **Apple Health**.
- We do **not** collect, sell, share, or use your data for advertising or analytics.

## What data the app handles

- **Health and fitness metrics** read from your wearable: heart rate, heart-rate
  variability, blood oxygen (SpO₂), skin temperature, respiratory rate, sleep stages,
  steps, workouts, and related activity values.
- **Apple Health data you allow it to read**, such as sleep, heart rate, and activity,
  used to show your trends and personal baselines. If you turn on background syncing
  for the Helio Strap, the app also reads your iPhone's step count, only to know when
  to sync.
- **Things you enter yourself**: profile inputs (age, height, weight, sex, goals),
  and optional period logs and headache logs. These are used only for on-device
  calculations and, if you allow it, written to Apple Health.
- **Your Helio Strap's pairing key**, which you enter once. It is stored in the
  iOS Keychain on your device and is only ever sent to your own strap.
- **Bluetooth** is used to connect to your wearable. **Location** is used **only
  during an active workout**: to map outdoor routes, and, if you turn on "Keep
  tracking when screen is off", to keep indoor workouts recording while your phone is
  locked (no location is stored then). It is never used at any other time and routes
  are not uploaded.
- **Notifications** (if you allow them) are scheduled on your device for the health
  alerts and reminders you turn on.

## Where the data goes

- Stored locally on your device in the app's database. Like any app data, it is
  included in your own device backups (iCloud or computer) under your Apple ID.
- Written to **Apple Health** only after you explicitly grant permission. Data in
  Apple Health is governed by Apple's privacy protections and your Health settings.
- Exported **by you** only: health-data exports (CSV/JSON) and the optional
  diagnostics file (device and sync details, which can include health readings, used
  for troubleshooting) are created only when you ask, and saved where you choose or
  shared through the iOS share sheet. Files the app saves in its Documents folder are
  visible to you in the Files app. Once you share a file, it is outside the app's
  control.

## What we do **not** do

- No analytics, tracking, advertising, or third-party data SDKs.
- No transmission of your health data to OpenCircuit or any third party.
- No cloud account or sign-in.
- No use of HealthKit data for advertising, marketing, or data mining, and no
  storage of HealthKit data in iCloud by the app.

## Your control

- Revoke Apple Health access anytime in **Settings ▸ Health ▸ Data Access &
  Devices**, or in the Health app.
- Turn off Bluetooth, Location, or Notifications access anytime in **Settings ▸
  OpenCircuit**.
- Delete the app to remove its local data. iOS keeps Keychain items after an app is
  deleted, so to remove your Helio Strap key too, tap **Forget Key** in the strap's setup
  screen (Device Info ▸ Replace or forget the key) before deleting the app. Data already
  written to Apple Health is managed in the Health app.

## Not a medical device

OpenCircuit is **not a medical device** and does not provide medical advice or
diagnosis. Readings are derived from consumer wearable sensors and may be inaccurate.
Features marked experimental are wellness estimates only. Consult a qualified
professional for health concerns.

## Not affiliated with RingConn or Zepp

OpenCircuit is an independent interoperability project. It is **not affiliated with,
authorized, or endorsed by** RingConn, JZ_Tech, Zepp Health, or Amazfit. "RingConn",
"Amazfit", and "Helio" are trademarks of their respective owners.

## Children

OpenCircuit is not directed at children under 13 and does not knowingly handle their
data beyond what is stored on the user's own device.

## Changes

If this policy changes, the updated version is published at this address with a new
"Last updated" date.

## Contact

Questions: open an issue at the project's GitHub repository,
<https://github.com/perezjuanj/OpenCircuit/issues>.
