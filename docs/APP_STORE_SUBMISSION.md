# App Store submission — OpenCircuit 1.0

What the store build must look like, what was changed in the repo for it, and what the
owner still does in Xcode and App Store Connect (ASC). `docs/TESTFLIGHT.md` covers the
archive and upload mechanics; this file covers review.

## 1. Repo state for the store build (audited 2026-10-03)

| Area | State |
|---|---|
| Bundle ids | `com.standardsoftwaresolutions.opencircuit`, extension `…opencircuit.WorkoutWidget`, team `765RD9BJ8C`, automatic signing |
| Version / build | `MARKETING_VERSION` 1.0, `CURRENT_PROJECT_VERSION` **58** in `ios/project.yml` (project level, shared by app and extension). Bump before every upload |
| Usage strings | Bluetooth, Health share, Health update, Location When In Use. No Always location is requested. Notifications need no string |
| Entitlements | HealthKit + HealthKit background delivery. No iCloud, no push, no App Groups |
| Background modes | `bluetooth-central`, `location`, `fetch`, `processing` (+ two BGTask ids). Each has a justification in §3 |
| Privacy manifest | `ios/OpenCircuit/PrivacyInfo.xcprivacy`: no tracking, no collected data, UserDefaults `CA92.1`. No other required-reason API is used by app code (file size via `fileSizeKey` is not a required-reason API) |
| Third-party code | Liveline (MIT, resolved 0.7.0) draws the live charts and ships its own privacy manifest. Its notice and Keyline Icons' are in `docs/THIRD_PARTY_NOTICES.md`, which also keeps the MIT text the project carried until 2026-10-04. The repo itself is PolyForm Noncommercial 1.0.0 (`LICENSE`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` (see §5) |
| App icon / launch | `AppIcon.icon` (Icon Composer, Xcode 26), `UILaunchScreen` with `LaunchLogo` + `LaunchBackground` |
| Devices | iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`), so ASC needs iPad screenshots too |
| Developer tools | The BP calibration screens and settings, the simulator demo data and the test seams are behind `#if DEBUG`. The calibration HTTP client (`CalibrationSupport.swift`, default URL `http://127.0.0.1:8765`) still compiles into Release, but its only presenter is a Debug-only button, so nothing in Release can reach it. The ring Debug section (last sync summary and last frame) is at the bottom of Profile ▸ Background Activity, in Release behind the 7-tap unlock, see §4. Its activity-channel probe ("RE tool") is compiled into Debug builds only |

### Changed for the store build

- **Calibration server settings hidden in Release.** Profile showed a "Calibration server"
  section (arbitrary URL + token, raw PPG upload, "Write BP estimates to Apple Health")
  even though the flow it configures was already Debug-only. It is now Debug-only too.
- **Blood Pressure no longer requested from HealthKit in Release.** Only the Debug
  calibration flow writes BP, so asking store users for it would be a request for data
  the app never uses (guideline 2.5.1). Already-granted TestFlight installs are unaffected.
- **Ring debug card hidden in Release until unlocked.** Profile showed every ring user a
  "Debug — last sync & frame" card with raw hex and an "RE tool" probe. Debug builds still
  show it; store and TestFlight builds show its read-only part (last sync summary, last
  frame) after **7 taps on the version line** at the bottom of Profile (7 more hide it). A
  TestFlight-only check can't be used, because App Review runs builds with the same sandbox
  receipt. Tell TestFlight testers about the taps. Once unlocked, it appears as a "Ring
  Debug" section at the bottom of Profile ▸ Background Activity, not on Profile itself (UI
  sweep, owner decision 2026-10-03). The "RE tool" activity-channel probe, the only part
  that writes to the ring, is `#if DEBUG` (owner decision 2026-10-04, build 58), so no
  store or TestFlight build can run it.
- **Maker credit moved.** "Made with love / StandardSoftware.io" sits on the Profile tab
  under the logo, name and version line. It is no longer in Profile ▸ Settings ▸ About.
- **"Sleep apnea assessment" renamed** to "Overnight blood-oxygen check", with copy that
  says it is a wellness estimate and can't tell you whether you have sleep apnea. The
  Sleep card already labels the result experimental and not a diagnosis. Naming a
  condition the app is not cleared to assess is a guideline 1.4.1 risk.
