import Foundation

/// Pack 0 is the scooter-level (combined) value; packs 1 and 2 are the individual batteries.
public enum Metric: String, CaseIterable, Codable, Sendable {
    case soc, health, energy, temperature, status

    public var title: String {
        switch self {
        case .soc: return "Charge"
        case .health: return "Health"
        case .energy: return "Energy"
        case .temperature: return "Temperature"
        case .status: return "State"
        }
    }

    public var unit: String {
        switch self {
        case .soc, .health, .energy: return "%"
        case .temperature: return "°C"
        case .status: return ""
        }
    }

    public var minimum: Double {
        switch self {
        case .temperature: return -40
        case .status: return 0
        default: return 0
        }
    }

    public var maximum: Double {
        switch self {
        case .temperature: return 85
        case .status: return 15
        default: return 100
        }
    }
}

/// Display state for a BMS status code (raw codes never reach the UI).
public enum BmsState: String, Sendable {
    case drive = "Drive"
    case standby = "Standby"
    case unknown = "—"

    public var label: String { rawValue }

    public static func of(_ code: Int?) -> BmsState {
        switch code {
        case 4: return .drive
        case 0, 2: return .standby
        default: return .unknown
        }
    }

    public static func of(_ code: Double?) -> BmsState {
        guard let code, code.isFinite, code == code.rounded(.down) else { return .unknown }
        return of(Int(code))
    }

    /// Any pack driving → drive; else any standby → standby.
    public static func combined(_ codes: [Double?]) -> BmsState {
        let states = codes.map { of($0) }
        if states.contains(.drive) { return .drive }
        if states.contains(.standby) { return .standby }
        return .unknown
    }
}

public struct Reading: Equatable, Sendable {
    public var pack: Int
    public var metric: Metric
    public var value: Double
    public var time: Int64

    public init(pack: Int, metric: Metric, value: Double, time: Int64) {
        self.pack = pack
        self.metric = metric
        self.value = value
        self.time = time
    }
}

/// Converts raw BMS frames into readings, inferring and latching the undocumented units.
public final class BmsDecoder {
    public private(set) var percentDivisor: Int?
    public private(set) var temperatureDivisor: Int?
    private var percentVote: Int?
    private var percentStreak = 0
    private var temperatureVote: Int?
    private var temperatureStreak = 0
    private let spikes = SpikeFilter()

    public static let latchFrames = 3
    public static let minHundredthsCelsius = -30.0
    public static let placeholderTemperatureRaw = 0x0028
    private static let percentSentinels: Set<Int> = [0xFF, 0xFE, 0x3FF, 0x7FF, 0xFFF, 0x7FFF, 0xFFFE, 0xFFFF]
    private static let temperatureSentinels: Set<Int> = [0x7F, 0x80, 0xFE, 0xFF, 0x7FFF, 0x8000, 0xFF80, 0xFFFE, 0xFFFF]

    public convenience init(_ percentDivisor: Int?, _ temperatureDivisor: Int?) {
        self.init(percentDivisor: percentDivisor, temperatureDivisor: temperatureDivisor)
    }

    public init(percentDivisor: Int? = nil, temperatureDivisor: Int? = nil) {
        self.percentDivisor = [1, 10, 100].contains(percentDivisor) ? percentDivisor : nil
        self.temperatureDivisor = [1, 10, 100].contains(temperatureDivisor) ? temperatureDivisor : nil
    }

    private func plausiblePercent(_ raw: Int) -> Bool {
        raw >= 1 && raw <= 10000 && !Self.percentSentinels.contains(raw)
    }

    private func percentEvidence(_ frame: BmsFrame) -> Int? {
        let healths = [frame.soh, frame.pack1Soh, frame.pack2Soh].filter(plausiblePercent)
        if !healths.isEmpty {
            if healths.allSatisfy({ $0 >= 50 && $0 <= 100 }) { return 1 }
            if healths.allSatisfy({ $0 >= 500 && $0 <= 1000 }) { return 10 }
            if healths.allSatisfy({ $0 >= 5000 && $0 <= 10000 }) { return 100 }
        }
        let fields = [frame.soc, frame.soh, frame.pack1Soc, frame.pack1Soh, frame.pack2Soc, frame.pack2Soh]
            .filter(plausiblePercent)
        guard let largest = fields.max() else { return nil }
        if largest <= 100 { return nil }
        return largest <= 1000 ? 10 : 100
    }

