import Foundation
import RutaCore

// Port of the battery-analytics half of `tests/AnalyticsTest.kt`: unit inference, latching,
// plausibility rules, the spike filter, the history cleaner and the live reading store.

private func bmsFrame(_ hex: String) -> BmsFrame {
    let values = hex.split(separator: " ").map { Int($0, radix: 16)! }
    return TcuParser.bms(values.map(UInt8.init))!
}

private func readingsOf(_ decoder: BmsDecoder, _ frame: BmsFrame, at: Int64 = 1_000_000) -> [String: Reading] {
    var out: [String: Reading] = [:]
    for reading in decoder.readings(frame, time: at) {
        out["\(reading.pack)-\(reading.metric.rawValue)"] = reading
    }
    return out
}

private func lookup(_ readings: [String: Reading], _ pack: Int, _ metric: Metric) -> Double? {
    readings["\(pack)-\(metric.rawValue)"]?.value
}

private func hasPack(_ readings: [String: Reading], _ pack: Int) -> Bool {
    readings.keys.contains { $0.hasPrefix("\(pack)-") }
}

private func hasMetric(_ readings: [String: Reading], _ metric: Metric) -> Bool {
    readings.keys.contains { $0.hasSuffix("-\(metric.rawValue)") }
}

private let liveFrameHex = "01 26 D9 16 95 1B 12 00 04 44 26 DB 16 95 13 23 1A EA 26 D7 16 96 13 26 1B 12 00 00 00 00"
private let emptyTempHex = "01 26 D9 16 94 00 00 00 04 44 26 DB 16 94 13 22 1A EA 26 D7 16 95 13 25 1B 12 00 00 00 00"