- **Health read usage string** now says the app reads Apple Health data (sleep, heart
  rate, activity) for trends and baselines, which is what it does.
- **Privacy policy** (`docs/PRIVACY.md`) updated for the Helio Strap, the Keychain key,
  steps read for background sync, period and headache logs, notifications, diagnostics
  export and Files visibility.

**Verification (2026-10-03 and 10-04).** The Swift changes were built and tested on a Mac as one
tree with the other PRs merged on 10-03/04 (#268 to #272): the Kit suite (2398 tests, 13 skipped, 0
failures), the full `OpenCircuitTests` suite (815 tests, 813 passed, 2 skipped, 0 failed) and the
migration gate (23 of 23) pass, and a Release build succeeds. The probe and credit change (build 58)
was verified the same way at its own commit (`520f93b`): the Kit suite (2398 tests, 13 skipped, 0
failures), `OpenCircuitTests` (815 tests, 813 passed, 2 skipped, 0 failed), the migration gate (23
of 23) and a Release build. Build 58 is the archive of master at `2ceda5f`, which differs from that
commit only by the version number, so the compiled code is the tested code. Build 57 (`a8930ce`)
is superseded and still contains the probe. Not tested: anything that needs a real ring or strap.
Still to do on a phone with a ring or strap, in the TestFlight build: Profile, Device Info and a
workout start.

## 2. App Store Connect checklist

Status on 2026-10-26 (resubmitted to App Review with build 88; the build 58 submission sat in Waiting for Review for 21 days and was withdrawn). *Done* means it is set in the 1.0 draft (written through the App Store
Connect API and read back). *Owner* means only the account holder can do it: a legal
declaration, a setting that has no API, or something that needs a phone and a wearable.

1. **Agreements**: *done.* The Free Apps agreement is accepted. Tax and banking are only needed
   if the app is ever paid.
2. **App record**: *done.* Bundle id above, name "OpenCircuit - Local fitness" (must not include
   RingConn or Amazfit), SKU `1111`, primary category **Health & Fitness**, subtitle "Wearable data
   to Apple Health".
3. **URLs**: *done.* Privacy Policy
   `https://github.com/perezjuanj/OpenCircuit/blob/master/docs/PRIVACY.md`; Support and Marketing
   URL `https://github.com/perezjuanj/OpenCircuit`.
4. **App Privacy label**: *owner* (no API). "Data Not Collected": App Privacy, Data Types, "No, we
   do not collect data from this app", Save, then **Publish** (top right). Until it is published
   Apple refuses the submission with `STATE_ERROR.APP_DATA_USAGES_REQUIRED`. True as long as
   nothing leaves the device without the user choosing to share a file.
5. **Age rating**: *done*, **9+**. Answers: no medical or treatment information (the app gives no
   diagnosis, treatment or medication guidance), health or wellness topics yes, every other
   question none or no. Apple's age-rating table puts that at 9+; "infrequent" medical or
   treatment information would make it 13+, "frequent" 16+. The Korean (GRAC) rating number, kids age
   band, developer age-rating URL and social-media restriction do not apply to this app and are
   left blank.
6. **Regulated medical device status**: *owner* (no API). Required because the category is
   Health & Fitness. Declare **No** for the EU/EEA, UK and US. The app is not FDA-cleared,
   CE-marked or registered, and says it is not a medical device.
7. **EU Digital Services Act trader status**: *owner* (legal declaration). ASC asks once per
   account, even if the app is not sold in the EU. Decide whether you act as a trader (for
   business purposes). If yes, the address, phone number and email you give are shown on the
   product page in the EU, so use business contact details.
8. **Description**: *done* (rewritten 2026-10-04). It names Apple Health, says "works with
   RingConn Gen 2 and Gen 3 smart rings and the Amazfit Helio Strap", and has the "not
   affiliated" and "not a medical device" lines. A script checked it for diagnose, detect,
   apnea, blood pressure and medical-grade before the write. The old text mentioned only a Gen 2
   ring.
