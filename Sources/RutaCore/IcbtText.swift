import Foundation

/// Text fields of the cluster frames (0x0302 caller, 0x0303 road, 0x0305 music): US-ASCII,
/// truncated to the field and zero-padded (no terminator). Letters, digits, whitespace and `+`
/// are kept; anything else is replaced (caller/road: `_`) or removed (music: empty). Other
/// non-ASCII letters and digits become `?`. Accented Latin letters fold to their base letter.
public enum IcbtText {
    public static func encode(_ text: String, length: Int, replacement: String) -> [UInt8] {
        var bytes = Array(sanitize(text, replacement: replacement).utf8)
        if bytes.count > length { bytes = Array(bytes.prefix(length)) }
        if bytes.count < length { bytes += Array(repeating: 0, count: length - bytes.count) }
        return bytes
    }

    /// Pure-ASCII result, one character per kept code point.
    public static func sanitize(_ text: String, replacement: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        var out = ""
        out.reserveCapacity(composed.count)
        for scalar in composed.unicodeScalars {
            let cp = fold(scalar.value)
            if (0x30...0x39).contains(cp) || (0x41...0x5A).contains(cp) || (0x61...0x7A).contains(cp) || cp == 0x2B {
                out.append(Character(Unicode.Scalar(cp)!))
            } else if cp == 0x20 || (0x09...0x0D).contains(cp) || (cp >= 0x80 && isSpaceChar(cp)) {
                out.append(" ")
            } else if cp >= 0x80 && isAlphabeticOrDigit(cp) {
                out.append("?")
            } else {
                out.append(contentsOf: replacement)
            }
        }
        return out
    }

    /// é → e, Å → A: a non-ASCII code point whose decomposition is one ASCII character plus marks.
    private static func fold(_ value: UInt32) -> UInt32 {
        guard value >= 0x80, let scalar = Unicode.Scalar(value) else { return value }
        let parts = Array(String(Character(scalar)).decomposedStringWithCanonicalMapping.unicodeScalars)
        guard let first = parts.first, first.value < 0x80 else { return value }
        guard parts.dropFirst().allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) else { return value }
        return first.value
    }

    private static func isSpaceChar(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static func isAlphabeticOrDigit(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.generalCategory == .decimalNumber
    }
}

/// Caller shown on the cluster during a call: 0x0302, 14 bytes. A non-empty `second` splits the
/// field into two 7-byte halves. Disallowed characters become `_`.
public struct CallerInfo: Equatable, Sendable {
    public static let length = 14

    public let first: String
    public let second: String

    public init(_ first: String, _ second: String = "") {
        self.first = first
        self.second = second
    }

    public func encode() -> [UInt8] {
        if second.isEmpty {
            return IcbtText.encode(first, length: Self.length, replacement: "_")
        }
        return IcbtText.encode(first, length: Self.length / 2, replacement: "_")
            + IcbtText.encode(second, length: Self.length / 2, replacement: "_")
    }

    /// The contact name when resolved, else the number, cleaned so it fits. Nil when there is
    /// nothing to show (do not send).
    public static func forCall(name: String?, number: String?) -> CallerInfo? {
        let display = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty && display.lowercased() != "unknown" {
            return CallerInfo(isPhoneLike(display) ? digitsOf(display) : display)
        }
        let digits = digitsOf(number ?? "")
        return digits.isEmpty ? nil : CallerInfo(digits)
    }

    private static func isPhoneLike(_ text: String) -> Bool {
        var digits = 0
        for scalar in text.unicodeScalars {
            if (0x30...0x39).contains(scalar.value) { digits += 1; continue }
            switch scalar.value {
            case 0x2B, 0x2D, 0x28, 0x29, 0x2E, 0x20: continue
            default: break
            }
            if scalar.properties.isWhitespace { continue }
            return false
        }
        return digits >= 3
    }

    private static func digitsOf(_ text: String) -> String {
        String(text.unicodeScalars.filter { (0x30...0x39).contains($0.value) || $0.value == 0x2B }.map { Character($0) })
    }
}
