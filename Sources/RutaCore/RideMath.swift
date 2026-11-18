import Foundation

// Ride and charging analytics. Port of `RideMath.kt`, host-tested by the Android repo's
// `RideAnalyticsTest.kt`. Units: time = UTC epoch ms, distance = m, speed = km/h, SOC = points.

/// A raw location fix. `speedKmh` is the receiver's Doppler speed, nil when the fix has none.
public struct GeoFix: Equatable, Sendable {
    public var time: Int64
    public var lat: Double
    public var lng: Double
    public var accuracyM: Double
    public var speedKmh: Double?

    public init(time: Int64, lat: Double, lng: Double, accuracyM: Double, speedKmh: Double? = nil) {
        self.time = time
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.speedKmh = speedKmh
    }
}

/// A fix accepted by `FixFilter`. A jitter-suppressed fix keeps the previous position, adds no
/// distance and reports 0 km/h.
public struct TrackStep: Equatable, Sendable {
    public var time: Int64
    public var lat: Double
    public var lng: Double
    public var accuracyM: Double
    public var stepM: Double
    public var speedKmh: Double
    public var moving: Bool

    public init(time: Int64, lat: Double, lng: Double, accuracyM: Double, stepM: Double, speedKmh: Double, moving: Bool) {
        self.time = time
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.stepM = stepM
        self.speedKmh = speedKmh
        self.moving = moving
    }
}

/// A stored ride point. `speedKmh` is the filtered speed, `distanceM` the cumulative distance.
public struct RidePoint: Equatable, Codable, Sendable {
    public var time: Int64
    public var lat: Double
    public var lng: Double
    public var speedKmh: Double
    public var distanceM: Double
    public var accuracyM: Double

    public init(time: Int64, lat: Double, lng: Double, speedKmh: Double, distanceM: Double, accuracyM: Double) {
        self.time = time
        self.lat = lat
        self.lng = lng
        self.speedKmh = speedKmh
        self.distanceM = distanceM
        self.accuracyM = accuracyM
    }
}

/// A finished ride. `start`/`end` span first to last movement; `avgKmh` is the moving average.
public struct Ride: Equatable, Codable, Identifiable, Sendable {
    public var id: Int64
    public var start: Int64
    public var end: Int64
    public var startLat: Double
    public var startLng: Double
    public var endLat: Double
    public var endLng: Double
    public var startPlace: String?
    public var endPlace: String?
    public var distanceM: Double
    public var durationS: Int64
    public var movingS: Int64
    public var peakKmh: Double
    public var avgKmh: Double
    public var socStart: Double?
    public var socEnd: Double?

    public init(
        id: Int64, start: Int64, end: Int64,
        startLat: Double, startLng: Double, endLat: Double, endLng: Double,
        startPlace: String?, endPlace: String?,
        distanceM: Double, durationS: Int64, movingS: Int64,
        peakKmh: Double, avgKmh: Double,
        socStart: Double?, socEnd: Double?
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.startLat = startLat
        self.startLng = startLng
        self.endLat = endLat
        self.endLng = endLng
        self.startPlace = startPlace
        self.endPlace = endPlace
        self.distanceM = distanceM
        self.durationS = durationS
        self.movingS = movingS
        self.peakKmh = peakKmh
        self.avgKmh = avgKmh
        self.socStart = socStart
        self.socEnd = socEnd
    }

    public var distanceKm: Double { distanceM / 1000 }
    /// Charge points used; negative when the charge rose. Nil without both readings.
    public var batteryUsed: Double? {
        guard let a = socStart, let b = socEnd else { return nil }
        return a - b
    }
    public var kmPerPercent: Double? { RideMath.kmPerPercent(distanceM: distanceM, socStart: socStart, socEnd: socEnd) }
    public var startLabel: String { startPlace ?? RideMath.latLngText(lat: startLat, lng: startLng) }
    public var endLabel: String { endPlace ?? RideMath.latLngText(lat: endLat, lng: endLng) }
    public var startArea: String? { RideMath.placeArea(startPlace) }
    public var endArea: String? { RideMath.placeArea(endPlace) }
}

