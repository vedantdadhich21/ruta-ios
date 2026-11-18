import Foundation

/// Fixed-decimal formatting in the POSIX locale, matching the Android UI's `number()`.
public func number(_ value: Double, decimals: Int = 1) -> String {
    String(format: "%.\(decimals)f", value)
}

/// A compact human distance: "820 m", "4.2 km", "112 km".
public func distanceText(_ metres: Double) -> String {
    if metres < 1000 { return "\(Int(metres.rounded())) m" }
    let km = metres / 1000
    return km < 10 ? "\(number(km, decimals: 1)) km" : "\(Int(km.rounded())) km"
}

extension String {
    /// Uppercase the first character, leaving the rest untouched.
    var capitalizingFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

extension Int64 {
    /// Milliseconds since the epoch as a `Date`.
    var date: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}
