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

## Keeping it alive

Free Apple ID signatures last **7 days**. On day 8 the app icon dims and it stops opening. Fix:
plug the iPhone into the same computer, open Sideloadly, drag the same IPA in, install again —
two minutes, and your rides and settings are untouched (they live in the app's own storage, which
survives re-signing).

Set a weekly phone reminder until the gifting is done with.

## Alternatives, if this gets serious

| Option | What changes |
|---|---|
| **AltStore / SideStore** | Same free 7-day idea, but can refresh over Wi-Fi instead of a cable, if the computer is on the same network |
| **TestFlight** | The giver pays $99/yr for an Apple Developer account; you just tap a link, installs over the air, builds last 90 days, no computer ever |
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
