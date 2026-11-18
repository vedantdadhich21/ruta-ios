import Foundation
import CoreLocation
import MapKit
import Observation
import RutaCore

/// In-app navigation on Apple Maps. It replaces the Android app's Google Maps notification listener:
/// MapKit gives the route, steps and progress directly, and the upcoming maneuver is mirrored to the
/// scooter's cluster.
@MainActor
@Observable
public final class NavigationModel: NSObject, MKLocalSearchCompleterDelegate {
    public struct Destination: Equatable {
        public var name: String
        public var lat: Double
        public var lng: Double

        public var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }

    public struct RouteStep: Equatable {
        public var instruction: String
        public var road: String
        public var turn: Int
        public var endM: Double
    }

    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            completer.queryFragment = query
        }
    }
    public private(set) var completions: [MKLocalSearchCompletion] = []
    public private(set) var destination: Destination?
    public private(set) var destinationName: String?
    public private(set) var route: MKRoute?
    public private(set) var isNavigating = false
    public private(set) var calculating = false
    public private(set) var rerouting = false
    public private(set) var arrived = false
    public private(set) var error: String?
    public private(set) var steps: [RouteStep] = []
    public private(set) var coordinates: [CLLocationCoordinate2D] = []
    public private(set) var cumulative: [Double] = []
    public private(set) var totalM = 0.0
    public private(set) var travelledM = 0.0
    public private(set) var remainingM = 0
    public private(set) var maneuverM = 0
    public private(set) var instruction = ""
    public private(set) var road = ""
    public private(set) var turn = NavTurn.straight
    public private(set) var arrivalDate: Date?
    public private(set) var startedAt: Date?
    /// Bumps whenever a new route is applied, so the map can fit it.
    public private(set) var routeRevision = 0

    public var onCue: ((MapsCue) -> Void)?
    public var onStop: (() -> Void)?

    private let completer = MKLocalSearchCompleter()
    private var offRouteCount = 0
    private var searchTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var pendingOrigin: CLLocationCoordinate2D?
    private var wantsRoute = false

    public override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // MARK: - Search

    public func clearSearch() {
        query = ""
        completions = []
    }

    public func select(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        searchTask?.cancel()
        calculating = true
        error = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard let item = response.mapItems.first else {
                    self.error = "No place found for that search."
                    self.calculating = false
                    return
                }
                let coordinate = item.placemark.coordinate
                self.destination = Destination(
                    name: item.name ?? completion.title,
                    lat: coordinate.latitude,
                    lng: coordinate.longitude
                )
                self.destinationName = self.destination?.name
                self.completions = []
                self.query = ""
                guard let origin = LocationService.shared.coordinate ?? self.pendingOrigin else {
                    self.wantsRoute = true
                    self.error = "Waiting for your location…"
                    self.calculating = false
                    return
                }
                await self.calculateRoute(from: origin, to: coordinate, name: self.destinationName ?? "Destination")
            } catch {
                self.error = "Could not find that place: \(error.localizedDescription)"
                self.calculating = false
            }
        }
    }

    public func route(to name: String, lat: Double, lng: Double, from origin: CLLocationCoordinate2D?) {
        destination = Destination(name: name, lat: lat, lng: lng)
        destinationName = name
        guard let origin else {
            wantsRoute = true
            error = "Waiting for your location."
            return
        }
        routeTask?.cancel()
        calculating = true
        routeTask = Task { [weak self] in
            await self?.calculateRoute(from: origin, to: CLLocationCoordinate2D(latitude: lat, longitude: lng), name: name)
        }
    }

    private func calculateRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, name: String) async {
        calculating = true
        rerouting = false
        error = nil
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                error = "No driving route to \(name)."
                calculating = false
                return
            }
            apply(route: route)
            wantsRoute = false
            calculating = false
            if isNavigating {
                travelledM = 0
                arrived = false
                startedAt = Date()
                advanceProgress()
            }
        } catch {
            self.error = "Route failed: \(error.localizedDescription)"
            calculating = false
            rerouting = false
        }
    }

    private func apply(route: MKRoute) {
        self.route = route
        coordinates = route.polyline.coordinates
        cumulative = []
        var running = 0.0
        cumulative.reserveCapacity(coordinates.count)
        for (index, coordinate) in coordinates.enumerated() {
            if index > 0 {
                let previous = coordinates[index - 1]
                running += RideMath.haversineM(
                    lat1: previous.latitude, lng1: previous.longitude,
                    lat2: coordinate.latitude, lng2: coordinate.longitude
                )
            }
            cumulative.append(running)
        }
        totalM = max(running, 1)
        routeRevision += 1
        steps = []
        var edge = 0.0
        for (index, step) in route.steps.enumerated() {
            edge = min(edge + step.distance, totalM)
            let next = index + 1 < route.steps.count ? route.steps[index + 1] : nil
            let instruction = next?.instructions ?? "Arrive at \(destinationName ?? "destination")"
            steps.append(RouteStep(
                instruction: instruction,
                road: RouteTurn.road(instruction),
                turn: RouteTurn.of(instruction),
                endM: edge
            ))
        }
        if steps.isEmpty {
            steps = [RouteStep(
                instruction: "Arrive at \(destinationName ?? "destination")",
                road: "", turn: NavTurn.destination, endM: totalM
            )]
        }
        advanceProgress()
    }

    // MARK: - Guidance

    public func begin() {
        guard route != nil, destination != nil else { return }
        isNavigating = true
        arrived = false
        startedAt = Date()
        advanceProgress()
        if let cue { onCue?(cue) }
        guard isNavigating else { return }
    }

    public func stop() {
        guard isNavigating || route != nil else { return }
        isNavigating = false
        arrived = false
        startedAt = nil
        onStop?()
        route = nil
        steps = []
        coordinates = []
        destination = nil
        destinationName = nil
        remainingM = 0
        maneuverM = 0
    }

    public func finish() {
        isNavigating = false
        arrived = false
        startedAt = nil
        route = nil
        steps = []
        remainingM = 0
        maneuverM = 0
        onStop?()
    }

    public func resetForNewLink() {
        if isNavigating { stop() }
        offRouteCount = 0
    }

    /// Called for every accepted GPS fix.
    public func update(lat: Double, lng: Double) {
        if wantsRoute, let destination, !calculating {
            wantsRoute = false
            let from = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            routeTask?.cancel()
            calculating = true
            routeTask = Task { [weak self] in
                await self?.calculateRoute(from: from, to: destination.coordinate, name: destination.name)
            }
        }
        guard isNavigating, !coordinates.isEmpty else { return }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let nearest = nearestPoint(to: coordinate)
        travelledM = nearest.alongM
        if nearest.distanceM > 70 {
            offRouteCount += 1
        } else {
            offRouteCount = 0
        }
        advanceProgress()
        if offRouteCount >= 3, !calculating, let destination {
            offRouteCount = 0
            rerouting = true
            let from = coordinate
            routeTask?.cancel()
            routeTask = Task { [weak self] in
                await self?.calculateRoute(from: from, to: destination.coordinate, name: destination.name)
            }
        }
    }

    private func advanceProgress() {
        guard let route, !steps.isEmpty else { return }
        remainingM = Int(max(totalM - travelledM, 0).rounded())
        let index = steps.firstIndex { $0.endM > travelledM } ?? steps.count - 1
        let step = steps[max(index, 0)]
        maneuverM = Int(max(step.endM - travelledM, 0).rounded())
        instruction = step.instruction
        road = step.road
        turn = step.turn
        let fraction = totalM > 0 ? min(max(Double(remainingM) / totalM, 0), 1) : 0
        arrivalDate = Date().addingTimeInterval(route.expectedTravelTime * fraction)
        if remainingM < 20 {
            arrived = true
        }
    }

    public var cue: MapsCue? {
        guard isNavigating, let arrivalDate, !arrived else { return nil }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: arrivalDate)
        return MapsCue(
            turn: turn,
            distanceMeters: maneuverM,
            instruction: instruction,
            road: road,
            arrivalHour24: parts.hour,
            arrivalMinute: parts.minute,
            remainingMeters: remainingM,
            rerouting: rerouting
        )
    }

    public var remainingText: String {
        remainingM >= 1000 ? String(format: "%.1f km", Double(remainingM) / 1000) : "\(remainingM) m"
    }

    public var maneuverText: String {
        maneuverM >= 1000 ? String(format: "%.1f km", Double(maneuverM) / 1000) : "\(maneuverM) m"
    }

    public var arrivalText: String? {
        guard let arrivalDate else { return nil }
        return arrivalDate.formatted(date: .omitted, time: .shortened)
    }

    public var routeDistanceText: String? {
        guard let route else { return nil }
        return String(format: "%.1f km", route.distance / 1000)
    }

    public var routeTimeText: String? {
        guard let route else { return nil }
        return RideMath.formatDuration(seconds: Int64(route.expectedTravelTime))
    }

    // MARK: - Geometry

    private func nearestPoint(to coordinate: CLLocationCoordinate2D) -> (alongM: Double, distanceM: Double) {
        guard coordinates.count > 1 else { return (0, .infinity) }
        var best = (along: 0.0, distance: Double.greatestFiniteMagnitude)
        let kx = cos(coordinate.latitude * Double.pi / 180)
        for index in 1..<coordinates.count {
            let a = coordinates[index - 1]
            let b = coordinates[index]
            let ax = (a.longitude - coordinate.longitude) * kx * 111_320
            let ay = (a.latitude - coordinate.latitude) * 111_320
            let bx = (b.longitude - coordinate.longitude) * kx * 111_320
            let by = (b.latitude - coordinate.latitude) * 111_320
            let dx = bx - ax
            let dy = by - ay
            let lengthSq = dx * dx + dy * dy
            let t = lengthSq > 0 ? min(max(-(ax * dx + ay * dy) / lengthSq, 0), 1) : 0
            let px = ax + t * dx
            let py = ay + t * dy
            let distance = (px * px + py * py).squareRoot()
            if distance < best.distance {
                let segment = cumulative[index] - cumulative[index - 1]
                best = (cumulative[index - 1] + segment * t, distance)
            }
        }
        return (best.along, best.distance)
    }

    // MARK: - Completer

    public nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.completions = results }
    }

    public nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.completions = [] }
    }
}