    private func signed(_ raw: Int) -> Int { Int(Int16(truncatingIfNeeded: raw)) }

    private func celsius(_ raw: Int, scale: Int) -> Double {
        scale == 100 ? Double(raw - 4000) / 100 : Double(signed(raw)) / Double(scale)
    }

    private func temperatureEvidence(_ raws: [Int]) -> Int? {
        guard !raws.isEmpty else { return nil }
        let values = raws.map(signed)
        if raws.contains(where: { $0 > 850 }), raws.allSatisfy({ celsius($0, scale: 100) >= -30 && celsius($0, scale: 100) <= 70 }) {
            return 100
        }
        if values.contains(where: { abs($0) > 85 }), values.allSatisfy({ $0 / 10 >= -30 && $0 / 10 <= 70 }) {
            return 10
        }
        if values.allSatisfy({ $0 >= 20 && $0 <= 60 }) { return 1 }
        return nil
    }

    private func hundredths(_ frame: BmsFrame) -> Bool {
        if temperatureDivisor == 100 { return true }
        guard temperatureDivisor == nil else { return false }
        return [frame.packTemp, frame.pack1Temp, frame.pack2Temp].contains { $0 >= 1000 && $0 <= 11000 }
    }

    private func temperatureRaw(_ frame: BmsFrame, pack: Int) -> Int {
        switch pack {
        case 0: return frame.packTemp
        case 1: return frame.pack1Temp
        default: return frame.pack2Temp
        }
    }

    private func withoutPack(_ frame: BmsFrame, _ pack: Int) -> BmsFrame {
        switch pack {
        case 0:
            return BmsFrame(
                soh: frame.soh, soc: 0, packTemp: 0, chargeTimeRaw: frame.chargeTimeRaw,
                bmsStatus: frame.bmsStatus, pack1Status: frame.pack1Status, pack2Status: frame.pack2Status,
                pack1Soh: frame.pack1Soh, pack1Soc: frame.pack1Soc, pack1Soe: frame.pack1Soe, pack1Temp: frame.pack1Temp,
                pack2Soh: frame.pack2Soh, pack2Soc: frame.pack2Soc, pack2Soe: frame.pack2Soe, pack2Temp: frame.pack2Temp
            )
        case 1:
            return BmsFrame(
                soh: frame.soh, soc: frame.soc, packTemp: frame.packTemp, chargeTimeRaw: frame.chargeTimeRaw,
                bmsStatus: frame.bmsStatus, pack1Status: frame.pack1Status, pack2Status: frame.pack2Status,
                pack1Soh: 0, pack1Soc: 0, pack1Soe: 0, pack1Temp: 0,
                pack2Soh: frame.pack2Soh, pack2Soc: frame.pack2Soc, pack2Soe: frame.pack2Soe, pack2Temp: frame.pack2Temp
            )
        default:
            return BmsFrame(
                soh: frame.soh, soc: frame.soc, packTemp: frame.packTemp, chargeTimeRaw: frame.chargeTimeRaw,
                bmsStatus: frame.bmsStatus, pack1Status: frame.pack1Status, pack2Status: frame.pack2Status,
                pack1Soh: frame.pack1Soh, pack1Soc: frame.pack1Soc, pack1Soe: frame.pack1Soe, pack1Temp: frame.pack1Temp,
                pack2Soh: 0, pack2Soc: 0, pack2Soe: 0, pack2Temp: 0
            )
        }
    }

