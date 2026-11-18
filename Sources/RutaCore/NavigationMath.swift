import Foundation

/// One navigation update, in the shape of the Android app's parsed Google Maps notification.
/// On iOS this is built from MapKit route steps instead of a notification.
public struct MapsCue: Equatable, Sendable {
    public var turn: Int
    public var distanceMeters: Int?
    public var instruction: String
    public var road: String
    public var arrivalHour24: Int?
    public var arrivalMinute: Int?
    public var remainingMeters: Int?
    public var rerouting: Bool
    /// The second of two back-to-back maneuvers, only when it has a "Then …" hint.
    public var thenTurn: Int?

    public init(
        turn: Int, distanceMeters: Int?, instruction: String, road: String,
        arrivalHour24: Int?, arrivalMinute: Int?, remainingMeters: Int?, rerouting: Bool,
        thenTurn: Int? = nil
    ) {
        self.turn = turn
        self.distanceMeters = distanceMeters
        self.instruction = instruction
        self.road = road
        self.arrivalHour24 = arrivalHour24
        self.arrivalMinute = arrivalMinute
        self.remainingMeters = remainingMeters
        self.rerouting = rerouting
        self.thenTurn = thenTurn
    }

    /// The 0x0303 road text: the "Then …" hint when a second maneuver follows, else the fitted road.
    public var tftRoad: String {
        if let thenTurn, let hint = RoadNames.thenHint(turn: thenTurn) { return hint }
        return RoadNames.fit(road)
    }

    public func frame(now: Date, distanceMeters: Int? = nil, remainingMeters: Int? = nil) -> NavFrame {
        let calendar = Calendar.current
        let nowParts = calendar.dateComponents([.hour, .minute], from: now)
        let distance = distanceMeters ?? self.distanceMeters
        let remaining = remainingMeters ?? self.remainingMeters
        var remainingMinutes = 0
        if let hour = arrivalHour24, let minute = arrivalMinute {
            var arrival = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if arrival < now.addingTimeInterval(-5 * 60) {
                arrival = calendar.date(byAdding: .day, value: 1, to: arrival) ?? arrival
            }
            remainingMinutes = max(Int(((arrival.timeIntervalSince(now) + 30) / 60).rounded(.down)), 0)
        }
        return NavFrame(
            active: true, turn: turn, distanceMeters: distance ?? 0, nextTurn: NavTurn.straight,
            arrivalHour24: arrivalHour24 ?? nowParts.hour ?? 0,
            arrivalMinute: arrivalMinute ?? nowParts.minute ?? 0,
            remainingMeters: remaining ?? 0,
            remainingMinutes: remainingMinutes,
            road: tftRoad
        )
    }
}

/// Counts maneuver and route distances down between navigation updates with GPS travel.
public final class NavCountdown {
    public struct Distances: Equatable, Sendable {
        public var maneuverM: Int
        public var remainingM: Int?

        public init(maneuverM: Int, remainingM: Int?) {
            self.maneuverM = maneuverM
            self.remainingM = remainingM
        }
    }

    private enum Mode { case fixed, remaining, zero }

    private final class Anchor {
        var mode: Mode
        var metres: Double
        var travelled: Double
        var mapsM: Int?
        var seenAt: Int64

        init(mode: Mode, metres: Double, travelled: Double, mapsM: Int?, seenAt: Int64) {
            self.mode = mode
            self.metres = metres
            self.travelled = travelled
            self.mapsM = mapsM
            self.seenAt = seenAt
        }
    }

    /// Recently seen maneuvers, oldest first; the last is current.
    private var anchors: [(key: String, anchor: Anchor)] = []
    private var current: Anchor?
    private var remainingBase: Double?
    private var remainingTravelled = 0.0

    public static let memory = 4
    public static let forgetMs: Int64 = 10 * 60_000
    public static let passedM = 150.0

    public init() {}

    public func update(_ cue: MapsCue, travelledM: Double, nowMs: Int64) {
        if let remaining = cue.remainingMeters {
            remainingBase = Double(remaining)
            remainingTravelled = travelledM
        }
        expire(travelledM, nowMs)
        let cueKey = Self.key(cue)
        let known = anchors.first { $0.key == cueKey }?.anchor
        let explicit = cue.distanceMeters
        let anchor: Anchor
        if let explicit {
            if let known, known.mapsM == explicit, abs(counted(known, travelledM) - Double(explicit)) <= Self.tolerance(explicit) {
                anchor = known
            } else {
                anchor = Anchor(mode: .fixed, metres: Double(explicit), travelled: travelledM, mapsM: explicit, seenAt: nowMs)
            }
        } else if let known {
            anchor = known
        } else if (cue.turn == NavTurn.straight && cue.thenTurn == nil) || cue.turn == NavTurn.destination {
            anchor = Anchor(mode: .remaining, metres: 0, travelled: travelledM, mapsM: nil, seenAt: nowMs)
        } else {
            anchor = Anchor(mode: .zero, metres: 0, travelled: travelledM, mapsM: nil, seenAt: nowMs)
        }
        anchor.seenAt = nowMs
        anchors.removeAll { $0.key == cueKey }
        anchors.append((cueKey, anchor))
        while anchors.count > Self.memory { anchors.removeFirst() }
        current = anchor
    }

