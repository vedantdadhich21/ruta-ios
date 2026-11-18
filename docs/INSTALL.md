# Installing Ruta on your iPhone

The build you were given is an **unsigned IPA** — the normal way to hand an app between people
without paying Apple for a store. The iPhone will only run apps it trusts, so before Ruta can
open, it needs a signature. You supply one yourself, for free, with your own Apple ID. Ten
minutes, once.

## What you need

- The `Ruta-unsigned.ipa` file
- Any computer — Mac or Windows
- A USB cable for the iPhone
- Your Apple ID and password (2FA: see step 6)

## Steps

1. Install **Sideloadly** on the computer — free from [sideloadly.io](https://sideloadly.io/).
2. Connect the iPhone with the cable. Unlock it and tap "Trust this computer" if asked.
3. Open Sideloadly. Drag `Ruta-unsigned.ipa` onto its window (or pick the file in its menu).
4. Enter your **Apple ID** as the developer account. Sideloadly signs the app with a personal
   certificate tied to you — the app never sees your password, and nothing is sent anywhere
   except Apple's signing servers.
5. Click Start / Install. The iPhone asks for your Apple ID password once more (this installs the
   profile). Then Ruta's icon appears on the home screen.
6. **If your Apple ID uses two-factor authentication** (it does by default), first create an
   *app-specific password*: appleid.apple.com → Sign-in and Security → App-Specific Passwords.
   Paste that into Sideloadly instead of your normal password.
7. First launch: iOS says "Untrusted Developer". Go to
   **Settings → General → VPN & Device Management** → tap your Apple ID under "Developer App" →
   **Trust**. Now Ruta opens.

## Does a sideloaded app run like a real app?

Yes — identically. The install routes (Sideloadly, SideInstaller/SideStore, TestFlight) don't change
the app at all; they only attach Apple's signature to the same compiled binary. Once installed,
Ruta opens from the home screen like any app, at full native speed, with normal Bluetooth, GPS and
data storage. The only difference from a store app is the signature's lifetime, and SideStore
renews that weekly by itself.

Two specifics for this app:

- **Don't put Ruta inside LiveContainer.** Guest apps in a container are the one variant where
  background behavior can differ — and the scooter link surviving a locked phone depends on it.
  There's no need: SideStore + Ruta together use 2 of the 3 free slots.
- **LocalDevVPN is plumbing.** It matters only while SideStore installs or refreshes; Ruta never
  needs it to run.

## Keeping it alive

Free Apple ID signatures last **7 days**. On day 8 the app icon dims and it stops opening. Fix:
plug the iPhone into the same computer, open Sideloadly, drag the same IPA in, install again —
two minutes, and your rides and settings are untouched (they live in the app's own storage, which
survives re-signing).

Set a weekly phone reminder until the gifting is done with.

## No computer of your own: SideStore (recommended)

If the rider has no computer, SideStore removes the weekly cable entirely. Once SideStore is on
the iPhone, the phone re-signs Ruta **itself**, in the background, every week — no Mac, no Apple
Developer account, no cost. One in-person setup with any Mac (a friend's is fine), then zero
maintenance:

1. On the Mac, install Sideloadly (as above). Connect the rider's iPhone by cable.
2. Download the SideStore IPA from [sidestore.io](https://sidestore.io) and side-load it with
   **the rider's own Apple ID** plus an app-specific password (step 6 above). Complete the
   pairing-file step it asks for — that file is what lets the phone refresh itself later.
3. On the iPhone, open SideStore and sign in with the same Apple ID.
4. In SideStore, tap **+**, pick `Ruta-unsigned.ipa`, and install — it signs and installs
   on-device.
5. Keep SideStore's background refresh enabled. From here the phone renews Ruta weekly by itself.

Honest limits: the phone must be unlocked and online sometimes (normal daily use is plenty); if
the app fully lapses past 7 days with the phone offline the whole time, one computer session
revives it; free Apple IDs allow only 3 sideloaded apps at once (SideStore + Ruta use 2 slots).

## Zero computers at all: SideInstaller (iOS 27+)

[SideInstaller](https://sideinstaller.net) (open source: [FrizzleM/SideInstaller](https://github.com/FrizzleM/SideInstaller))
does the whole setup on the iPhone: pairing, signing with **your own Apple ID**, installing. No
Mac, no PC, no cable — the phone pairs with itself (iOS 27) and a free App Store app,
**LocalDevVPN**, gives it the tunnel that replaces the USB cable.

1. On the iPhone, open **sideinstaller.net** in Safari — the official site, and nothing else.
   `sideinstaller.com` is a known fake that distributes malware; clones of the app itself look
   identical, so the link above is the only source to type credentials into.
2. Install the app, then **LocalDevVPN** from the App Store, and connect it when asked.
3. Sign in with your Apple ID (2FA as normal). Credentials stay on the device.
4. Tap **Install SideStore**, complete the self-pairing prompt (Settings shows a code to confirm).
5. Open SideStore, tap **+**, pick `Ruta-unsigned.ipa`, install. Keep LocalDevVPN around for
   installs and the weekly refresh cycle.

Version reality check:

| iOS | Works without any computer? |
|---|---|
| 27+ | **Yes — the whole chain on-device** |
| 17.4–26.x | SideInstaller works, but needs a pairing file made once on a computer — use the Sideloadly route above |
| 14.0–16.6.1 (16.7 RC, 17.0) | Don't bother: TrollStore (below) installs permanently |

Expect some jitter: Apple sign-in occasionally fails (retry), and the certificate list for the
pre-27 install route changes as certificates get revoked — pick another and continue.

## Old iPhone on iOS 14.0–16.6.1: TrollStore is truly forever

TrollStore exploits a system bug (fixed in iOS 16.7 / 17) to install apps with **no signature
expiry at all** — no Apple ID, no refresh, ever. Check Settings → General → About:

- System version **14.0 through ~16.6.1** → use TrollStore. Installing Ruta is a two-minute
  on-device step and it never needs anything again. This is the only genuinely
  install-once-run-forever option.
- **16.7+ / 17 or newer** → not supported; use SideStore above.

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
| **TestFlight via any iOS dev you know** | Free to you: their paid account hosts the build; rider taps a link, 90-day installs, no computer ever |
| **AltStore classic** | Same 7-day idea as Sideloadly, but can refresh over Wi-Fi when the Mac is on the same network |
| **Xcode, if you own a Mac** | Open the repo's `Ruta.xcodeproj`, pick your team, hit Run — same 7-day rule |

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Unable to install" during step 5 | iPhone full, or already 3 sideloaded apps installed — delete one, retry |
| App dims after a week | Expected: re-sign (see "Keeping it alive") |
| Password rejected with 2FA | You used your normal password — make an app-specific password (step 6) |
| "Untrusted Developer" at launch | You skipped step 7's Trust screen |
| Nothing happens when plugged in | Different cable port / unlock the phone / restart Sideloadly |

Once it's installed, continue with [TESTING.md](TESTING.md) for the scooter pairing and the
60-minute test walkthrough.
