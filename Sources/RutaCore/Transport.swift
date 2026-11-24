import Foundation

public enum BluetoothState: Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

public struct DiscoveredScooter: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum TransportEvent: Sendable {
    case bluetoothState(BluetoothState)
    case discovered(DiscoveredScooter)
    case connected
    case ready
    case disconnected(String?)
    case value(characteristic: String, data: [UInt8])
    case writeResult(characteristic: String, success: Bool)
    case readResult(characteristic: String, success: Bool)
    case notifyState(characteristic: String, enabled: Bool)
    case pairingRequired(Bool)
    case failure(String)
}

/// Everything the session needs from a BLE link. Implemented by CoreBluetooth on a real phone and
/// by `FakeScooterTransport` for the simulator, the macOS preview and tests.
public protocol ScooterTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    /// Lowercase characteristic UUIDs the connected scooter exposes; empty until `.ready`.
    var availableCharacteristics: Set<String> { get }

    func startScan()
    func stopScan()
    func connect(to id: UUID)
    func disconnect()
    func setNotify(_ characteristic: String, enabled: Bool)
    func read(_ characteristic: String)
    func write(_ characteristic: String, _ data: [UInt8], withResponse: Bool)
    /// Returns true when the session may enter READY. A transport can refuse while a pairing/security
    /// episode is still unresolved.
    @discardableResult
    func noteSetupAccepted() -> Bool
}

public extension ScooterTransport {
    @discardableResult
    func noteSetupAccepted() -> Bool { true }
}

/// Stable identity of a scooter on this phone. iOS hides the Bluetooth MAC address; a
/// `CBPeripheral.identifier` is the closest equivalent and is stable per iPhone (not across phones).
public struct SavedScooter: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var nickname: String

    public init(id: UUID, name: String, nickname: String) {
        self.id = id
        self.name = name
        self.nickname = nickname
    }

    public var displayName: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : nickname
    }
}

/// Local, non-secret scooter list. The Bluetooth PIN never reaches this app on iOS: the system
/// pairing sheet asks for it, and the system stores the bond.
public final class ScooterStore {
    private let key = "ruta.scooters"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [SavedScooter] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedScooter].self, from: data)) ?? []
    }

    public func save(_ scooters: [SavedScooter]) {
        guard let data = try? JSONEncoder().encode(scooters) else { return }
        defaults.set(data, forKey: key)
    }

    public func add(_ scooter: SavedScooter) {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == scooter.id }) {
            all[index] = scooter
        } else {
            all.append(scooter)
        }
        save(all)
    }

    public func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    public func first() -> SavedScooter? {
        load().first
    }
}
