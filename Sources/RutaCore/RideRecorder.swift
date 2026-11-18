import Foundation

public enum GpsStatus: String, Equatable, Sendable {
    case off = "Off"
    case noPermission = "No location permission"
    case disabled = "Location is off"
    case idle = "Listening"
    case searching = "Waiting for GPS"
    case fix = "GPS fix"
}

/// Live values for the Home ride card.
public struct LiveRideState: Equatable, Sendable {
    public var gps: GpsStatus = .off
    public var riding = false
    public var startedAt: Int64 = 0
    public var distanceM = 0.0
    public var durationS: Int64 = 0
    public var speedKmh = 0.0
    public var peakKmh = 0.0
    public var averageKmh = 0.0
    public var socStart: Double?
    public var charging: ChargeSession?
    public var linkReady = false
    public var socPercent: Double?
    public var range: RangeEstimate?

    public init() {}
}

/// Turns phone fixes and scooter state into stored rides. Mirrors the Android ride tracker's rules:
/// a ride starts on the ignition or after 10 s above 8 km/h, and ends 60 s after the ignition goes
/// off, 2 min after the link drops, or 5 min at a standstill. Tracks keep moving points plus one
/// point every 10 s when stopped, and a ride needs 200 m and a minute to be kept.
public final class RideRecorder {
    public static let freshFixMs: Int64 = 20_000
    public static let freshSocMs: Int64 = 90_000
    public static let recentMs: Int64 = 60_000
    public static let chargeSaveMs: Int64 = 60_000

    private struct Active {
        var id: Int64
        var start: Int64
        var socStart: Double?
        let track = RideAccumulator()
        var points: [RidePoint] = []
        var lastStoredAt: Int64 = 0
        var skipped: RidePoint?
        var startPlace: String?
    }

    public let store: RideStore
    public let chargeStore: ChargeStore?

    public private(set) var state = LiveRideState()
    public var onSaved: ((StoredRide) -> Void)?
    public var onChargeChanged: ((ChargeSession?) -> Void)?
    public var onLog: ((String) -> Void)?

    private let filter = FixFilter()
    private let segmenter = RideSegmenter()
    private let smoother = SpeedSmoother()
    private let charges = ChargeDetector()
    private var recent: [(time: Int64, step: TrackStep)] = []
    private var active: Active?
    private var linkReady = false
    private var ignition: Bool?
    private var soc: ValueAt?
    private var decodedRangeKm: Double?
    private var lastChargeSaveAt: Int64 = 0
    private var chargingSaved = false
    private var lastSmoothedSpeed = 0.0

    public init(store: RideStore, chargeStore: ChargeStore? = nil) {
        self.store = store
        self.chargeStore = chargeStore
    }

    // MARK: - Inputs

    public func setLink(ready: Bool) {
        linkReady = ready
        state.linkReady = ready
        if !ready { ignition = nil; decodedRangeKm = nil }
    }

    public func vehicle(_ vehicle: VehicleState?) {
        ignition = vehicle?.ignitionOn
    }

    public func range(_ km: Double?) {
        decodedRangeKm = km
    }

    public func soc(_ value: Double?, at time: Int64) {
        guard let value, value.isFinite else { soc = nil; return }
        soc = ValueAt(time: time, value: value)
    }

    /// A filtered GPS fix. `now` should be the current wall clock in milliseconds.
    public func fix(lat: Double, lng: Double, accuracyM: Double, speedKmh: Double?, at time: Int64) {
        let fix = GeoFix(time: time, lat: lat, lng: lng, accuracyM: accuracyM, speedKmh: speedKmh)
        guard let step = filter.accept(fix) else { return }
        state.gps = .fix
        let speed = smoother.add(step.speedKmh)
        lastSmoothedSpeed = speed
        state.speedKmh = speed
        recent.append((time, step))
        recent.removeAll { time - $0.time > Self.recentMs }
        if active != nil { record(step) }
        refresh(now: time)
    }

    /// Samples the inputs once a second. Safe to call more often.
    public func tick(now: Int64) {
        let fresh = recent.last.flatMap { now - $0.time <= Self.freshFixMs ? $0.step : nil }
        if fresh != nil {
            state.gps = .fix
            state.speedKmh = lastSmoothedSpeed
        } else if state.gps == .fix {
            state.gps = .searching
        }
        let freshSoc = freshSoc(now: now)
        let event = segmenter.update(now: now, linkReady: linkReady, ignitionOn: ignition, speedKmh: fresh?.speedKmh)
        switch event {
        case .started(let time, let byIgnition):
            begin(at: time, now: now, byIgnition: byIgnition)
        case .ended(let time, let reason):
            end(at: time, reason: reason, now: now)
        case nil:
            break
        }
        if let active, active.socStart == nil { self.active?.socStart = freshSoc }
        updateCharging(now: now, soc: freshSoc)
        refresh(now: now)
    }