/// A charging session on pack 0; while in progress, `end`/`socEnd` are the latest rise.
public struct ChargeSession: Equatable, Codable, Sendable {
    public var start: Int64
    public var end: Int64
    public var socStart: Double
    public var socEnd: Double
    public var id: Int64

    public init(start: Int64, end: Int64, socStart: Double, socEnd: Double, id: Int64 = 0) {
        self.start = start
        self.end = end
        self.socStart = socStart
        self.socEnd = socEnd
        self.id = id
    }

    public var durationS: Int64 { (end - start) / 1000 }
    public var gained: Double { socEnd - socStart }
    public var percentPerHour: Double {
        guard end > start else { return 0 }
        return gained * 3_600_000.0 / Double(end - start)
    }
}

/// One chart bucket; buckets without data are omitted (draw them as gaps).
public struct BucketPoint: Equatable, Sendable {
    public var time: Int64
    public var avg: Double
    public var min: Double
    public var max: Double
    public var count: Int

    public init(time: Int64, avg: Double, min: Double, max: Double, count: Int = 1) {
        self.time = time
        self.avg = avg
        self.min = min
        self.max = max
        self.count = count
    }
}

public struct ValueAt: Equatable, Sendable {
    public var time: Int64
    public var value: Double

    public init(time: Int64, value: Double) {
        self.time = time
        self.value = value
    }
}

/// The geocoder fields `RideMath.placeLabel` uses (MKPlacemark's equivalents).
public struct PlaceParts: Equatable, Sendable {
    public var thoroughfare: String?
    public var subLocality: String?
    public var locality: String?
    public var featureName: String?
    public var subAdminArea: String?
    public var adminArea: String?

    public init(
        thoroughfare: String?, subLocality: String?, locality: String?,
        featureName: String? = nil, subAdminArea: String? = nil, adminArea: String? = nil
    ) {
        self.thoroughfare = thoroughfare
        self.subLocality = subLocality
        self.locality = locality
        self.featureName = featureName
        self.subAdminArea = subAdminArea
        self.adminArea = adminArea
    }
}

/// Totals over a set of rides; `avgKmh` is total distance over total moving time.
public struct RideStats: Equatable, Sendable {
    public var rides: Int
    public var distanceM: Double
    public var durationS: Int64
    public var movingS: Int64
    public var peakKmh: Double
    public var avgKmh: Double
    public var batteryUsed: Double
    public var kmPerPercent: Double?

    public init(
        rides: Int, distanceM: Double, durationS: Int64, movingS: Int64,
        peakKmh: Double, avgKmh: Double, batteryUsed: Double, kmPerPercent: Double?
    ) {
        self.rides = rides
        self.distanceM = distanceM
        self.durationS = durationS
        self.movingS = movingS
        self.peakKmh = peakKmh
        self.avgKmh = avgKmh
        self.batteryUsed = batteryUsed
        self.kmPerPercent = kmPerPercent
    }
}

public enum RideEndReason: String, Equatable, Sendable {
    case ignitionOff = "IGNITION_OFF"
    case linkLost = "LINK_LOST"
    case idle = "IDLE"
    case stopped = "STOPPED"
}

public enum RideEvent: Equatable, Sendable {
    case started(time: Int64, byIgnition: Bool)
    case ended(time: Int64, reason: RideEndReason)
}

public enum RideMath {
    public static let earthRadiusM = 6_371_008.8
    public static let maxAccuracyM = 25.0
    public static let maxJumpKmh = 120.0
    /// Below this reported speed a fix inside the accuracy radius is GPS jitter, not movement.
    public static let jitterKmh = 3.0
    public static let minStepM = 5.0
    public static let movingKmh = 2.0
    public static let startKmh = 8.0
    public static let startHoldMs: Int64 = 10_000
    public static let ignitionOffMs: Int64 = 60_000
    public static let linkLostMs: Int64 = 120_000
    public static let idleMs: Int64 = 300_000
    public static let minRideM = 200.0
    public static let minRideS: Int64 = 60
    /// Below this many charge points used, km per % is noise.
    public static let minUsedPercent = 1.0

