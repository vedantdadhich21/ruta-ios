import Foundation
import CoreLocation
import Observation
import RutaCore

/// The app's state: one scooter link, live telemetry, rides, charging and alerts. Views observe this
/// object; the protocol work stays in `ScooterSession` and `RideRecorder`.
@MainActor
@Observable
public final class RutaModel {
    public enum Tab: String, CaseIterable, Identifiable {
        case home = "Home"
        case navigate = "Navigate"
        case rides = "Rides"
        case battery = "Battery"
        case more = "More"

        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .home: return "gauge.with.dots.needle.67percent"
            case .navigate: return "location.north.line.fill"
            case .rides: return "point.topleft.down.to.point.bottomright.curvepath"
            case .battery: return "battery.75percent"
            case .more: return "ellipsis"
            }
        }
    }

    /// The selected tab.
    public var tab: Tab = .home

    // MARK: - Settings

    public var demoMode: Bool {
        didSet {
            defaults.set(demoMode, forKey: Key.demo)
            guard oldValue != demoMode else { return }
            restartLink()
        }
    }

    /// Forward turn-by-turn to the cluster. iOS gets cues from the in-app map.
    public var navigationEnabled: Bool {
        didSet {
            defaults.set(navigationEnabled, forKey: Key.navigation)
            session.navigationEnabled = navigationEnabled
        }
    }

    public var announceCharge: Bool {
        didSet { defaults.set(announceCharge, forKey: Key.chargeAlerts) }
    }

    /// Charge level to alert at: 80, 90 or 100 %.
    public var chargeTarget: Int {
        didSet { defaults.set(chargeTarget, forKey: Key.chargeTarget) }
    }

    public var unitMiles: Bool {
        didSet { defaults.set(unitMiles, forKey: Key.miles) }
    }

    // MARK: - Link

    public private(set) var session: ScooterSession
    public private(set) var transport: ScooterTransport
    public private(set) var statusText = "Not connected"
    public private(set) var phase: LinkPhase = .idle
    public private(set) var reconnecting = false
    public var bluetooth: BluetoothState {
        #if os(iOS)
        (transport as? BluetoothScooterTransport)?.state ?? .unknown
        #else
        .poweredOn
        #endif
    }
    public private(set) var discovered: [DiscoveredScooter] = []
    public private(set) var scanning = false
    public private(set) var connectedName: String?
    public private(set) var info: TcuInfo?
    public private(set) var vehicle: VehicleState?
    public private(set) var lastHandlebar: String?
    public private(set) var saved: [SavedScooter]
    public private(set) var pairing = false

    // MARK: - Telemetry

    public private(set) var latest: [MetricKey: Reading] = [:]
    public private(set) var series: [MetricKey: [ValueAt]] = [:]
    public private(set) var lastReadingAt: Int64 = 0
    public private(set) var ride = LiveRideState()
    public private(set) var rides: [StoredRide] = []
    public private(set) var charges: [ChargeSession] = []
    public private(set) var alert: AlertMessage?
    public private(set) var alertLog: [AlertMessage] = []

    // MARK: - Services

    public let navigation: NavigationModel
    public let diagnostics = DiagnosticsLog.shared
    public let location = LocationService.shared

    private let defaults: UserDefaults
    private let scooters = ScooterStore()
    private let rideStore = RideStore()
    private let chargeStore = ChargeStore()
    private let demoRideStore: RideStore
    private let demoChargeStore: ChargeStore
    private var recorder: RideRecorder
    private let chargeWatch = ChargeWatch()
    private var ticker: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?
    private var started = false
    private var lastAlertAt: [String: Int64] = [:]

    private enum Key {
        static let demo = "ruta.demo"
        static let navigation = "ruta.navigation"
        static let chargeAlerts = "ruta.chargeAlerts"
        static let chargeTarget = "ruta.chargeTarget"
        static let miles = "ruta.miles"
        static let demoSeeded = "ruta.demoSeeded"
    }

    public init(demo: Bool? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let startDemo = demo ?? defaults.bool(forKey: Key.demo)
        self.demoMode = startDemo
        let navEnabled = defaults.object(forKey: Key.navigation) == nil
            ? true : defaults.bool(forKey: Key.navigation)
        self.navigationEnabled = navEnabled
        self.announceCharge = defaults.object(forKey: Key.chargeAlerts) == nil
            ? true : defaults.bool(forKey: Key.chargeAlerts)
        let target = defaults.integer(forKey: Key.chargeTarget)
        self.chargeTarget = [80, 90, 100].contains(target) ? target : 100
        self.unitMiles = defaults.bool(forKey: Key.miles)
        self.saved = scooters.load()

        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ruta", isDirectory: true)
        demoRideStore = RideStore(url: folder.appendingPathComponent("demo-rides.json"))
        demoChargeStore = ChargeStore(url: folder.appendingPathComponent("demo-charges.json"))

        let demoTransport = FakeScooterTransport()
        let realTransport: ScooterTransport
        #if os(iOS)
        realTransport = BluetoothScooterTransport()
        #else
        realTransport = FakeScooterTransport()
        #endif
        let chosenTransport = startDemo ? demoTransport : realTransport
        transport = chosenTransport
        recorder = RideRecorder(store: startDemo ? demoRideStore : RideStore())
        navigation = NavigationModel()
        session = ScooterSession(transport: chosenTransport)
        session.navigationEnabled = navEnabled
        rides = (startDemo ? demoRideStore : rideStore).load()
        charges = (startDemo ? demoChargeStore : chargeStore).load()

        wireSession()
        wireRecorder()
        if startDemo {
            seedDemoIfNeeded()
            rides = demoRideStore.load()
            charges = demoChargeStore.load()
        }
        location.onFix = { [weak self] fix in self?.accept(fix) }
        location.onStatus = { [weak self] status in self?.ride.gps = status }
        navigation.onCue = { [weak self] cue in self?.navigationCue(cue) }
        navigation.onStop = { [weak self] in self?.session.stopNavigation() }
    }

    // MARK: - Lifecycle

    /// Starts the 1 Hz sampler and, when a scooter is remembered, tries it once.
    public func start() {
        guard !started else { return }
        started = true
        location.requestOneShot()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.tick()
            }
        }
        if demoMode {
            connect(SavedScooter(
                id: FakeScooterTransport.demoID,
                name: "HMC VX2",
                nickname: "Demo VX2"
            ))
        } else if let first = saved.first {
            connect(first)
        }
    }

    /// Call when the app moves to the background. Saves the active ride; iOS does not keep tracking
    /// with the app closed.
    public func saveAndPause() {
        recorder.stop(now: now)
        refreshRides()
    }

    private func tick() {
        let now = now
        recorder.setLink(ready: phase == .ready)
        recorder.tick(now: now)
        ride = recorder.state
        session.callState = callState
        session.callDurationS = callSeconds
        session.missedCalls = missedCalls
        session.unreadMessages = unreadMessages
        finishNavigationIfNeeded()
        if let cue = navigation.cue {
            session.pushNavigation(cue.frame(now: Date()))
        }
        watchCharge(now: now)
        #if os(iOS)
        keepAwake(phase == .ready || ride.riding)
        #endif
    }

    // MARK: - Link actions

    public func startScan() {
        discovered = []
        scanning = true
        transport.startScan()
        scanTimer?.cancel()
        scanTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stopScan()
        }
    }

    public func stopScan() {
        scanning = false
        transport.stopScan()
    }

    public func connect(_ scooter: DiscoveredScooter) {
        stopScan()
        var savedScooter = SavedScooter(id: scooter.id, name: scooter.name, nickname: scooter.name)
        if let existing = saved.first(where: { $0.id == scooter.id }) {
            savedScooter.nickname = existing.nickname
        }
        scooters.add(savedScooter)
        saved = scooters.load()
        connect(savedScooter)
    }

    public func connect(_ scooter: SavedScooter) {
        connectedName = scooter.displayName
        phase = .connecting
        recorder.setLink(ready: false)
        session.connect(id: scooter.id, name: scooter.displayName)
        navigation.resetForNewLink()
    }

    public func disconnect() {
        session.disconnect()
        stopScan()
        phase = .idle
        recordingStopped()
    }

    public func refreshLive() {
        session.refresh()
    }

    public func rename(_ scooter: SavedScooter, nickname: String) {
        var updated = scooter
        updated.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        scooters.add(updated)
        saved = scooters.load()
        if session.phase != .idle, connectedName != nil { connectedName = updated.displayName }
    }

    public func forget(_ scooter: SavedScooter) {
        if connectedName != nil { disconnect() }
        scooters.remove(id: scooter.id)
        saved = scooters.load()
    }

    public func notify(_ message: AlertMessage) {
        alert = message
        alertLog.insert(message, at: 0)
        if alertLog.count > 30 { alertLog.removeLast(alertLog.count - 30) }
    }

    public func dismissAlert() {
        alert = nil
    }

    // MARK: - Ride helpers

    public func refreshRides() {
        rides = activeRideStore.load()
        charges = activeChargeStore.load()
    }

    public func deleteRide(_ id: Int64) {
        activeRideStore.delete(id: id)
        refreshRides()
    }

    public func renameRide(_ stored: StoredRide, start: String?, end: String?) {
        _ = activeRideStore.updatePlaces(id: stored.id, start: start, end: end)
        refreshRides()
    }

    public var efficiency: RangeEfficiency {
        RangeModel.efficiency(rides.map(\.ride))
    }

    public var rideStats: RideStats {
        RideMath.stats(rides.map(\.ride))
    }

    public var latestSoc: Double? {
        latest[MetricKey(pack: 0, metric: .soc)]?.value
    }

    public var range: RangeEstimate? {
        RangeModel.estimate(socPercent: latestSoc, decodedKm: session.decodedRangeKm, efficiency: efficiency)
    }

    public var fullChargeEta: String? {
        guard let live = ride.charging else { return nil }
        return ChargeEta.phrase(ChargeEta.minutesToFull(socPercent: latestSoc, session: live))
    }

    public var isConnected: Bool { phase == .ready }
    public var hasScooter: Bool { !saved.isEmpty }

    public func reading(pack: Int, _ metric: Metric) -> Reading? {
        latest[MetricKey(pack: pack, metric: metric)]
    }

    public func value(pack: Int, _ metric: Metric) -> Double? {
        latest[MetricKey(pack: pack, metric: metric)]?.value
    }

    public func history(_ metric: Metric, pack: Int = 0, hours: Double = 6, buckets: Int = 120) -> [BucketPoint] {
        let key = MetricKey(pack: pack, metric: metric)
        guard let values = series[key], let first = values.first, let last = values.last else { return [] }
        let end = max(last.time, first.time + 1)
        return RideMath.downsample(values, start: first.time, end: end, buckets: buckets)
    }

    public var packs: [Int] {
        let found = Set(latest.keys.map(\.pack))
        return found.sorted()
    }

    public var packStates: [BmsState] {
        (0...2).map { BmsState.of(value(pack: $0, .status)) }
    }

    public var bmsState: BmsState {
        BmsState.combined((0...2).map { value(pack: $0, .status) })
    }

    // MARK: - Units

    public func speedText(_ kmh: Double) -> String {
        unitMiles ? String(format: "%.0f", kmh * 0.621371) : String(format: "%.0f", kmh)
    }

    public var speedUnit: String { unitMiles ? "mph" : "km/h" }

    public func distanceText(_ metres: Double) -> String {
        unitMiles
            ? String(format: "%.1f mi", metres / 1609.344)
            : String(format: "%.1f km", metres / 1000)
    }

    public func shortDistanceText(_ metres: Double) -> String {
        if unitMiles {
            let feet = metres * 3.28084
            return feet >= 1000 ? String(format: "%.1f mi", feet / 5280) : String(format: "%.0f ft", feet)
        }
        return metres >= 1000 ? String(format: "%.1f km", metres / 1000) : String(format: "%.0f m", metres)
    }

    // MARK: - Wiring

    private func wireSession() {
        session.onStatus = { [weak self] text in self?.statusText = text }
        session.onLog = { _ in }
        session.onDiscovered = { [weak self] scooter in
            guard let self else { return }
            if let index = self.discovered.firstIndex(where: { $0.id == scooter.id }) {
                self.discovered[index] = scooter
            } else {
                self.discovered.append(scooter)
            }
            self.discovered.sort { $0.rssi > $1.rssi }
        }
        session.onReading = { [weak self] reading in self?.accept(reading) }
        session.onVehicle = { [weak self] state in
            guard let self else { return }
            self.vehicle = state
            self.recorder.vehicle(state)
        }
        session.onInfo = { [weak self] info in self?.info = info }
        session.onConnected = { [weak self] in
            guard let self else { return }
            self.phase = .ready
            self.reconnecting = false
            self.pairing = false
            self.recorder.setLink(ready: true)
            self.location.start()
            self.connectivityAlert()
        }
        session.onEnded = { [weak self] lost in
            guard let self else { return }
            self.phase = .idle
            self.reconnecting = lost
            self.recorder.setLink(ready: false)
            if lost {
                self.recordingStopped()
            } else {
                self.recordingStopped()
                self.location.stop()
            }
        }
        session.onHardControl = { [weak self] event in
            self?.lastHandlebar = Self.describe(event)
        }
    }

    private func wireRecorder() {
        recorder.onSaved = { [weak self] stored in
            guard let self else { return }
            self.refreshRides()
            self.lookUpPlaces(stored)
            self.notify(AlertText.rideSaved(stored.ride))
        }
        recorder.onChargeChanged = { [weak self] session in
            self?.ride.charging = session
        }
        recorder.onLog = { _ in }
    }

    private func restartLink() {
        if session.phase != .idle { session.disconnect() }
        phase = .idle
        reconnecting = false
        discovered = []
        stopScan()
        recorder = RideRecorder(
            store: demoMode ? demoRideStore : rideStore,
            chargeStore: demoMode ? demoChargeStore : chargeStore
        )
        wireRecorder()
        let next: ScooterTransport
        if demoMode {
            next = FakeScooterTransport()
        } else {
            #if os(iOS)
            next = BluetoothScooterTransport()
            #else
            next = FakeScooterTransport()
            #endif
        }
        transport = next
        session = ScooterSession(transport: next)
        session.navigationEnabled = navigationEnabled
        wireSession()
        rides = activeRideStore.load()
        charges = activeChargeStore.load()
        latest = [:]
        series = [:]
        ride = LiveRideState()
        if demoMode {
            seedDemoIfNeeded()
            rides = demoRideStore.load()
        }
    }

    private var activeRideStore: RideStore { demoMode ? demoRideStore : rideStore }
    private var activeChargeStore: ChargeStore { demoMode ? demoChargeStore : chargeStore }

    private func accept(_ reading: Reading) {
        latest[MetricKey(pack: reading.pack, metric: reading.metric)] = reading
        let key = MetricKey(pack: reading.pack, metric: reading.metric)
        var values = series[key] ?? []
        if let last = values.last {
            if abs(last.value - reading.value) >= 0.01 || reading.time - last.time >= 10_000 {
                values.append(ValueAt(time: reading.time, value: reading.value))
            }
        } else {
            values.append(ValueAt(time: reading.time, value: reading.value))
        }
        if values.count > 4_000 { values.removeFirst(values.count - 4_000) }
        series[key] = values
        lastReadingAt = max(lastReadingAt, reading.time)
        if reading.pack == 0 && reading.metric == .soc {
            recorder.soc(reading.value, at: reading.time)
        }
    }

    private func accept(_ fix: GeoFix) {
        recorder.fix(lat: fix.lat, lng: fix.lng, accuracyM: fix.accuracyM, speedKmh: fix.speedKmh, at: fix.time)
        navigation.update(lat: fix.lat, lng: fix.lng)
        ride = recorder.state
    }

    private func watchCharge(now: Int64) {
        let event = chargeWatch.update(
            session: recorder.state.charging,
            socPercent: latestSoc,
            linkReady: phase == .ready,
            riding: ride.riding,
            target: chargeTarget
        )
        guard let event, announceCharge else { return }
        switch event {
        case .reached(let percent):
            notify(AlertText.chargeReached(
                percent: percent,
                rangeKm: range?.km,
                estimated: range?.estimated ?? true
            ))
        case .stopped(let percent):
            notify(AlertText.chargeStopped(percent: percent))
        }
        charges = activeChargeStore.load()
    }

    private func connectivityAlert() {
        guard !demoMode else { return }
        if saved.first != nil {
            notify(AlertMessage(
                "Scooter connected",
                "Turn-by-turn and battery data appear here while Ruta is open.",
                "Scooter connected"
            ))
        }
    }

    private func recordingStopped() {
        if ride.riding {
            recorder.stop(now: now)
            refreshRides()
        }
    }

    // MARK: - Navigation

    public func beginNavigation() {
        navigation.begin()
        location.start()
    }

    public func endNavigation() {
        navigation.stop()
        if !ride.riding && session.phase != .ready { location.stop() }
    }

    private func navigationCue(_ cue: MapsCue) {
        guard phase == .ready, navigationEnabled else { return }
        session.pushNavigation(cue.frame(now: Date()))
    }

    private func finishNavigationIfNeeded() {
        guard navigation.arrived, navigation.isNavigating else { return }
        navigation.finish()
        session.stopNavigation()
        if navigationEnabled {
            notify(AlertText.arrived(navigation.destinationName ?? "your destination"))
        }
    }

    // MARK: - Places

    private func lookUpPlaces(_ stored: StoredRide) {
        let ride = stored.ride
        Task { [weak self] in
            let start = await PlaceLookup.name(lat: ride.startLat, lng: ride.startLng)
            let end = await PlaceLookup.name(lat: ride.endLat, lng: ride.endLng)
            guard let self else { return }
            _ = self.activeRideStore.updatePlaces(id: ride.id, start: start, end: end)
            self.rides = self.activeRideStore.load()
        }
    }

    // MARK: - Demo history

    private func seedDemoIfNeeded() {
        guard demoRideStore.load().isEmpty else { return }
        let seeded = DemoTrips.make(now: now)
        demoRideStore.save(seeded.rides)
        demoChargeStore.save(seeded.charges)
    }

    // MARK: - Phone status

    public var connectedSeconds: Int64 = 0

    private var callState: TcuCallState { .none }
    private var callSeconds: Int { 0 }
    private var missedCalls: Int { 0 }
    private var unreadMessages: Int { 0 }

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func describe(_ event: HardControlEvent) -> String {
        switch event {
        case .callAccept: return "Accept call (the iPhone cannot take the call from here)"
        case .callReject: return "Reject call (the iPhone cannot take the call from here)"
        case .callVolumeUp: return "Call volume up"
        case .callVolumeDown: return "Call volume down"
        case .musicVolumeUp: return "Volume up (iOS blocks media control)"
        case .musicVolumeDown: return "Volume down (iOS blocks media control)"
        case .musicPlayPause: return "Play/pause (iOS blocks media control)"
        case .musicNext: return "Next track (iOS blocks media control)"
        case .musicPrevious: return "Previous track (iOS blocks media control)"
        case .musicMute: return "Mute (iOS blocks media control)"
        case .voiceStart: return "Voice assistant"
        case .voiceCancel: return "Voice cancelled"
        }
    }
}

#if os(iOS)
import UIKit

private extension RutaModel {
    func keepAwake(_ awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
    }
}
#endif

/// Reverse geocoding for ride place names, using the system geocoder.
public enum PlaceLookup {
    public static func name(lat: Double, lng: Double) async -> String? {
        #if canImport(CoreLocation)
        let location = CLLocation(latitude: lat, longitude: lng)
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            let parts = marks.map {
                PlaceParts(
                    thoroughfare: $0.thoroughfare,
                    subLocality: $0.subLocality,
                    locality: $0.locality,
                    featureName: $0.name,
                    subAdminArea: $0.subAdministrativeArea,
                    adminArea: $0.administrativeArea
                )
            }
            return RideMath.placeLabel(parts)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
