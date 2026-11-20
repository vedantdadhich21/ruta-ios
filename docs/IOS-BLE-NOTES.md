# iOS BLE notes for the Vida TCU

What differs from the Android app, learned from the source comparison and the first real-device
session. Keep this next to any future BLE work.

## Discovery: included services (fixed)

Android's `BluetoothGatt.discoverServices()` returns **every** service, primary and secondary.
CoreBluetooth's `discoverServices(nil)` returns **only primary** services. A TCU that nests a
channel as an included service therefore looks like it is missing characteristics on iOS:

- connect succeeds
- characteristics are "missing"
- the app says "does not expose the Hero TCU link" on every retry, with or without a bond

The transport now calls `discoverIncludedServices(nil, for:)` on every primary and discovers
characteristics of the included services too. This was the main suspect for the empty link.

## Characteristic lookup: mirror the Android rules

`ScooterConnection.characteristic(uuid)` is deliberate:

- stats (`0x0401`/`0x0402`): last match on a **plaintext** service; the encrypted command service
  (`02ce005e-…`) is only a fallback
- everything else: the **INFO** service (`1e5af1a3-…`) first, then the last match anywhere

Duplicates exist on the TCU. `GattResolution.resolve` implements the rules as a pure function and
`GattResolutionTests` covers them; the transport resolves each UUID to one `CBCharacteristic`
before the session uses it.

## Bonding: iOS has no API

Android calls `createBond()` and answers the pairing request with the PIN. iOS has no bond API and
no bond-state callback. The system PIN sheet appears only when an operation requires encryption.
The transport therefore does a read of a likely-protected characteristic when the required four are
missing, then retries discovery after 1.5 s and again after 10 s (the sheet may be on screen).

The official My VIDA iOS app is the practical way to create the bond: pair the scooter there once,
close it, then Ruta connects to the already-bonded peripheral. Bonds are system-wide, not per app.

## Cached GATT tables

CoreBluetooth caches services/characteristics per peripheral. A table cached during pre-bond,
partial discovery can keep being served after bonding. A phone reboot (bonds survive) is the cheap
way to clear it. The diagnostics log now records the table the app actually sees, so a field report
shows whether the cache is stale or the device is presenting less.

## What Diagnostics records

Every service (8-char prefix) with each characteristic (4-char prefix) and its properties
(`r`/`w`/`W`/`n`/`i`), plus discovery, read, write and notify errors. The link's Stage A/B statuses
follow. That is enough to tell apart "iOS cannot see it", "the read failed for encryption" and "the
TCU is not answering".

## Known unknowns

- Whether the TCU hides part of its table until bonded (Android never needs to check; it always bonds
  first).
- Whether iOS 27 changes legacy passkey pairing for this accessory.
- The VX2 is the only model the Android project was captured on.