    public func readings(_ frame: BmsFrame, time: Int64) -> [Reading] {
        let percentFields = [frame.soc, frame.soh, frame.pack1Soc, frame.pack1Soh, frame.pack1Soe, frame.pack2Soc, frame.pack2Soh, frame.pack2Soe]
        let temps = [frame.packTemp, frame.pack1Temp, frame.pack2Temp]
        if percentFields.allSatisfy({ $0 == 0 }) && temps.allSatisfy({ $0 == 0 }) { return [] }

        var f = frame
        if hundredths(frame) {
            for pack in 0...2 where temperatureRaw(frame, pack: pack) == Self.placeholderTemperatureRaw {
                f = withoutPack(f, pack)
            }
        }

        let percentNow = percentEvidence(f)
        if percentDivisor == nil, let percentNow {
            percentStreak = percentNow == percentVote ? percentStreak + 1 : 1
            percentVote = percentNow
            if percentStreak >= Self.latchFrames { percentDivisor = percentNow }
        }
        let divisor = Double(percentDivisor ?? percentNow ?? 1)

        func scaled(_ raw: Int) -> Double? {
            guard plausiblePercent(raw) else { return nil }
            let value = Double(raw) / divisor
            return value >= 0 && value <= 100 ? value : nil
        }

        if ReadingRules.asleep(soc: scaled(f.pack1Soc), energy: scaled(f.pack1Soe)) { f = withoutPack(f, 1) }
        if ReadingRules.asleep(soc: scaled(f.pack2Soc), energy: scaled(f.pack2Soe)) { f = withoutPack(f, 2) }

        let present: [Int: Bool] = [
            0: plausiblePercent(f.soc) || plausiblePercent(f.soh),
            1: [f.pack1Soc, f.pack1Soh, f.pack1Soe].contains(where: plausiblePercent),
            2: [f.pack2Soc, f.pack2Soh, f.pack2Soe].contains(where: plausiblePercent),
        ]

        var output: [Reading] = []
        func add(_ pack: Int, _ metric: Metric, _ value: Double) {
            guard value.isFinite, value >= metric.minimum, value <= metric.maximum else { return }
            if metric == .health && !ReadingRules.healthPlausible(value) { return }
            if spikes.accept(pack: pack, metric: metric, value: value, time: time) {
                output.append(Reading(pack: pack, metric: metric, value: value, time: time))
            }
        }
        func percent(_ pack: Int, _ metric: Metric, _ raw: Int) {
            if let value = scaled(raw) { add(pack, metric, value) }
        }

        percent(0, .soc, f.soc)
        percent(0, .health, f.soh)
        percent(1, .soc, f.pack1Soc)
        percent(1, .health, f.pack1Soh)
        percent(1, .energy, f.pack1Soe)
        percent(2, .soc, f.pack2Soc)
        percent(2, .health, f.pack2Soh)
        percent(2, .energy, f.pack2Soe)

        let temperatures = [(0, f.packTemp), (1, f.pack1Temp), (2, f.pack2Temp)]
            .filter { present[$0.0] == true && !Self.temperatureSentinels.contains($0.1) }
        let temperatureNow = temperatureEvidence(temperatures.map(\.1))
        if temperatureDivisor == nil, let temperatureNow {
            temperatureStreak = temperatureNow == temperatureVote ? temperatureStreak + 1 : 1
            temperatureVote = temperatureNow
            if temperatureStreak >= Self.latchFrames { temperatureDivisor = temperatureNow }
        }
        if let scale = temperatureDivisor ?? temperatureNow {
            for (pack, raw) in temperatures {
                let value = celsius(raw, scale: scale)
                if scale != 100 || (raw != 0 && value >= Self.minHundredthsCelsius) {
                    add(pack, .temperature, value)
                }
            }
        }

        if present[0] == true { add(0, .status, Double(f.bmsStatus)) }
        if present[1] == true { add(1, .status, Double(f.pack1Status)) }
        if present[2] == true { add(2, .status, Double(f.pack2Status)) }
        return output
    }
}

/// Plausibility rules for BMS readings.
public enum ReadingRules {
    public static let minHealth = 50.0
    public static let maxEnergyBelowCharge = 25.0
    public static let maxJump = 10.0
    public static let jumpWindowMs: Int64 = 60_000
    public static let confirmSamples = 3
    public static let placeholderCelsius = -39.6

    public static func healthPlausible(_ percent: Double) -> Bool { percent >= minHealth }

    public static func asleep(soc: Double?, energy: Double?) -> Bool {
        guard let soc, let energy else { return false }
        return soc - energy > maxEnergyBelowCharge
    }

    public static func placeholder(_ celsius: Double) -> Bool {
        abs(celsius - placeholderCelsius) < 0.05
    }
}

/// Holds back single-sample SOC/SOE glitches.
public final class SpikeFilter {
    private struct Accepted { var value: Double; var time: Int64 }
    private struct Held { var value: Double; var count: Int }
    private struct Key: Hashable { var pack: Int; var metric: Metric }
    private var accepted: [Key: Accepted] = [:]
    private var held: [Key: Held] = [:]

    public init() {}

