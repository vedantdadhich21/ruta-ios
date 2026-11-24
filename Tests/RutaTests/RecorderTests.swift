import Foundation
import RutaCore

// Ride recording and charge detection, driven by a manual clock and synthetic GPS fixes.

func runRideRecorder() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ruta-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RideStore(url: folder.appendingPathComponent("rides.json"))
    let chargeStore = ChargeStore(url: folder.appendingPathComponent("charges.json"))
    let recorder = RideRecorder(store: store, chargeStore: chargeStore)
    var saved: [StoredRide] = []
    recorder.onSaved = { saved.append($0) }

    let t0: Int64 = 1_700_000_000_000
    recorder.setLink(ready: true)
    recorder.vehicle(VehicleState(
        ignitionOn: true, immobilised: false, handleLocked: false,
        rideMode: 3, regenLevel: 2, accelerationLevel: 3, speedLimit: 60, time: t0
    ))
    recorder.soc(57.81, at: t0)
    recorder.tick(now: t0)
    check(recorder.state.riding, "ride starts on the ignition")

    // ~30 km/h: 8.33 m/s, so 70 s is ~580 m.
    var lat = 12.9716
    for second in 0..<70 {
        let now = t0 + Int64(second + 1) * 1_000
        lat += 8.33 / 111_320.0
        recorder.fix(lat: lat, lng: 77.5946, accuracyM: 5, speedKmh: 30, at: now)
        recorder.tick(now: now)
    }
    check(recorder.state.distanceM > 200, "distance accumulates (\(Int(recorder.state.distanceM)) m)")
    check(abs(recorder.state.averageKmh - 30) < 1, "average speed")
    check(recorder.state.peakKmh > 20, "peak speed")

    // Ignition off for a minute ends the ride.
    recorder.vehicle(VehicleState(
        ignitionOn: false, immobilised: true, handleLocked: true,
        rideMode: 3, regenLevel: 0, accelerationLevel: 0, speedLimit: 60, time: t0 + 71_000
    ))
    for second in 0..<130 {
        recorder.tick(now: t0 + 71_000 + Int64(second) * 1_000)
    }
    check(saved.count == 1, "ride saved")
    if let ride = saved.first {
        check(ride.points.count >= 2, "track points stored (\(ride.points.count))")
        check(ride.ride.distanceKm > 0.5 && ride.ride.distanceKm < 0.7, "ride distance \(ride.ride.distanceKm)")
        check(ride.ride.socStart == 57.81, "start charge")
        check(abs(ride.ride.peakKmh - 30) < 3, "peak \(ride.ride.peakKmh)")
        check(ride.ride.durationS >= 65, "duration \(ride.ride.durationS)")
    }
    check(store.load().count == 1, "ride on disk")
    check(!recorder.state.riding, "no longer riding")

    // Short rides are discarded.
    let before = saved.count
    recorder.vehicle(VehicleState(
        ignitionOn: true, immobilised: false, handleLocked: false,
        rideMode: 3, regenLevel: 0, accelerationLevel: 0, speedLimit: 60, time: t0 + 200_000
    ))
    recorder.tick(now: t0 + 200_000)
    recorder.fix(lat: lat + 0.00001, lng: 77.5946, accuracyM: 5, speedKmh: 5, at: t0 + 201_000)
    recorder.tick(now: t0 + 201_000)
    recorder.vehicle(VehicleState(
        ignitionOn: false, immobilised: true, handleLocked: true,
        rideMode: 3, regenLevel: 0, accelerationLevel: 0, speedLimit: 60, time: t0 + 202_000
    ))
    for second in 0..<70 { recorder.tick(now: t0 + 202_000 + Int64(second) * 1_000) }
    check(saved.count == before && store.load().count == 1, "short ride discarded")

    // Charging: a 2 % rise over 6 minutes is a session once the link drops.
    let charger = RideRecorder(store: store, chargeStore: chargeStore)
    charger.setLink(ready: true)
    charger.soc(50, at: t0)
    charger.tick(now: t0)
    for minute in 1...7 {
        let now = t0 + Int64(minute) * 60_000
        charger.soc(minute >= 3 ? 52 : 50, at: now)
        charger.tick(now: now)
    }
    check(charger.state.charging != nil, "charging detected")
    charger.setLink(ready: false)
    charger.tick(now: t0 + 8 * 60_000)
    let charges = chargeStore.load()
    check(charges.count == 1, "charging session saved")
    if let charge = charges.first {
        check(charge.socStart == 50 && charge.socEnd == 52, "charge session charge")
    }

    // A paused active ride is checkpointed and recovered by a fresh recorder instead of being lost.
    let recoveryStore = RideStore(url: folder.appendingPathComponent("recovery-rides.json"))
    let first = RideRecorder(store: recoveryStore)
    let start: Int64 = 1_700_100_000_000
    first.setLink(ready: true)
    first.vehicle(VehicleState(
        ignitionOn: true, immobilised: false, handleLocked: false,
        rideMode: 3, regenLevel: 0, accelerationLevel: 0, speedLimit: 60, time: start
    ))
    first.tick(now: start)
    var recoveryLat = 12.9716
    for second in 0..<70 {
        let now = start + Int64(second + 1) * 1_000
        recoveryLat += 8.33 / 111_320.0
        first.fix(lat: recoveryLat, lng: 77.5946, accuracyM: 5, speedKmh: 30, at: now)
        first.tick(now: now)
    }
    first.pause(now: start + 71_000)

    let recovered = RideRecorder(store: recoveryStore)
    var recoveredSaved: [StoredRide] = []
    recovered.onSaved = { recoveredSaved.append($0) }
    check(recovered.state.riding && recovered.state.distanceM > 200, "unfinished ride recovered from checkpoint")
    recovered.resume(now: start + 80_000)
    recovered.setLink(ready: true)
    recovered.vehicle(VehicleState(
        ignitionOn: true, immobilised: false, handleLocked: false,
        rideMode: 3, regenLevel: 0, accelerationLevel: 0, speedLimit: 60, time: start + 80_000
    ))
    recovered.tick(now: start + 80_000)
    recovered.vehicle(VehicleState(
        ignitionOn: false, immobilised: true, handleLocked: true,
        rideMode: 3, regenLevel: 0, accelerationLevel: 0, speedLimit: 60, time: start + 81_000
    ))
    for second in 0..<70 { recovered.tick(now: start + 81_000 + Int64(second) * 1_000) }
    check(recoveredSaved.count == 1 && recoveryStore.load().count == 1, "recovered ride is saved once")

    // A charge-only checkpoint must not manufacture an empty active ride.
    let chargeOnlyStore = RideStore(url: folder.appendingPathComponent("charge-only-rides.json"))
    let chargeOnlyCharges = ChargeStore(url: folder.appendingPathComponent("charge-only-charges.json"))
    let charging = RideRecorder(store: chargeOnlyStore, chargeStore: chargeOnlyCharges)
    charging.setLink(ready: true)
    charging.soc(50, at: t0)
    charging.tick(now: t0)
    charging.soc(52, at: t0 + 360_000)
    charging.tick(now: t0 + 360_000)
    check(charging.state.charging != nil, "charge-only session active")
    charging.pause(now: t0 + 360_000)
    let chargeRecovered = RideRecorder(store: chargeOnlyStore, chargeStore: chargeOnlyCharges)
    check(!chargeRecovered.state.riding && chargeRecovered.state.charging != nil,
          "charge-only checkpoint restores charging without a phantom ride")
}