    public static func haversineM(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let p1 = lat1 * Double.pi / 180
        let p2 = lat2 * Double.pi / 180
        let dp = p2 - p1
        let dl = (lng2 - lng1) * Double.pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusM * asin(sqrt(min(max(h, 0.0), 1.0)))
    }

    public static func median3(_ a: Double, _ b: Double, _ c: Double) -> Double {
        max(min(a, b), min(max(a, b), c))
    }

    public static func averageKmh(distanceM: Double, movingMs: Int64) -> Double {
        movingMs > 0 ? distanceM * 3600.0 / Double(movingMs) : 0
    }

    public static func kmPerPercent(distanceM: Double, socStart: Double?, socEnd: Double?) -> Double? {
        guard let a = socStart, let b = socEnd else { return nil }
        let used = a - b
        return used >= minUsedPercent ? distanceM / 1000 / used : nil
    }

    public static func stats(_ rides: [Ride]) -> RideStats {
        let distance = rides.reduce(0) { $0 + $1.distanceM }
        let moving = rides.reduce(Int64(0)) { $0 + $1.movingS }
        let metered = rides.filter { $0.batteryUsed != nil }
        let used = metered.reduce(0.0) { $0 + ($1.batteryUsed ?? 0) }
        let meteredKm = metered.reduce(0.0) { $0 + $1.distanceM } / 1000
        return RideStats(
            rides: rides.count,
            distanceM: distance,
            durationS: rides.reduce(Int64(0)) { $0 + $1.durationS },
            movingS: moving,
            peakKmh: rides.map(\.peakKmh).max() ?? 0,
            avgKmh: averageKmh(distanceM: distance, movingMs: moving * 1000),
            batteryUsed: used,
            kmPerPercent: used >= minUsedPercent ? meteredKm / used : nil
        )
    }

    public static func bucketWidth(start: Int64, end: Int64, buckets: Int) -> Int64 {
        max(1, (end - start + Int64(buckets) - 1) / Int64(max(buckets, 1)))
    }

    /// Averages `values` in `[start, end)` into at most `buckets` buckets.
    public static func downsample(_ values: [ValueAt], start: Int64, end: Int64, buckets: Int) -> [BucketPoint] {
        guard buckets > 0, end > start else { return [] }
        let width = bucketWidth(start: start, end: end, buckets: buckets)
        var grouped: [Int64: [ValueAt]] = [:]
        for value in values where value.time >= start && value.time < end && value.value.isFinite {
            grouped[(value.time - start) / width, default: []].append(value)
        }
        return grouped.keys.sorted().map { bucket in
            let items = grouped[bucket]!
            let sum = items.reduce(0.0) { $0 + $1.value }
            return BucketPoint(
                time: start + bucket * width + width / 2,
                avg: sum / Double(items.count),
                min: items.map(\.value).min() ?? 0,
                max: items.map(\.value).max() ?? 0,
                count: items.count
            )
        }
    }

    public static func speedSeries(_ points: [RidePoint], buckets: Int) -> [BucketPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        return downsample(points.map { ValueAt(time: $0.time, value: $0.speedKmh) }, start: first.time, end: last.time + 1, buckets: buckets)
    }

