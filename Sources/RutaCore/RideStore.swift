import Foundation

/// A finished ride together with its GPS track. Stored as one JSON file: a few hundred rides with
/// thinned tracks fit comfortably, and the format stays readable while debugging.
public struct StoredRide: Codable, Equatable, Sendable, Identifiable {
    public var ride: Ride
    public var points: [RidePoint]

    public var id: Int64 { ride.id }

    public init(ride: Ride, points: [RidePoint]) {
        self.ride = ride
        self.points = points
    }
}

/// Finished rides on disk (JSON). iOS needs no database dependency here.
public final class RideStore {
    let url: URL
    private let queue = DispatchQueue(label: "ruta.rides.store")

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ruta", isDirectory: true)
            self.url = folder.appendingPathComponent("rides.json")
        }
    }

    public func load() -> [StoredRide] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([StoredRide].self, from: data)
        } catch {
            quarantineCorruptFile()
            return []
        }
    }

    public func rides() -> [Ride] {
        load().map(\.ride)
    }

    public func save(_ rides: [StoredRide]) {
        queue.sync {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if rides.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(rides) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Adds a ride (replacing one with the same id) and returns the new list, newest first.
    @discardableResult
    public func add(_ stored: StoredRide) -> [StoredRide] {
        var all = load().filter { $0.id != stored.id }
        all.append(stored)
        all.sort { $0.ride.start > $1.ride.start }
        save(all)
        return all
    }

    @discardableResult
    public func delete(id: Int64) -> [StoredRide] {
        let all = load().filter { $0.id != id }
        save(all)
        return all
    }

    public func updatePlaces(id: Int64, start: String?, end: String?) -> [StoredRide] {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return all }
        all[index].ride.startPlace = start
        all[index].ride.endPlace = end
        save(all)
        return all
    }

    /// Next ride id: one past the largest stored id.
    public func nextId() -> Int64 {
        (load().map(\.id).max() ?? 0) + 1
    }

    private func quarantineCorruptFile() {
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let corrupt = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: corrupt)
    }
}

/// Charging sessions, learned as they happen, kept next to the rides.
public final class ChargeStore {
    private let url: URL
    private let queue = DispatchQueue(label: "ruta.charges.store")

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ruta", isDirectory: true)
            self.url = folder.appendingPathComponent("charges.json")
        }
    }

    public func load() -> [ChargeSession] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ChargeSession].self, from: data)
        } catch {
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            let corrupt = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            return []
        }
    }

    public func save(_ sessions: [ChargeSession]) {
        queue.sync {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(sessions) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