9. **Screenshots**: *done.* iPhone 6.9" (1320 x 2868, 6 shots) and iPad 13" (2064 x 2752, 4 shots)
   are in the 1.0 draft. They come from a Debug simulator build with demo data (`-OCDemoData`) and
   show only screens that ship in Release. ASC rejects an alpha channel and the simulator writes
   RGBA, so flatten to RGB before uploading. No RingConn or Zepp logos. The earlier 5.8" and 6.5"
   sets (an old UI) were deleted.
10. **Review notes and demo video**: *done.* §3 is exactly what is saved, and the App Review
    contact is the TestFlight review contact (phone in international format, which the App Store
    Connect form requires). The demo video is attached under App Review Information as
    `OpenCircuit-App-Review-Demo.mov` (69 s, from the owner's phone, 88.5 MB, processed COMPLETE
    with a matching checksum). It shows the ring connecting, the Apple Health permission sheet, the
    Today screen with a live heart-rate measurement, the Sync from Ring and Sync to Apple Health
    buttons, and the Sleep tab. It does not show a first-time pairing or a sync running, and §3
    says only what it shows. Its Health permission sheet lists Blood Pressure, which the store
    build does not request (Debug-only since #269), so it was probably recorded from a Debug or
    pre-#269 build. The owner chose to submit with it as is, so §3 says in one sentence that the
    sheet in the recording lists Blood Pressure and the store build does not request it. A
    re-record from TestFlight build 58 can still replace it:
    `asc_upload_review_video.py --replace`.
11. **Export compliance**: *owner.* Confirm the answer in §5. The build declares
    `ITSAppUsesNonExemptEncryption = false`, so ASC does not ask again.
12. **Build**: *done*: build 58 (master `2ceda5f`) is archived with Xcode 26, uploaded, VALID,
    attached to 1.0 and in the Internal Testers group, with "What to Test" explaining the 7-tap
    unlock (and that the probe is Debug-only). Build 57 is superseded. *Owner:* install build 58
    from TestFlight on a phone with the ring or strap and use it before submitting.
    *Later TestFlight build (not the submission):* build 73 (master `8d29cc5`, version 1.0) adds the
    strap in-progress-night fix (#274) and the Recovery HRV write (#277). It was archived with
    Xcode 26.6, uploaded, VALID, approved for beta testing and added to the Internal and External
    Testers groups on 2026-10-06. The 1.0 submission above still points at build 58, so the
    App Store build does not carry either change until a later version ships them.
13. **Xcode privacy report**: partly done. Checked on 2026-10-03: Liveline 0.7.0 ships its own
    `PrivacyInfo.xcprivacy`, its sources use no network or required-reason API, and the Release
    binary imports no `stat`-family symbol. Checked on the build 58 archive: it contains the app
    manifest (no tracking, no collected data, UserDefaults `CA92.1`) and Liveline's, and embeds no
    frameworks. *Owner:* run Organizer ▸ right-click the archive ▸ Generate Privacy Report once.
14. **Accessibility Nutrition Labels**: optional for 1.0, skipped. Apple says they become
    mandatory over time. Claim only what you have tested on a phone, among VoiceOver, Larger
    Text, Dark Interface, Differentiate Without Color Alone, Sufficient Contrast and Reduced
    Motion.
15. **Price and availability**: *done.* Free (USD 0.00, base territory United States), available in
    all 175 countries and regions, including ones Apple adds later. If Submit for Review stops on
    China mainland (it can need an ICP filing number), deselect it under Pricing and Availability.
16. **Content rights**: *done.* "Does not use third-party content". The libraries and icons the
    app bundles are listed in `docs/THIRD_PARTY_NOTICES.md`.
17. **Copyright and release**: *done.* Copyright "2026 Standard Software Solutions", release after
    approval.
18. **Submit for Review**: *done.* Build 58 was submitted on 2026-10-04 and never left Waiting for
    Review, so it was withdrawn on 2026-10-26 (`canceled: true`; the version showed
    `DEVELOPER_REJECTED`, which is Apple's name for withdrawn) and the 1.0 version was resubmitted
    through the API (`asc_submit_review.py --expect-build 88`) at 07:08 UTC: build 88 (master `976707f`),
    same screenshots and demo video, review notes updated (§3: body-weight read, health alerts,
    Live Activity, Shortcuts, Recovery HRV). The plist, entitlements, background modes and privacy
    manifest are identical to build 58 (`git diff 2ceda5f origin/master` touches only the build number
    in `ios/project.yml`); the archive has no `OCDemoData`, no Blood Pressure request and the same
    export answer. Release is after approval. Withdraw with `canceled: true` on the review submission.

## 3. Review notes (as saved in ASC)

> OpenCircuit reads health data from the user's own wearable (a RingConn Gen 2/Gen 3 smart ring or an Amazfit Helio Strap) over Bluetooth Low Energy and writes it to Apple Health. It has no account, no server and no analytics; all data stays on the device and in the user's HealthKit store. Because the app needs the wearable to show data, a screen recording from a real device is attached: the ring connecting, the Apple Health permission sheet, the Today screen with a live heart-rate measurement, the Sync from Ring and Sync to Apple Health buttons, and the Sleep tab. The Apple Health permission sheet in the recording lists Blood Pressure; the App Store build does not request Blood Pressure (that request exists only in development builds).
>
> Background modes:
> - bluetooth-central: the wearable syncs its stored history when it reconnects, so Apple Health stays current without opening the app.
> - fetch / processing: scheduled background syncs (BGTaskScheduler) for the same purpose.
> - location: used only while the user is recording a workout. Outdoor workouts map the GPS route written to Apple Health as an HKWorkoutRoute. For indoor workouts there is an opt-in setting, off by default (Profile > Settings > Workouts > "Keep tracking when screen is off"), that keeps a low-accuracy location session running so heart-rate recording from the wearable continues while the phone is locked; no location is stored, and the setting explains the blue indicator and battery cost. Location is never used outside a workout, and only When In Use permission is requested.
>
> HealthKit: the app writes heart rate, HRV, SpO2, temperature, respiratory rate, sleep, steps, energy, workouts, menstrual flow and headache logs, and reads back the same types to show trends. HealthKit background delivery of the iPhone's step count is used only to time background syncs for the strap. It also reads the latest body weight from Apple Health (read-only, asked once, the first time the Calories card is shown) so calorie estimates use a current weight; the user can decline and enter weight in Profile instead.
>
> Changes since the recording: the build has been updated since the video was made. It adds wellness alerts that the user can switch off (Profile > Settings > Health alerts), including an alert when skin temperature, sleeping heart rate, HRV and breathing rate move away from the user's usual overnight values, worded as "possible illness signs" or "possible fever signs" with the line "Not a medical device or a diagnosis."; a workout Live Activity on the Lock Screen and Dynamic Island while a workout is recording; Shortcuts actions (start a workout, vibrate the wearable, set or clear a wake alarm, log a headache); and, on iOS 27 and later, the HRV value is also written to Apple Health's Recovery HRV type. Nothing in these features needs a network, an account, or any permission beyond those listed here.
>
> The app is not a medical device and shows that disclaimer in onboarding, in Profile, and next to every alert and experimental estimate.
>
> Seven taps on the version line at the bottom of Profile reveal a read-only "Ring Debug" section at the bottom of Profile > Background Activity (the last sync summary and the last raw frame received from the ring). It is there for our own TestFlight debugging, needs a ring the reviewer does not have, and collects or sends nothing off the device.
>
> Helio Strap pairing needs a key extracted with a computer (docs/HELIO_KEY_EXTRACTION.md in the GitHub repository); that is why the video shows the strap already set up.

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

- **Hidden diagnostics readout (2.3.1)**: reachable in Release after 7 taps on Profile's
  version line, read-only (last sync summary and last frame), and disclosed in the review
  notes. The part that wrote to the ring, the "RE tool" activity-channel probe
  (`activityProbeRow` in `Observability/RingDebugToolsSection.swift`, which asked the ring
  for history on five channel numbers the official app never uses), has been `#if DEBUG`
  since build 58. TestFlight testers no longer have it; run it from a Debug build. Nothing
  in Release calls the `RingSession` methods behind it, and the Release build contains none
  of their strings or symbols (checked with `nm` and string probes on the Release build of
  the tested tree, with the Debug build as the control).
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