    /// Charging sessions in a stored pack-0 SOC series. A gap longer than `gapMs` counts as a lost link.
    public static func chargeSessions(_ samples: [ValueAt], gapMs: Int64 = 120_000) -> [ChargeSession] {
        let detector = ChargeDetector()
        var found: [Int64: ChargeSession] = [:]
        var order: [Int64] = []
        func record(_ session: ChargeSession?) {
            guard let session else { return }
            if found[session.start] == nil { order.append(session.start) }
            found[session.start] = session
        }
        var previous: Int64?
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            if let previous, sample.time - previous > gapMs {
                record(detector.update(now: previous + gapMs, soc: nil, linkReady: false, riding: false))
            }
            record(detector.update(now: sample.time, soc: sample.value, linkReady: true, riding: false))
            previous = sample.time
        }
        record(detector.stop())
        return order.compactMap { found[$0] }
    }

    private static let plusCode = try! NSRegularExpression(pattern: "^[23456789CFGHJMPQRVWX]{2,8}\\+[23456789CFGHJMPQRVWX]*$", options: .caseInsensitive)
    private static let plusCodePrefix = try! NSRegularExpression(pattern: "^[23456789CFGHJMPQRVWX]{2,8}\\+[23456789CFGHJMPQRVWX]*[ ,]+", options: .caseInsensitive)
    private static let unnamed = try! NSRegularExpression(pattern: "^unnamed( road)?$", options: .caseInsensitive)
    private static let houseNumber = try! NSRegularExpression(
        pattern: "^(?:(?:plot|h\\.?\\s*no|house\\s*no|door\\s*no|flat|no)\\b.*|\\d\\w*(?:[/-]\\w+)+.*|\\d+[a-z]?)$",
        options: .caseInsensitive
    )

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A geocoder field worth showing: no plus codes, house numbers or "Unnamed Road".
    private static func usable(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let match = plusCodePrefix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter }),
              !matches(plusCode, text),
              !matches(unnamed, text),
              !matches(houseNumber, text) else { return nil }
        return text
    }

    /// Place label from geocoder results (nearest first): "Riverside Garden Rd, Lakeside".
    public static func placeLabel(_ results: [PlaceParts]) -> String? {
        func first(_ field: (PlaceParts) -> String?) -> String? {
            for result in results {
                if let value = usable(field(result)) { return value }
            }
            return nil
        }
        let street = first { $0.thoroughfare }
        let area = first { $0.subLocality }
        let city = first { $0.locality }
        let fallback = first { $0.featureName } ?? first { $0.subAdminArea } ?? first { $0.adminArea }
        let label: String?
        if let street {
            var parts = [street]
            if let next = area ?? city {
                if next.lowercased() != street.lowercased() { parts.append(next) }
            }
            label = parts.joined(separator: ", ")
        } else {
            label = area ?? city ?? fallback
        }
        guard let label, !label.isEmpty else { return nil }
        return label
    }

    public static func placeLabel(
        subLocality: String?, thoroughfare: String?, locality: String?,
        featureName: String? = nil, subAdminArea: String? = nil, adminArea: String? = nil
    ) -> String? {
        placeLabel([PlaceParts(
            thoroughfare: thoroughfare, subLocality: subLocality, locality: locality,
            featureName: featureName, subAdminArea: subAdminArea, adminArea: adminArea
        )])
    }

    /// The area of a `placeLabel` ("Lakeside" from "Riverside Garden Rd, Lakeside").
    public static func placeArea(_ label: String?) -> String? {
        guard let label, let range = label.range(of: ", ", options: .backwards) else {
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        let area = label[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return area.isEmpty ? nil : area
    }

    private static let streetWords = [
        "road": "Rd", "street": "St", "lane": "Ln", "avenue": "Ave", "highway": "Hwy",
        "expressway": "Expy", "boulevard": "Blvd", "junction": "Jn", "circle": "Cir",
    ]
    private static let streetWord = try! NSRegularExpression(
        pattern: "\\b(\(streetWords.keys.joined(separator: "|")))\\b", options: .caseInsensitive
    )

    /// Place text for compact titles: street words abbreviated, spaces tidied.
    public static func shortPlace(_ text: String) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let range = NSRange(collapsed.startIndex..., in: collapsed)
        let matches = streetWord.matches(in: collapsed, range: range)
        var output = collapsed
        for match in matches.reversed() {
            guard let r = Range(match.range, in: output) else { continue }
            let word = String(output[r]).lowercased()
            output.replaceSubrange(r, with: streetWords[word] ?? String(output[r]))
        }
        return output
    }

    /// Short ride title from start and end labels, preferring areas.
    public static func rideTitle(startPlace: String?, endPlace: String?) -> String? {
        guard let a = startPlace?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty,
              let b = endPlace?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return nil }
        let areaA = placeArea(a) ?? a
        let areaB = placeArea(b) ?? b
        if areaA.lowercased() != areaB.lowercased() {
            return "\(shortPlace(areaA)) → \(shortPlace(areaB))"
        }
        let firstA = a.components(separatedBy: ", ").first?.trimmingCharacters(in: .whitespaces) ?? a
        let firstB = b.components(separatedBy: ", ").first?.trimmingCharacters(in: .whitespaces) ?? b
        if firstA.lowercased() != firstB.lowercased() {
            return "\(shortPlace(firstA)) → \(shortPlace(firstB))"
        }
        return "Around \(shortPlace(firstA))"
    }

    /// Chart points prepared for drawing: gaps split runs; points in one slot merge.
    public static func plotRuns(_ points: [BucketPoint], origin: Int64, slotMs: Int64, gapMs: Int64) -> [[BucketPoint]] {
        var runs: [[BucketPoint]] = []
        var run: [BucketPoint] = []
        var slot = Int64.min
        var weight = 0.0
        var timeSum = 0.0
        var avgSum = 0.0
        var low = Double.infinity
        var high = -Double.infinity
        var count = 0

        func flush() {
            guard count > 0 else { return }
            run.append(BucketPoint(
                time: Int64((timeSum / weight).rounded()),
                avg: avgSum / weight, min: low, max: high, count: count
            ))
            weight = 0; timeSum = 0; avgSum = 0; count = 0
            low = .infinity; high = -.infinity
        }

        var previous: Int64?
        for point in points {
            guard point.avg.isFinite else { continue }
            let gap = previous.map { point.time - $0 > gapMs } ?? false
            let nextSlot = slotMs > 0 ? floorDivide(point.time - origin, slotMs) : Int64.min
            if gap || slotMs <= 0 || nextSlot != slot { flush() }
            if gap && !run.isEmpty { runs.append(run); run = [] }
            slot = nextSlot
            let w = Double(max(point.count, 1))
            weight += w; timeSum += Double(point.time) * w; avgSum += point.avg * w
            low = min(low, point.min); high = max(high, point.max)
            count += max(point.count, 1)
            previous = point.time
        }
        flush()
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }

    /// Insights' default period: true when every known time is within the day before `now`.
    public static func fitsLastDay(_ times: [Int64?], now: Int64) -> Bool {
        let known = times.compactMap { $0 }
        return !known.isEmpty && known.allSatisfy { $0 >= now - 86_400_000 }
    }

    public static func latLngText(lat: Double, lng: Double) -> String {
        String(format: "%.4f, %.4f", lat, lng)
    }

    /// "45 s", "12 min", "1 h 05 min".
    public static func formatDuration(seconds: Int64) -> String {
        if seconds < 60 { return "\(max(seconds, 0)) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return String(format: "%d h %02d min", seconds / 3600, seconds % 3600 / 60)
    }

    /// At most `max` points, evenly spaced, always keeping the first and last.
    public static func thin(_ points: [RidePoint], max maximum: Int) -> [RidePoint] {
        guard points.count > maximum, maximum >= 2 else { return points }
        let step = Double(points.count - 1) / Double(maximum - 1)
        return (0..<maximum).map { points[Int((Double($0) * step).rounded())] }
    }

    /// Projects a track into a width × height box (equirectangular, aspect preserved, centred, north up).
    public static func project(_ points: [RidePoint], width: Float, height: Float, padding: Float = 0) -> [Float] {
        guard let first = points.first else { return [] }
        var minLat = first.lat, maxLat = first.lat, minLng = first.lng, maxLng = first.lng
        for point in points {
            minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
            minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
        }
        let kx = cos((minLat + maxLat) / 2 * Double.pi / 180)
        let spanX = (maxLng - minLng) * kx
        let spanY = maxLat - minLat
        let w = max(width - 2 * padding, 0)
        let h = max(height - 2 * padding, 0)
        var scale = Double.greatestFiniteMagnitude
        if spanX > 0 { scale = min(scale, Double(w) / spanX) }
        if spanY > 0 { scale = min(scale, Double(h) / spanY) }
        if scale == .greatestFiniteMagnitude { scale = 0 }
        let left = Double(padding) + (Double(w) - spanX * scale) / 2
        let top = Double(padding) + (Double(h) - spanY * scale) / 2
        var output = [Float](repeating: 0, count: points.count * 2)
        for (index, point) in points.enumerated() {
            output[2 * index] = Float(left + (point.lng - minLng) * kx * scale)
            output[2 * index + 1] = Float(top + (maxLat - point.lat) * scale)
        }
        return output
    }

    /// Google Maps directions from the first to the last point of the track.
    public static func routeUrl(_ points: [RidePoint]) -> String? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        return directionsUrl(fromLat: first.lat, fromLng: first.lng, toLat: last.lat, toLng: last.lng)
    }

    public static func directionsUrl(fromLat: Double, fromLng: Double, toLat: Double, toLng: Double) -> String {
        func ll(_ lat: Double, _ lng: Double) -> String { String(format: "%.6f,%.6f", lat, lng) }
        return "https://www.google.com/maps/dir/?api=1&origin=\(ll(fromLat, fromLng))&destination=\(ll(toLat, toLng))&travelmode=driving"
    }
}

