import Foundation

/// The console snippet from `docs/HELIO_KEY_EXTRACTION.md` Method 1 (Gadgetbridge's, for the Zepp
/// website), kept in ONE constant so the setup screen's "Copy key snippet" button can't drift from the
/// guide. `HelioSetupCopyTests` reads the guide and asserts it contains this text exactly.
enum HelioKeySnippet {
    static let text = #"""
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
"""#
}
