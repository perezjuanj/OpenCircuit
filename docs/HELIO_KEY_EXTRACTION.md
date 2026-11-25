# Getting your Amazfit Helio Strap's auth key

_Researched 2026-09-30 for #215. Methods break whenever Zepp changes its servers. Every
method below carries the most recent date we found showing it working. Re-check before
relying on this page._

## What the key is, and why you need it once

The Helio Strap refuses to share its stored history (sleep, HRV, SpO₂, temperature, steps…)
with any app that doesn't prove it knows a secret **auth key**. That key is 16 bytes, shown
as 32 hexadecimal characters (e.g. `0123456789abcdef0123456789abcdef`, sometimes written with
a `0x` in front). It is created by **Zepp's servers** when you pair the strap in the Zepp
app. There is no known way to create it on the phone or on the strap.
([Gadgetbridge: Huami/Xiaomi server pairing](https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/))

So the one-time cost of using a Helio Strap with OpenCircuit is:

1. pair the strap in the official Zepp app once;
2. get the key from your Zepp account: in the app if you sign in to Zepp with an email and
   password (Method 0), otherwise on a computer (Methods 1 and 2);
3. paste it into OpenCircuit (Method 0 saves it for you).

After that OpenCircuit talks only to the strap. Syncing sends nothing to Zepp.

**Treat the key like a password.** Anyone with it and physical Bluetooth range can read your
strap's health data. Don't post it in bug reports or screenshots. OpenCircuit keeps it in
the iOS Keychain.

## Good to know

- **Zepp can stay installed.** While Zepp is running it can take the strap's link, and a sync in
  OpenCircuit then reports the strap busy. If that happens, close Zepp or turn off its Bluetooth
  (Settings ▸ Zepp ▸ Bluetooth). Start workouts in OpenCircuit (Activity tab ▸ Workout).
- **Never unpair the strap in Zepp.** It invalidates the key (see below).
- **The first sync shows what the strap still holds**, often about a week. History then builds up
  day by day, so a short first sync is not a fault.
- Firmware updates for the strap are done in the Zepp app. OpenCircuit is iPhone only.

## What invalidates the key

| Action | Effect | Source |
|---|---|---|
| **Unpairing** the strap in the Zepp app | key is invalidated; you must pair again and fetch a new key | Gadgetbridge pairing page (above) |
| **Factory reset** of the strap | the Bluetooth address changes, so you need a new key | same |
| Re-pairing in Zepp | issues a new key (follows from the two rows above) | inference |
| Reading the key (any method below) | **no effect**; it's a read-only lookup of your account | huami-token README; inference |
| Using the same key in several apps | works; the key is a shared secret, not a login session | Gadgetbridge wiki, per research notes (not re-verified) |

That is why the last step below says **delete** the Zepp app rather than "remove device".

## Before you start (all methods)

- **Pair, sync and update the strap in the Zepp app first.** The key only exists on Zepp's
  servers after pairing. The huami-token README asks for "pair, sync and update" before
  fetching.
- **Know how you log in to Zepp.** Methods 0 and 2 need a Zepp/Amazfit account with an **email and
  password**. If you signed up with Apple, Google or another social login, Methods 0 and 2 won't
  work. The huami-token README says to create an email/password account in that case. Method 1
  uses the Zepp website's own login, which may support social login. We could not confirm that.
- **Methods 1 and 2 need a computer (Mac, Windows or Linux).** Only Method 0 works from an
  iPhone alone, and only for email-and-password accounts (see "Methods compared" below).

## Method 0 (easiest): in the app, with an email-and-password Zepp account

_No computer, under a minute. Last confirmed: 2026-11-25, against a real Helio Strap account._

1. In OpenCircuit, open **Profile ▸ Device ▸ Amazfit Helio Strap**.
2. Tap **Get the key from my Zepp account** and sign in with the **email and password** of the
   Zepp account your strap is paired to.
3. OpenCircuit reads the strap's key, saves it in the Keychain, signs out of Zepp and connects.
   If the account has more than one device with a key, pick the Helio Strap from the list (only
   the last part of each Bluetooth address is shown).

**Limits, stated in the app too:**

- **Email and password accounts only.** If you sign in to Zepp with Google, Apple, Facebook or
  another account, there's no password this can use. Use Method 1 instead.
- Your email and password go **straight from the phone to Zepp's servers, once**. OpenCircuit
  doesn't save them, and signs out of Zepp right after. It is the only time OpenCircuit contacts
  any vendor server, and only when you tap the button.