/// Drops unusable fixes. Slow fixes inside the accuracy radius are jitter and add nothing.
public final class FixFilter {
    private let maxAccuracyM: Double
    private let maxKmh: Double
    private var anchor: GeoFix?
    private var lastTime: Int64 = 0
    private var jumps = 0

    public init(maxAccuracyM: Double = RideMath.maxAccuracyM, maxKmh: Double = RideMath.maxJumpKmh) {
        self.maxAccuracyM = maxAccuracyM
        self.maxKmh = maxKmh
    }

    public func reset() {
        anchor = nil
        lastTime = 0
        jumps = 0
    }

    public func accept(_ fix: GeoFix) -> TrackStep? {
        guard fix.lat.isFinite, fix.lng.isFinite, abs(fix.lat) <= 90, abs(fix.lng) <= 180,
              !(fix.lat == 0 && fix.lng == 0), fix.accuracyM <= maxAccuracyM else { return nil }
        let reported = fix.speedKmh.flatMap { $0.isFinite && $0 >= 0 && $0 <= maxKmh ? $0 : nil }
        guard let from = anchor else { return restart(fix, reported: reported) }
        let dt = fix.time - lastTime
        guard dt > 0 else { return nil }
        let d = RideMath.haversineM(lat1: from.lat, lng1: from.lng, lat2: fix.lat, lng2: fix.lng)
        if d * 3600.0 / Double(dt) > maxKmh {
            jumps += 1
            return jumps >= 5 ? restart(fix, reported: reported) : nil
        }
        jumps = 0
        lastTime = fix.time
        if (reported == nil || reported! < RideMath.jitterKmh) && d < max(RideMath.minStepM, fix.accuracyM) {
            return TrackStep(time: fix.time, lat: from.lat, lng: from.lng, accuracyM: fix.accuracyM, stepM: 0, speedKmh: 0, moving: false)
        }
        anchor = fix
        let speed = reported ?? d * 3600.0 / Double(max(fix.time - from.time, 1))
        return TrackStep(time: fix.time, lat: fix.lat, lng: fix.lng, accuracyM: fix.accuracyM, stepM: d, speedKmh: speed, moving: speed >= RideMath.movingKmh)
    }

