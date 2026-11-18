# Testing Ruta on a real scooter

A ~60-minute script for the first person with an iPhone and a Vida scooter. Ordered so the one
thing that could be broken (the pairing PIN flow) gets settled first, before anything else is
touched. Send notes back to whoever gave you the build — especially anything in the Diagnostics
log.

**You need:** an iPhone on iOS 17 or newer, the scooter (tested model family: VX2), and the
Bluetooth PIN the official Vida app uses. If you don't know the PIN, pair once with the official
app on any phone to confirm it works, or check the scooter's manual/sticker.

## 0. Two-minute pre-flight with nRF Connect (optional but worth it)

This settles the biggest unknown without Ruta in the loop:

1. Install **nRF Connect for Mobile** from the App Store.
2. Turn the scooter on. In nRF Connect → Scanner, look for a device named `HMC…`.
3. Tap Connect. iOS should show the **system pairing sheet** — enter the PIN.
4. If it pairs: pairing works on your iPhone, full stop. Disconnect and move on.
5. If no sheet appears, or the PIN is rejected: Ruta will not work either. Try forgetting the
   scooter in Settings › Bluetooth, restart the scooter, and retry once. If it still fails, stop
   here and report — the scooter's firmware may reject Apple devices.

## 1. Install and explore (5 min)

- Install the build — full step-by-step in [`INSTALL.md`](INSTALL.md) if you were given the
  unsigned IPA; if it came via TestFlight, just tap the link.
- Open Ruta. Read the one-time intro. Allow Bluetooth and location when asked.
- Home shows the connect card. Turn on **Demo mode** (Connect sheet, or More › Settings).
- Check every tab with the fake scooter: Home metrics, Navigate search, Rides list and a ride's
  map + speed chart, Battery packs and trends, More › Diagnostics.

## 2. Pair for real (5 min)

1. Close the official Vida app completely (app switcher, swipe away).
2. Scooter on, standing next to it. Ruta › Connect › Scan.
3. Pick the `HMC…` device. Enter the PIN in the iOS sheet.
4. Expect, within a few seconds: "Connected · preparing scooter link…" → the Home speed dial and
   battery ring fill in, and Batteries shows the total and both packs.
5. Compare charge % and pack temperatures against the official app — they should match.

**If it loops "Reconnecting…"**: the official app (or another phone) is holding the link. Close
it, then tap the scooter again.

## 3. A short ride (15 min)

1. With the link live and location allowed, turn the ignition on. Home should show
   "Ride in progress".
2. Ride 1–2 km somewhere normal. Keep the screen on where practical.
3. Turn the ignition off. Within a minute the ride should end; an alert shows distance, time, peak
   and average.
4. Rides tab: the ride is in the list with a track thumbnail and both place names. Open it:
   - Map shows the route; start and end pins are right.
   - Speed chart looks like the ride you did.
   - Battery use matches roughly what the charge % dropped.

## 4. Charging (10 min, can overlap with dinner)

1. Plug the scooter in while Ruta is connected. Home shows the charging banner; Battery shows
   "+X % this session" and an ETA to full.
2. Set More › Charge target to 80 %, let it pass 80 — expect the charged-to-80 % alert exactly
   once.
3. Unplug. The session appears in Battery › Charging sessions.

## 5. Navigation to the cluster (15 min)

1. Navigate tab, search a café or landmark a few km away, tap it, **Start**.
2. On the phone: map follows you, distance-to-turn counts down.
3. On the scooter's cluster: the same turn arrow, distance, and the arrival time. The distance
   should tick down every second even when the phone screen dims.
4. Take a wrong turn on purpose: after a few seconds the phone says Rerouting and the cluster
   gets the new instruction.
5. Arrive (or tap End): the cluster returns to normal, and a "You have arrived" alert shows.

## 6. Handlebar buttons (2 min)

Press the mode/answer/media buttons on the handlebar a few times while connected. They cannot
control iPhone calls or music — iOS forbids it — but each press should appear in More ›
Diagnostics with its name (e.g. "Next track (iOS blocks media control)"). That confirms the
button frames are decoded.

## Report back

- Did step 0 pass?
- Screenshots of Home, Battery and one ride detail while connected.
- More › Diagnostics › share (the square-with-arrow) after a session with a ride — include the
  raw frames if anything misbehaved.
- Anything that didn't match the expectations above, and what the scooter model/firmware shows in
  More (the BLE protocol version).

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| No pairing sheet when connecting | Pair once through the **official My VIDA app** (App Store), then reopen Ruta — iOS keeps the
  bond at the system level, so Ruta inherits it. Otherwise: forget the scooter in Settings ›
  Bluetooth, scooter off/on, scan again |
| "Reconnecting…" forever | Official app or another phone holds the link; close it, or the scooter is out of range |
| Connected but batteries empty | Wait ~10 s for the first BMS burst; if still empty, share the diagnostics log |
| Ride not saved | Rides need ≥ 200 m and ≥ 1 min of movement; check location permission |
| Cluster shows nothing during nav | Check the cluster line on the Navigate tab; share the diagnostics log |
| Everything dead after 7 days | Free-account installs expire; re-sign the app, or use TestFlight |