func runBatteryAnalytics() {
    let now: Int64 = 1_000_000

    func u16(_ value: Int) -> [Int] { [value >> 8 & 0xFF, value & 0xFF] }
    var raw = [1]
    for value in [95, 81, 31] { raw += u16(value) }
    raw += [0x12, 0x34, 0x56]
    for value in [96, 80, 79, 30, 94, 82, 81, 32] { raw += u16(value) }
    let bms = TcuParser.bms(raw.map(UInt8.init))!
    check(bms.soh == 95 && bms.soc == 81 && bms.packTemp == 31, "raw BMS fields")
    check(bms.chargeTimeRaw == 0x123 && bms.bmsStatus == 4 && bms.pack1Status == 5 && bms.pack2Status == 6, "status fields")
    check(bms.pack1Soc == 80 && bms.pack2Soc == 82 && bms.pack2Temp == 32, "pack fields")

    // Whole units: one frame votes but never latches.
    let whole = BmsDecoder()
    let readings = readingsOf(whole, bms)
    check(lookup(readings, 1, .soc) == 80 && lookup(readings, 2, .soc) == 82, "pack SOC")
    check(lookup(readings, 0, .health) == 95 && lookup(readings, 1, .temperature) == 30, "health and temperature")
    check(whole.percentDivisor == nil && whole.temperatureDivisor == nil, "one frame never latches")
    for _ in 0..<(BmsDecoder.latchFrames - 1) { _ = readingsOf(whole, bms) }
    check(whole.percentDivisor == 1 && whole.temperatureDivisor == 1, "whole units latch")

    // A latched scale never moves; a stray field is dropped alone.
    let stray = readingsOf(whole, bms.copy(pack1Soh: 4000, pack2Soe: 300))
    check(whole.percentDivisor == 1 && lookup(stray, 2, .energy) == nil && lookup(stray, 1, .health) == nil, "stray field dropped")
    check(lookup(stray, 1, .soc) == 80, "pack 1 SOC survives")
    let strayTemp = readingsOf(whole, bms.copy(pack1Temp: 200))
    check(lookup(strayTemp, 1, .temperature) == nil && whole.temperatureDivisor == 1, "stray temperature dropped")

    // Tenths.
    let tenths = BmsDecoder()
    let tenthsFrame = bms.copy(
        soh: 950, soc: 812, pack1Soh: 960, pack1Soc: 805, pack1Soe: 790,
        pack2Soh: 940, pack2Soc: 820, pack2Soe: 810
    )
    check(lookup(readingsOf(tenths, tenthsFrame), 1, .soc) == 80.5, "tenths before latching")
    for _ in 0..<(BmsDecoder.latchFrames - 1) { _ = readingsOf(tenths, tenthsFrame) }
    check(tenths.percentDivisor == 10, "tenths latch")
    let lowFrame = bms.copy(soh: 0, soc: 90, pack1Soh: 0, pack1Soc: 85, pack1Soe: 0, pack2Soh: 0, pack2Soc: 95, pack2Soe: 0)
    check(lookup(readingsOf(tenths, lowFrame, at: now + 61_000), 1, .soc) == 8.5, "latched tenths without SOH")
    check(BmsDecoder(percentDivisor: 10).percentDivisor == 10 && BmsDecoder(percentDivisor: 7).percentDivisor == nil, "divisor validation")

    // Disagreeing votes restart the streak.
    let mixed = BmsDecoder()
    _ = readingsOf(mixed, tenthsFrame)
    _ = readingsOf(mixed, tenthsFrame)
    _ = readingsOf(mixed, bms)
    _ = readingsOf(mixed, tenthsFrame)
    check(mixed.percentDivisor == nil, "mixed votes do not latch")

    // Absent packs.
    let single = readingsOf(BmsDecoder(), bms.copy(pack2Soh: 0xFFFF, pack2Soc: 0xFFFF, pack2Soe: 0xFFFF, pack2Temp: 0))
    check(lookup(single, 1, .soc) == 80 && lookup(single, 0, .soc) == 81 && !hasPack(single, 2), "absent pack")
    check(lookup(readingsOf(BmsDecoder(), bms.copy(pack1Soh: 0)), 1, .health) == nil, "zero SOH")
    check(lookup(readingsOf(BmsDecoder(), bms.copy(soc: 60000)), 0, .soc) == nil, "implausible SOC")
    let zero = BmsFrame(
        soh: 0, soc: 0, packTemp: 0, chargeTimeRaw: 0, bmsStatus: 0, pack1Status: 0, pack2Status: 0,
        pack1Soh: 0, pack1Soc: 0, pack1Soe: 0, pack1Temp: 0,
        pack2Soh: 0, pack2Soc: 0, pack2Soe: 0, pack2Temp: 0
    )
    check(BmsDecoder().readings(zero, time: now).isEmpty, "all-zero frame")

    // Temperature: > 85 is impossible in whole °C, so the frame votes tenths.
    let cold = BmsDecoder()
    let coldFrame = bms.copy(packTemp: 305, pack1Temp: 100, pack2Temp: 0xFFF6)
    let coldReadings = readingsOf(cold, coldFrame)
    check(lookup(coldReadings, 0, .temperature) == 30.5, "tenths pack 0")
    check(lookup(coldReadings, 1, .temperature) == 10.0, "tenths pack 1")
    check(lookup(coldReadings, 2, .temperature) == -1.0, "signed tenths")
    for _ in 0..<(BmsDecoder.latchFrames - 1) { _ = readingsOf(cold, coldFrame) }
    check(cold.temperatureDivisor == 10, "tenths latch")
    check(!hasMetric(readingsOf(BmsDecoder(), bms.copy(packTemp: 70, pack1Temp: 75, pack2Temp: 72)), .temperature), "ambiguous temperature hidden")
    check(lookup(readingsOf(BmsDecoder(temperatureDivisor: 1), bms.copy(pack1Temp: 0xFFF6)), 1, .temperature) == -10, "forced whole scale")

    // Hundredths with the −40 °C offset.
    let hundredths = BmsDecoder()
    let warm = bms.copy(packTemp: 6930, pack1Temp: 6890, pack2Temp: 6930)
    let warmReadings = readingsOf(hundredths, warm)
    check(lookup(warmReadings, 0, .temperature) == 29.3 && lookup(warmReadings, 1, .temperature) == 28.9, "hundredths")
    for _ in 0..<(BmsDecoder.latchFrames - 1) { _ = readingsOf(hundredths, warm) }
    check(hundredths.temperatureDivisor == 100 && BmsDecoder(temperatureDivisor: 100).temperatureDivisor == 100, "hundredths latch")
    let asleepTotal = readingsOf(BmsDecoder(100, 100), warm.copy(packTemp: BmsDecoder.placeholderTemperatureRaw))
    check(!hasPack(asleepTotal, 0), "hundredths pack-0 placeholder removes the whole aggregate pack")
    check(lookup(asleepTotal, 1, .soc) != nil, "pack 1 survives pack-0 placeholder")

    // Live 30-byte frames.
    let liveFrame = bmsFrame(liveFrameHex)
    let live = BmsDecoder()
    let liveReadings = readingsOf(live, liveFrame)
    check(lookup(liveReadings, 0, .soc) == 57.81 && lookup(liveReadings, 0, .health) == 99.45, "live SOC and SOH")
    check(lookup(liveReadings, 1, .energy) == 48.99, "live SOE")
    check(lookup(liveReadings, 0, .temperature) == 29.3 && lookup(liveReadings, 1, .temperature) == 28.9 && lookup(liveReadings, 2, .temperature) == 29.3, "live temperatures")
    for _ in 0..<(BmsDecoder.latchFrames - 1) { _ = readingsOf(live, liveFrame) }
    check(live.percentDivisor == 100 && live.temperatureDivisor == 100, "live latch")

    let emptyTemp = bmsFrame(emptyTempHex)
    let emptyReadings = readingsOf(live, emptyTemp)
    check(lookup(emptyReadings, 0, .temperature) == nil && lookup(emptyReadings, 1, .temperature) == 28.9, "empty pack temperature")
    check(lookup(emptyReadings, 0, .soc) == 57.8, "live SOC with empty temp")
    check(!hasMetric(readingsOf(BmsDecoder(percentDivisor: 100), emptyTemp), .temperature), "no vote from an empty temperature")

    check(lookup(readingsOf(BmsDecoder(100, 100), liveFrame), 2, .temperature) == 29.3, "restored hundredths latch")
    check(lookup(readingsOf(BmsDecoder(100, 100), bms.copy(pack1Temp: 2850)), 1, .temperature) == -11.5, "offset pack temperature")
    check(lookup(readingsOf(BmsDecoder(temperatureDivisor: 10), bms.copy(pack1Temp: 305)), 1, .temperature) == 30.5, "forced tenths")

    // 0x0028 is the pack-1 placeholder in hundredths.
    let placeholder = liveFrame.copy(pack1Temp: 0x0028)
    let placeholderReadings = readingsOf(BmsDecoder(100, 100), placeholder)
    check(!hasPack(placeholderReadings, 1) && lookup(placeholderReadings, 0, .temperature) == 29.3 && lookup(placeholderReadings, 2, .temperature) == 29.3, "placeholder drops the pack")
    check(lookup(readingsOf(BmsDecoder(100, 100), liveFrame.copy(pack1Temp: 999)), 1, .temperature) == nil, "just below −30 °C")
    check(lookup(readingsOf(BmsDecoder(100, 100), liveFrame.copy(pack1Temp: 1000)), 1, .temperature) == -30, "exactly −30 °C")

    let unlatched = BmsDecoder()
    for _ in 0..<BmsDecoder.latchFrames {
        let r = readingsOf(unlatched, placeholder)
        check(!hasPack(r, 1) && lookup(r, 2, .temperature) == 29.3, "asleep pack before latching")
    }
    check(unlatched.temperatureDivisor == 100 && unlatched.percentDivisor == 100, "other packs still vote")
    for _ in 0..<BmsDecoder.latchFrames { _ = readingsOf(unlatched, liveFrame) }
    let afterLatch = readingsOf(unlatched, placeholder)
    check(lookup(afterLatch, 1, .temperature) == nil && lookup(afterLatch, 2, .temperature) == 29.3, "asleep pack after latching")

    // Status codes.
    check(BmsState.of(4) == .drive && BmsState.of(0) == .standby && BmsState.of(7) == .unknown, "live status codes")
    check(BmsState.of(lookup(readingsOf(BmsDecoder(), liveFrame), 0, .status)) == .drive, "status reading")

    // D1: field glitches at ÷100.
    let t0: Int64 = 1_700_028_943_599
    let parked = liveFrame.copy(
        soc: 5597, packTemp: 6940, bmsStatus: 0, pack1Status: 2, pack2Status: 2,
        pack1Soc: 5595, pack1Soe: 12, pack1Temp: 0x0028,
        pack2Soc: 5599, pack2Soe: 4710, pack2Temp: 6940
    )
    for decoder in [BmsDecoder(100, 100), BmsDecoder()] {
        let r = readingsOf(decoder, parked, at: t0)
        check(!hasPack(r, 1), "asleep pack 1 dropped")
        check(lookup(r, 0, .soc) == 55.97 && lookup(r, 0, .temperature) == 29.4, "pack 0 untouched")
        check(BmsState.of(lookup(r, 0, .status)) == .standby, "pack 0 standby")
        check(lookup(r, 2, .soc) == 55.99 && lookup(r, 2, .energy) == 47.1 && lookup(r, 2, .health) == 99.43, "pack 2 untouched")
    }
    check(!hasPack(readingsOf(BmsDecoder(100, 100), parked.copy(pack1Temp: 6900), at: t0), 1), "SOE-only sleep")
    let bothAsleep = readingsOf(BmsDecoder(100, 100), parked.copy(pack2Soe: 2500), at: t0)
    check(!hasPack(bothAsleep, 2) && !hasPack(bothAsleep, 1), "pack 2 asleep too")
    check(lookup(readingsOf(BmsDecoder(100, 100), parked.copy(pack1Soe: 4690, pack1Temp: 6900), at: t0), 1, .energy) == 46.9, "9 points below SOC is normal")

    let wholeRaw = readingsOf(BmsDecoder(1, 1), bms.copy(pack1Temp: 0x0028))
    check(lookup(wholeRaw, 1, .temperature) == 40 && lookup(wholeRaw, 1, .soc) == 80, "0x0028 is 40 °C in whole degrees")
    check(lookup(readingsOf(BmsDecoder(1, 10), bms.copy(pack1Temp: 0x0028)), 1, .temperature) == 4, "0x0028 is 4 °C in tenths")
    let zeroTemp = readingsOf(BmsDecoder(100, 100), liveFrame.copy(pack1Temp: 0), at: t0)
    check(lookup(zeroTemp, 1, .temperature) == nil && lookup(zeroTemp, 1, .soc) == 57.81, "raw 0 only empties the temperature")

    // HEALTH below 50 % is a misread field.
    let health = BmsDecoder(100, 100)
    let badSoh = readingsOf(health, liveFrame.copy(soh: 1025), at: t0)
    check(lookup(badSoh, 0, .health) == nil && lookup(badSoh, 0, .soc) == 57.81 && lookup(badSoh, 1, .health) == 99.47, "pack 0 health 10.25 %")
    check(lookup(readingsOf(health, liveFrame.copy(pack1Soh: 269), at: t0), 1, .health) == nil, "pack 1 health 2.69 %")
    check(lookup(readingsOf(health, liveFrame.copy(pack1Soh: 1039), at: t0), 1, .health) == nil, "pack 1 health 10.39 %")
    check(lookup(readingsOf(health, liveFrame.copy(pack1Soh: 5000), at: t0), 1, .health) == 50, "health 50 % is plausible")
    check(ReadingRules.healthPlausible(50) && !ReadingRules.healthPlausible(49.99), "health rule")

    // Single-sample SOC jump.
    let spike = BmsDecoder(100, 100)
    check(lookup(readingsOf(spike, liveFrame.copy(pack2Soc: 5659), at: t0), 2, .soc) == 56.59, "spike baseline")
    let glitch = readingsOf(spike, liveFrame.copy(pack2Soc: 2), at: t0 + 500)
    check(lookup(glitch, 2, .soc) == nil && lookup(glitch, 2, .energy) == 49.02 && lookup(glitch, 2, .health) == 99.43, "single-sample glitch held")
    check(lookup(readingsOf(spike, liveFrame.copy(pack2Soc: 5657), at: t0 + 1_000), 2, .soc) == 56.57, "recovery accepted")
    check(lookup(readingsOf(spike, liveFrame.copy(pack1Soe: 3900), at: t0 + 1_500), 1, .energy) == 39, "SOE 39 % accepted")
    let soeJump = readingsOf(spike, liveFrame.copy(pack1Soe: 5000), at: t0 + 2_000)
    check(lookup(soeJump, 1, .energy) == nil && lookup(soeJump, 1, .soc) == 57.81, "11-point SOE move held")

    let swap = BmsDecoder(100, 100)
    func swapped(_ socRaw: Int) -> BmsFrame { liveFrame.copy(pack2Soc: socRaw, pack2Soe: 8900) }
    check(lookup(readingsOf(swap, liveFrame.copy(pack2Soc: 5659), at: t0), 2, .soc) != nil, "swap baseline")
    let firstSwap = readingsOf(swap, swapped(9000), at: t0 + 500)
    check(lookup(firstSwap, 2, .soc) == nil && lookup(firstSwap, 2, .energy) == nil && lookup(firstSwap, 2, .health) != nil, "first swap sample held")
    check(lookup(readingsOf(swap, swapped(9002), at: t0 + 1_000), 2, .soc) == nil, "second swap sample held")
    let confirmed = readingsOf(swap, swapped(9004), at: t0 + 1_500)
    check(lookup(confirmed, 2, .soc) == 90.04 && lookup(confirmed, 2, .energy) == 89, "third agreeing sample accepted")
    check(lookup(readingsOf(swap, swapped(9006), at: t0 + 2_000), 2, .soc) == 90.06, "and then normal")

    let noisy = BmsDecoder(100, 100)
    _ = readingsOf(noisy, liveFrame.copy(pack2Soc: 5659), at: t0)
    for (i, raw) in [2, 3000, 4, 6].enumerated() {
        check(lookup(readingsOf(noisy, liveFrame.copy(pack2Soc: raw), at: t0 + 500 * Int64(i + 1)), 2, .soc) == nil, "disagreeing suspect \(i)")
    }
    check(lookup(readingsOf(noisy, liveFrame.copy(pack2Soc: 2000), at: t0 + 61_000), 2, .soc) == 20, "accept after the window")

    let filter = SpikeFilter()
    check(filter.accept(pack: 1, metric: .soc, value: 56, time: 0), "filter first")
    check(filter.accept(pack: 2, metric: .soc, value: 10, time: 0), "filter pack independence")
    check(filter.accept(pack: 1, metric: .temperature, value: -39.6, time: 0), "filter metric pass-through")
    check(!filter.accept(pack: 1, metric: .soc, value: 0.02, time: 1_000), "filter holds a jump")
    check(filter.accept(pack: 1, metric: .soc, value: 0.02, time: -5_000), "clock step back is not a jump")

    // History cleaner: migration over a field export.
    var nextId: Int64 = 1
    func row(_ session: String, _ time: Int64, _ pack: Int, _ metric: Metric, _ value: Double) -> StoredReading {
        defer { nextId += 1 }
        return StoredReading(id: nextId, session: session, time: time, pack: pack, metric: metric, value: value)
    }

    let s1 = "00000000-0000-4000-8000-000000000001"
    let health0 = [99.45, 99.45, 10.25, 99.45, 99.45].enumerated().map { index, value in
        row(s1, 1_700_025_240_878 + Int64(index - 2) * 10_000, 0, .health, value)
    }
    check(HistoryCleaner.rejected(health0) == [health0[2].id], "stored health glitch")

    let s2 = "00000000-0000-4000-8000-000000000002"
    let health1 = [
        (1_700_035_357_910, 99.47), (1_700_035_449_910, 2.69), (1_700_035_479_910, 99.47),
        (1_700_036_623_235, 10.39), (1_700_036_653_235, 99.47),
    ].map { row(s2, $0.0, 1, .health, $0.1) }
    check(HistoryCleaner.rejected(health1) == [health1[1].id, health1[3].id], "stored pack 1 health glitches")

    let s3 = "00000000-0000-4000-8000-000000000003"
    let soc2 = [56.59, 56.59, 56.59, 0.02, 56.57, 56.57, 56.57].enumerated().map { index, value in
        row(s3, 1_700_026_504_721 + Int64(index - 3) * 10_000, 2, .soc, value)
    }
    check(HistoryCleaner.rejected(soc2) == [soc2[3].id], "stored SOC glitch")

    let resumed = [
        row(s3, 1_000_000, 2, .soc, 56), row(s2, 1_030_000, 2, .soc, 80), row(s2, 1_040_000, 2, .soc, 80.1),
    ]
    check(HistoryCleaner.rejected(resumed).isEmpty, "new session starts clean")

    // Parked: pack 1 frames every ~10 s; two normal, then 33 asleep.
    let s4 = "00000000-0000-4000-8000-000000000004"
    let start: Int64 = 1_700_028_943_599
    func frame(_ time: Int64, _ energy: Double, _ temperature: Double?, _ soc: Double) -> [StoredReading] {
        var rows = [
            row(s4, time, 1, .soc, soc), row(s4, time, 1, .health, 99.47),
            row(s4, time, 1, .energy, energy), row(s4, time, 1, .status, 2),
        ]
        if let temperature { rows.append(row(s4, time, 1, .temperature, temperature)) }
        return rows
    }
    let pack0 = [
        row(s4, start, 0, .soc, 55.97), row(s4, start, 0, .temperature, 29.4), row(s4, start, 0, .status, 0),
    ]
    for temperatureKept in [true, false] {
        let normal = frame(start - 20_000, 47.12, 29.0, 55.98) + frame(start - 10_000, 47.08, 29.0, 55.95)
        var asleep: [StoredReading] = []
        for index in 0..<33 {
            asleep += frame(start + Int64(index) * 11_000, 0.12, temperatureKept ? -39.600000000000001 : nil, 55.95)
        }
        let rejected = HistoryCleaner.rejected(asleep + pack0 + normal)
        check(rejected == Set(asleep.map(\.id)), "asleep frames: \(rejected.count) of \(asleep.count)")
    }
    let ride = (0..<20).map { row(s4, start + Int64($0) * 30_000, 0, .soc, 58 - Double($0) * 0.2) }
    check(HistoryCleaner.rejected(ride + [row(s4, start, 0, .temperature, -40)]).isEmpty, "real ride untouched")
    check(ReadingRules.placeholder(-39.6) && ReadingRules.placeholder(-39.599999999999994) && !ReadingRules.placeholder(-40), "placeholder rule")

    // Live reading store.
    let model = BatteryAnalytics()
    check(model.imbalance(now: now) == nil, "no imbalance yet")
    model.accept(Reading(pack: 1, metric: .soc, value: 80, time: now))
    model.accept(Reading(pack: 2, metric: .soc, value: 64, time: now))
    check(model.imbalance(now: now) == 16, "imbalance")
    check(model.fresh(pack: 1, metric: .soc, now: now + 90_001) == nil, "stale reading")
    model.clear()
    check(model.reading(pack: 1, metric: .soc) == nil, "cleared store")
}
