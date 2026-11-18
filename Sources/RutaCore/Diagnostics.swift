import Foundation

/// In-memory diagnostics ring buffer. Mirrors the Android `DiagLog`: everything the connection
/// does is recorded, and the rider can export it from the app when something goes wrong.
public final class DiagnosticsLog {
    public static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int
    private let formatter: DateFormatter

    public init(limit: Int = 2_000) {
        self.limit = limit
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.formatter = formatter
    }

    public func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
        #if DEBUG
        print("[Ruta] \(line)")
        #endif
    }

    public func export() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }
}
