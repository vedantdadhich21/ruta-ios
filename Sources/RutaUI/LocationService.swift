import Foundation
import CoreLocation
import RutaCore

/// Phone location for ride tracking. iOS asks once for "when in use"; the app only records while it
/// is open, and keeps the screen awake during a ride instead of asking for background location.
@MainActor
public final class LocationService: NSObject, CLLocationManagerDelegate {
    public static let shared = LocationService()

    public var onFix: ((GeoFix) -> Void)?
    public var onStatus: ((GpsStatus) -> Void)?
    public private(set) var status: GpsStatus = .off {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    private let manager = CLLocationManager()
    private var running = false

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
        refreshStatus()
    }

    public func start() {
        running = true
        requestAuthorization()
        if authorized { manager.startUpdatingLocation() }
        refreshStatus()
    }

    private func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        #if os(iOS)
        manager.requestWhenInUseAuthorization()
        #elseif os(macOS)
        manager.requestAlwaysAuthorization()
        #endif
    }

    private var authorized: Bool {
        #if os(macOS)
        return manager.authorizationStatus == .authorized
        #else
        return manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        #endif
    }

    public func stop() {
        running = false
        manager.stopUpdatingLocation()
        refreshStatus()
    }

    /// One fix for "where am I" before a ride starts.
    public func requestOneShot() {
        requestAuthorization()
        manager.requestLocation()
    }

    public var coordinate: CLLocationCoordinate2D? {
        manager.location?.coordinate
    }

    private func refreshStatus() {
        switch manager.authorizationStatus {
        case .notDetermined, .restricted, .denied:
            status = .noPermission
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            status = running ? (CLLocationManager.locationServicesEnabled() ? .searching : .disabled) : .idle
        @unknown default:
            status = .noPermission
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes: [GeoFix] = locations.map { location in
            GeoFix(
                time: Int64(location.timestamp.timeIntervalSince1970 * 1000),
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                accuracyM: location.horizontalAccuracy,
                speedKmh: location.speed >= 0 ? location.speed * 3.6 : nil
            )
        }
        Task { @MainActor in
            self.status = CLLocationManager.locationServicesEnabled()
                ? (self.running ? .fix : .idle)
                : .disabled
            for fix in fixes { self.onFix?(fix) }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.running { self.status = .searching }
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshStatus()
            if self.running, self.authorized {
                manager.startUpdatingLocation()
            }
        }
    }
}