    private func restart(_ fix: GeoFix, reported: Double?) -> TrackStep {
        anchor = fix
        lastTime = fix.time
        jumps = 0
        return TrackStep(time: fix.time, lat: fix.lat, lng: fix.lng, accuracyM: fix.accuracyM, stepM: 0, speedKmh: reported ?? 0, moving: false)
    }
}

/// Median of the last three speeds; until three exist, the lowest.
public final class SpeedSmoother {
    private var window: [Double] = []

    public init() {}

    public var full: Bool { window.count == 3 }

    public func add(_ kmh: Double) -> Double {
        if window.count == 3 { window.removeFirst() }
        window.append(kmh)
        if full { return RideMath.median3(window[0], window[1], window[2]) }
        return window.min() ?? kmh
    }

    public func reset() { window.removeAll() }
}

/// Accumulates one ride from filtered steps; `replay` rebuilds an interrupted ride from stored points.
public final class RideAccumulator {
    public private(set) var distanceM = 0.0
    public private(set) var movingMs: Int64 = 0
    public private(set) var peakKmh = 0.0
    public private(set) var speedKmh = 0.0
    public private(set) var last: RidePoint?
    public private(set) var startPoint: RidePoint?
    public private(set) var endPoint: RidePoint?
    private let smoother = SpeedSmoother()

