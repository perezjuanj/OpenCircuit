# App Store submission — OpenCircuit 1.0

What the store build must look like, what was changed in the repo for it, and what the
owner still does in Xcode and App Store Connect (ASC). `docs/TESTFLIGHT.md` covers the
archive and upload mechanics; this file covers review.

## 1. Repo state for the store build (audited 2026-10-03)

| Area | State |
|---|---|
| Bundle ids | `com.standardsoftwaresolutions.opencircuit`, extension `…opencircuit.WorkoutWidget`, team `765RD9BJ8C`, automatic signing |
| Version / build | `MARKETING_VERSION` 1.0, `CURRENT_PROJECT_VERSION` in `ios/project.yml` (project level, shared by app and extension). Bump before every upload |
| Usage strings | Bluetooth, Health share, Health update, Location When In Use. No Always location is requested. Notifications need no string |
| Entitlements | HealthKit + HealthKit background delivery. No iCloud, no push, no App Groups |
| Background modes | `bluetooth-central`, `location`, `fetch`, `processing` (+ two BGTask ids). Each has a justification in §3 |
| Privacy manifest | `ios/OpenCircuit/PrivacyInfo.xcprivacy`: no tracking, no collected data, UserDefaults `CA92.1`. No other required-reason API is used by app code (file size via `fileSizeKey` is not a required-reason API) |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` (see §5) |
| App icon / launch | `AppIcon.icon` (Icon Composer, Xcode 26), `UILaunchScreen` with `LaunchLogo` + `LaunchBackground` |
| Devices | iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`), so ASC needs iPad screenshots too |
| Developer tools | Reverse-engineering capture tools, the BP calibration flow, simulator demo data and test seams are all behind `#if DEBUG`. Release builds contain none of them |

### Changed for the store build (this branch)

- **Calibration server settings hidden in Release.** Profile showed a "Calibration server"
  section (arbitrary URL + token, raw PPG upload, "Write BP estimates to Apple Health")
  even though the flow it configures was already Debug-only. It is now Debug-only too.
- **Blood Pressure no longer requested from HealthKit in Release.** Only the Debug
  calibration flow writes BP, so asking store users for it would be a request for data
  the app never uses (guideline 2.5.1). Already-granted TestFlight installs are unaffected.
- **Indoor workout keep-alive hidden in Release.** It ran a location session purely to
  keep the app alive during indoor workouts, which guideline 2.5.4 does not allow for the
  `location` background mode. Outdoor workouts still record a GPS route as before. A
  stored opt-in from an earlier TestFlight build is ignored in Release.
- **Ring debug card hidden in Release until unlocked.** Profile showed every ring user a
  "Debug — last sync & frame" card with raw hex and an "RE tool" probe. Debug builds still
  show it; store and TestFlight builds show it after **7 taps on the version line** at the
  bottom of Profile (7 more hide it). A TestFlight-only check can't be used, because App
  Review runs builds with the same sandbox receipt. Tell TestFlight testers about the taps.
- **"Sleep apnea assessment" renamed** to "Overnight blood-oxygen check", with copy that
  says it is a wellness estimate and can't tell you whether you have sleep apnea. The
  Sleep card already labels the result experimental and not a diagnosis. Naming a
  condition the app is not cleared to assess is a guideline 1.4.1 risk.
- **Health read usage string** now says the app reads Apple Health data (sleep, heart
  rate, activity) for trends and baselines, which is what it does.
- **Privacy policy** (`docs/PRIVACY.md`) updated for the Helio Strap, the Keychain key,
  steps read for background sync, period and headache logs, notifications, diagnostics
  export and Files visibility.

**Needs a Mac build before merge.** None of the Swift changes have been compiled. Build
Release for a device, run `OpenCircuitTests`, and check Profile, Device Info and a
workout start on the phone.

## 2. App Store Connect checklist (owner)

1. **Agreements**: Paid Apps / Free Apps agreement accepted, tax and banking done if paid.
2. **App record**: bundle id above, name "OpenCircuit" (must not include RingConn or
   Amazfit), primary category **Health & Fitness**, SKU.
