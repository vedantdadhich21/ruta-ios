import Foundation
import RutaCore

// Port of `tests/RangeTest.kt`: range estimates, learning, charge ETA, charge alerts, BMS state.

private func rangeRide(_ start: Int64, _ distanceM: Double, _ socStart: Double?, _ socEnd: Double?) -> Ride {
    Ride(
        id: start, start: start, end: start + 600_000, startLat: 17.4, startLng: 78.3, endLat: 17.5, endLng: 78.4,
        startPlace: nil, endPlace: nil, distanceM: distanceM, durationS: 600, movingS: 600,
        peakKmh: 40, avgKmh: 30, socStart: socStart, socEnd: socEnd
    )
}

private let rangeMinute: Int64 = 60_000

private func rangeSession(_ startMin: Int64, _ endMin: Int64, _ from: Double, _ to: Double) -> ChargeSession {
    ChargeSession(start: startMin * rangeMinute, end: endMin * rangeMinute, socStart: from, socEnd: to)
}

func runRange() {
    let d = RangeModel.defaultKmPerPercent
    check(d == 1.12, "default efficiency")
    check(RangeModel.estimate(socPercent: 57.81, decodedKm: nil, kmPerPercent: d) == RangeEstimate(km: 64, estimated: true, kmPerPercent: 1.12), "TFT 64 km at 57 %")
    check(RangeModel.estimate(socPercent: 55.5, decodedKm: nil, kmPerPercent: d)!.km == 62, "62 km at 55.5 %")
    check(RangeModel.estimate(socPercent: 55, decodedKm: nil, kmPerPercent: d)!.km == 61, "61 km at 55 %")
    check(RangeModel.estimate(socPercent: 100, decodedKm: nil, kmPerPercent: d)!.km == 112 && RangeModel.estimate(socPercent: 0, decodedKm: nil, kmPerPercent: d)!.km == 0, "range at the ends")
    check(RangeModel.estimate(socPercent: 0.5, decodedKm: nil, kmPerPercent: d)!.km == 0, "floor to whole km")
    check(RangeModel.estimate(socPercent: 140, decodedKm: nil, kmPerPercent: d)!.km == 112 && RangeModel.estimate(socPercent: -3, decodedKm: nil, kmPerPercent: d)!.km == 0, "charge clamped")
    check(RangeModel.estimate(socPercent: nil, decodedKm: nil, kmPerPercent: d) == nil && RangeModel.estimate(socPercent: .nan, decodedKm: nil, kmPerPercent: d) == nil, "no charge")
    check(RangeModel.estimate(socPercent: 57.81, decodedKm: 63.5, kmPerPercent: d) == RangeEstimate(km: 63.5, estimated: false, kmPerPercent: 1.12), "decoded wins")
    check(RangeModel.estimate(socPercent: nil, decodedKm: 70, kmPerPercent: d)!.apply { $0.km == 70 && !$0.estimated }, "decoded only")
    check(RangeModel.estimate(socPercent: 50, decodedKm: -1, kmPerPercent: d)!.apply { $0.estimated && $0.km == 56 }, "decoded below zero")
    check(RangeModel.estimate(socPercent: 50, decodedKm: 999, kmPerPercent: d)!.estimated && RangeModel.estimate(socPercent: 50, decodedKm: .nan, kmPerPercent: d)!.estimated, "implausible decoded")
    check(RangeModel.estimate(socPercent: nil, decodedKm: .infinity, kmPerPercent: d) == nil, "infinite decoded")
    check(RangeModel.estimate(socPercent: 50, decodedKm: nil, kmPerPercent: 3)!.apply { $0.km == 80 && $0.kmPerPercent == 1.6 }, "efficiency high clamp")
    check(RangeModel.estimate(socPercent: 50, decodedKm: nil, kmPerPercent: 0.2)!.apply { $0.km == 35 && $0.kmPerPercent == 0.7 }, "efficiency low clamp")
    check(RangeModel.estimate(socPercent: 50, decodedKm: nil, kmPerPercent: .nan)!.kmPerPercent == d && RangeModel.estimate(socPercent: 50, decodedKm: nil, kmPerPercent: -1)!.kmPerPercent == d, "garbage efficiency")
    check(RangeModel.clampKmPerPercent(1.3) == 1.3, "clamp passes through")
    let series = RangeModel.series([BucketPoint(time: 5, avg: 50, min: 40, max: 60, count: 3)], kmPerPercent: 1.2)
    check(series.single!.apply { $0.time == 5 && near($0.avg, 60) && near($0.min, 48) && near($0.max, 72) && $0.count == 3 }, "range series")

    check(RangeModel.rideSample(distanceM: 6_000, socStart: 60, socEnd: 55) == 1.2, "ride sample")
    check(RangeModel.rideSample(distanceM: 2_999, socStart: 60, socEnd: 55) == nil, "too short to learn")
    check(RangeModel.rideSample(distanceM: 6_000, socStart: 60, socEnd: 58.5) == nil, "too little charge")
    check(RangeModel.rideSample(distanceM: 6_000, socStart: nil, socEnd: 55) == nil && RangeModel.rideSample(distanceM: 6_000, socStart: 55, socEnd: 60) == nil, "invalid samples")
    check(RangeModel.rideSample(distanceM: 3_000, socStart: 60, socEnd: 58) == 1.5, "threshold sample")

    check(RangeModel.learnedKmPerPercent([]) == d, "nothing to learn")
    check(RangeModel.learnedKmPerPercent([
        rangeRide(1, 2_000, 60, 50), rangeRide(2, 9_000, 60, 59), rangeRide(3, 9_000, nil, nil),
    ]) == d, "unqualified rides")
    check(near(RangeModel.learnedKmPerPercent([rangeRide(1, 6_600, 60, 55)]), 1.18), "one ride")
    let two = [rangeRide(2, 5_000, 55, 50), rangeRide(1, 6_600, 60, 55)]
    check(near(RangeModel.learnedKmPerPercent(two), 1.18 + 0.3 * (1.0 - 1.18)), "start order")
    check(near(RangeModel.learnedKmPerPercent([rangeRide(1, 20_000, 60, 58)]), 1.12 + 0.3 * (1.6 - 1.12)), "high sample clamp")
    check(near(RangeModel.learnedKmPerPercent([rangeRide(1, 3_000, 60, 40)]), 1.12 + 0.3 * (0.7 - 1.12)), "low sample clamp")
    let steady = (1...40).map { rangeRide(Int64($0), 8_000, 60, 55) }
    check(near(RangeModel.learnedKmPerPercent(steady), 1.6, 1e-3) && RangeModel.learnedKmPerPercent(steady) <= 1.6, "steady convergence")
    let thirsty = (1...40).map { rangeRide(Int64($0), 3_000, 60, 55) }
    check(near(RangeModel.learnedKmPerPercent(thirsty), 0.7, 1e-3) && RangeModel.learnedKmPerPercent(thirsty) >= 0.7, "thirsty convergence")

    check(RangeModel.efficiency([]) == RangeEfficiency(d, 0) && !RangeEfficiency.default.learned, "default efficiency object")
    let short = [rangeRide(1, 368, 14, 10.8), rangeRide(2, 863, 26.7, 13.7)]
    check(RangeModel.efficiency(short) == .default, "short rides do not teach")
    let learned = RangeModel.efficiency(short + [rangeRide(3, 6_600, 60, 55)])
    check(learned.learned && learned.rides == 1 && near(learned.kmPerPercent, 1.18), "one qualifying ride")
    let estimate = RangeModel.estimate(socPercent: 57.81, decodedKm: nil, efficiency: learned)!
    check(estimate.learned && estimate.estimated && estimate.kmPerPercent == learned.kmPerPercent && estimate.km == 68, "learned estimate")
    check(RangeModel.estimate(socPercent: 57.81, decodedKm: nil, efficiency: .default) == RangeEstimate(km: 64, estimated: true, kmPerPercent: d, learned: false), "default estimate")
    check(RangeModel.estimate(socPercent: 57.81, decodedKm: 63.5, efficiency: learned)!.apply { !$0.estimated && $0.learned && $0.km == 63.5 }, "learned decoded")
    check(!RangeModel.estimate(socPercent: 57.81, decodedKm: nil, kmPerPercent: 1.18)!.learned, "number overload is not learned")
    check(RangeModel.estimate(socPercent: 50, decodedKm: nil, efficiency: RangeEfficiency(3, 4))!.apply { $0.kmPerPercent == 1.6 && $0.km == 80 && $0.learned }, "learned clamp")

    check(ChargeEta.minutesToFull(socPercent: 55, percentPerHour: 20) == 135, "2 h 15")
    check(ChargeEta.minutesToFull(socPercent: 80, percentPerHour: 40) == 30, "exact half hour")
    check(ChargeEta.minutesToFull(socPercent: 99.9, percentPerHour: 20) == 1, "partial minute rounds up")
    check(ChargeEta.minutesToFull(socPercent: 57.81, percentPerHour: 18) == 141, "140.6 min")
    check(ChargeEta.minutesToFull(socPercent: 100, percentPerHour: 20) == 0 && ChargeEta.minutesToFull(socPercent: 104, percentPerHour: 20) == 0, "full now")
    check(ChargeEta.minutesToFull(socPercent: -5, percentPerHour: 50) == 120, "charge clamped")
    check(ChargeEta.minutesToFull(socPercent: nil, percentPerHour: 20) == nil && ChargeEta.minutesToFull(socPercent: 50, percentPerHour: nil) == nil, "unknown ETA")
    check(ChargeEta.minutesToFull(socPercent: .nan, percentPerHour: 20) == nil && ChargeEta.minutesToFull(socPercent: 50, percentPerHour: .infinity) == nil, "NaN ETA")
    check(ChargeEta.minutesToFull(socPercent: 50, percentPerHour: 0) == nil && ChargeEta.minutesToFull(socPercent: 50, percentPerHour: -12) == nil && ChargeEta.minutesToFull(socPercent: 50, percentPerHour: 0.9) == nil, "not charging")
    check(ChargeEta.minutesToFull(socPercent: 0, percentPerHour: 4) == nil && ChargeEta.minutesToFull(socPercent: 4, percentPerHour: 4) == 1440, "beyond a day")

    check(BmsState.of(4) == .drive && BmsState.of(4.0) == .drive, "drive state")
    check(BmsState.of(0) == .standby && BmsState.of(2) == .standby && BmsState.of(2.0) == .standby, "standby state")
    check([1, 3, 5, 7, 11, -1, 255].allSatisfy { BmsState.of($0) == .unknown }, "unknown codes")
    check(BmsState.of(nil as Int?) == .unknown && BmsState.of(nil as Double?) == .unknown, "nil state")
    check(BmsState.of(Double.nan) == .unknown && BmsState.of(4.5) == .unknown, "non-integral state")
    check(BmsState.drive.label == "Drive" && BmsState.standby.label == "Standby", "state labels")
    check(BmsState.combined([0, 2, 2]) == .standby, "combined standby")
    check(BmsState.combined([0, 4, 2]) == .drive, "combined drive")
    check(BmsState.combined([4, nil, 4]) == .drive, "combined with nil")
    check(BmsState.combined([nil, 7]) == .unknown && BmsState.combined([]) == .unknown, "combined unknown")
    check(BmsState.combined([0, 11, 2]) == .standby, "combined transient ignored")

    check(ChargeEta.rateAfterS == 600, "rate window")
    check(ChargeEta.minutesToFull(socPercent: 60, session: rangeSession(0, 9, 55, 58)) == nil, "rate not trusted at 9 min")
    check(ChargeEta.minutesToFull(socPercent: 60, session: rangeSession(0, 30, 50, 60)) == 120, "session rate")
    check(ChargeEta.minutesToFull(socPercent: nil, session: rangeSession(0, 30, 50, 60)) == 120, "latest rise")
    check(ChargeEta.minutesToFull(socPercent: 70, session: rangeSession(0, 30, 50, 60)) == 90, "live charge wins")
    check(ChargeEta.minutesToFull(socPercent: 100, session: rangeSession(0, 60, 80, 100)) == 0, "session full")
    check(ChargeEta.phrase(45) == "Full in 45 min", "ETA phrase")
    check(ChargeEta.phrase(70) == "Full in 1 h 10 min", "ETA phrase hours")
    check(ChargeEta.phrase(65) == "Full in 1 h 05 min", "ETA phrase padded")
    check(ChargeEta.phrase(1) == "Full in 1 min", "ETA phrase minute")
    check(ChargeEta.phrase(0) == "Full" && ChargeEta.phrase(nil) == nil && ChargeEta.phrase(-3) == nil, "ETA phrase ends")

    // ChargeWatch.
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 5, 54, 78.2), socPercent: 78.2, linkReady: true, riding: false, target: 80) == nil, "below target")
        check(w.update(session: rangeSession(0, 9, 54, 79.9), socPercent: 79.9, linkReady: true, riding: false, target: 80) == nil, "just below")
        check(w.update(session: rangeSession(0, 12, 54, 80.3), socPercent: 80.3, linkReady: true, riding: false, target: 80) == .reached(percent: 80), "target reached")
        check(w.update(session: rangeSession(0, 15, 54, 81), socPercent: 81, linkReady: true, riding: false, target: 80) == nil, "once per session")
        check(w.update(session: rangeSession(0, 60, 54, 92), socPercent: 92, linkReady: true, riding: false, target: 80) == nil, "still once")
    }
    check(ChargeWatch().update(session: rangeSession(0, 6, 78, 81.7), socPercent: 81.7, linkReady: true, riding: false, target: 80) == .reached(percent: 81), "jump over line")
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 5, 85, 86), socPercent: 86, linkReady: true, riding: false, target: 80) == nil, "first seen above target")
        check(w.update(session: rangeSession(0, 9, 85, 88), socPercent: 88, linkReady: true, riding: false, target: 80) == nil, "still above")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 5, 70, 80.5), socPercent: 80.5, linkReady: true, riding: false, target: 80) == .reached(percent: 80), "target 80")
        check(w.update(session: rangeSession(0, 9, 70, 85), socPercent: 85, linkReady: true, riding: false, target: 90) == nil, "target raised")
        check(w.update(session: rangeSession(0, 30, 70, 90.1), socPercent: 90.1, linkReady: true, riding: false, target: 90) == .reached(percent: 90), "target 90")
        check(w.update(session: rangeSession(0, 35, 70, 91), socPercent: 91, linkReady: true, riding: false, target: 80) == nil, "target lowered")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 5, 90, 99.98), socPercent: 99.98, linkReady: true, riding: false, target: 100) == nil, "not quite full")
        check(w.update(session: rangeSession(0, 9, 90, 100), socPercent: 100, linkReady: true, riding: false, target: 100) == .reached(percent: 100), "full")
        check(w.update(session: nil, socPercent: 100, linkReady: true, riding: false, target: 100) == nil, "full once")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 5, 90, 99.4), socPercent: 99.4, linkReady: true, riding: false, target: 100) == nil, "balancing")
        check(w.update(session: nil, socPercent: 99.4, linkReady: true, riding: false, target: 100) == .reached(percent: 100), "ended at full line")
        check(w.update(session: nil, socPercent: 99.4, linkReady: true, riding: false, target: 100) == nil, "full not repeated")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 30, 41, 63.7), socPercent: 63.7, linkReady: true, riding: false, target: 80) == nil, "charging")
        check(w.update(session: nil, socPercent: 63.6, linkReady: true, riding: false, target: 80) == .stopped(percent: 63), "stopped early")
        check(w.update(session: nil, socPercent: 63.6, linkReady: true, riding: false, target: 80) == nil, "stopped once")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 30, 70, 85), socPercent: 85, linkReady: true, riding: false, target: 80) == .reached(percent: 85), "first seen at 85")
        check(w.update(session: nil, socPercent: 85, linkReady: true, riding: false, target: 80) == nil, "above target is expected")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 30, 70, 97), socPercent: 97, linkReady: true, riding: false, target: 100) == nil, "below full")
        check(w.update(session: nil, socPercent: 97, linkReady: true, riding: false, target: 100) == .stopped(percent: 97), "stopped below full")
    }
    for (ready, riding, soc) in [(false, false, 60.0), (true, true, 60.0), (true, false, nil)] {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 30, 41, 60), socPercent: 60, linkReady: true, riding: false, target: 80) == nil, "session seen")
        check(w.update(session: nil, socPercent: soc, linkReady: ready, riding: riding, target: 80) == nil, "no promise without the link")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 30, 41, 60), socPercent: 60, linkReady: true, riding: false, target: 80) == nil, "paused session")
        check(w.update(session: nil, socPercent: 60, linkReady: true, riding: false, target: 80) == .stopped(percent: 60), "paused stop")
        check(w.update(session: rangeSession(0, 50, 41, 61), socPercent: 61, linkReady: true, riding: false, target: 80) == nil, "resumed")
        check(w.update(session: rangeSession(0, 90, 41, 80), socPercent: 80, linkReady: true, riding: false, target: 80) == .reached(percent: 80), "resumed reaches")
        check(w.update(session: nil, socPercent: 80, linkReady: true, riding: false, target: 80) == nil, "resumed once")
        check(w.update(session: rangeSession(0, 120, 41, 82), socPercent: 82, linkReady: true, riding: false, target: 80) == nil, "same start")
    }
    do {
        let w = ChargeWatch()
        check(w.update(session: rangeSession(0, 30, 70, 80), socPercent: 80, linkReady: true, riding: false, target: 80) == .reached(percent: 80), "one session")
        check(w.update(session: nil, socPercent: 80, linkReady: false, riding: false, target: 80) == nil, "link lost")
        check(w.update(session: rangeSession(300, 330, 60, 80.2), socPercent: 80.2, linkReady: true, riding: false, target: 80) == .reached(percent: 80), "new session reaches again")
    }
    check(ChargeWatch().update(session: nil, socPercent: 50, linkReady: true, riding: false, target: 80) == nil, "nothing before a session")

    check(AlertText.chargeReached(percent: 80, rangeKm: 90, estimated: true) == AlertMessage("Charged to 80 %", "Range 90 km est.", "Charged to 80 % · range 90 km est."), "charge alert")
    check(AlertText.chargeReached(percent: 81, rangeKm: 90.7, estimated: false).line == "Charged to 81 % · range 91 km", "range rounds")
    check(AlertText.chargeReached(percent: 80, rangeKm: 90.4, estimated: false).line == "Charged to 80 % · range 90 km", "range rounds down")
    check(AlertText.chargeReached(percent: 100, rangeKm: 112, estimated: true).title == "Fully charged", "fully charged")
    check(AlertText.chargeReached(percent: 90, rangeKm: nil, estimated: true) == AlertMessage("Charged to 90 %", nil, "Charged to 90 %"), "charge alert without range")
    check(AlertText.chargeReached(percent: 90, rangeKm: .nan, estimated: true).text == nil, "NaN range")
    check(AlertText.chargeStopped(percent: 63) == AlertMessage("Charging stopped at 63 %", "No rise for 10 min while connected", "Charging stopped at 63 %"), "stopped alert")
    check(AlertText.range(short: true, wholeKm: 5, remainingKm: 22.4, rangeKm: 18, estimated: true) == AlertMessage("Short by 5 km", "Charge before you arrive · 22 km to go, 18 km range est.", "Short by 5 km — charge before you arrive"), "short range alert")
    check(AlertText.range(short: true, wholeKm: 0, remainingKm: 18, rangeKm: 18.5, estimated: false).title == "Short by 1 km", "never short by 0")
    check(AlertText.range(short: false, wholeKm: 3, remainingKm: 22, rangeKm: 25, estimated: true) == AlertMessage("Range is tight · 3 km spare", "22 km to go, 25 km range est.", "Range is tight · 3 km spare"), "tight range")
    check(AlertText.range(short: false, wholeKm: 3, remainingKm: 8.4, rangeKm: 12, estimated: true).text == "8.4 km to go, 12 km range est.", "tight decimals")
    check(AlertText.range(short: false, wholeKm: -1, remainingKm: 25.5, rangeKm: 25, estimated: false).apply { $0.title == "Range is tight · no spare" && $0.text == "26 km to go, 25 km range" }, "no spare")
    check(AlertText.range(short: false, wholeKm: 0, remainingKm: 24.6, rangeKm: 25, estimated: false).title == "Range is tight · 0 km spare", "zero spare")
    check(AlertText.range(short: true, wholeKm: 2, remainingKm: 21, rangeKm: 18.6, estimated: true).text == "Charge before you arrive · 21 km to go, 19 km range est.", "short text")
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}

private extension RangeEstimate {
    func apply(_ body: (RangeEstimate) -> Bool) -> Bool { body(self) }
}

private extension BucketPoint {
    func apply(_ body: (BucketPoint) -> Bool) -> Bool { body(self) }
}

private extension AlertMessage {
    func apply(_ body: (AlertMessage) -> Bool) -> Bool { body(self) }
}
