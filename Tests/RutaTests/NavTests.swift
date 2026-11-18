import Foundation
import RutaCore

// Port of the pure parts of `tests/NavTest.kt`: TFT road names, "Then …" hints, the distance
// countdown and the navigation odometer. The Android notification parser has no iOS equivalent.

private func navCue(
    _ turn: Int, _ road: String, distance: Int? = nil, remaining: Int? = nil,
    instruction: String = "", then: Int? = nil
) -> MapsCue {
    MapsCue(
        turn: turn, distanceMeters: distance, instruction: instruction, road: road,
        arrivalHour24: nil, arrivalMinute: nil, remainingMeters: remaining, rerouting: false,
        thenTurn: then
    )
}

func runNavigation() {
    // Road names.
    let cases: [(String, String)] = [
        ("Riverside Garden Rd", "Riverside"),
        ("Swami Vidyananda Ln", "Vidyananda"),
        ("Ganesh Nagar Rd", "Ganesh"),
        ("Sri Sai Nagar Rd", "Sai Nagar"),
        ("Old Harbor Hwy", "Harbor"),
        ("Outer Ring Rd", "ORR"),
        ("Outer Ring Road", "ORR"),
        ("ORR Service Rd", "ORR"),
        ("National Highway 48", "NH 48"),
        ("NH 48", "NH 48"),
        ("NH65", "NH65"),
        ("MG Road", "MG Rd"),
        ("Mahatma Gandhi Road", "Gandhi Rd"),
        ("Cedar City Main Road", "Cedar"),
        ("Lakeside Main Rd", "Lakeside"),
        ("5th Main Rd", "5th Main"),
        ("1st Cross Road", "1st Cross"),
        ("100 Feet Road", "100 Feet"),
        ("Church Street", "Church St"),
        ("St. Mark's Road", "Marks Rd"),
        ("Road No. 12", "Rd No 12"),
        ("Maple Hills Rd No 12", "Rd No 12"),
        ("Dr. A.P.J. Abdul Kalam Rd", "Kalam"),
        ("Sardar Patel Rd", "Patel Rd"),
        ("Greenfield - Oakwood Rd", "Oakwood"),
        ("Greenfield Rd", "Greenfield"),
        ("Rampur Rd", "Rampur Rd"),
        ("Rotary Club Rd", "Rotary"),
        ("Oakdene", "Oakdene"),
        ("Clocktower Circle", "Clocktower"),
        ("Śivājī Nagar", "Sivaji"),
        ("100% Pure Rd", "100 Pure"),
        ("Road", "Rd"),
        ("Swami", "Swami"),
        ("", ""),
    ]
    for (name, want) in cases {
        eq(RoadNames.fit(name), want, "fit '\(name)'")
    }

    eq(RoadNames.tftChars, 9, "budget")
    eq(RoadNames.fit("Ganesh Nagar Rd", budget: 12), "Ganesh Nagar", "budget 12")
    eq(RoadNames.fit("Riverside Garden Rd", budget: 16), "Riverside", "budget clamps to the field")
    eq(RoadNames.fit("Sri Sai Nagar Rd", budget: 14), "Sai Nagar Rd", "budget 14")
    eq(RoadNames.fit("Swami Vidyananda Ln", budget: 13), "Vidyananda Ln", "budget 13 keeps the suffix")
    eq(RoadNames.fit("Chandrasekharapuram Rd"), "Chandrasekhara", "a word longer than the field is cut at 14")

    for name in cases.map(\.0) + ["Maple Heights Check Post Rd", "Eastpark - Westerdale Main Rd", "Shri Krishna Colony Rd", "K V Rao Rd"] {
        let fitted = RoadNames.fit(name)
        check(fitted.count <= RoadNames.fieldBytes, "'\(name)' → '\(fitted)' length")
        check(fitted.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "+" || $0 == "?") }, "'\(name)' → '\(fitted)' characters")
        check(!fitted.hasPrefix(" ") && !fitted.hasSuffix(" ") && !fitted.contains("  "), "'\(name)' → '\(fitted)' spacing")
        check(String(decoding: NavFrame.roadBytes(fitted), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")) == fitted, "'\(name)' field unchanged")
        if fitted.count > RoadNames.tftChars { check(!fitted.contains(" "), "'\(name)' → '\(fitted)' overflows with more than one word") }
    }

    let frame = navCue(NavTurn.right, "Riverside Garden Rd", distance: 300).frame(now: Date())
    eq(frame.road, "Riverside", "frame road")
    eq(frame.roadText, "Riverside", "frame roadText")
    let roadBytes = Array(frame.encode()[13..<27])
    eq(String(decoding: roadBytes, as: UTF8.self), "Riverside\0\0\0\0\0", "road bytes")
    check(NavFrame(active: true, turn: NavTurn.left, distanceMeters: 0, nextTurn: NavTurn.straight, arrivalHour24: 0, arrivalMinute: 0, remainingMeters: 0, remainingMinutes: 0, road: "Cedar City Main Road").roadText == "Cedar City Mai", "raw 14-byte cut")
    check(NavFrame(active: true, turn: NavTurn.left, distanceMeters: 0, nextTurn: NavTurn.straight, arrivalHour24: 0, arrivalMinute: 0, remainingMeters: 0, remainingMinutes: 0, road: "MG Road/NH-65").roadText == "MG Road_NH_65", "sanitising kept")

    // Then hints.
    eq(RoadNames.thenHint(turn: NavTurn.right, budget: 9), "Then R", "right at 9")
    eq(RoadNames.thenHint(turn: NavTurn.right, budget: 10), "Then right", "right at 10")
    eq(RoadNames.thenHint(turn: NavTurn.keepLeft, budget: 11), "Then keep L", "keep left at 11")
    eq(RoadNames.thenHint(turn: NavTurn.keepLeft, budget: 14), "Then keep left", "keep left at 14")
    eq(RoadNames.thenHint(turn: NavTurn.uTurnLeft, budget: 12), "Then U turn", "U-turn at 12")
    eq(RoadNames.thenHint(turn: NavTurn.roundaboutRight, budget: 20), "Then rndabout", "budget clamps to the field")
    check(RoadNames.thenHint(turn: NavTurn.straight) == nil, "straight has no hint")
    check(RoadNames.thenHint(turn: NavTurn.destination) == nil, "destination has no hint")
    for turn in 0x42...0x5A {
        for budget in 1...16 {
            guard let hint = RoadNames.thenHint(turn: turn, budget: budget) else { continue }
            check(hint.hasPrefix("Then ") && hint.count <= RoadNames.fieldBytes, "hint '\(hint)'")
            check(hint.allSatisfy { $0.isASCII && ($0.isLetter || $0 == " ") }, "hint '\(hint)' characters")
            if budget >= RoadNames.tftChars { check(hint.count <= budget, "hint '\(hint)' over budget \(budget)") }
        }
    }
    eq(
        NavCountdown.key(navCue(NavTurn.left, "MG Rd", then: NavTurn.right)),
        NavCountdown.key(navCue(NavTurn.left, "MG Rd")),
        "countdown key ignores the hint"
    )

    // Rounding.
    let rounding: [(Double, Int)] = [
        (-5, 0), (0, 0), (4.9, 0), (5, 10), (84, 80), (994, 990), (995, 1000),
        (1049, 1000), (1050, 1100), (3389, 3400), (12345, 12300),
    ]
    for (metres, want) in rounding {
        eq(NavCountdown.round(metres), want, "round \(metres)")
    }

    // Explicit distance, then GPS travel counts it down.
    let c = NavCountdown()
    eq(c.at(travelledM: 0), NavCountdown.Distances(maneuverM: 0, remainingM: nil), "before any update")
    c.update(navCue(NavTurn.left, "Swami Vidyananda Ln", distance: 120, remaining: 3389), travelledM: 0, nowMs: 0)
    eq(c.at(travelledM: 0), NavCountdown.Distances(maneuverM: 120, remainingM: 3400), "anchor")
    eq(c.at(travelledM: 37), NavCountdown.Distances(maneuverM: 80, remainingM: 3400), "37 m later")
    eq(c.at(travelledM: 115), NavCountdown.Distances(maneuverM: 10, remainingM: 3300), "115 m later")
    eq(c.at(travelledM: 130), NavCountdown.Distances(maneuverM: 0, remainingM: 3300), "past the turn")
    c.update(navCue(NavTurn.left, "Swami Vidyananda Ln", distance: 120, remaining: 3369), travelledM: 20, nowMs: 1_000)
    eq(c.at(travelledM: 20), NavCountdown.Distances(maneuverM: 100, remainingM: 3400), "same text keeps counting")
    c.update(navCue(NavTurn.left, "Swami Vidyananda Ln", distance: 100, remaining: 3367), travelledM: 22, nowMs: 2_000)
    eq(c.at(travelledM: 30), NavCountdown.Distances(maneuverM: 90, remainingM: 3400), "new value restarts")
    c.update(navCue(NavTurn.left, "Swami Vidyananda Ln", remaining: 3329), travelledM: 60, nowMs: 3_000)
    eq(c.at(travelledM: 60), NavCountdown.Distances(maneuverM: 60, remainingM: 3300), "same maneuver, no distance")
    c.update(navCue(NavTurn.left, "Swami Vidyananda Ln", distance: 100, remaining: 3328), travelledM: 61, nowMs: 4_000)
    eq(c.at(travelledM: 61), NavCountdown.Distances(maneuverM: 100, remainingM: 3300), "drift corrected")

    // The stationary sequence: Maps flips between two instructions.
    let r = NavCountdown()
    let real: [(Int, String, Int?, Int)] = [
        (NavTurn.straight, "Ganesh Nagar Rd", nil, 3402),
        (NavTurn.straight, "Ganesh Nagar Rd", nil, 3391),
        (NavTurn.left, "Ganesh Nagar Rd", nil, 3390),
        (NavTurn.straight, "Ganesh Nagar Rd", nil, 3391),
        (NavTurn.left, "Ganesh Nagar Rd", 50, 3402),
        (NavTurn.straight, "Ganesh Nagar Rd", nil, 3395),
        (NavTurn.left, "Ganesh Nagar Rd", nil, 3395),
    ]
    let realWant = [
        NavCountdown.Distances(maneuverM: 3400, remainingM: 3400),
        NavCountdown.Distances(maneuverM: 3400, remainingM: 3400),
        NavCountdown.Distances(maneuverM: 0, remainingM: 3400),
        NavCountdown.Distances(maneuverM: 3400, remainingM: 3400),
        NavCountdown.Distances(maneuverM: 50, remainingM: 3400),
        NavCountdown.Distances(maneuverM: 3400, remainingM: 3400),
        NavCountdown.Distances(maneuverM: 50, remainingM: 3400),
    ]
    for (i, item) in real.enumerated() {
        r.update(navCue(item.0, item.1, distance: item.2, remaining: item.3), travelledM: 0, nowMs: Int64(i) * 2_000)
        eq(r.at(travelledM: 0), realWant[i], "real #\(i)")
    }

    // No distance: a new STRAIGHT or DESTINATION uses the remaining route; other turns are 0.
    let s = NavCountdown()
    s.update(navCue(NavTurn.straight, "Old Harbor Hwy", remaining: 2402), travelledM: 0, nowMs: 0)
    eq(s.at(travelledM: 0), NavCountdown.Distances(maneuverM: 2400, remainingM: 2400), "straight → remaining")
    eq(s.at(travelledM: 150), NavCountdown.Distances(maneuverM: 2300, remainingM: 2300), "straight counts down")
    s.update(navCue(NavTurn.destination, "", remaining: 52), travelledM: 160, nowMs: 1_000)
    eq(s.at(travelledM: 160), NavCountdown.Distances(maneuverM: 50, remainingM: 50), "destination → remaining")
    s.update(navCue(NavTurn.right, "MG Rd", remaining: 42), travelledM: 170, nowMs: 2_000)
    eq(s.at(travelledM: 170), NavCountdown.Distances(maneuverM: 0, remainingM: 40), "new turn without distance → 0")
    s.update(navCue(NavTurn.straight, "", remaining: 32, then: NavTurn.left), travelledM: 180, nowMs: 3_000)
    eq(s.at(travelledM: 180), NavCountdown.Distances(maneuverM: 0, remainingM: 30), "straight then turn → 0")

    let n = NavCountdown()
    n.update(navCue(NavTurn.straight, "Ganesh Nagar Rd"), travelledM: 0, nowMs: 0)
    eq(n.at(travelledM: 0), NavCountdown.Distances(maneuverM: 0, remainingM: nil), "no progress")

    let m = NavCountdown()
    m.update(navCue(NavTurn.right, "Riverside Garden Rd", distance: 500, remaining: 2402), travelledM: 0, nowMs: 0)
    eq(m.at(travelledM: 102), NavCountdown.Distances(maneuverM: 400, remainingM: 2300), "between updates")
    m.update(navCue(NavTurn.right, "Riverside Garden Rd", distance: 400, remaining: 2252), travelledM: 102, nowMs: 10_000)
    eq(m.at(travelledM: 102), NavCountdown.Distances(maneuverM: 400, remainingM: 2300), "remaining from the update")

    let p = NavCountdown()
    p.update(navCue(NavTurn.left, "Ganesh Nagar Rd", distance: 50, remaining: 3402), travelledM: 0, nowMs: 0)
    p.update(navCue(NavTurn.right, "MG Rd", distance: 300, remaining: 3342), travelledM: 60, nowMs: 1_000)
    p.update(navCue(NavTurn.left, "Ganesh Nagar Rd", remaining: 3102), travelledM: 300, nowMs: 2_000)
    eq(p.at(travelledM: 300).maneuverM, 0, "passed maneuver forgotten")

    let t = NavCountdown()
    t.update(navCue(NavTurn.left, "X Rd", distance: 50), travelledM: 0, nowMs: 0)
    t.update(navCue(NavTurn.left, "X Rd"), travelledM: 0, nowMs: NavCountdown.forgetMs + 1)
    eq(t.at(travelledM: 0).maneuverM, 0, "stale maneuver forgotten")
    t.reset()
    eq(t.at(travelledM: 0), NavCountdown.Distances(maneuverM: 0, remainingM: nil), "reset")

    // A ride: 10 m/s for 30 s after "500 m"; the frame at 1 Hz counts down in 10 m steps.
    let ride = NavCountdown()
    let odo = NavOdometer()
    let start = navCue(NavTurn.right, "Riverside Garden Rd", distance: 500, remaining: 2402)
    var lat = 45.0
    _ = odo.add(timeMs: 0, lat: lat, lng: 7, accuracyM: 5, speedMps: 10, gps: true)
    ride.update(start, travelledM: odo.totalM, nowMs: 0)
    var shown: [Int] = []
    for second in 1...30 {
        lat += 10 / 111_194.93
        _ = odo.add(timeMs: Int64(second) * 1_000, lat: lat, lng: 7, accuracyM: 5, speedMps: 10, gps: true)
        let now = ride.at(travelledM: odo.totalM)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 16, minute: 0, second: second))!
        let frame = start.frame(now: date, distanceMeters: now.maneuverM, remainingMeters: now.remainingM)
        shown.append(frame.distanceMeters)
        let bytes = frame.encode()
        eq(Int(bytes[2]) << 8 | Int(bytes[3]), frame.distanceMeters, "wire distance \(second)")
        eq(frame.roadText, "Riverside", "ride road")
    }
    eq(shown.first!, 490, "first tick")
    eq(shown.last!, 200, "after 300 m")
    check(zip(shown, shown.dropFirst()).allSatisfy { $1 <= $0 } && shown.allSatisfy { $0 % 10 == 0 }, "monotonic 10 m steps: \(shown)")

    // Odometer.
    let step = 10.0 / 111_194.93
    let still = NavOdometer()
    for (i, wobble) in [0, 3e-5, -2e-5, 1e-5, -3e-5].enumerated() {
        _ = still.add(timeMs: Int64(i) * 1_000, lat: 45 + wobble, lng: 7, accuracyM: 8, speedMps: 0.2, gps: true)
    }
    eq(still.totalM, 0, "stationary jitter")

    let moving = NavOdometer()
    for i in 0...10 {
        _ = moving.add(timeMs: Int64(i) * 1_000, lat: 45 + Double(i) * step, lng: 7, accuracyM: 5, speedMps: 10, gps: true)
    }
    check(abs(moving.totalM - 100) < 0.5, "moving: \(moving.totalM)")

    let poor = NavOdometer()
    _ = poor.add(timeMs: 1_000, lat: 45, lng: 7, accuracyM: 5, speedMps: 10, gps: true)
    check(!poor.add(timeMs: 2_000, lat: 45 + step, lng: 7, accuracyM: 45, speedMps: 10, gps: true), "poor accuracy")
    check(!poor.add(timeMs: 2_000, lat: 45 + step, lng: 7, accuracyM: .nan, speedMps: 10, gps: true), "no accuracy")
    check(!poor.add(timeMs: 500, lat: 45 + step, lng: 7, accuracyM: 5, speedMps: 10, gps: true), "out of order")
    check(!poor.add(timeMs: 1_000, lat: 45 + step, lng: 7, accuracyM: 5, speedMps: 10, gps: true), "same time")
    eq(poor.totalM, 0, "dropped")

    let mixed = NavOdometer()
    _ = mixed.add(timeMs: 0, lat: 45, lng: 7, accuracyM: 5, speedMps: 10, gps: true)
    check(!mixed.add(timeMs: 2_000, lat: 45 + 5 * step, lng: 7, accuracyM: 20, speedMps: nil, gps: false), "network while GPS fresh")
    check(!mixed.add(timeMs: 8_000, lat: 45 + 6 * step, lng: 7, accuracyM: 20, speedMps: nil, gps: false), "new network leg")
    check(mixed.add(timeMs: 14_000, lat: 45 + 9 * step, lng: 7, accuracyM: 20, speedMps: nil, gps: false), "network distance")
    check(abs(mixed.totalM - 30) < 0.5, "mixed: \(mixed.totalM)")

    let jumpy = NavOdometer()
    _ = jumpy.add(timeMs: 0, lat: 45, lng: 7, accuracyM: 5, speedMps: 10, gps: true)
    for i in 1...4 { check(!jumpy.add(timeMs: Int64(i) * 1_000, lat: 45.01, lng: 7, accuracyM: 5, speedMps: 10, gps: true), "jump \(i)") }
    check(!jumpy.add(timeMs: 5_000, lat: 45.01, lng: 7, accuracyM: 5, speedMps: 10, gps: true), "fifth re-anchors")
    check(jumpy.add(timeMs: 6_000, lat: 45.01 + step, lng: 7, accuracyM: 5, speedMps: 10, gps: true), "after re-anchor")
    check(abs(jumpy.totalM - 10) < 0.5, "jumpy: \(jumpy.totalM)")
    jumpy.pause()
    check(!jumpy.add(timeMs: 60_000, lat: 45.02, lng: 7, accuracyM: 5, speedMps: 10, gps: true), "paused leg")
    check(abs(jumpy.totalM - 10) < 0.5, "paused total")
    jumpy.reset()
    eq(jumpy.totalM, 0, "reset")
    check(abs(NavOdometer.haversineM(lat1: 45, lng1: 7, lat2: 45 + step, lng2: 7) - 10) < 0.01, "odometer haversine")
}