/// Maps a MapKit instruction ("Turn right onto MG Road") to the cluster's turn symbol and road name.
public enum RouteTurn {
    public static func of(_ instruction: String) -> Int {
        let text = instruction.lowercased()
        if text.contains("arrive") || text.contains("destination") || text.contains("you have reached") {
            return NavTurn.destination
        }
        if text.contains("u-turn") || text.contains("u turn") { return NavTurn.uTurnLeft }
        if text.contains("roundabout") || text.contains("rotary") || text.contains("traffic circle") {
            return text.contains("take the") && text.contains("exit") ? NavTurn.roundaboutRight : NavTurn.roundaboutLeft
        }
        if text.contains("slight left") { return NavTurn.slightLeft }
        if text.contains("slight right") { return NavTurn.slightRight }
        if text.contains("sharp left") { return NavTurn.sharpLeft }
        if text.contains("sharp right") { return NavTurn.sharpRight }
        if text.contains("keep left") { return NavTurn.keepLeft }
        if text.contains("keep right") { return NavTurn.keepRight }
        if text.contains("fork left") { return NavTurn.forkLeft }
        if text.contains("fork right") { return NavTurn.forkRight }
        if text.contains("ramp") || text.contains("exit") {
            return text.contains("left") ? NavTurn.rampLeft : NavTurn.rampRight
        }
        if text.contains("merge") { return NavTurn.merge }
        if text.contains("ferry") || text.contains("train") { return NavTurn.ferryTrain }
        if text.contains("turn left") || text.contains("left onto") { return NavTurn.left }
        if text.contains("turn right") || text.contains("right onto") { return NavTurn.right }
        return NavTurn.straight
    }

    public static func road(_ instruction: String) -> String {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in [" onto ", " on ", " toward ", " towards ", " via "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                var road = String(text[range.upperBound...])
                if let cut = road.range(of: " and ") { road = String(road[..<cut.lowerBound]) }
                road = road.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
                if road.isEmpty { continue }
                return road
            }
        }
        return ""
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var values = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&values, range: NSRange(location: 0, length: pointCount))
        return values
    }
}
