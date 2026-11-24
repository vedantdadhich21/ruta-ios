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
    private var routeRequest = 0
    private var searchRequest = 0
    private let countdown = NavCountdown()
    private let odometer = NavOdometer()
    private var nextTurn: Int?

    public override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // MARK: - Search

    public func clearSearch() {
        searchRequest += 1
        searchTask?.cancel()
        query = ""
        completions = []
    }

    public func select(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        searchRequest += 1
        let searchID = searchRequest
        searchTask?.cancel()
        calculating = true
        error = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled, searchID == self.searchRequest else { return }
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
                let request = self.nextRouteRequest()
                await self.calculateRoute(from: origin, to: coordinate, name: self.destinationName ?? "Destination", requestID: request)
            } catch {
                guard !Task.isCancelled, searchID == self.searchRequest else { return }
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
        let request = nextRouteRequest()
        routeTask = Task { [weak self] in
            await self?.calculateRoute(from: origin, to: CLLocationCoordinate2D(latitude: lat, longitude: lng), name: name, requestID: request)
        }
    }

    private func nextRouteRequest() -> Int {
        routeRequest += 1
        return routeRequest
    }

    private func calculateRoute(
        from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
        name: String, requestID: Int
    ) async {
        guard !Task.isCancelled, requestID == routeRequest else { return }
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
            guard !Task.isCancelled, requestID == routeRequest else { return }
            guard let route = response.routes.first else {
                error = "No driving route to \(name)."
                calculating = false
                return
            }
            apply(route: route)
            wantsRoute = false
            calculating = false
            if isNavigating {
                startedAt = Date()
                advanceProgress()
            }
        } catch {
            guard !Task.isCancelled, requestID == routeRequest else { return }
            self.error = "Route failed: \(error.localizedDescription)"
            calculating = false
            rerouting = false
        }
    }

    private func apply(route: MKRoute) {
        travelledM = 0
        arrived = false
        offRouteCount = 0
        countdown.reset()
        odometer.reset()
        nextTurn = nil
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
        clearNavigation(notify: true)
    }

    public func finish() {
        clearNavigation(notify: true)
    }

    private func clearNavigation(notify: Bool) {
        invalidateRequests()
        isNavigating = false
        arrived = false
        startedAt = nil
        route = nil
        steps = []
        coordinates = []
        cumulative = []
        destination = nil
        destinationName = nil
        pendingOrigin = nil
        error = nil
        remainingM = 0
        maneuverM = 0
        travelledM = 0
        totalM = 0
        arrivalDate = nil
        countdown.reset()
        odometer.reset()
        nextTurn = nil
        if notify { onStop?() }
    }

    private func invalidateRequests() {
        searchRequest += 1
        routeRequest += 1
        searchTask?.cancel()
        routeTask?.cancel()
        calculating = false
        wantsRoute = false
        rerouting = false
    }

    public func resetForNewLink() {
        if isNavigating || route != nil || destination != nil || calculating { stop() }
        offRouteCount = 0
    }

    /// Called only for GPS fixes accepted by the ride filter.
    public func update(fix: GeoFix) {
        if wantsRoute, let destination, !calculating {
            wantsRoute = false
            let from = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lng)
            routeTask?.cancel()
            calculating = true
            let request = nextRouteRequest()
            routeTask = Task { [weak self] in
                await self?.calculateRoute(from: from, to: destination.coordinate, name: destination.name, requestID: request)
            }
        }
        guard isNavigating, !coordinates.isEmpty else { return }
        let speedMps = fix.speedKmh.map { $0 / 3.6 }
        let added = odometer.add(
            timeMs: fix.time, lat: fix.lat, lng: fix.lng,
            accuracyM: fix.accuracyM, speedMps: speedMps, gps: true
        )
        guard added else { return }
        let coordinate = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lng)
        let nearest = nearestPoint(to: coordinate)
        if nearest.distanceM > 70 {
            offRouteCount += 1
        } else {
            offRouteCount = 0
            // Route progress cannot move backwards from GPS jitter. A reroute resets it explicitly.
            if nearest.alongM >= travelledM { travelledM = nearest.alongM }
        }
        advanceProgress()
        if offRouteCount >= 3, !calculating, let destination {
            offRouteCount = 0
            rerouting = true
            let from = coordinate
            routeTask?.cancel()
            let request = nextRouteRequest()
            routeTask = Task { [weak self] in
                await self?.calculateRoute(from: from, to: destination.coordinate, name: destination.name, requestID: request)
            }
        }
    }

    /// Advances the cluster countdown between GPS updates using distance actually travelled.
    public func tick() {
        guard isNavigating, !arrived else { return }
        let distances = countdown.at(travelledM: odometer.totalM)
        maneuverM = max(0, distances.maneuverM)
        if let remaining = distances.remainingM { remainingM = max(0, remaining) }
        updateArrival()
        if remainingM < 20 { arrived = true }
    }

    private func advanceProgress() {
        guard let _ = route, !steps.isEmpty else { return }
        let rawRemaining = Int(max(totalM - travelledM, 0).rounded())
        let index = steps.firstIndex { $0.endM > travelledM } ?? steps.count - 1
        let step = steps[max(index, 0)]
        let rawManeuver = Int(max(step.endM - travelledM, 0).rounded())
        instruction = step.instruction
        road = step.road
        turn = step.turn
        nextTurn = RouteTurn.thenTurn(step.instruction)

        let raw = MapsCue(
            turn: turn, distanceMeters: rawManeuver, instruction: instruction, road: road,
            arrivalHour24: nil, arrivalMinute: nil, remainingMeters: rawRemaining,
            rerouting: rerouting, thenTurn: nextTurn
        )
        countdown.update(raw, travelledM: odometer.totalM, nowMs: Int64(ProcessInfo.processInfo.systemUptime * 1000))
        let distances = countdown.at(travelledM: odometer.totalM)
        maneuverM = max(0, distances.maneuverM)
        remainingM = max(0, distances.remainingM ?? rawRemaining)
        updateArrival()
        if remainingM < 20 { arrived = true }
    }

    private func updateArrival() {
        guard let route else { arrivalDate = nil; return }
        let fraction = totalM > 0 ? min(max(Double(remainingM) / totalM, 0), 1) : 0
        arrivalDate = Date().addingTimeInterval(route.expectedTravelTime * fraction)
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
            rerouting: rerouting,
            thenTurn: nextTurn
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
    private static let sideNote = regex("\\s*\\([^)]*\\)")
    private static let leadingLandmark = regex("^at\\s+(?!the\\s)[^,]+,\\s*")
    private static let nameClause = regex(
        "\\s+(?:onto|towards?|after|before|past|via|by|follow)\\s+|\\s+(?:at|on)\\s+(?!(?:the|your)\\s+(?:next\\s+)?(?:left|right|roundabout|rotary|traffic circle|fork|end)\\b)|\\s+to\\s+(?!(?:take|stay|continue|follow|merge|keep|turn|make|use|go|enter|exit|join|reach|get|avoid)\\b)"
    )
    private static let destination = regex(
        "\\byour destination\\b|\\bdestination will be on\\b|\\byou have arrived\\b|\\barrived? at\\b|\\b(?:is|will be) on (?:the|your) (?:left|right)\\.?$|^(?:you(?:'|’)ve\\s+)?arrived\\b"
    )
    private static let thenClause = regex(
        "(?:\\s*[,;]\\s*|\\s+[·•|]\\s+|\\s+|^)(?:and\\s+)?then\\b[\\s,]*(?=(?:turn|keep|make|take|bear|slight|sharp|stay|continue|go|merge|exit|enter|use|head|at\\s+the|u[- ]?turn|you(?:'|’)ll|arrive|your\\s+destination|the\\s+destination)\\b)"
    )

    public static func of(_ instruction: String) -> Int {
        let core = current(instruction).lowercased()
        let maneuver = Self.split(nameClause, replacing(leadingLandmark, in: core, with: "")).first ?? core
        func has(_ pattern: String) -> Bool { matches(regex("\\b(?:\(pattern))\\b"), in: maneuver) }
        let left = has("left")
        let right = has("right")

        if has("u[- ]?turn") {
            return has("left u[- ]?turn|u[- ]?turn to the left") ? NavTurn.uTurnLeft : NavTurn.uTurnRight
        }
        if has("roundabouts?|traffic circle|at the rotary|(?:\\d+(?:st|nd|rd|th)|first|second|third|fourth|fifth|sixth) exit|exit\\s+\\d+") {
            return has("counterclockwise|anticlockwise") ? NavTurn.roundaboutRight : NavTurn.roundaboutLeft
        }
        if matches(destination, in: core) { return NavTurn.destination }
        if has("sharp left") { return NavTurn.sharpLeft }
        if has("sharp right") { return NavTurn.sharpRight }
        if has("slight left|bear left|slightly left") { return NavTurn.slightLeft }
        if has("slight right|bear right|slightly right") { return NavTurn.slightRight }
        if has("keep left") { return NavTurn.keepLeft }
        if has("keep right") { return NavTurn.keepRight }
        if has("turn left|make a left") { return NavTurn.left }
        if has("turn right|make a right") { return NavTurn.right }
        if has("fork") { return right && !left ? NavTurn.forkRight : NavTurn.forkLeft }
        if has("ramp|exit") { return right && !left ? NavTurn.rampRight : NavTurn.rampLeft }
        if has("merge") { return NavTurn.merge }
        if has("ferry") { return has("train") ? NavTurn.ferryTrain : NavTurn.ferry }
        if has("head|continue|straight|stay|pass") { return NavTurn.straight }
        if left && !right { return NavTurn.left }
        if right && !left { return NavTurn.right }
        return NavTurn.straight
    }

    public static func road(_ instruction: String) -> String {
        let text = replacing(sideNote, in: instruction, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(destination, in: text.lowercased()) { return "" }
        func after(_ keyword: String) -> String? {
            let pattern = "\\b\(keyword)\\s++(?!(?:the|your)\\s+(?:left|right)\\b)(.+)$"
            guard let match = regex(pattern, options: .caseInsensitive).firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ), let range = Range(match.range(at: 1), in: text) else { return nil }
            var value = String(text[range])
            let separators = regex("\\s+towards?\\s+|\\s+via\\s+|\\s+for\\s+\\d|\\s*[,;]\\s*|\\s+then\\s+|\\s+[·•|]\\s+", options: .caseInsensitive)
            if let cut = separators.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let range = Range(cut.range, in: value) {
                value = String(value[..<range.lowerBound])
            }
            value = value.components(separatedBy: "/").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
            return value.isEmpty ? nil : value
        }
        let to = "to(?!\\s+(?:take|stay|continue|follow|merge|keep|turn|make|use|go|enter|exit|join|reach|get|avoid)\\b)"
        return after("onto") ?? after("on") ?? after("towards") ?? after("toward")
            ?? after(to) ?? after("follow(?!\\s+signs\\b)") ?? ""
    }

    public static func current(_ instruction: String) -> String {
        let text = replacing(sideNote, in: instruction, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = thenClause.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            let head = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return head.isEmpty ? text : head
        }
        return text
    }

    /// A second maneuver only when the instruction contains an explicit "then …" clause.
    public static func thenTurn(_ instruction: String) -> Int? {
        let text = replacing(sideNote, in: instruction, with: "")
        guard let match = thenClause.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : of(tail)
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(_ expression: NSRegularExpression, in text: String, with replacement: String) -> String {
        expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement
        )
    }

    private static func split(_ expression: NSRegularExpression, _ text: String) -> [String] {
        expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{1F}"
        ).components(separatedBy: "\u{1F}")
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
