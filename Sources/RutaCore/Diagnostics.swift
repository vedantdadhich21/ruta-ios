import Foundation

/// Diagnostics ring buffer plus a durable, size-bounded append-only file. Disk work runs on a serial
/// queue so BLE callbacks never wait for file I/O; the rider can export recent lines from More even
/// after a crash/relaunch.
public final class DiagnosticsLog {
    public static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private let diskQueue = DispatchQueue(label: "ruta.diagnostics")
    private var lines: [String] = []
    private let limit: Int
    private let formatter: DateFormatter
    private let fileURL: URL?
    private var sessionHeaderWritten = false
    private var diskGeneration = 0
    private static let maxDiskBytes = 2_000_000

    public init(limit: Int = 2_000, persistent: Bool = true) {
        self.limit = limit
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.formatter = formatter
        if persistent {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ruta", isDirectory: true)
            let url = folder.appendingPathComponent("diagnostics.log")
            fileURL = url
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                lines = text.split(separator: "\n").suffix(limit).map(String.init)
            }
        } else {
            fileURL = nil
        }
    }

    public func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        var batch = [line]
        if !sessionHeaderWritten {
            sessionHeaderWritten = true
            let header = "— \(RutaBuild.header.replacingOccurrences(of: "\n", with: " · "))"
            lines.append(header)
            batch.insert(header, at: 0)
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        let generation = diskGeneration
        let url = fileURL
        lock.unlock()

        if let url {
            diskQueue.async {
                guard generation == self.currentDiskGeneration() else { return }
                self.append(batch, to: url)
            }
        }
        #if DEBUG
        print("[Ruta] \(line)")
        #endif
    }

    public func export() -> String {
        lock.lock()
        defer { lock.unlock() }
        return RutaBuild.header + "\n\n" + lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        sessionHeaderWritten = false
        diskGeneration += 1
        let generation = diskGeneration
        let url = fileURL
        lock.unlock()
        if let url {
            diskQueue.async {
                guard generation == self.currentDiskGeneration() else { return }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    private func currentDiskGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return diskGeneration
    }

    private func append(_ batch: [String], to url: URL) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > Self.maxDiskBytes,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let tail = text.split(separator: "\n").suffix(1_000).joined(separator: "\n") + "\n"
            try? Data(tail.utf8).write(to: url, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { _ = try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: Data((batch.joined(separator: "\n") + "\n").utf8))
    }
}
