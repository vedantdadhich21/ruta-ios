import Foundation

/// Road names for the scooter's TFT, which shows about `tftChars` characters before cutting the
/// name off. Port of `RoadNames.kt`; see the original comments for the full rationale.
public enum RoadNames {
    /// Characters the TFT shows before its "…" (≈ 8–9 seen on the VX2).
    public static let tftChars = 9
    /// Size of the 0x0303 road field.
    public static let fieldBytes = 14

    public static func fit(_ name: String, budget: Int = tftChars) -> String {
        let limit = min(max(budget, 1), fieldBytes)
        let words = shorten(tokens(name))
        if words.isEmpty { return "" }
        if joined(words).count <= limit { return joined(words) }

        var core = dropWhere(words) { index, word in isHonorific(word, index: index) }
        core = dropWhere(core) { _, word in word.count == 1 && word.first!.isLetter }
        if joined(core).count <= limit { return joined(core) }
        while core.count > 1, let last = core.last, suffixes.contains(last.lowercased()) {
            core.removeLast()
        }
        if joined(core).count <= limit { return joined(core) }

        var best: Pick?
        for from in core.indices {
            for to in from..<core.count {
                let run = Array(core[from...to])
                let text = joined(run)
                if text.count > limit { break }
                if !run.contains(where: distinctive) { continue }
                let pick = Pick(text: text, score: run.reduce(0) { $0 + score($1) }, from: from)
                if best == nil || pick > best! { best = pick }
            }
        }
        if let best { return best.text }

        let word = core.enumerated().max { a, b in
            let sa = score(a.element), sb = score(b.element)
            if sa != sb { return sa < sb }
            if a.element.count != b.element.count { return a.element.count < b.element.count }
            return a.offset < b.offset
        }?.element ?? ""
        return String(word.prefix(fieldBytes))
    }

    /// "Then …" hint for the road field when a second maneuver follows right after the current one.
    public static func thenHint(turn: Int, budget: Int = tftChars) -> String? {
        guard let forms = thenHints[turn] else { return nil }
        let limit = min(max(budget, 1), fieldBytes)
        return forms.first { $0.count <= limit } ?? forms.last
    }

    private struct Pick: Comparable {
        var text: String
        var score: Double
        var from: Int

        static func < (a: Pick, b: Pick) -> Bool {
            if a.score != b.score { return a.score < b.score }
            if a.text.count != b.text.count { return a.text.count < b.text.count }
            return a.from < b.from
        }
    }

    private static let thenHints: [Int: [String]] = {
        let left = ["Then left"]
        let right = ["Then right", "Then R"]
        let uTurn = ["Then U turn", "Then Uturn", "Then U"]
        let keepLeft = ["Then keep left", "Then keep L", "Then kp L"]
        let keepRight = ["Then keep right", "Then keep R", "Then kp R"]
        let roundabout = ["Then rndabout", "Then rdbt"]
        let exit = ["Then exit"]
        return [
            NavTurn.left: left, NavTurn.slightLeft: left, NavTurn.sharpLeft: left,
            NavTurn.right: right, NavTurn.slightRight: right, NavTurn.sharpRight: right,
            NavTurn.uTurnLeft: uTurn, NavTurn.uTurnRight: uTurn,
            NavTurn.keepLeft: keepLeft, NavTurn.forkLeft: keepLeft,
            NavTurn.keepRight: keepRight, NavTurn.forkRight: keepRight,
            NavTurn.roundaboutLeft: roundabout, NavTurn.roundaboutRight: roundabout,
            NavTurn.rampLeft: exit, NavTurn.rampRight: exit,
        ]
    }()

    /// ASCII words: apostrophes removed, everything the road field cannot carry splits words.
    private static func tokens(_ name: String) -> [String] {
        let stripped = name.replacingOccurrences(of: "[’'`´]", with: "", options: .regularExpression)
        return IcbtText.sanitize(stripped, replacement: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func shorten(_ words: [String]) -> [String] {
        var out = words.map { abbreviations[$0.lowercased()] ?? $0 }
        func lower(_ i: Int) -> String? { out.indices.contains(i) ? out[i].lowercased() : nil }
        var i = 0
        while i < out.count {
            if ["outer", "inner"].contains(lower(i) ?? ""), lower(i + 1) == "ring", lower(i + 2) == "rd" {
                let short = lower(i) == "outer" ? "ORR" : "IRR"
                out.removeSubrange(i...(i + 2))
                out.insert(short, at: i)
            } else if lower(i) == "national", lower(i + 1) == "hwy" {
                out.remove(at: i)
                out[i] = "NH"
            } else if lower(i) == "state", lower(i + 1) == "hwy", out.indices.contains(i + 2), out[i + 2].contains(where: \.isNumber) {
                out.remove(at: i)
                out[i] = "SH"
            }
            i += 1
        }
        return out
    }

    private static func joined(_ words: [String]) -> String { words.joined(separator: " ") }

    private static func dropWhere(_ words: [String], drop: (Int, String) -> Bool) -> [String] {
        let kept = words.enumerated().filter { !drop($0.offset, $0.element) }.map(\.element)
        return kept.isEmpty ? words : kept
    }

    /// "St" is Saint only as the first word ("St Marks Rd"); at the end it is Street.
    private static func isHonorific(_ word: String, index: Int) -> Bool {
        let lower = word.lowercased()
        return honorifics.contains(lower) || (index == 0 && lower == "st")
    }

    private static func score(_ word: String) -> Double {
        let lower = word.lowercased()
        if word.contains(where: \.isNumber) { return 8 }
        if connectors.contains(lower) { return 0.5 }
        if generic.contains(lower) || suffixes.contains(lower) { return 1 }
        if word.count == 1 { return 0.5 }
        return Double(word.count)
    }

    private static func distinctive(_ word: String) -> Bool { score(word) >= 2 }

    private static let abbreviations = [
        "road": "Rd", "rd": "Rd", "street": "St", "lane": "Ln", "avenue": "Ave", "highway": "Hwy",
        "expressway": "Expy", "boulevard": "Blvd", "junction": "Jn", "circle": "Cir", "number": "No",
    ]

    private static let suffixes: Set<String> = [
        "rd", "st", "ln", "ave", "hwy", "expy", "blvd", "marg", "path", "way", "rds", "sarani", "salai",
    ]

    private static let honorifics: Set<String> = [
        "sri", "shri", "shree", "sree", "srimati", "shrimati", "smt", "swami", "swamy", "dr", "doctor", "sir",
        "saint", "sant", "pandit", "pt", "prof", "late", "mahatma", "sardar", "netaji", "lokmanya", "maharshi",
        "guru", "capt", "col", "lt", "maj", "gen",
    ]

    private static let generic: Set<String> = [
        "nagar", "main", "colony", "layout", "garden", "gardens", "park", "city", "cross", "cir", "jn", "chowk",
        "market", "bazar", "bazaar", "hills", "enclave", "vihar", "bagh", "old", "new", "north", "south", "east",
        "west", "upper", "lower", "inner", "outer", "ring", "service", "phase", "sector", "block", "stage",
        "extension", "ext", "village", "town", "gate", "flyover", "bridge", "bypass", "link", "approach",
        "station", "metro", "bus", "stand", "temple", "complex", "plaza", "mall", "tower", "towers", "street",
        "lane", "road", "x", "club", "society", "residency", "apartments", "school", "college", "hospital",
    ]

    private static let connectors: Set<String> = ["no", "of", "and", "the", "to", "via"]
}