    public func accept(pack: Int, metric: Metric, value: Double, time: Int64) -> Bool {
        guard metric == .soc || metric == .energy else { return true }
        let key = Key(pack: pack, metric: metric)
        if let last = accepted[key],
           abs(value - last.value) > ReadingRules.maxJump,
           time - last.time >= 0, time - last.time <= ReadingRules.jumpWindowMs {
            let run = held[key].flatMap { abs(value - $0.value) <= ReadingRules.maxJump ? $0.count : nil } ?? 0
            if run + 1 < ReadingRules.confirmSamples {
                held[key] = Held(value: value, count: run + 1)
                return false
            }
        }
        held.removeValue(forKey: key)
        accepted[key] = Accepted(value: value, time: time)
        return true
    }

    public func clear() {
        accepted.removeAll()
        held.removeAll()
    }
}

/// Latest reading per pack and metric, with freshness.
public final class BatteryAnalytics {
    private var latest: [String: Reading] = [:]

    public init() {}

    private func key(_ pack: Int, _ metric: Metric) -> String { "\(pack)-\(metric.rawValue)" }

    public func accept(_ reading: Reading) {
        latest[key(reading.pack, reading.metric)] = reading
    }

    public func clear() { latest.removeAll() }

    public func reading(pack: Int, metric: Metric) -> Reading? { latest[key(pack, metric)] }

    public func fresh(pack: Int, metric: Metric, now: Int64) -> Double? {
        guard let reading = reading(pack: pack, metric: metric), now - reading.time >= 0, now - reading.time <= 90_000 else { return nil }
        return reading.value
    }

    public func imbalance(now: Int64) -> Double? {
        guard let one = fresh(pack: 1, metric: .soc, now: now),
              let two = fresh(pack: 2, metric: .soc, now: now) else { return nil }
        return abs(one - two)
    }
}

/// One row of stored battery history.
public struct StoredReading: Equatable, Sendable {
    public var id: Int64
    public var session: String
    public var time: Int64
    public var pack: Int
    public var metric: Metric
    public var value: Double

    public init(id: Int64, session: String, time: Int64, pack: Int, metric: Metric, value: Double) {
        self.id = id
        self.session = session
        self.time = time
        self.pack = pack
        self.metric = metric
        self.value = value
    }
}

/// Applies `ReadingRules` to stored history (the Android app's v7 migration): a pack frame (same
/// session, time and pack) holding the placeholder temperature, or asleep by SOE vs SOC, is dropped
/// whole; HEALTH below 50 % is dropped; SOC/SOE rows go through a `SpikeFilter` that restarts with
/// every session. Feed rows ordered by pack, time, session, id, then call `finish`.
public final class HistoryCleaner {
    private let spikes = SpikeFilter()
    private var session: String?
    private var frame: [StoredReading] = []
    private var rejected: [Int64] = []

    public init() {}

    public func add(_ row: StoredReading) {
        if let first = frame.first,
           first.pack != row.pack || first.time != row.time || first.session != row.session {
            flush()
        }
        frame.append(row)
    }

    /// Ids of every rejected row; call once, after the last `add`.
    public func finish() -> [Int64] {
        flush()
        return rejected
    }

    private func flush() {
        guard let first = frame.first else { return }
        if first.session != session {
            spikes.clear()
            session = first.session
        }
        let soc = frame.first { $0.metric == .soc }?.value
        let energy = frame.first { $0.metric == .energy }?.value
        let placeholder = frame.contains { $0.metric == .temperature && ReadingRules.placeholder($0.value) }
        if placeholder || ReadingRules.asleep(soc: soc, energy: energy) {
            rejected.append(contentsOf: frame.map(\.id))
        } else {
            for row in frame {
                let keep: Bool
                switch row.metric {
                case .health: keep = ReadingRules.healthPlausible(row.value)
                case .soc, .energy: keep = spikes.accept(pack: row.pack, metric: row.metric, value: row.value, time: row.time)
                default: keep = true
                }
                if !keep { rejected.append(row.id) }
            }
        }
        frame.removeAll()
    }

    /// Ids of the rows the live rules would have rejected; any order.
    public static func rejected(_ rows: [StoredReading]) -> Set<Int64> {
        let cleaner = HistoryCleaner()
        rows.sorted { a, b in
            if a.pack != b.pack { return a.pack < b.pack }
            if a.time != b.time { return a.time < b.time }
            if a.session != b.session { return a.session < b.session }
            return a.id < b.id
        }.forEach(cleaner.add)
        return Set(cleaner.finish())
    }
}
