# Installing Ruta on your iPhone

The build you were given is an **unsigned IPA** — the normal way to hand an app between people
without paying Apple for a store. The iPhone will only run apps it trusts, so before Ruta can
open, it needs a signature. You supply one yourself, for free, with your own Apple ID. Ten
minutes, once.

## What you need

- The `Ruta-unsigned-<short-sha>.ipa` file from the latest successful CI run
- Any Mac, or a Windows PC with current iTunes/iCloud (not the Microsoft Store versions)
- A USB cable for the iPhone
- The Apple ID that will sign the app (the rider's, or the gift-giver's)
- **Developer Mode on the iPhone** (see below)

## Steps

1. On the iPhone: **Settings → Privacy & Security → Developer Mode → On**, then restart and
   confirm the prompt after the restart. (If the toggle is hidden, attempting a developer install
   in Sideloadly usually makes it appear.)
2. Install **Sideloadly** on the computer — free from [sideloadly.io](https://sideloadly.io/).
3. Connect the iPhone with the cable. Unlock it and tap "Trust this computer" if asked.
4. Open Sideloadly. Drag `Ruta-unsigned-<short-sha>.ipa` onto its window.
5. Enter the signing **Apple ID**. Sideloadly signs the app with a personal certificate tied to
   that account — the app never sees the password; it goes only to Apple's signing service.
6. Click Start / Install. If Sideloadly asks for an app-specific password, create one at
   appleid.apple.com → Sign-in and Security → App-Specific Passwords and paste it. Follow the
   installed version's 2FA prompts; app-specific passwords are not required for every account
   configuration.
7. First launch: if iOS says "Untrusted Developer", go to
   **Settings → General → VPN & Device Management** → tap the signing Apple ID under
   "Developer App" → **Trust**. Now Ruta opens.

## Does a sideloaded app run like a real app?

Yes — identically. Sideloadly, SideInstaller and SideStore attach Apple's signature to the same
compiled binary; TestFlight uses a separately built, signed archive. Once installed, Ruta opens from
the home screen like any app, at full native speed, with normal Bluetooth, GPS and data storage.

Two specifics for this app:

- **Don't put Ruta inside LiveContainer.** Guest apps in a container are the one variant where
  background behavior can differ. There's no need: SideStore + Ruta together use 2 of the 3 free
  installed-app slots.
- **LocalDevVPN is plumbing.** It matters only while SideStore installs or refreshes; Ruta never
  needs it to run.
- **GPS/navigation are foreground-only in this build.** Keep Ruta open and the screen awake while
  riding; the already-recorded part of a ride is saved when the app backgrounds.

## Keeping it alive

Free Apple ID signatures last **7 days**. On day 8 the app icon dims and it stops opening. Fix:
plug the iPhone into the same computer, open Sideloadly, drag the same IPA in, install again —
two minutes. Data survives only when you keep the **same signing Apple ID** and **same bundle ID**
and install **over** the existing app; never uninstall first. Auto-refresh re-signs cached code; it
does not download a new IPA, so install each new build explicitly.

Set a weekly phone reminder until the gifting is done with.

## No computer of your own: SideStore (recommended)

If the rider has no computer, SideStore removes the weekly cable entirely. Once SideStore is on
the iPhone, the phone re-signs Ruta **itself**, in the background, every week — no Mac, no Apple
Developer account, no cost. One in-person setup with any Mac (a friend's is fine), then zero
maintenance:

1. On the Mac, follow the current prerequisites at
   [SideStore's installation docs](https://docs.sidestore.io/docs/installation/install) and install
   **iloader**. Connect the rider's iPhone by cable.
2. In iloader, sign in with the signing Apple Account, select the iPhone and choose
   **Install SideStore (Stable)**. Complete any 2FA/app-specific-password prompt that version asks
   for. This also sets up the pairing file the phone needs for on-device refresh.
3. On the iPhone, trust the developer profile, enable Developer Mode if prompted, install and
   connect LocalDevVPN, then open SideStore and sign in with the same Apple Account.
4. In SideStore, tap **+**, pick the downloaded `Ruta-unsigned-<short-sha>.ipa`, and install.
5. Keep SideStore's background refresh enabled. From here the phone renews Ruta weekly by itself.

Honest limits: the phone must be unlocked and online sometimes (normal daily use is plenty); if
the app fully lapses past 7 days with the phone offline the whole time, one computer session
revives it. No **paid** Apple Developer Program membership is needed. Free Apple IDs allow
3 installed sideloaded apps and 10 new App IDs per 7 days (SideStore + Ruta use 2 slots and two
App IDs).

## Zero computers at all: SideInstaller (iOS 27+)

[SideInstaller](https://sideinstaller.net) (open source: [FrizzleM/SideInstaller](https://github.com/FrizzleM/SideInstaller))
does the whole setup on the iPhone: pairing, signing with **your own Apple ID**, installing. No
Mac, no PC, no cable — the phone pairs with itself (iOS 27) and a free App Store app,
**LocalDevVPN**, gives it the tunnel that replaces the USB cable.

1. On the iPhone, install **Open Minis** and **LocalDevVPN** from the App Store, enable Developer
   Mode, and allow Open Minis location access as its setup instructions request.
2. Open **sideinstaller.net** in Safari — the official site, and nothing else.
   `sideinstaller.com` is a known fake that distributes malware; clones of the app itself look
   identical, so the link above is the only source to type credentials into.
3. In Open Minis → console icon → **Shell Terminal**, connect LocalDevVPN, then run the command
   shown on the official install page (currently
   `wget -qO- https://raw.githubusercontent.com/FrizzleM/siboot/main/minis/install.sh | sh`).
4. Follow siboot's prompts: sign in with the signing Apple ID and complete the self-pairing code
   shown in Settings. It installs SideInstaller.
5. Open SideInstaller → connect LocalDevVPN → **Install SideStore**.
6. Open SideStore, tap **+**, pick the downloaded `Ruta-unsigned-<short-sha>.ipa`, install. Keep LocalDevVPN around for
   installs and the weekly refresh cycle.

Version reality check:

| iOS | Works without any computer? |
|---|---|
| 27+ | **Yes — the whole chain on-device** |
| 17.4–26.x | SideInstaller works, but needs a pairing file made once on a computer — use the Sideloadly route above |
| 17.0–17.3 | Use Sideloadly with a computer |
| Below 17 | **Ruta cannot run** (minimum iOS 17) |

Expect some jitter: Apple sign-in occasionally fails (retry), and the certificate list for the
pre-27 install route changes as certificates get revoked — pick another and continue.

## TrollStore is not an option for Ruta

TrollStore can install apps permanently on older iOS versions, but **Ruta requires iOS 17 or
newer**. The TrollStore-supported iOS 14–16 line cannot run this app, and iOS 17.0.1+ is not
supported by TrollStore. Use SideStore/SideInstaller above.

## The shortcut you may have heard of: enterprise-cert web signers

Services like Scarlet or ESign's free tiers take an unsigned IPA and return an install link that
needs no computer and no Apple ID. They sign with misused corporate certificates. It works
until Apple revokes the certificate in one of its periodic sweeps — then every app from that
signer dies instantly, everywhere, until you find another one. You are installing a provisioning
profile run by anonymous operators onto a daily phone. Not recommended on the device that holds
an Apple ID, banking apps and a scooter worth real money.

## Alternatives, if this gets serious

| Option | What changes |
|---|---|
| **TestFlight via any iOS dev you know** | Free to you: their paid account hosts a separately signed Xcode 26+ build; rider taps a link, 90-day installs, no computer ever. The unsigned CI IPA itself is not a TestFlight build |
| **AltStore classic** | Same 7-day idea as Sideloadly, but can refresh over Wi-Fi when the Mac is on the same network |
| **Xcode, if you own a Mac** | Open the repo's `Ruta.xcodeproj`, pick your team, hit Run — same 7-day rule |

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Unable to install" | iPhone full, Developer Mode off, or already 3 sideloaded apps installed — check each, then retry |
| App dims after a week | Expected: re-sign (see "Keeping it alive") |
| Password rejected with 2FA | Follow the installed Sideloadly version's sign-in flow; use an app-specific password only if it asks for one |
| "Untrusted Developer" at launch | Trust the signing Apple ID under Settings → General → VPN & Device Management |
| Nothing happens when plugged in | Different cable port / unlock the phone / restart Sideloadly |

Once it's installed, continue with [TESTING.md](TESTING.md) for the scooter pairing and the
60-minute test walkthrough.
