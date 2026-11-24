import Foundation
import RutaCore

// Port of `tests/RideAnalyticsTest.kt`: ride filtering, segmentation, summaries, charging.

private let metresPerDegree = RideMath.earthRadiusM * Double.pi / 180

func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

private func rideFix(_ time: Int64, northM: Double, speed: Double? = nil, accuracy: Double = 5) -> GeoFix {
    GeoFix(time: time, lat: 12.9 + northM / metresPerDegree, lng: 77.6, accuracyM: accuracy, speedKmh: speed)
}

private func summaryRide(_ id: Int64, _ distanceM: Double, _ movingS: Int64, _ peak: Double, _ socStart: Double?, _ socEnd: Double?) -> Ride {
    Ride(
        id: id, start: 0, end: movingS * 1000, startLat: 12.9, startLng: 77.6, endLat: 13.0, endLng: 77.6,
        startPlace: nil, endPlace: nil, distanceM: distanceM, durationS: movingS, movingS: movingS,
        peakKmh: peak, avgKmh: RideMath.averageKmh(distanceM: distanceM, movingMs: movingS * 1000),
        socStart: socStart, socEnd: socEnd
    )
}

func runRideMath() {
    // Haversine.
    check(near(RideMath.haversineM(lat1: 0, lng1: 0, lat2: 1, lng2: 0), metresPerDegree, 1e-6), "1° latitude")
    check(near(RideMath.haversineM(lat1: 0, lng1: 0, lat2: 0, lng2: 1), metresPerDegree, 1e-6), "1° longitude at equator")
    check(near(RideMath.haversineM(lat1: 60, lng1: 10, lat2: 60, lng2: 11), metresPerDegree / 2, 50), "cos 60")
    check(near(RideMath.haversineM(lat1: 0, lng1: 0, lat2: 0, lng2: 180), Double.pi * RideMath.earthRadiusM, 1e-3), "half circumference")
    check(RideMath.haversineM(lat1: 12.9, lng1: 77.6, lat2: 12.9, lng2: 77.6) == 0, "same point")
    check(near(
        RideMath.haversineM(lat1: 12.9, lng1: 77.6, lat2: 13, lng2: 77.7),
        RideMath.haversineM(lat1: 13, lng1: 77.7, lat2: 12.9, lng2: 77.6), 1e-9
    ), "symmetric")

    // FixFilter.
    let f = FixFilter()
    check(f.accept(rideFix(0, northM: 0, accuracy: 30)) == nil, "worse than 25 m")
    check(f.accept(rideFix(0, northM: 0, accuracy: .nan)) == nil, "no accuracy")
    check(f.accept(GeoFix(time: 0, lat: 0, lng: 0, accuracyM: 5)) == nil, "0,0 placeholder")
    let first = f.accept(rideFix(1_000, northM: 0, speed: 0))!
    check(first.stepM == 0 && !first.moving, "first fix")
    let jitter = f.accept(rideFix(2_000, northM: 3, speed: 1))!
    check(jitter.stepM == 0 && jitter.speedKmh == 0 && !jitter.moving && jitter.lat == first.lat, "jitter")
    check(f.accept(rideFix(3_000, northM: 12, accuracy: 15))!.stepM == 0, "inside accuracy radius")
    let move = f.accept(rideFix(4_000, northM: 10, speed: 36))!
    check(near(move.stepM, 10, 0.01) && move.speedKmh == 36 && move.moving, "real movement")
    check(f.accept(rideFix(4_000, northM: 20, speed: 36)) == nil, "out of order")
    check(f.accept(rideFix(5_000, northM: 510, speed: 36)) == nil, "500 m in a second")
    let after = f.accept(rideFix(6_000, northM: 30, speed: 36))!
    check(near(after.stepM, 20, 0.01), "from last good fix")
    let implied = f.accept(rideFix(7_000, northM: 40, speed: 500))!
    check(near(implied.speedKmh, 36, 0.1) && implied.moving, "impossible Doppler → implied")
    let creep = f.accept(rideFix(10_000, northM: 46))!
    check(near(creep.stepM, 6, 0.01) && near(creep.speedKmh, 7.2, 0.1), "slow creep")

    let g = FixFilter()
    _ = g.accept(rideFix(0, northM: 0))
    for i in 0..<4 { check(g.accept(rideFix(Int64(i + 1) * 1_000, northM: 5_000 + Double(i))) == nil, "jump \(i)") }
    let restarted = g.accept(rideFix(5_000, northM: 5_004))!
    check(restarted.stepM == 0 && restarted.lat == rideFix(0, northM: 5_004).lat, "anchor restart")
    check(near(g.accept(rideFix(6_000, northM: 5_014, speed: 36))!.stepM, 10, 0.01), "after restart")

    // Smoothing.
    let s = SpeedSmoother()
    check(s.add(90) == 90 && !s.full, "smoother 1")
    check(s.add(30) == 30, "lower of two")
    check(s.add(32) == 32 && s.full, "smoother full")
    check(s.add(95) == 32, "spike ignored")
    check(s.add(34) == 34, "smoother median")
    check(RideMath.median3(3, 1, 2) == 2 && RideMath.median3(1, 1, 5) == 1, "median3")

    // Segmentation.
    let t0: Int64 = 1_000_000
    let a = RideSegmenter()
    check(a.update(now: t0, linkReady: false, ignitionOn: true, speedKmh: 30) == nil && !a.riding, "no link, no ignition start")
    check(a.update(now: t0 + 1_000, linkReady: true, ignitionOn: true, speedKmh: nil) == .started(time: t0 + 1_000, byIgnition: true) && a.riding, "ignition start")
    let off = t0 + 2_000
    check(a.update(now: off, linkReady: true, ignitionOn: false, speedKmh: 0) == nil, "off begins")
    check(a.update(now: off + 59_000, linkReady: true, ignitionOn: false, speedKmh: 0) == nil, "59 s off")
    check(a.update(now: off + 60_000, linkReady: true, ignitionOn: false, speedKmh: 0) == .ended(time: off, reason: .ignitionOff) && !a.riding, "ignition off end")

    let b = RideSegmenter()
    for i in 0...9 { check(b.update(now: t0 + Int64(i) * 1_000, linkReady: true, ignitionOn: nil, speedKmh: 20) == nil, "hold \(i)") }
    check(b.update(now: t0 + 10_000, linkReady: true, ignitionOn: nil, speedKmh: 20) == .started(time: t0, byIgnition: false), "speed start")
    check(b.update(now: t0 + 11_000, linkReady: true, ignitionOn: false, speedKmh: 30) == nil, "moving despite ignition off flag")
    check(b.update(now: t0 + 80_000, linkReady: true, ignitionOn: false, speedKmh: 30) == nil && b.riding, "still riding")
    check(b.update(now: t0 + 81_000, linkReady: false, ignitionOn: nil, speedKmh: 30) == nil, "link lost begins")
    check(b.update(now: t0 + 200_000, linkReady: false, ignitionOn: nil, speedKmh: 30) == nil, "119 s lost")
    check(b.update(now: t0 + 201_000, linkReady: false, ignitionOn: nil, speedKmh: 30) == .ended(time: t0 + 201_000, reason: .linkLost), "link lost end")

    let c = RideSegmenter()
    _ = c.update(now: t0, linkReady: true, ignitionOn: nil, speedKmh: 20)
    _ = c.update(now: t0 + 5_000, linkReady: true, ignitionOn: nil, speedKmh: 5)
    check(c.update(now: t0 + 10_000, linkReady: true, ignitionOn: nil, speedKmh: 20) == nil, "dip restarts hold")
    check(c.update(now: t0 + 20_000, linkReady: true, ignitionOn: nil, speedKmh: 20) == .started(time: t0 + 10_000, byIgnition: false), "hold restarted")

    let noLink = RideSegmenter()
    for i in 0...30 { check(noLink.update(now: t0 + Int64(i) * 1_000, linkReady: false, ignitionOn: nil, speedKmh: 40) == nil, "no link speed \(i)") }

    let d = RideSegmenter()
    check(d.update(now: t0, linkReady: true, ignitionOn: true, speedKmh: 0) == .started(time: t0, byIgnition: true), "idle start")
    _ = d.update(now: t0 + 60_000, linkReady: true, ignitionOn: true, speedKmh: 25)
    _ = d.update(now: t0 + 61_000, linkReady: true, ignitionOn: true, speedKmh: 1)
    _ = d.update(now: t0 + 360_000, linkReady: true, ignitionOn: true, speedKmh: nil)
    check(d.update(now: t0 + 361_000, linkReady: true, ignitionOn: true, speedKmh: nil) == .ended(time: t0 + 61_000, reason: .idle), "idle end")
    check(d.update(now: t0 + 362_000, linkReady: true, ignitionOn: true, speedKmh: nil) == nil && !d.riding, "ignition alone does not restart")
    for i in 0...9 { _ = d.update(now: t0 + 363_000 + Int64(i) * 1_000, linkReady: true, ignitionOn: true, speedKmh: 15) }
    check(d.update(now: t0 + 373_000, linkReady: true, ignitionOn: true, speedKmh: 15) == .started(time: t0 + 363_000, byIgnition: false), "movement restarts")
    check(d.stop(now: t0 + 374_000) == .ended(time: t0 + 374_000, reason: .stopped) && d.stop(now: t0 + 375_000) == nil, "stop")
    _ = d.update(now: t0 + 376_000, linkReady: true, ignitionOn: false, speedKmh: nil)
    check(d.update(now: t0 + 377_000, linkReady: true, ignitionOn: true, speedKmh: nil) == .started(time: t0 + 377_000, byIgnition: true), "ignition after off")

    let paused = RideSegmenter()
    _ = paused.update(now: t0, linkReady: true, ignitionOn: true, speedKmh: 0)
    paused.pause()
    check(paused.update(now: t0 + 5_000, linkReady: true, ignitionOn: true, speedKmh: 0) == nil && paused.riding,
          "background pause neither ends nor restarts the active ride")
    paused.resume(now: t0 + 10_000)
    check(paused.update(now: t0 + 11_000, linkReady: true, ignitionOn: true, speedKmh: 0) == nil && paused.riding,
          "resume continues the same ride")
    check(paused.stop(now: t0 + 12_000) == .ended(time: t0 + 12_000, reason: .stopped), "paused ride can still be stopped")

    let charge = ChargeDetector()
    _ = charge.update(now: t0, soc: 50, linkReady: true, riding: false)
    _ = charge.update(now: t0 + 360_000, soc: 52, linkReady: true, riding: false)
    check(charge.active != nil, "charge session active before pause")
    charge.pause(now: t0 + 360_000)
    charge.resume(now: t0 + 1_560_000)
    check(charge.update(now: t0 + 1_561_000, soc: 52, linkReady: true, riding: false) == nil && charge.active != nil,
          "background pause does not create a false charging-stop event")

    // Ride summary.
    let track = RideAccumulator()
    let points = sampleRide().map { track.add($0) }
    check(near(track.distanceM, 1_798, 1e-6), "sample distance \(track.distanceM)")
    check(track.movingMs == 170_000, "moving ms \(track.movingMs)")
    check(track.peakKmh == 54, "peak \(track.peakKmh)")
    check(near(track.averageKmh, 1_798.0 / 170 * 3.6, 1e-6), "average")
    let ride = track.finish(id: 7, socStart: 80, socEnd: 79)!
    check(ride.id == 7 && ride.start == 30_000 && ride.end == 260_000 && ride.durationS == 230 && ride.movingS == 170, "ride span")
    check(near(ride.startLat, rideFix(0, northM: 2).lat, 1e-9) && ride.peakKmh == 54, "ride start")
    check(near(ride.kmPerPercent!, 1.798, 1e-6) && ride.batteryUsed == 1, "ride efficiency")
    check(ride.startLabel == "12.9000, 77.6000", "lat/lng label")
    check(points.first!.distanceM == 0 && points.last!.distanceM == track.distanceM, "cumulative points")

    let replayed = RideAccumulator.replay(points.reversed())
    check(replayed.finish(id: 7, socStart: 80, socEnd: 79) == ride, "replay")

    let short = RideAccumulator()
    for t in 0...10 {
        short.add(TrackStep(time: Int64(t) * 1_000, lat: 12.9, lng: 77.6, accuracyM: 5, stepM: t == 0 ? 0 : 10, speedKmh: 36, moving: t > 0))
    }
    check(short.finish(id: 1, socStart: nil, socEnd: nil) == nil, "100 m is too short")
    let quick = RideAccumulator()
    for t in 0...30 {
        quick.add(TrackStep(time: Int64(t) * 1_000, lat: 12.9, lng: 77.6, accuracyM: 5, stepM: t == 0 ? 0 : 10, speedKmh: 36, moving: t > 0))
    }
    check(near(quick.distanceM, 300, 1e-9) && quick.finish(id: 1, socStart: nil, socEnd: nil) == nil, "30 s is too short")
    let enough = RideAccumulator()
    for t in 0...60 {
        enough.add(TrackStep(time: Int64(t) * 1_000, lat: 12.9, lng: 77.6, accuracyM: 5, stepM: t == 0 ? 0 : 10, speedKmh: 36, moving: t > 0))
    }
    check(enough.finish(id: 1, socStart: nil, socEnd: nil)!.durationS == 60, "60 s and 600 m is a ride")
    check(RideAccumulator().finish(id: 1, socStart: nil, socEnd: nil) == nil, "empty ride")

    // Battery + stats.
    check(RideMath.kmPerPercent(distanceM: 12_000, socStart: 60, socEnd: 57) == 4, "km/%")
    check(RideMath.kmPerPercent(distanceM: 5_000, socStart: 60, socEnd: 59.5) == nil, "under a point is noise")
    check(RideMath.kmPerPercent(distanceM: 5_000, socStart: nil, socEnd: 59) == nil && RideMath.kmPerPercent(distanceM: 5_000, socStart: 60, socEnd: 62) == nil, "invalid km/%")
    check(RideMath.averageKmh(distanceM: 1_000, movingMs: 100_000) == 36 && RideMath.averageKmh(distanceM: 1_000, movingMs: 0) == 0, "average speed")

    let stats = RideMath.stats([
        summaryRide(1, 10_000, 1_200, 55, 80, 77),
        summaryRide(2, 6_000, 600, 62, nil, nil),
    ])
    check(stats.rides == 2 && stats.distanceM == 16_000 && stats.movingS == 1_800 && stats.peakKmh == 62, "stats totals")
    check(near(stats.avgKmh, 32) && stats.batteryUsed == 3, "stats average and battery")
    check(near(stats.kmPerPercent!, 10.0 / 3), "stats km/% ignores unmetered rides")
    let empty = RideMath.stats([])
    check(empty.rides == 0 && empty.avgKmh == 0 && empty.kmPerPercent == nil, "empty stats")

    // Charging sessions.
    let minute: Int64 = 60_000
    func series(_ minutes: ClosedRange<Int>, _ soc: (Double) -> Double) -> [ValueAt] {
        minutes.map { ValueAt(time: Int64($0) * minute / 2, value: soc(Double($0) / 2)) }
    }
    let samples = series(0...200) { m in m < 20 ? 50 : (m <= 80 ? 50 + (m - 20) * 0.5 : 80) }
    let sessions = RideMath.chargeSessions(samples)
    check(sessions.count == 1, "one charge session")
    let session = sessions[0]
    check(session.start == 20 * minute && session.end == 80 * minute && session.socStart == 50 && session.socEnd == 80, "session span")
    check(session.durationS == 3_600 && near(session.percentPerHour, 30) && session.gained == 30, "session rate")

    let detector = ChargeDetector()
    check(detector.update(now: 0, soc: 50, linkReady: true, riding: false) == nil, "detector low")
    check(detector.update(now: 4 * minute, soc: 52, linkReady: true, riding: false) == nil && detector.active == nil, "not confirmed at 4 min")
    check(detector.update(now: 5 * minute, soc: 52.5, linkReady: true, riding: false) == nil && detector.active == ChargeSession(start: 0, end: 5 * minute, socStart: 50, socEnd: 52.5), "confirmed at 5 min")
    check(detector.update(now: 14 * minute, soc: 52.5, linkReady: true, riding: false) == nil && detector.active != nil, "still charging")
    check(detector.update(now: 15 * minute, soc: 52.5, linkReady: true, riding: false) == ChargeSession(start: 0, end: 5 * minute, socStart: 50, socEnd: 52.5) && detector.active == nil, "stall ends")

    let riding = ChargeDetector()
    for m in 0...20 { check(riding.update(now: Int64(m) * minute, soc: 50 + Double(m), linkReady: true, riding: true) == nil && riding.active == nil, "no charge while riding") }
    let lost = ChargeDetector()
    _ = lost.update(now: 0, soc: 50, linkReady: true, riding: false)
    _ = lost.update(now: 6 * minute, soc: 52, linkReady: true, riding: false)
    check(lost.update(now: 7 * minute, soc: 52.5, linkReady: false, riding: false) == ChargeSession(start: 0, end: 6 * minute, socStart: 50, socEnd: 52), "link drop ends")

    check(RideMath.chargeSessions(series(0...240) { 50 + $0 / 120 }).isEmpty, "slow drift is not charging")

    func gapped(_ gapMinutes: Int) -> [ChargeSession] {
        let before = series(0...60) { $0 < 10 ? 50 : 50 + ($0 - 10) * 0.5 }
        let resume = 30 + gapMinutes
        let after = series((resume * 2)...((resume + 35) * 2)) { min(60 + ($0 - Double(resume)) * 0.5, 70) }
        return RideMath.chargeSessions(before + after)
    }
    let bridged = gapped(10)
    check(bridged.count == 1 && bridged[0].start == 10 * minute && bridged[0].socStart == 50 && bridged[0].socEnd == 70, "short gap bridged")
    check(bridged[0].end == 60 * minute, "bridged end")
    let split = gapped(120)
    check(split.count == 2 && split[0].socEnd == 60 && split[1].socStart == 60 && split[1].socEnd == 70, "long gap splits")

    // Downsampling.
    let values = (0..<100).map { ValueAt(time: Int64($0) * 1_000, value: Double($0)) }
    let buckets = RideMath.downsample(values + [ValueAt(time: 100_000, value: 999), ValueAt(time: -1, value: -999)], start: 0, end: 100_000, buckets: 10)
    check(buckets.count == 10, "ten buckets")
    for (k, b) in buckets.enumerated() {
        check(b.time == Int64(k) * 10_000 + 5_000 && b.avg == Double(k * 10) + 4.5 && b.min == Double(k * 10) && b.max == Double(k * 10 + 9) && b.count == 10, "bucket \(k)")
    }
    let gappy = RideMath.downsample(values.filter { $0.time < 30_000 || $0.time >= 40_000 }, start: 0, end: 100_000, buckets: 10)
    check(gappy.count == 9 && !gappy.contains { $0.time == 35_000 }, "gap omitted")
    check(RideMath.downsample(values, start: 0, end: 100_000, buckets: 1000).count == 100, "never more buckets than samples")
    check(RideMath.downsample(values, start: 10, end: 10, buckets: 5).isEmpty && RideMath.downsample(values, start: 0, end: 10, buckets: 0).isEmpty, "empty ranges")
    check(RideMath.bucketWidth(start: 0, end: 100, buckets: 3) == 34 && RideMath.bucketWidth(start: 0, end: 2, buckets: 10) == 1, "bucket width")
    let day = (0..<2880).map { ValueAt(time: Int64($0) * 30_000, value: 50) }
    check(RideMath.downsample(day, start: 0, end: 86_400_000, buckets: 96).allSatisfy { $0.count == 30 }, "day buckets")

    let chartTrack = (0...9).map { RidePoint(time: Int64($0) * 1_000, lat: 12.9, lng: 77.6, speedKmh: Double($0) * 10, distanceM: Double($0) * 10, accuracyM: 5) }
    let speed = RideMath.speedSeries(chartTrack, buckets: 5)
    check(speed.count == 5 && speed.first!.avg == 5 && speed.last!.max == 90, "speed series")

    // Helpers.
    check(RideMath.placeLabel(subLocality: "Lakeside", thoroughfare: "Riverside Garden Rd", locality: "Northgate") == "Riverside Garden Rd, Lakeside", "street + area")
    check(RideMath.placeLabel(subLocality: "Koramangala", thoroughfare: "80 Feet Road", locality: "Bengaluru") == "80 Feet Road, Koramangala", "80 Feet Road")
    check(RideMath.placeLabel(subLocality: "Greenfield", thoroughfare: nil, locality: "Northgate") == "Greenfield", "area only")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: nil, locality: "Northgate") == "Northgate", "city only")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: "Old Harbor Hwy", locality: "Northgate") == "Old Harbor Hwy, Northgate", "street + city")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: nil, locality: "Bengaluru", featureName: "7J4V+2C") == "Bengaluru", "plus code skipped")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: "MG Road", locality: nil, featureName: "12", subAdminArea: nil, adminArea: "Karnataka") == "MG Road", "house number skipped")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: nil, locality: nil, featureName: "221/B") == nil, "only house number")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: nil, locality: nil, featureName: "Lakeside Mall", subAdminArea: "Greenfield District", adminArea: "Northshire") == "Lakeside Mall", "feature name")
    check(RideMath.placeLabel(subLocality: nil, thoroughfare: nil, locality: nil, featureName: "12", subAdminArea: "Greenfield District", adminArea: "Northshire") == "Greenfield District", "district fallback")
    check(RideMath.placeLabel(subLocality: "Indiranagar", thoroughfare: nil, locality: "Indiranagar") == "Indiranagar", "deduplicated")
    check(RideMath.placeLabel(subLocality: "Lakeside", thoroughfare: "Lakeside", locality: "Northgate") == "Lakeside", "same street and area")
    check(RideMath.placeLabel(subLocality: "Lakeside", thoroughfare: "Unnamed Road", locality: "Northgate") == "Lakeside", "unnamed road")
    check(RideMath.placeLabel(subLocality: "Lakeside", thoroughfare: "12-2-345", locality: "Northgate") == "Lakeside", "plot number")
    check(RideMath.placeLabel(subLocality: "Lakeside", thoroughfare: "Plot No 5", locality: "Northgate") == "Lakeside", "plot no")
    check(RideMath.placeLabel(subLocality: "Maple Heights", thoroughfare: "Road No. 36", locality: "Northgate") == "Road No. 36, Maple Heights", "road no 36")
    check(RideMath.placeLabel(subLocality: "7J4V+2C Greenfield", thoroughfare: nil, locality: "Northgate") == "Greenfield", "plus code prefix")
    check(RideMath.placeLabel(subLocality: " ", thoroughfare: " ", locality: nil) == nil, "blank")
    let results = [
        PlaceParts(thoroughfare: nil, subLocality: nil, locality: "Northgate", featureName: "7J4V+2C"),
        PlaceParts(thoroughfare: "Riverside Garden Rd", subLocality: "Lakeside", locality: "Northgate"),
        PlaceParts(thoroughfare: "Old Harbor Hwy", subLocality: "Greenfield", locality: "Northgate"),
    ]
    check(RideMath.placeLabel(results) == "Riverside Garden Rd, Lakeside", "several results")
    check(RideMath.placeLabel([]) == nil, "no results")
    check(RideMath.placeArea("Riverside Garden Rd, Lakeside") == "Lakeside" && RideMath.placeArea("Lakeside") == "Lakeside" && RideMath.placeArea(nil) == nil, "place area")
    check(RideMath.shortPlace("Riverside Garden Road") == "Riverside Garden Rd", "short place")
    check(RideMath.shortPlace(" 80 Feet  ROAD, Koramangala ") == "80 Feet Rd, Koramangala", "short place spaces")
    check(RideMath.shortPlace("Church Street") == "Church St" && RideMath.shortPlace("Broadway") == "Broadway", "whole words")
    check(RideMath.shortPlace("Lanesborough Avenue") == "Lanesborough Ave", "avenue")
    check(RideMath.rideTitle(startPlace: "Riverside Garden Road, Lakeside", endPlace: "Lakeside") == "Riverside Garden Rd → Lakeside", "title within an area")
    check(RideMath.rideTitle(startPlace: "Lakeside", endPlace: "Riverside Garden Road, Lakeside") == "Lakeside → Riverside Garden Rd", "title reversed")
    check(RideMath.rideTitle(startPlace: "Riverside Garden Rd, Lakeside", endPlace: "Old Harbor Highway, Greenfield") == "Lakeside → Greenfield", "title areas")
    check(RideMath.rideTitle(startPlace: "Hill Road, Lakeside", endPlace: "hill road, Lakeside") == "Around Hill Rd", "around")
    check(RideMath.rideTitle(startPlace: nil, endPlace: "Greenfield") == nil && RideMath.rideTitle(startPlace: " ", endPlace: "Greenfield") == nil, "title needs both")

    // Plot runs.
    let hour: Int64 = 3_600_000
    let pts = [
        BucketPoint(time: 0, avg: 50, min: 49, max: 51, count: 1),
        BucketPoint(time: hour, avg: 60, min: 60, max: 60, count: 3),
        BucketPoint(time: 2 * hour, avg: 40, min: 40, max: 40, count: 1),
        BucketPoint(time: 10 * hour, avg: 30, min: 30, max: 30, count: 1),
    ]
    let unmerged = RideMath.plotRuns(pts, origin: 0, slotMs: 0, gapMs: hour * 3 / 2)
    check(unmerged.count == 2 && unmerged[0].count == 3 && unmerged[1] == [pts[3]], "plot runs")
    let merged = RideMath.plotRuns(pts, origin: 0, slotMs: 2 * hour, gapMs: hour * 3 / 2)
    check(merged.count == 2 && merged[0].count == 2 && merged[1].count == 1, "merged runs")
    let firstMerged = merged[0][0]
    check(firstMerged.count == 4 && near(firstMerged.avg, 57.5) && firstMerged.min == 49 && firstMerged.max == 60 && firstMerged.time == 2_700_000, "weighted merge")
    check(merged[0][1] == BucketPoint(time: 2 * hour, avg: 40, min: 40, max: 40, count: 1), "second merged bucket")
    check(RideMath.plotRuns([], origin: 0, slotMs: hour, gapMs: hour).isEmpty, "empty plot runs")
    check(RideMath.plotRuns([BucketPoint(time: 5, avg: .nan, min: 0, max: 0)], origin: 0, slotMs: hour, gapMs: hour).isEmpty, "NaN plot run")

    let now: Int64 = 100 * 86_400_000
    check(RideMath.fitsLastDay([now - hour, nil, now - 20 * hour], now: now), "fits last day")
    check(!RideMath.fitsLastDay([now - hour, now - 30 * hour], now: now), "older than a day")
    check(!RideMath.fitsLastDay([nil, nil], now: now) && !RideMath.fitsLastDay([], now: now), "no times")

    check(RideMath.latLngText(lat: 12.97161, lng: 77.59456) == "12.9716, 77.5946", "lat lng text")
    check(RideMath.formatDuration(seconds: 45) == "45 s" && RideMath.formatDuration(seconds: 720) == "12 min" && RideMath.formatDuration(seconds: 3_900) == "1 h 05 min", "duration text")

    let longTrack = (0...100).map { RidePoint(time: Int64($0) * 1_000, lat: 12.9 + Double($0) * 0.0001, lng: 77.6, speedKmh: 30, distanceM: Double($0) * 11.1, accuracyM: 5) }
    let url = RideMath.routeUrl(longTrack)!
    check(url == "https://www.google.com/maps/dir/?api=1&origin=12.900000,77.600000&destination=12.910000,77.600000&travelmode=driving", "route url")
    check(!url.contains("waypoints"), "no waypoints")
    check(RideMath.directionsUrl(fromLat: 1, fromLng: 2, toLat: 3, toLng: 4) == "https://www.google.com/maps/dir/?api=1&origin=1.000000,2.000000&destination=3.000000,4.000000&travelmode=driving", "directions url")
    check(RideMath.routeUrl(Array(longTrack.prefix(1))) == nil, "route needs two points")
    let thinned = RideMath.thin(longTrack, max: 10)
    check(thinned.count == 10 && thinned.first == longTrack.first && thinned.last == longTrack.last, "thin")
    check(RideMath.thin(longTrack, max: 500) == longTrack, "thin keeps short tracks")

    let xy = RideMath.project([longTrack.first!, longTrack.last!], width: 200, height: 100, padding: 10)
    check(xy.count == 4 && xy[0] == 100 && xy[2] == 100 && xy[1] == 90 && xy[3] == 10, "project vertical")
    let dot = RideMath.project([longTrack.first!], width: 200, height: 100)
    check(dot[0] == 100 && dot[1] == 50, "project dot")
}

/// Parked 30 s, 120 s at 36 km/h (one Doppler spike), 20 s at 54, a 60 s stop, 30 s at 36, parked 60 s.
private func sampleRide() -> [TrackStep] {
    let filter = FixFilter()
    var fixes: [GeoFix] = []
    var north = 0.0
    for t in 0...30 { fixes.append(rideFix(Int64(t) * 1_000, northM: t % 2 == 0 ? 2 : -2, speed: 0)) }
    for t in 31...150 { north += 10; fixes.append(rideFix(Int64(t) * 1_000, northM: north, speed: t == 100 ? 90 : 36)) }
    for t in 151...170 { north += 15; fixes.append(rideFix(Int64(t) * 1_000, northM: north, speed: 54)) }
    for t in 231...260 { north += 10; fixes.append(rideFix(Int64(t) * 1_000, northM: north, speed: 36)) }
    for t in 261...320 { fixes.append(rideFix(Int64(t) * 1_000, northM: north + (t % 2 == 0 ? 2 : -2), speed: 0)) }
    return fixes.compactMap { filter.accept($0) }
}