    public static let gapMs: Int64 = 5_000

    public init() {}

    @discardableResult
    public func add(_ step: TrackStep) -> RidePoint {
        let previous = last
        let stepM = previous == nil ? 0 : step.stepM
        distanceM += stepM
        let point = RidePoint(time: step.time, lat: step.lat, lng: step.lng, speedKmh: step.speedKmh, distanceM: distanceM, accuracyM: step.accuracyM)
        if let previous, step.moving, stepM > 0 {
            let dt = step.time - previous.time
            if dt <= Self.gapMs {
                movingMs += dt
            } else if step.speedKmh > 0 {
                movingMs += min(dt, Int64((stepM * 3600.0 / step.speedKmh).rounded()))
            }
            if startPoint == nil { startPoint = previous }
            endPoint = point
        }
        speedKmh = smoother.add(step.speedKmh)
        if smoother.full { peakKmh = max(peakKmh, speedKmh) }
        last = point
        return point
    }

    public var averageKmh: Double { RideMath.averageKmh(distanceM: distanceM, movingMs: movingMs) }

    /// The ride between first and last movement, or nil when shorter than 200 m or 60 s.
    public func finish(id: Int64, socStart: Double?, socEnd: Double?) -> Ride? {
        guard let from = startPoint, let to = endPoint else { return nil }
        let durationS = (to.time - from.time) / 1000
        guard distanceM >= RideMath.minRideM, durationS >= RideMath.minRideS else { return nil }
        return Ride(
            id: id, start: from.time, end: to.time,
            startLat: from.lat, startLng: from.lng, endLat: to.lat, endLng: to.lng,
            startPlace: nil, endPlace: nil,
            distanceM: distanceM, durationS: durationS, movingS: movingMs / 1000,
            peakKmh: peakKmh, avgKmh: averageKmh, socStart: socStart, socEnd: socEnd
        )
    }

    public static func replay(_ points: [RidePoint]) -> RideAccumulator {
        let accumulator = RideAccumulator()
        var previous: RidePoint?
        for point in points.sorted(by: { $0.time < $1.time }) {
            let stepM = previous.map { max(point.distanceM - $0.distanceM, 0) } ?? 0
            accumulator.add(TrackStep(
                time: point.time, lat: point.lat, lng: point.lng, accuracyM: point.accuracyM,
                stepM: stepM, speedKmh: point.speedKmh,
                moving: stepM > 0 && point.speedKmh >= RideMath.movingKmh
            ))
            previous = point
        }
        return accumulator
    }
}

/// Ride start/stop rules. Feed `update` about once a second and on every fix.
public final class RideSegmenter {
    public private(set) var riding = false
    public private(set) var startedAt: Int64 = 0
    private var ignitionArmed = true
    private var fastSince: Int64?
    private var offSince: Int64?
    private var lostSince: Int64?
    private var idleSince: Int64?
    private var lastMovingAt: Int64 = 0

    public init() {}

