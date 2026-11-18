import Foundation

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
public final class BluetoothScooterTransport: NSObject, ScooterTransport {
    public var onEvent: ((TransportEvent) -> Void)?
    public private(set) var availableCharacteristics: Set<String> = []
    /// Last CoreBluetooth state, for the connection screen.
    public private(set) var state: BluetoothState = .unknown

    /// Scooters advertise a name starting with "HMC" (the TCU's prefix).
    public static let namePrefix = "HMC"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var known: [UUID: CBPeripheral] = [:]
    private var servicesToDiscover = 0
    private var pendingRead: String?
    private var pendingWrite: String?
    private var wantedID: UUID?
    private var scanRequested = false
    private var connectTimeout: DispatchWorkItem?

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
        characteristics.removeAll()
        availableCharacteristics = []
    }

    public func setNotify(_ characteristic: String, enabled: Bool) {
        guard let characteristic = characteristics[characteristic.lowercased()] else { return }
        peripheral?.setNotifyValue(enabled, for: characteristic)
    }

    public func read(_ characteristic: String) {
        guard let characteristic = characteristics[characteristic.lowercased()] else { return }
        pendingRead = characteristic.uuid.uuidString.lowercased()
        peripheral?.readValue(for: characteristic)
    }

    public func write(_ characteristic: String, _ data: [UInt8], withResponse: Bool) {
        guard let characteristic = characteristics[characteristic.lowercased()] else { return }
        let target = peripheral
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        target?.writeValue(Data(data), for: characteristic, type: type)
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
        onEvent?(.connected)
        // The TCU is not ready for discovery in the first instant (same wait as Android).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak peripheral] in
            guard let self, let peripheral, self.peripheral === peripheral else { return }
            peripheral.discoverServices(nil)
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
        characteristics.removeAll()
        availableCharacteristics = []
        onEvent?(.disconnected(reason))
    }
}

extension BluetoothScooterTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            onEvent?(.failure("Service discovery failed: \(error!.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        servicesToDiscover = services.count
        if services.isEmpty {
            onEvent?(.failure("This scooter exposes no Bluetooth services."))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        servicesToDiscover -= 1
        // Service four (stats) can live on any plaintext service; the command service is encrypted,
        // so its characteristics are kept only as a fallback.
        let isCommand = service.uuid.uuidString.lowercased() == Tcu.commandService
        for characteristic in service.characteristics ?? [] {
            let key = characteristic.uuid.uuidString.lowercased()
            if isCommand, characteristics[key] != nil { continue }
            characteristics[key] = characteristic
        }
        guard servicesToDiscover <= 0 else { return }
        availableCharacteristics = Set(characteristics.keys)
        guard availableCharacteristics.contains(Tcu.phoneHeartbeat), availableCharacteristics.contains(Tcu.statsRequest) else {
            onEvent?(.failure("This scooter does not expose the Hero TCU link."))
            return
        }
        onEvent?(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristic.uuid.uuidString.lowercased()
        if let error {
            if pendingRead == key {
                pendingRead = nil
                onEvent?(.readResult(characteristic: key, success: false))
            }
            onEvent?(.failure("Read failed: \(error.localizedDescription)"))
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
        pendingWrite = nil
        onEvent?(.writeResult(
            characteristic: characteristic.uuid.uuidString.lowercased(),
            success: error == nil
        ))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onEvent?(.notifyState(
            characteristic: characteristic.uuid.uuidString.lowercased(),
            enabled: error == nil && characteristic.isNotifying
        ))
    }
}
#endif