    /// Saves an active ride and charging session; used when the app leaves the foreground.
    public func stop(now: Int64) {
        if case .ended(let time, let reason)? = segmenter.stop(now: now) {
            end(at: time, reason: reason, now: now)
        }
        if let charge = charges.stop() { saveCharge(charge, now: now, finished: true) }
        refresh(now: now)
    }

    // MARK: - Ride

    private func begin(at time: Int64, now: Int64, byIgnition: Bool) {
        let freshSoc = freshSoc(now: now)
        let ride = Active(id: store.nextId(), start: time, socStart: freshSoc)
        active = ride
        for step in recent where step.time >= time {
            record(step.step)
        }
        onLog?(byIgnition ? "Ride started (ignition on)" : "Ride started (moving)")
    }

    private func record(_ step: TrackStep) {
        guard var ride = active else { return }
        let point = ride.track.add(step)
        if ride.lastStoredAt == 0 || step.stepM > 0 || point.time - ride.lastStoredAt >= 10_000 {
            if step.stepM > 0, let skipped = ride.skipped { ride.points.append(skipped) }
            ride.points.append(point)
            ride.lastStoredAt = point.time
            ride.skipped = nil
        } else {
            ride.skipped = point
        }
        active = ride
    }

    private func end(at time: Int64, reason: RideEndReason, now: Int64) {
        guard let ride = active else { return }
        active = nil
        let socEnd = soc.flatMap { $0.time >= ride.start ? $0.value : nil }
        guard let summary = ride.track.finish(id: ride.id, socStart: ride.socStart, socEnd: socEnd) else {
            onLog?(String(
                format: "Ride not saved: %.0f m (needs %.0f m and 1 min)",
                ride.track.distanceM, RideMath.minRideM
            ))
            return
        }
        var stored = StoredRide(ride: summary, points: ride.points)
        stored.ride.startPlace = ride.startPlace
        store.add(stored)
        onSaved?(stored)
        onLog?(String(
            format: "Ride saved: %.1f km in %@, peak %.0f km/h, avg %.0f km/h (%@)",
            summary.distanceKm, RideMath.formatDuration(seconds: summary.durationS),
            summary.peakKmh, summary.avgKmh, reason.rawValue.lowercased()
        ))
    }

    /// Fills the place names after the tracker has looked them up.
    public func setPlaces(id: Int64, start: String?, end: String?) {
        store.updatePlaces(id: id, start: start, end: end)
    }

    // MARK: - Charging

    private func updateCharging(now: Int64, soc: Double?) {
        let session = charges.update(now: now, soc: soc, linkReady: linkReady, riding: segmenter.riding)
        if let live = charges.active {
            if !chargingSaved {
                chargingSaved = true
                lastChargeSaveAt = 0
                onLog?("Charging detected")
            }
            onChargeChanged?(live)
            if now - lastChargeSaveAt >= Self.chargeSaveMs {
                lastChargeSaveAt = now
                saveCharge(live, now: now, finished: false)
            }
        } else if let session {
            saveCharge(session, now: now, finished: true)
            onChargeChanged?(nil)
        }
    }

    private func saveCharge(_ session: ChargeSession, now: Int64, finished: Bool) {
        guard let chargeStore else { return }
        var all = chargeStore.load()
        if let index = all.firstIndex(where: { $0.start == session.start }) {
            all[index] = session
        } else {
            all.append(session)
        }
        all.sort { $0.start > $1.start }
        chargeStore.save(all)
        if finished {
            chargingSaved = false
            onLog?("Charging session saved: \(Int(session.socStart)) % → \(Int(session.socEnd)) %")
        }
    }

    // MARK: - State

    private func freshSoc(now: Int64) -> Double? {
        guard let soc, now - soc.time <= Self.freshSocMs, soc.value.isFinite else { return nil }
        return soc.value
    }

    private func refresh(now: Int64) {
        state.linkReady = linkReady
        state.riding = segmenter.riding
        state.charging = charges.active
        let fresh = freshSoc(now: now)
        state.socPercent = fresh
        state.range = RangeModel.estimate(
            socPercent: fresh, decodedKm: decodedRangeKm,
            efficiency: RangeModel.efficiency(store.rides())
        )
        guard let active else {
            state.startedAt = 0
            state.distanceM = 0
            state.durationS = 0
            state.peakKmh = 0
            state.averageKmh = 0
            state.socStart = nil
            if !segmenter.riding { state.speedKmh = 0 }
            return
        }
        state.startedAt = active.start
        state.distanceM = active.track.distanceM
        state.durationS = max((now - active.start) / 1000, 0)
        state.peakKmh = active.track.peakKmh
        state.averageKmh = active.track.averageKmh
        state.socStart = active.socStart
    }
}