- It uses the same sign-in requests as the Zepp app (ported from
  [huami-token](https://codeberg.org/argrento/huami-token), used with its author's permission).
  If Zepp changes them, it stops working; Method 1 still works then.
- It talks to Zepp's US servers, as huami-token does. We haven't confirmed EU or China accounts;
  if sign-in fails for yours, use Method 1.

## Method 1 (recommended): Zepp website + Gadgetbridge's console snippet

_No installs, about 5 minutes. Last confirmed: listed as a current method on Gadgetbridge's
pairing page, fetched 2026-09-30. The page itself carries no date._

1. On the computer, open **https://watchface.zepp.com/** and sign in with the **same Zepp
   account** your strap is paired to.
2. In the same browser tab, open Gadgetbridge's instructions at
   **https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/** and find the section for
   the Zepp watchface website. Copy the snippet from **that page only**. Never paste code
   from anywhere else into a browser console: that is how account-stealing scams work.
3. Go back to the watchface.zepp.com tab and open the browser's developer console:
   - Chrome / Edge / Brave: `Ctrl+Shift+J` (Windows/Linux) or `Cmd+Option+J` (Mac);
   - Firefox: `Ctrl+Shift+K` / `Cmd+Option+K`;
   - Safari (Mac): first enable **Settings › Advanced › "Show features for web developers"**,
     then `Cmd+Option+C`.
4. Paste the snippet and press Enter. Some browsers first ask you to type something like
   `allow pasting`. Do that, then paste again. Allow a pop-up if the page asks.
5. The output lists your devices. Find the entry for the Helio Strap and, inside its
   `additionalInfo`, the value after **`"auth_key":`**. It is 32 characters of `0-9` and `a-f`.
   If you have several devices, match the strap by its name or MAC address.
6. Copy those 32 characters (with or without `0x`) into OpenCircuit.
7. Close the tab. Optionally sign out of watchface.zepp.com.

The snippet (also from the Gadgetbridge page):

```javascript
(()=>{try{
    const zeppCookie = document.cookie.match("hm-user-login-info=(.*?);")?.[1]?.replaceAll("%2C", ",");
    var userCredentials = {};
    if (zeppCookie) {
        userCredentials = JSON.parse(decodeURI(zeppCookie))["token_info"];
    } else {
        userCredentials = {
            'user_id': document.cookie.match("userid=(.*?);")?.[1]?.replaceAll("%2C", ","),
            'app_token': document.cookie.match("apptoken=(.*?);")?.[1]?.replaceAll("%2C", ",")
        };
    }
    if (!userCredentials.user_id) {
        throw new Error("Account was not found, make sure you've currently visiting and signed in https://watchface.zepp.com/");
    }
    console.log("Your user credentials is:");
    console.log(userCredentials);
    const userId = userCredentials["user_id"];
    console.log("User ID:", userId);
    fetch(`https://api-mifit-us3.zepp.com/users/${userId}/devices` + "?" + new URLSearchParams({
        "appid": "2882303761517383915", "channel": "play", "enableMultiDevice": "true", "device_type": "android_phone",
        "cv": "151262_8.7.1-play", "device": "android_33", "v": "2.0", "lang": "en_US", "country": "US"
    }), { method: "GET", headers: {
        "User-Agent": "Zepp/8.5.3-play (2201116SG; Android 12; Density/2.525)",
        "apptoken": userCredentials["app_token"],
        "channel": "play", "appname": "com.huami.midong", "appplatform": "android_phone",
        "cv": "151262_8.7.1-play", "v": "2.0", "lang": "en_US", "country": "US",
        "hm-privacy-diagnostics": "false", "hm-privacy-ceip": "true"
    }}).then((x) => x.json()).then((d) => {
        const linkedDevices = d["items"];
        if (!linkedDevices.length) { throw new Error("There is no device found linked to this account.") }
        const devicesData = new Blob([JSON.stringify(linkedDevices)], { type: "application/json" });
        if (!window.open(URL.createObjectURL(devicesData))) { console.log("Listing linked devices below:"); console.log(linkedDevices); }
    })
}catch (e){alert(`An error is detected.\n${e}\n\nIf this script doesn't work, make sure to report this issue and try another browser or other methods.`)}})();
```

**If it fails:**
- *An empty list, or no `auth_key`*: the strap isn't paired to this account, or hasn't synced
  yet. Open Zepp, let it sync, and try again.
- *An error about the account or token*: sign out and back in on watchface.zepp.com. The snippet
  uses the login the website stored in your browser. Region: the snippet calls a US Zepp API
  host. We haven't confirmed whether EU or China accounts need a different host. If it fails
  for you, use Method 2.
- *The key is rejected in OpenCircuit ("wrong auth key")*: the strap was unpaired, re-paired
  or reset after you copied it. Fetch it again.

## Method 2 (fallback): the `huami-token` script

_Needs Python and a terminal, about 15–30 minutes the first time. Last confirmed: maintainer
removed the README's "not working" notice on **2026-02-24**, after Zepp changed its login API in
September 2025 and broke the tool for about five months. One user still reported a login
failure on 2026-02-26 (issue #127, open, no diagnosis)._
([codeberg.org/argrento/huami-token](https://codeberg.org/argrento/huami-token))

1. Install **Python 3.10 or newer** and the **`uv`** tool.
2. Download the project from codeberg (clone it), then install it from source as its README
   describes. The README says the PyPI package is outdated, so don't use `pip install huami-token`.
3. Run it with the Amazfit method, your Zepp **email and password**, and the Bluetooth-keys
   option. The README shows the exact command (`--method amazfit … --bt_keys`).
4. The output lists your devices with a key for each. Copy the Helio Strap's 32-character key
   into OpenCircuit.

**Failure modes:** social-login accounts (Apple/Google) can't sign in, so create an
email/password Zepp account and pair the strap under it. HTTP `401` means wrong email or
password. `400`/`429` responses and "cannot login" were the symptoms of the 2025 API change;
if they come back, the tool is broken again, so check its issue tracker. The Xiaomi-account
mode is currently broken by Xiaomi's 2FA (issue #119, April 2026), but that mode doesn't apply
to the Helio Strap.

## After you have the key

1. Paste it into OpenCircuit and let it connect and sync once.
2. **Delete the Zepp app** from your phone. **Don't** use "Remove device"/unpair inside Zepp.
   Unpairing invalidates the key. Deleting the app also stops Zepp from grabbing the Bluetooth
   connection away from OpenCircuit. (Gadgetbridge gives the same advice for all Zepp devices.)
3. Keep a copy of the key in your password manager. If you ever reinstall OpenCircuit, you can
   paste it again without touching Zepp.

Once Zepp is gone, the strap's firmware stays at its current version. That's stable, but you
won't get updates. If you need Zepp back later (for a firmware update, say), reinstall it and
sign in. **Don't** re-pair unless it forces you to. If it does, fetch a new key afterwards.

## Methods compared

| Method | Needs | Account type | Strap paired in Zepp first | Works from iPhone only | Breaks Zepp pairing | Last seen working |
|---|---|---|---|---|---|---|
| 0. In the app ("Get the key from my Zepp account") | iPhone only | **email + password** Zepp/Amazfit account | yes | **yes** | no | 2026-11-25 (real account) |
| 1. watchface.zepp.com + console snippet | computer + desktop browser | whatever the website accepts (social login unconfirmed) | yes | no (iPhone Safari has no console without a Mac) | no | listed as current 2026-09-30; no dated user report found |
| 2. `huami-token` (`--method amazfit`) | computer + Python 3.10+ + `uv` | **email + password** Zepp/Amazfit account | yes | no | no | README fix 2026-02-24 (one open failure report 2026-02-26) |
| 3. Rooted Android: read the key from the Zepp app's database | rooted Android phone | any | yes | no | no | undated (long-standing technique) |
| 4. HelioCore (third-party iOS app that logs into Zepp for you) | building it from source in Xcode; unlicensed | email + password | yes | yes, if you can build and sign an app | no | repo 2026-06-03 (single initial commit) |
| `huafetcher` | listed by Gadgetbridge; steps not verified | ? | yes | ? | no | not verified |
| Mi Fitness log grep / Xiaomi cloud token extractor | Xiaomi account + Android | Xiaomi | — | — | — | **not applicable**: those cover Xiaomi-ecosystem devices, not Zepp |

OpenCircuit used to refuse to sign in to Zepp at all (plan of record §3). Since 2026-11-25 it
offers Method 0 as an **opt-in, one-time** lookup: syncing still never contacts Zepp, nothing is
saved but the key, and the paste-a-key path stays for everyone else.

## Sources (fetched 2026-09-30)

- Gadgetbridge, "Huami/Xiaomi server pairing": https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/ (methods, the unpair/reset warnings; undated page)
- Gadgetbridge Amazfit device list, Helio Strap entry: https://gadgetbridge.org/gadgets/wearables/amazfit/#device__amazfit_helio_strap (pair in the vendor app first, then obtain the key)
- huami-token: https://codeberg.org/argrento/huami-token (latest commit 2026-02-24 "readme: remove not-working message"). Issues: #118 (2025-09-24, API change broke login), #119 (fix, released as 0.8.0 around Feb 2026; Xiaomi mode still broken in April 2026), #127 (2026-02-26, open login failure)
- Gadgetbridge issues confirming users past the key step on a Helio Strap: #5799 (2026-02-15), #5843 (2026-03-06), #5986 (2026-04-08, firmware 3.11.0)
- Amazfit support, "How to set the heart rate push function?": https://support.amazfit.com/us/amazfit_helio_strap/docs/GyUIdtHLvoMqNUxOkuNcQB4hn4d (relevant to OpenCircuit's no-key live-HR tier)
