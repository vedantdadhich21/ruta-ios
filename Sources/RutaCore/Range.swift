import Foundation

/// Range for the UI. `km` is whole kilometres when `estimated`; a decoded range passes through.
public struct RangeEstimate: Equatable, Sendable {
    public var km: Double
    public var estimated: Bool
    public var kmPerPercent: Double
    public var learned: Bool

    public init(km: Double, estimated: Bool, kmPerPercent: Double, learned: Bool = false) {
        self.km = km
        self.estimated = estimated
        self.kmPerPercent = kmPerPercent
        self.learned = learned
    }
}

/// The km per charge point the estimate uses: learned from qualifying rides, else the default.
public struct RangeEfficiency: Equatable, Sendable {
    public var kmPerPercent: Double
    public var rides: Int

    public init(_ kmPerPercent: Double, _ rides: Int) {
        self.kmPerPercent = kmPerPercent
        self.rides = rides
    }

    public var learned: Bool { rides > 0 }
    public static let `default` = RangeEfficiency(RangeModel.defaultKmPerPercent, 0)
}

public enum RangeModel {
    /// VX2 TFT: 64 km at 57 %, 62 km at 55 %, 61 km at 55 %.
    public static let defaultKmPerPercent = 1.12
    public static let minKmPerPercent = 0.7
    public static let maxKmPerPercent = 1.6
    public static let learnMinKm = 3.0
    public static let learnMinUsedPercent = 2.0
    public static let learnAlpha = 0.3
    public static let maxDecodedKm = 300.0

    public static func clampKmPerPercent(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultKmPerPercent }
        return min(max(value, minKmPerPercent), maxKmPerPercent)
    }

    public static func estimate(socPercent: Double?, decodedKm: Double?, kmPerPercent: Double) -> RangeEstimate? {
        estimate(socPercent: socPercent, decodedKm: decodedKm, efficiency: RangeEfficiency(kmPerPercent, 0))
    }

    public static func estimate(socPercent: Double?, decodedKm: Double?, efficiency: RangeEfficiency) -> RangeEstimate? {
        let k = clampKmPerPercent(efficiency.kmPerPercent)
        if let decodedKm, decodedKm.isFinite, decodedKm >= 0, decodedKm <= maxDecodedKm {
            return RangeEstimate(km: decodedKm, estimated: false, kmPerPercent: k, learned: efficiency.learned)
        }
        guard let socPercent, socPercent.isFinite else { return nil }
        let clamped = min(max(socPercent, 0), 100)
        return RangeEstimate(km: (clamped * k).rounded(.down), estimated: true, kmPerPercent: k, learned: efficiency.learned)
    }

    public static func rideSample(distanceM: Double, socStart: Double?, socEnd: Double?) -> Double? {
        guard let socStart, let socEnd, distanceM.isFinite else { return nil }
        let used = socStart - socEnd
        let km = distanceM / 1000
        guard used.isFinite, used >= learnMinUsedPercent, km >= learnMinKm else { return nil }
        return km / used
    }

    public static func learnedKmPerPercent(_ rides: [Ride]) -> Double {
        efficiency(rides).kmPerPercent
    }

    public static func efficiency(_ rides: [Ride]) -> RangeEfficiency {
        var value = defaultKmPerPercent
        var samples = 0
        for ride in rides.sorted(by: { $0.start < $1.start }) {
            guard let sample = rideSample(distanceM: ride.distanceM, socStart: ride.socStart, socEnd: ride.socEnd) else { continue }
            let clamped = min(max(sample, minKmPerPercent), maxKmPerPercent)
            value += learnAlpha * (clamped - value)
            samples += 1
        }
        return RangeEfficiency(clampKmPerPercent(value), samples)
    }

    /// Charge history as a range series in km with the same efficiency for every point.
    public static func series(_ soc: [BucketPoint], kmPerPercent: Double) -> [BucketPoint] {
        let k = clampKmPerPercent(kmPerPercent)
        return soc.map { BucketPoint(time: $0.time, avg: $0.avg * k, min: $0.min * k, max: $0.max * k, count: $0.count) }
    }
}

/// Time to a full charge for Home's "Full in" tile.
public enum ChargeEta {
    public static let minPercentPerHour = 1.0
    public static let maxMinutes = 24 * 60
    public static let rateAfterS: Int64 = 600

    public static func minutesToFull(socPercent: Double?, percentPerHour: Double?) -> Int? {
        guard let socPercent, socPercent.isFinite,
              let percentPerHour, percentPerHour.isFinite else { return nil }
        guard percentPerHour >= minPercentPerHour else { return nil }
        let missing = 100 - min(max(socPercent, 0), 100)
        if missing <= 0 { return 0 }
        let minutes = Int((missing / percentPerHour * 60.0 - 1e-9).rounded(.up))
        return minutes <= maxMinutes ? minutes : nil
    }

