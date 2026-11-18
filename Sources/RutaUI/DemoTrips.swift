import Foundation
import RutaCore

/// Believable history for demo mode and the macOS preview: rides around Bengaluru with real-looking
/// tracks, charge levels and place names, plus a few charging sessions. Nothing is fetched.
public enum DemoTrips {
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func double(_ range: ClosedRange<Double>) -> Double {
            let unit = Double(next() % 10_000) / 10_000
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private static let places: [(String, Double, Double)] = [
        ("Indiranagar, Bengaluru", 12.9719, 77.6412),
        ("Koramangala 5th Block, Bengaluru", 12.9352, 77.6245),
        ("Jayanagar 4th Block, Bengaluru", 12.9250, 77.5938),
        ("MG Road, Bengaluru", 12.9756, 77.6068),
        ("Hebbal, Bengaluru", 13.0358, 77.5970),
        ("Whitefield, Bengaluru", 12.9698, 77.7500),
        ("Malleshwaram, Bengaluru", 13.0035, 77.5645),
        ("HSR Layout, Bengaluru", 12.9121, 77.6446),
        ("Cubbon Park, Bengaluru", 12.9763, 77.5929),
        ("Bellandur, Bengaluru", 12.9304, 77.6784),
        ("Rajajinagar, Bengaluru", 12.9916, 77.5557),
        ("Banashankari, Bengaluru", 12.9255, 77.5468),
    ]

    private static let roads = [
        "100 Feet Rd, Indiranagar", "80 Feet Rd, Koramangala", "Sarjapur Rd, Bellandur",
        "Old Madras Rd, Indiranagar", "Bellary Rd, Hebbal", "Chord Rd, Rajajinagar",
        "Hosur Rd, HSR Layout", "Kanakapura Rd, Banashankari", "Mysore Rd, Jayanagar",
    ]

    public static func make(now: Int64) -> (rides: [StoredRide], charges: [ChargeSession]) {
        var random = Seeded(state: 0x52555441)
        var rides: [StoredRide] = []
        var charges: [ChargeSession] = []
        let day: Int64 = 86_400_000

        // One ride every other day, newest first, ending before "now".
        for index in 0..<9 {
            let daysAgo = Int64(2 + index * 2)
            let minutesAgo = Int64(random.int(40...300))
            let end = now - daysAgo * day - minutesAgo * 60_000
            let minutes = random.int(11...44)
            let start = end - Int64(minutes) * 60_000
            let from = places[random.int(0...(places.count - 1))]
            let to = places[random.int(0...(places.count - 1))]
            let targetKm = random.double(3.2...17.5)
            let socStart = random.double(46...94)
            let kmPerPercent = random.double(0.95...1.3)
            let socEnd = max(socStart - targetKm / kmPerPercent, 8)

            var points: [RidePoint] = []
            var lat = from.1
            var lng = from.2
            var heading = atan2(to.2 - from.2, to.1 - from.1)
            let steps = max(minutes * 2, 12)
            let startMs = start
            let durationMs = Double(end - start)
            var distance = 0.0
            var peak = 0.0
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                if step > 0 {
                    let progress = fraction
                    // Pull toward the destination while wandering a little.
                    let desired = atan2(to.2 - lng, to.1 - lat)
                    heading += (desired - heading) * 0.55 + sin(progress * 9) * 0.05
                    let remainingKm = max(targetKm * (1 - progress), 0.15)
                    let stepM = remainingKm * 1000 / Double(steps - step + 1)
                    lat += cos(heading) * stepM / 111_320
                    lng += sin(heading) * stepM / (111_320 * cos(lat * .pi / 180))
                    distance += stepM
                }
                let speed = max(6, 38 + sin(fraction * 7.5) * 14 + random.double(-3...3))
                peak = max(peak, speed)
                points.append(RidePoint(
                    time: startMs + Int64(durationMs * fraction),
                    lat: lat, lng: lng,
                    speedKmh: speed, distanceM: distance, accuracyM: 5
                ))
            }
            guard let first = points.first, let last = points.last else { continue }
            let ride = Ride(
                id: Int64(rides.count + 1),
                start: start, end: end,
                startLat: first.lat, startLng: first.lng,
                endLat: last.lat, endLng: last.lng,
                startPlace: random.int(0...1) == 0 ? from.0 : "\(roads[random.int(0...(roads.count - 1))]), Bengaluru",
                endPlace: to.0,
                distanceM: distance,
                durationS: (end - start) / 1000,
                movingS: Int64(Double((end - start) / 1000) * random.double(0.72...0.92)),
                peakKmh: peak,
                avgKmh: distance * 3.6 / Double(max(end - start, 1)) * 1000,
                socStart: socStart,
                socEnd: socEnd
            )
            rides.append(StoredRide(ride: ride, points: points))
        }
        rides.sort { $0.ride.start > $1.ride.start }

        // Three overnight charges, each starting low and ending high.
        for index in 0..<3 {
            let start = now - Int64(5 + index * 4) * day - 7 * 3_600_000
            let hours: Int64 = Int64(random.int(2...5))
            let soc = Double(random.int(28...52))
            charges.append(ChargeSession(
                start: start,
                end: start + hours * 3_600_000 + Int64(random.int(0...50)) * 60_000,
                socStart: soc,
                socEnd: min(100, soc + random.double(38...58)),
                id: Int64(index + 1)
            ))
        }
        charges.sort { $0.start > $1.start }
        return (rides, charges)
    }
}