3. **URLs**: Privacy Policy
   `https://github.com/perezjuanj/OpenCircuit/blob/master/docs/PRIVACY.md` (merge this
   branch first so it is current). Support URL
   `https://github.com/perezjuanj/OpenCircuit/issues` or a page on standardsoftware.io.
4. **App Privacy label**: "Data Not Collected". True as long as nothing leaves the
   device without the user choosing to share a file.
5. **Age rating**: answer "Medical/Treatment Information: Infrequent/Mild"; no other
   content flags.
6. **Description**: name Apple Health explicitly (HealthKit apps must say so), say
   "works with RingConn Gen 2/Gen 3 rings and the Amazfit Helio Strap", add "not
   affiliated with RingConn or Zepp Health", and "not a medical device". No words like
   diagnose, detect, apnea, blood pressure, or medical-grade.
7. **Screenshots**: iPhone 6.9" and iPad 13" sets. Use real data, no RingConn or Zepp
   logos.
8. **Review notes and demo video**: the reviewer has no ring or strap, so attach a short
   screen recording of pairing, a sync, the Today screen and the Apple Health
   permission sheet, and paste the notes in §3.
9. **Export compliance**: confirm the answer in §5 when ASC asks.
10. **Build**: bump `CURRENT_PROJECT_VERSION`, archive Release with Xcode 26, upload,
    then test that exact build from TestFlight on a phone before submitting.
11. **Xcode privacy report**: in Organizer, right-click the archive ▸ Generate Privacy
    Report, and confirm the Liveline package adds no undeclared required-reason API.

## 3. Review notes (paste into ASC)

> OpenCircuit reads health data from the user's own wearable (a RingConn Gen 2/Gen 3
> smart ring or an Amazfit Helio Strap) over Bluetooth Low Energy and writes it to Apple
> Health. It has no account, no server and no analytics; all data stays on the device
> and in the user's HealthKit store. A demo video is attached because the app needs the
> wearable to show data.
>
> Background modes:
> - bluetooth-central: the wearable syncs its stored history when it reconnects, so
>   Apple Health stays current without opening the app.
> - fetch / processing: scheduled background syncs (BGTaskScheduler) for the same purpose.
> - location: used only while the user is recording an outdoor workout, to map the GPS
>   route written to Apple Health as an HKWorkoutRoute. It is never used outside a
>   workout, and only When In Use permission is requested.
>
> HealthKit: the app writes heart rate, HRV, SpO₂, temperature, respiratory rate, sleep,
> steps, energy, workouts, menstrual flow and headache logs, and reads back the same
> types to show trends. HealthKit background delivery of the iPhone's step count is used
> only to time background syncs for the strap.
>
> The app is not a medical device and shows that disclaimer in onboarding, in Profile,
> and next to every alert and experimental estimate.

## 4. Guideline risks still open (owner judgement)

- **Hardware dependence (2.1 / 4.2)**: without a demo video the reviewer cannot exercise
  the app. The video is the mitigation.
- **Helio Strap key (2.1)**: pairing needs a key extracted with a computer
  (`docs/HELIO_KEY_EXTRACTION.md`). Mention it in the review notes if the strap appears
  in screenshots, so it is not read as an incomplete feature.
- **Trademarks (5.2)**: "RingConn" and "Amazfit" may appear as compatibility statements
  only, never in the app name, subtitle or icon.
- **High HR / low SpO₂ alerts (1.4.1)**: they carry the not-a-medical-device note. Keep
  their copy as "alerts", never "detection".
- **Diagnostics in Files**: `UIFileSharingEnabled` exposes exported files in the Files
  app. That is user-initiated and covered by the privacy policy.

## 5. Export compliance

The app uses SM3 hashing to authenticate to the ring, and AES-128 plus B-163 ECDH to pair
with and talk to the Helio Strap over Bluetooth. All of it only authenticates to and
exchanges data with the user's own wearable, and the app's primary function is health
tracking, not information security or communications. On that basis the plist declares
no non-exempt encryption. This is not legal advice: if unsure, answer ASC's questions as
"uses standard encryption, exempt", or file the annual self-classification report.