    public static func minutesToFull(socPercent: Double?, session: ChargeSession) -> Int? {
        minutesToFull(
            socPercent: socPercent ?? session.socEnd,
            percentPerHour: session.durationS >= rateAfterS ? session.percentPerHour : nil
        )
    }

    public static func phrase(_ minutes: Int?) -> String? {
        guard let minutes, minutes >= 0 else { return nil }
        if minutes == 0 { return "Full" }
        return "Full in \(RideMath.formatDuration(seconds: Int64(minutes) * 60))"
    }
}

public enum ChargeEvent: Equatable, Sendable {
    case reached(percent: Int)
    case stopped(percent: Int)
}

/// Charge alerts from the live charging session.
public final class ChargeWatch {
    private var last: ChargeSession?
    private var ended = true
    private var reached: (start: Int64, target: Int)?

    public static let fullPercent = 99.0

    public init() {}

    public func update(session: ChargeSession?, socPercent: Double?, linkReady: Bool, riding: Bool, target: Int) -> ChargeEvent? {
        let previous = last
        if let session {
            let before = previous.flatMap { $0.start == session.start ? $0.socEnd : nil } ?? session.socStart
            last = session
            ended = false
            let line = Double(target)
            if before < line && session.socEnd >= line {
                return reach(session: session, target: target, percent: target >= 100 ? 100 : floorPercent(session.socEnd))
            }
            return nil
        }
        guard let previous, !ended else { return nil }
        ended = true
        guard linkReady, !riding, let soc = socPercent, soc.isFinite else { return nil }
        let stoppedAt = previous.socEnd
        if target >= 100 && stoppedAt >= Self.fullPercent {
            return reach(session: previous, target: target, percent: 100)
        }
        let line = target >= 100 ? Self.fullPercent : Double(target)
        return stoppedAt < line ? .stopped(percent: floorPercent(stoppedAt)) : nil
    }

    private func reach(session: ChargeSession, target: Int, percent: Int) -> ChargeEvent? {
        if let reached, reached.start == session.start && reached.target == target { return nil }
        reached = (session.start, target)
        return .reached(percent: percent)
    }

    private func floorPercent(_ value: Double) -> Int {
        min(max(Int(value.rounded(.down)), 0), 100)
    }
}

/// One alert's words: title, optional text, and its one-line in-app form.
public struct AlertMessage: Equatable, Sendable {
    public var title: String
    public var text: String?
    public var line: String

    public init(_ title: String, _ text: String?, _ line: String) {
        self.title = title
        self.text = text
        self.line = line
    }
}

/// Wording of the rider alerts.
public enum AlertText {
    public static func chargeReached(percent: Int, rangeKm: Double?, estimated: Bool) -> AlertMessage {
        let title = percent >= 100 ? "Fully charged" : "Charged to \(max(percent, 0)) %"
        var range: String?
        if let rangeKm, rangeKm.isFinite, rangeKm >= 0 {
            range = "range \(Int(rangeKm.rounded())) km" + (estimated ? " est." : "")
        }
        let text = range.map { $0.capitalizingFirst }
        return AlertMessage(title, text, range.map { "\(title) · \($0)" } ?? title)
    }

    public static func chargeStopped(percent: Int, stallMinutes: Int64 = ChargeDetector.stallMs / 60_000) -> AlertMessage {
        let title = "Charging stopped at \(min(max(percent, 0), 100)) %"
        return AlertMessage(title, "No rise for \(stallMinutes) min while connected", title)
    }

    public static func range(short: Bool, wholeKm: Int, remainingKm: Double, rangeKm: Double, estimated: Bool) -> AlertMessage {
        let facts = "\(km(remainingKm)) km to go, \(Int(max(rangeKm, 0).rounded())) km range" + (estimated ? " est." : "")
        if short {
            let by = max(wholeKm, 1)
            return AlertMessage("Short by \(by) km", "Charge before you arrive · \(facts)", "Short by \(by) km — charge before you arrive")
        }
        let title = rangeKm < remainingKm
            ? "Range is tight · no spare"
            : "Range is tight · \(max(wholeKm, 0)) km spare"
        return AlertMessage(title, facts, title)
    }

    public static func rideSaved(_ ride: Ride) -> AlertMessage {
        let title = String(format: "Ride saved · %.1f km", ride.distanceKm)
        let text = "\(RideMath.formatDuration(seconds: ride.durationS)) · peak \(Int(ride.peakKmh.rounded())) km/h · avg \(Int(ride.avgKmh.rounded())) km/h"
        return AlertMessage(title, text, "\(title) · \(text)")
    }

    public static func arrived(_ name: String) -> AlertMessage {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "You have arrived"
        return AlertMessage(title, clean.isEmpty ? "Navigation ended" : "Navigation to \(clean) ended", "\(title) · \(clean)")
    }

    private static func km(_ value: Double) -> String {
        let v = max(value, 0)
        return v < 10 ? number(v, decimals: 1) : number(v, decimals: 0)
    }
}
