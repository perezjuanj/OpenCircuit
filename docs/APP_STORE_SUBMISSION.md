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
| Third-party code | Liveline (MIT, resolved 0.7.0) draws the live charts and ships its own privacy manifest. Its notice and Keyline Icons' are in `docs/THIRD_PARTY_NOTICES.md` |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` (see §5) |
| App icon / launch | `AppIcon.icon` (Icon Composer, Xcode 26), `UILaunchScreen` with `LaunchLogo` + `LaunchBackground` |
| Devices | iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`), so ASC needs iPad screenshots too |
| Developer tools | The BP calibration screens and settings, the simulator demo data and the test seams are behind `#if DEBUG`. The calibration HTTP client (`CalibrationSupport.swift`, default URL `http://127.0.0.1:8765`) still compiles into Release, but its only presenter is a Debug-only button, so nothing in Release can reach it. The ring Debug card (last frame, "RE tool" probe) is in Release behind the 7-tap unlock, see §4 |

### Changed for the store build (this branch)

- **Calibration server settings hidden in Release.** Profile showed a "Calibration server"
  section (arbitrary URL + token, raw PPG upload, "Write BP estimates to Apple Health")
  even though the flow it configures was already Debug-only. It is now Debug-only too.
- **Blood Pressure no longer requested from HealthKit in Release.** Only the Debug
  calibration flow writes BP, so asking store users for it would be a request for data
  the app never uses (guideline 2.5.1). Already-granted TestFlight installs are unaffected.
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