    public func at(travelledM: Double) -> Distances {
        Distances(
            maneuverM: Self.round(current.map { counted($0, travelledM) } ?? 0),
            remainingM: remaining(travelledM).map(Self.round)
        )
    }

    public func reset() {
        anchors.removeAll()
        current = nil
        remainingBase = nil
        remainingTravelled = 0
    }

    private func remaining(_ travelledM: Double) -> Double? {
        guard let base = remainingBase else { return nil }
        return max(0, base - max(0, travelledM - remainingTravelled))
    }

    private func counted(_ anchor: Anchor, _ travelledM: Double) -> Double {
        switch anchor.mode {
        case .fixed: return max(0, anchor.metres - max(0, travelledM - anchor.travelled))
        case .remaining: return remaining(travelledM) ?? 0
        case .zero: return 0
        }
    }

    private func expire(_ travelledM: Double, _ nowMs: Int64) {
        anchors.removeAll { _, anchor in
            nowMs - anchor.seenAt > Self.forgetMs
                || (anchor.mode == .fixed && travelledM - anchor.travelled > anchor.metres + Self.passedM)
        }
    }

    /// Same maneuver: same cluster symbol and road.
    public static func key(_ cue: MapsCue) -> String {
        "\(cue.turn)|\(cue.road.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// 10 m steps below 1 km, 0.1 km steps above; never negative.
    public static func round(_ metres: Double) -> Int {
        guard metres > 0 else { return 0 }
        let tens = Int((metres / 10).rounded()) * 10
        return tens < 1000 ? tens : Int((metres / 100).rounded()) * 100
    }

    /// How far a count may drift from the reported rounded value before the update wins.
    public static func tolerance(_ metres: Int) -> Double {
        if metres < 1000 { return max(30, Double(metres) * 0.1) }
        if metres < 10_000 { return 100 }
        return 1000
    }
}

/// Cumulative distance from location fixes for `NavCountdown`.
public final class NavOdometer {
    public private(set) var totalM = 0.0

    private struct Fix {
        var lat: Double
        var lng: Double
        var gps: Bool
    }

    private let maxAccuracyM: Double
    private var anchor: Fix?
    private var lastTime: Int64 = 0
    private var lastGpsAt = Int64.min
    private var jumps = 0

    public static let maxMps = 70.0
    public static let maxJumps = 5
    public static let movingMps = 1.0
    public static let minStepM = 5.0
    public static let gpsPreferredMs: Int64 = 5_000

    public init(maxAccuracyM: Double = 30) {
        self.maxAccuracyM = maxAccuracyM
    }

    /// `timeMs` monotonic; `speedMps` nil when the fix has none. True when distance was added.
    @discardableResult
    public func add(timeMs: Int64, lat: Double, lng: Double, accuracyM: Double, speedMps: Double?, gps: Bool) -> Bool {
        guard lat.isFinite, lng.isFinite, abs(lat) <= 90, abs(lng) <= 180, !(lat == 0 && lng == 0) else { return false }
        guard accuracyM <= maxAccuracyM else { return false }
        if gps {
            lastGpsAt = timeMs
        } else if lastGpsAt != Int64.min, timeMs - lastGpsAt >= 0, timeMs - lastGpsAt < Self.gpsPreferredMs {
            return false
        }
        guard let from = anchor, from.gps == gps else {
            restart(timeMs, lat, lng, gps)
            return false
        }
        let dt = timeMs - lastTime
        guard dt > 0 else { return false }
        let d = Self.haversineM(lat1: from.lat, lng1: from.lng, lat2: lat, lng2: lng)
        if d * 1000 / Double(dt) > Self.maxMps {
            jumps += 1
            if jumps >= Self.maxJumps { restart(timeMs, lat, lng, gps) }
            return false
        }
        jumps = 0
        lastTime = timeMs
        if !((speedMps ?? 0) >= Self.movingMps) && d < max(Self.minStepM, accuracyM) { return false }
        totalM += d
        anchor = Fix(lat: lat, lng: lng, gps: gps)
        return true
    }

    public func reset() {
        totalM = 0
        pause()
    }

    /// Keep the total, but the next fix starts a new leg.
    public func pause() {
        anchor = nil
        lastTime = 0
        lastGpsAt = Int64.min
        jumps = 0
    }

    private func restart(_ timeMs: Int64, _ lat: Double, _ lng: Double, _ gps: Bool) {
        anchor = Fix(lat: lat, lng: lng, gps: gps)
        lastTime = timeMs
        jumps = 0
    }

    public static func haversineM(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        RideMath.haversineM(lat1: lat1, lng1: lng1, lat2: lat2, lng2: lng2)
    }
}
