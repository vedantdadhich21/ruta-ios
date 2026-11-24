# One-iteration field diagnostic — VX2 / HMC_708983

Use the same iPhone 12 Pro on iOS 27.2.1. Change one variable at a time and save each Ruta log
before doing anything else.

## 0. Verify the binary

Ruta → More → About, and the first lines of More → Diagnostics → share:

- commit is a full SHA, **not `local`**;
- build is the CI run number, **not `1`**.

Do not test a locally built binary.

## 1. Android baseline, then remove contention

1. Android Bluetooth on: connect Android Ruta and confirm **live battery data**.
2. Record its service table, MTU and TCU firmware if available.
3. Force-close Android Ruta and turn **Android Bluetooth completely off**.

A stored Android bond is not the variable; an active Android connection is.

## 2. Clean iPhone starting state

1. Force-close My VIDA, nRF Connect and Ruta.
2. iPhone Settings → Bluetooth → forget `HMC_708983` if present.
3. Toggle iPhone Bluetooth off/on.
4. Power-cycle the scooter; ignition on; phone next to the scooter.
5. Do not pair through iPhone Settings.

## 3. Create the official-app bond

1. Open My VIDA and pair from inside the app.
2. Record: PIN sheet appeared? accepted/rejected/no sheet?
3. Confirm **live battery/vehicle values** and the scooter Bluetooth indicator. "Connected" alone
   is not enough.
4. Force-close My VIDA.
5. Do not forget the device, toggle Bluetooth or reboot.

## 4. iOS reference capture in nRF Connect

Without changing the bond/cache:

1. Connect nRF to `HMC_708983` and capture the full tree: service UUIDs, primary/secondary flags,
   include edges, characteristic UUIDs and properties.
2. Confirm INFO `1e5af1a3-…` has `0103`/`0104`; a stats service has `0401`/`0402`; ICBT
   `76f2f660-…` if exposed.
3. Read `0101`; enable notifications on `0104` and `0402`; record exact errors.
4. Disconnect and force-close nRF.

## 5. Ruta, without clearing anything

1. Open Ruta, Demo mode off. If it auto-connects, disconnect.
2. More → Diagnostics → **Clear**.
3. Connect → Scan → `HMC_708983`.
4. Record whether Ruta shows a PIN sheet.
5. Wait for live data or the final error.
6. Export/save the log **before** changing Bluetooth, forgetting the device or rebooting.

## 6. Only if nRF and Ruta are both incomplete: one cache reset

1. Save the first Ruta export separately.
2. Reboot iPhone (bonds survive), power-cycle scooter.
3. Do not forget the device and do not open My VIDA first.
4. Repeat nRF inspection, then clear Ruta Diagnostics and repeat Ruta.
5. Save the second log separately.
6. Reopen My VIDA once to confirm it still works.

## Interpretation

| Observation | Conclusion |
|---|---|
| nRF and Ruta both see all four required characteristics and Ruta works | Bond/bootstrap was the old root cause |
| nRF sees all four; Ruta's tree is incomplete/missing them | Ruta discovery/resolution bug |
| Both incomplete; both complete after reboot without re-pairing | iOS GATT cache |
| nRF completes after reboot; Ruta remains incomplete | Ruta discovery/cache-instance bug |
| Both remain incomplete after reboot while My VIDA works | Official-app-specific initialization/security gate |
| Ruta sees all four but read/notify fails with auth/encryption errors | Bond/security operation problem, not discovery |

Send both Ruta exports (if there are two), the nRF tree/screenshots, and the PIN-sheet observation.
The Ruta log now includes build/commit, cached service count, full UUIDs, include edges, instance
ordinals, properties, selected instances, write limits and exact error domains/codes.