**Verification (2026-10-03).** The Swift changes were built and tested on a Mac as one tree
with the other PRs merged that day (#268, #270, #271): the Kit suite, the full
`OpenCircuitTests` suite and the migration gate pass, and a Release build for the iOS
Simulator succeeds. Still to do on a phone with a ring or strap, in the TestFlight build:
Profile, Device Info and a workout start.

## 2. App Store Connect checklist (owner)

1. **Agreements**: Paid Apps / Free Apps agreement accepted, tax and banking done if paid.
2. **App record**: bundle id above, name "OpenCircuit" (must not include RingConn or
   Amazfit), primary category **Health & Fitness**, SKU.
3. **URLs**: Privacy Policy
   `https://github.com/perezjuanj/OpenCircuit/blob/master/docs/PRIVACY.md` (master carries
   the current policy once this change is merged). Support URL
   `https://github.com/perezjuanj/OpenCircuit/issues` or a page on standardsoftware.io.
4. **App Privacy label**: "Data Not Collected". True as long as nothing leaves the
   device without the user choosing to share a file.
5. **Age rating**: claim no medical or treatment information (the app gives no diagnosis,
   treatment or medication guidance) and do claim health or wellness topics, with no
   other content flags. Apple's age-rating table puts that at 9+. Claiming "infrequent"
   medical or treatment information moves the rating to 13+, and "frequent" to 16+.
6. **Regulated medical device status**: required because the category is Health &
   Fitness. Declare **No** for the EU/EEA, UK and US. The app is not FDA-cleared,
   CE-marked or registered, and says it is not a medical device.
7. **EU Digital Services Act trader status**: ASC asks once per account, even if the app
   is not sold in the EU. Decide whether you act as a trader (for business purposes). If
   yes, the address, phone number and email you give are shown on the product page in the
   EU, so use business contact details.
8. **Description**: name Apple Health explicitly (HealthKit apps must say so), say
   "works with RingConn Gen 2/Gen 3 rings and the Amazfit Helio Strap", add "not
   affiliated with RingConn or Zepp Health", and "not a medical device". No words like
   diagnose, detect, apnea, blood pressure, or medical-grade.
9. **Screenshots**: iPhone 6.9" (1320 x 2868) and iPad 13" (2064 x 2752) sets. Demo data
   from a Debug simulator build (`-OCDemoData`) is fine, or use your own; no RingConn or
   Zepp logos.
10. **Review notes and demo video**: the reviewer has no ring or strap, so attach a short
    screen recording of pairing, a sync, the Today screen and the Apple Health
    permission sheet, and paste the notes in §3.
11. **Export compliance**: confirm the answer in §5 when ASC asks.
12. **Build**: bump `CURRENT_PROJECT_VERSION`, archive Release with Xcode 26, upload,
    then test that exact build from TestFlight on a phone before submitting.
13. **Xcode privacy report**: in Organizer, right-click the archive ▸ Generate Privacy
    Report, and confirm the Liveline package adds no undeclared required-reason API.
    Checked on 2026-10-03: Liveline 0.7.0 ships its own `PrivacyInfo.xcprivacy`, its
    sources use no network or required-reason API, and the Release binary imports no
    `stat`-family symbol. Still run the report on the real archive.
14. **Accessibility Nutrition Labels** (optional for now; Apple says they become
    mandatory over time): claim only what you have tested on a phone, among VoiceOver,
    Larger Text, Dark Interface, Differentiate Without Color Alone, Sufficient Contrast and
    Reduced Motion.

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
> - location: used only while the user is recording a workout. Outdoor workouts map the
>   GPS route written to Apple Health as an HKWorkoutRoute. For indoor workouts there is an
>   opt-in setting, off by default (Profile ▸ Settings ▸ Workouts ▸ "Keep tracking when
>   screen is off"), that keeps a low-accuracy location session running so heart-rate
>   recording from the wearable continues while the phone is locked; no location is
>   stored, and the setting explains the blue indicator and battery cost. Location is
>   never used outside a workout, and only When In Use permission is requested.
>
> HealthKit: the app writes heart rate, HRV, SpO₂, temperature, respiratory rate, sleep,
> steps, energy, workouts, menstrual flow and headache logs, and reads back the same
> types to show trends. HealthKit background delivery of the iPhone's step count is used
> only to time background syncs for the strap.
>
> The app is not a medical device and shows that disclaimer in onboarding, in Profile,
> and next to every alert and experimental estimate.
>
> Seven taps on the version line at the bottom of Profile reveal a diagnostics card (the
> last sync frame and a protocol probe that asks the ring for history on test channels).
> It is there for our own TestFlight debugging and collects or sends nothing off the
> device.

## 4. Guideline risks still open (owner judgement)

- **Indoor keep-alive (2.5.4)**: kept by owner decision (2026-10-03). Guideline 2.5.4
  allows the `location` background mode for location features, and the indoor option
  uses it only to stay awake. It is opt-in and justified in the review notes; if review
  rejects it, hide the Profile ▸ Workouts toggle in Release and stop both readers of
  `workout.indoorKeepAlive` (`WorkoutSessionManager`, `StrapWorkoutRecorder`) from honouring it.
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

- **Hidden diagnostics card (2.3.1)**: reachable in Release after 7 taps on Profile's
  version line, and disclosed in the review notes. Its "RE tool" row (`activityProbeRow`
  in `ContentView.swift`) asks the ring for history on five channel numbers the official
  app never uses. To carry no risk, wrap that row in `#if DEBUG`; TestFlight testers then
  lose the probe but keep the rest of the card.
- **Dead calibration code in Release**: `CalibrationSupport.swift` (HTTP client, default
  `http://127.0.0.1:8765`) compiles into Release with no way to reach it, so the binary
  contains `URLSession` calls although the app makes no network request. Wrap the file's
  types in `#if DEBUG` in a follow-up if a review asks.

## 5. Export compliance

What the binary contains: AES-128 through CommonCrypto (`ZeppAES`), NIST B-163 elliptic-curve
Diffie-Hellman implemented in the app (`B163.swift`, a port of the public-domain
tiny-ECDH-c, because CryptoKit has no binary curves), and SM3 for the ring's challenge
response (`RingAuth`). All three are published standards; none is proprietary. They only
authenticate to and exchange data with the user's own wearable, and the app's primary
function is health tracking, not information security, communications or storage. On that
basis the plist declares `ITSAppUsesNonExemptEncryption = false`.

Apple's export-compliance page lists apps using standard algorithms or the OS's crypto
among those that need a determination, and says you carry the liability for claiming an
exemption inaccurately. So this is the owner's declaration, not legal advice: read BIS's
encryption guidance once, and if you disagree with the basis above, answer ASC's
questionnaire instead of relying on the plist key (and file the annual self-classification
report if it says so).