    /// `speedKmh` is the latest fresh filtered GPS speed, nil without a recent fix.
    public func update(now: Int64, linkReady: Bool, ignitionOn: Bool?, speedKmh: Double?) -> RideEvent? {
        if ignitionOn == false { ignitionArmed = true }
        let speed = speedKmh ?? 0
        if speed > RideMath.startKmh { fastSince = fastSince ?? now } else { fastSince = nil }
        if speed >= RideMath.movingKmh { lastMovingAt = now }

        if !riding {
            guard linkReady else { return nil }
            let byIgnition = ignitionOn == true && ignitionArmed
            let bySpeed = fastSince.map { now - $0 >= RideMath.startHoldMs } ?? false
            guard byIgnition || bySpeed else { return nil }
            riding = true
            startedAt = bySpeed ? (fastSince ?? now) : now
            offSince = nil; lostSince = nil; idleSince = nil
            lastMovingAt = speed >= RideMath.movingKmh ? now : startedAt
            return .started(time: startedAt, byIgnition: byIgnition)
        }

        if ignitionOn == false && speed <= RideMath.startKmh { offSince = offSince ?? now } else { offSince = nil }
        if !linkReady { lostSince = lostSince ?? now } else { lostSince = nil }
        if speed < RideMath.movingKmh { idleSince = idleSince ?? now } else { idleSince = nil }

        let reason: RideEndReason
        let since: Int64
        if let off = offSince, now - off >= RideMath.ignitionOffMs {
            reason = .ignitionOff; since = off
        } else if let lost = lostSince, now - lost >= RideMath.linkLostMs {
            reason = .linkLost; since = lost
        } else if let idle = idleSince, now - idle >= RideMath.idleMs {
            reason = .idle; since = idle
        } else {
            return nil
        }
        if reason == .idle && ignitionOn == true { ignitionArmed = false }
        return end(at: min(max(since, lastMovingAt), now), reason: reason)
    }

    public func stop(now: Int64) -> RideEvent? {
        riding ? end(at: now, reason: .stopped) : nil
    }

    private func end(at time: Int64, reason: RideEndReason) -> RideEvent {
        riding = false
        fastSince = nil; offSince = nil; lostSince = nil; idleSince = nil
        return .ended(time: time, reason: reason)
    }
}

/// Charging from the pack-0 SOC series.
public final class ChargeDetector {
    public private(set) var active: ChargeSession?
    private var low: ValueAt?
    private var previous: ChargeSession?

    public static let minRise = 1.0
    public static let confirmMs: Int64 = 300_000
    public static let stallMs: Int64 = 600_000
    public static let windowMs: Int64 = 1_800_000
    public static let mergeMs: Int64 = 1_800_000

    public init() {}

    @discardableResult
    public func update(now: Int64, soc: Double?, linkReady: Bool, riding: Bool) -> ChargeSession? {
        if !linkReady || riding {
            low = nil
            let done = finish()
            if riding { previous = nil }
            return done
        }
        if let current = active {
            if let soc, soc.isFinite {
                if soc > current.socEnd {
                    active = ChargeSession(start: current.start, end: now, socStart: current.socStart, socEnd: soc, id: current.id)
                    return nil
                }
                return now - current.end >= Self.stallMs ? finish() : nil
            }
            return now - current.end >= Self.stallMs ? finish() : nil
        }
        guard let soc, soc.isFinite else { return nil }
        guard let base = low, soc > base.value, now - base.time <= Self.windowMs else {
            low = ValueAt(time: now, value: soc)
            return nil
        }
        if soc - base.value >= Self.minRise && now - base.time >= Self.confirmMs {
            if let last = previous, base.time - last.end <= Self.mergeMs, base.value >= last.socEnd - 0.5 {
                active = ChargeSession(start: last.start, end: now, socStart: last.socStart, socEnd: soc, id: last.id)
            } else {
                active = ChargeSession(start: base.time, end: now, socStart: base.value, socEnd: soc)
            }
            previous = nil
            low = nil
        }
        return nil
    }

    public func stop() -> ChargeSession? {
        low = nil
        let done = finish()
        previous = nil
        return done
    }

    private func finish() -> ChargeSession? {
        guard let done = active else { return nil }
        active = nil
        previous = done
        return done
    }
}
