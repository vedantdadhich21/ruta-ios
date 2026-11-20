import Foundation

/// Android's characteristic lookup rules, kept pure so they can be tested on the host.
/// Mirrors `ScooterConnection.characteristic(uuid)` from the Android app:
/// - stats (`0x0401`/`0x0402`) come from a plaintext service when one has them; the command
///   service is encrypted and is only a fallback;
/// - everything else prefers the INFO service, then falls back to the last match anywhere.
public enum GattResolution {
    public struct Found: Equatable, Sendable {
        public let service: String
        public let characteristic: String

        public init(service: String, characteristic: String) {
            self.service = service.lowercased()
            self.characteristic = characteristic.lowercased()
        }
    }

    public static func resolve(
        _ found: [Found],
        commandService: String = Tcu.commandService,
        infoService: String = Tcu.infoService
    ) -> [String: Found] {
        let command = commandService.lowercased()
        let info = infoService.lowercased()
        let stats: Set<String> = [Tcu.statsRequest, Tcu.statsUpdate]
        var result: [String: Found] = [:]

        for characteristic in Set(found.map(\.characteristic)) {
            if stats.contains(characteristic) {
                let plaintext = found.last { $0.characteristic == characteristic && $0.service != command }
                let any = found.last { $0.characteristic == characteristic }
                if let chosen = plaintext ?? any { result[characteristic] = chosen }
            } else {
                let onInfo = found.last { $0.characteristic == characteristic && $0.service == info }
                let any = found.last { $0.characteristic == characteristic }
                if let chosen = onInfo ?? any { result[characteristic] = chosen }
            }
        }
        return result
    }
}

#if canImport(CoreBluetooth)
import CoreBluetooth

/// CoreBluetooth link to the scooter. Discovery and the GATT sequence live here; the protocol
/// behaviour (heartbeats, stats, navigation) is in `ScooterSession`.
///
/// iOS specifics that differ from Android:
/// - No MAC address: the scooter is identified by `CBPeripheral.identifier`.
/// - Pairing is a one-time system sheet; there is no PIN API and no bond-state events. The bond is
///   stored by iOS, so a later connection just works.
/// - No MTU request; iOS negotiates a usable MTU itself (usually 185 bytes).
/// - `discoverServices(nil)` returns only *primary* services, unlike Android, so included services
///   are discovered explicitly before characteristics. A TCU that nests a channel as a secondary
///   service is otherwise invisible and looks like "the scooter does not expose the TCU link".
public final class BluetoothScooterTransport: NSObject, ScooterTransport {
    public var onEvent: ((TransportEvent) -> Void)?
    public private(set) var availableCharacteristics: Set<String> = []
    /// Last CoreBluetooth state, for the connection screen.
    public private(set) var state: BluetoothState = .unknown

    /// Scooters advertise a name starting with "HMC" (the TCU's prefix).
    public static let namePrefix = "HMC"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var found: [(service: CBService, characteristic: CBCharacteristic)] = []
    private var resolved: [String: CBCharacteristic] = [:]
    private var known: [UUID: CBPeripheral] = [:]
    private var pendingIncluded = 0
    private var pendingCharacteristics = 0
    private var pendingRead: String?
    private var pendingWrite: String?
    private var wantedID: UUID?
    private var scanRequested = false
    private var connectTimeout: DispatchWorkItem?
    private var discoveryAttempt = 0
    private var probingPairing = false

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func startScan() {
        scanRequested = true
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanRequested = false
        central.stopScan()
    }

    public func connect(to id: UUID) {
        wantedID = id
        central.stopScan()
        let target: CBPeripheral?
        if let known = known[id] {
            target = known
        } else {
            target = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let target else {
            // Not in the system cache yet: scan until it shows up.
            scanRequested = true
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
            return
        }
        resetDiscovery()
        discoveryAttempt = 0
        peripheral = target
        target.delegate = self
        armConnectTimeout()
        central.connect(target, options: nil)
    }

    public func disconnect() {
        cancelConnectTimeout()
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        resetDiscovery()
    }

    public func setNotify(_ characteristic: String, enabled: Bool) {
        let key = characteristic.lowercased()
        guard let characteristic = resolved[key] else {
            Log.gatt("No characteristic for notify \(short(key))")
            return
        }
        peripheral?.setNotifyValue(enabled, for: characteristic)
    }

    public func read(_ characteristic: String) {
        let key = characteristic.lowercased()
        guard let characteristic = resolved[key] else {
            Log.gatt("No characteristic for read \(short(key))")
            return
        }
        pendingRead = key
        peripheral?.readValue(for: characteristic)
    }

    public func write(_ characteristic: String, _ data: [UInt8], withResponse: Bool) {
        let key = characteristic.lowercased()
        guard let characteristic = resolved[key] else {
            Log.gatt("No characteristic for write \(short(key))")
            return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral?.writeValue(Data(data), for: characteristic, type: type)
    }

    // MARK: - Discovery

    private func resetDiscovery() {
        found.removeAll()
        resolved.removeAll()
        availableCharacteristics = []
        pendingIncluded = 0
        pendingCharacteristics = 0
        probingPairing = false
    }

    private func beginDiscovery() {
        found.removeAll()
        resolved.removeAll()
        availableCharacteristics = []
        pendingIncluded = 0
        pendingCharacteristics = 0
        peripheral?.discoverServices(nil)
    }

    private func discoverCharacteristics(of peripheral: CBPeripheral) {
        var unique: [CBService] = []
        var seen = Set<ObjectIdentifier>()
        for primary in peripheral.services ?? [] {
            if seen.insert(ObjectIdentifier(primary)).inserted { unique.append(primary) }
            for included in primary.includedServices ?? [] {
                if seen.insert(ObjectIdentifier(included)).inserted { unique.append(included) }
            }
        }
        pendingCharacteristics = unique.count
        if unique.isEmpty {
            onEvent?(.failure("This scooter exposes no Bluetooth services."))
            return
        }
        for service in unique {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    private func finishDiscovery() {
        let grouped = Dictionary(grouping: found, by: { $0.service.uuid.uuidString.lowercased() })
        for (service, items) in grouped.sorted(by: { $0.key < $1.key }) {
            let list = items
                .map { "\(short($0.characteristic.uuid.uuidString))…/\(Self.properties($0.characteristic.properties))" }
                .joined(separator: " ")
            Log.gatt("Service \(String(service.prefix(8))): \(list)")
        }

        let matches = found.map {
            GattResolution.Found(
                service: $0.service.uuid.uuidString,
                characteristic: $0.characteristic.uuid.uuidString
            )
        }
        resolved = [:]
        for (characteristic, match) in GattResolution.resolve(matches) {
            if let pair = found.first(where: {
                $0.characteristic.uuid.uuidString.lowercased() == characteristic
                    && $0.service.uuid.uuidString.lowercased() == match.service
            }) {
                resolved[characteristic] = pair.characteristic
            }
        }
        availableCharacteristics = Set(found.map { $0.characteristic.uuid.uuidString.lowercased() })

        let required = [Tcu.tcuHeartbeat, Tcu.phoneHeartbeat, Tcu.statsRequest, Tcu.statsUpdate]
        let missing = required.filter { resolved[$0] == nil }

        guard missing.isEmpty else {
            let labels = missing.map { short($0) }.joined(separator: " ")
            Log.gatt("Missing \(labels) after discovery (attempt \(discoveryAttempt + 1))")
            // A protected read is the only way an app can start iOS bonding, and some firmware
            // exposes the rest of the table only after the bond exists. Retry patiently: the PIN
            // sheet may be on screen while the clock runs.
            switch discoveryAttempt {
            case 0:
                discoveryAttempt = 1
                probePairing()
            case 1:
                discoveryAttempt = 2
                Log.gatt("Waiting for pairing, then rediscovering")
                retryDiscovery(after: 10)
            default:
                onEvent?(.failure(
                    "This scooter does not expose the Hero TCU link (\(labels) missing). "
                        + "Open More › Diagnostics for the service list."
                ))
            }
            return
        }

        Log.gatt("Link ready: \(resolved.count) characteristics")
        onEvent?(.ready)
    }

    private func probePairing() {
        guard !probingPairing else { return }
        guard let peripheral else { return }
        let candidate = found
            .map(\.characteristic)
            .first {
                $0.properties.contains(.read)
                    && $0.service?.uuid.uuidString.lowercased() != Tcu.commandService
            }
        if let candidate {
            probingPairing = true
            Log.gatt("Reading \(short(candidate.uuid.uuidString)) to prompt pairing")
            peripheral.readValue(for: candidate)
        } else {
            Log.gatt("Nothing readable to prompt pairing; rediscovering")
        }
        retryDiscovery(after: 1.5)
    }

    private func retryDiscovery(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let peripheral = self.peripheral, peripheral.state == .connected else { return }
            self.probingPairing = false
            self.beginDiscovery()
        }
    }

    private func short(_ uuid: String) -> String {
        String(uuid.lowercased().prefix(4))
    }

    private static func properties(_ properties: CBCharacteristicProperties) -> String {
        var out = ""
        if properties.contains(.read) { out += "r" }
        if properties.contains(.write) { out += "w" }
        if properties.contains(.writeWithoutResponse) { out += "W" }
        if properties.contains(.notify) { out += "n" }
        if properties.contains(.indicate) { out += "i" }
        return out.isEmpty ? "-" : out
    }

    private func armConnectTimeout() {
        cancelConnectTimeout()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let peripheral = self.peripheral, peripheral.state != .connected else { return }
            self.onEvent?(.failure("Scooter did not respond. Keep it on and nearby, then retry."))
            self.central.cancelPeripheralConnection(peripheral)
        }
        connectTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
    }

    private func cancelConnectTimeout() {
        connectTimeout?.cancel()
        connectTimeout = nil
    }

    private static func bluetoothState(_ state: CBManagerState) -> BluetoothState {
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        @unknown default: return .unknown
        }
    }
}

private enum Log {
    static func gatt(_ message: String) {
        DiagnosticsLog.shared.log(message)
    }
}

extension BluetoothScooterTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = Self.bluetoothState(central.state)
        onEvent?(.bluetoothState(state))
        if central.state == .poweredOn, scanRequested {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.uppercased().hasPrefix(Self.namePrefix) else { return }
        known[peripheral.identifier] = peripheral
        onEvent?(.discovered(DiscoveredScooter(
            id: peripheral.identifier, name: name, rssi: RSSI.intValue
        )))
        if wantedID == peripheral.identifier {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            armConnectTimeout()
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelConnectTimeout()
        self.peripheral = peripheral
        peripheral.delegate = self
        discoveryAttempt = 0
        onEvent?(.connected)
        // The TCU is not ready for discovery in the first instant (same wait as Android).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak peripheral] in
            guard let self, let peripheral, self.peripheral === peripheral else { return }
            self.beginDiscovery()
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimeout()
        onEvent?(.disconnected(error?.localizedDescription))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimeout()
        let reason: String?
        if let error = error as NSError? {
            // 7 = the peripheral went away; 14/15 usually mean the bond was refused or removed.
            reason = "GATT \(error.code)"
        } else {
            reason = nil
        }
        self.peripheral = nil
        resetDiscovery()
        onEvent?(.disconnected(reason))
    }
}

extension BluetoothScooterTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Log.gatt("Service discovery failed: \(error.localizedDescription)")
            onEvent?(.failure("Service discovery failed: \(error.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            Log.gatt("No services")
            onEvent?(.failure("This scooter exposes no Bluetooth services."))
            return
        }
        Log.gatt("Services: " + services.map { String($0.uuid.uuidString.lowercased().prefix(8)) }.joined(separator: " "))
        pendingIncluded = services.count
        for service in services {
            peripheral.discoverIncludedServices(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?
    ) {
        if let error {
            Log.gatt("Included services for \(String(service.uuid.uuidString.prefix(8))) failed: \(error.localizedDescription)")
        }
        pendingIncluded -= 1
        guard pendingIncluded <= 0 else { return }
        discoverCharacteristics(of: peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            Log.gatt("Characteristics for \(String(service.uuid.uuidString.prefix(8))) failed: \(error.localizedDescription)")
        }
        for characteristic in service.characteristics ?? [] {
            found.append((service, characteristic))
        }
        pendingCharacteristics -= 1
        guard pendingCharacteristics <= 0 else { return }
        finishDiscovery()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristic.uuid.uuidString.lowercased()
        if let error {
            if probingPairing {
                Log.gatt("Pairing read failed: \(error.localizedDescription)")
                return
            }
            Log.gatt("Read \(short(key)) failed: \(error.localizedDescription)")
            if pendingRead == key {
                pendingRead = nil
                onEvent?(.readResult(characteristic: key, success: false))
            }
            return
        }
        if let value = characteristic.value {
            onEvent?(.value(characteristic: key, data: [UInt8](value)))
        }
        if pendingRead == key {
            pendingRead = nil
            onEvent?(.readResult(characteristic: key, success: true))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Log.gatt("Write \(short(characteristic.uuid.uuidString)) failed: \(error.localizedDescription)")
        }
        pendingWrite = nil
        onEvent?(.writeResult(
            characteristic: characteristic.uuid.uuidString.lowercased(),
            success: error == nil
        ))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Log.gatt("Notify \(short(characteristic.uuid.uuidString)) failed: \(error.localizedDescription)")
        }
        onEvent?(.notifyState(
            characteristic: characteristic.uuid.uuidString.lowercased(),
            enabled: error == nil && characteristic.isNotifying
        ))
    }
}
#endif
