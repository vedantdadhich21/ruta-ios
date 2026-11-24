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

public enum GattTraversal {
    /// Breadth-first order of primary + included services, with cycle/duplicate protection. The
    /// transport dispatches one included-service discovery per returned entry.
    public static func order(primary: [String], included: [String: [String]]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var queue: [String] = []
        for id in primary where seen.insert(id).inserted {
            result.append(id)
            queue.append(id)
        }
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            for child in included[parent] ?? [] where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
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
/// - Included services are walked explicitly, and every connection/discovery pass is generation
///   guarded so a late callback from an old attempt cannot corrupt a new one.
public final class BluetoothScooterTransport: NSObject, ScooterTransport {
    public var onEvent: ((TransportEvent) -> Void)?
    public private(set) var availableCharacteristics: Set<String> = []
    /// Last CoreBluetooth state, for the connection screen.
    public private(set) var state: BluetoothState = .unknown

    /// Scooters advertise a name starting with "HMC" (the TCU's prefix).
    public static let namePrefix = "HMC"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    fileprivate var attempt: PeripheralAttempt?
    private var resolved: [String: CBCharacteristic] = [:]
    private var known: [UUID: CBPeripheral] = [:]

    private var generation = 0
    private var pendingConnectID: UUID?
    private var connectingID: UUID?
    private var wantedID: UUID?
    private var uiScanRequested = false
    private var resolveScanRequested = false
    private var connectRetries = 0
    private var connectTimeout: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?

    fileprivate var discoveryGeneration = 0
    private var discoveryAttempt = 0
    private var discoveryErrorRetried = false
    private var setupAccepted = false
    private var discoveryActive = false
    private var discoveryWatchdog: DispatchWorkItem?
    private var graphServices: [CBService] = []
    private var primaryServices: [CBService] = []
    private var includedByParent: [ObjectIdentifier: [CBService]] = [:]
    private var visitedServices = Set<ObjectIdentifier>()
    private var includeQueue: [CBService] = []
    private var pendingIncluded = 0
    private var pendingCharacteristics = 0
    private var pairingProbeTried = false
    private var pairingCharacteristic: CBCharacteristic?
    private var pairingWatchdog: DispatchWorkItem?
    private enum AuthKind { case read, write, notify }
    private var authPairingActive = false
    private var authPairingKey: String?
    private var authPairingKind: AuthKind?
    private var authPairingTimeout: DispatchWorkItem?
    private var operationRetryWork: DispatchWorkItem?

    private var pendingRead: String?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public transport

    public func startScan() {
        uiScanRequested = true
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Stops only the user-visible scan. A remembered-scooter lookup has its own scan and must not
    /// be cancelled just because the Connect sheet was dismissed.
    public func stopScan() {
        uiScanRequested = false
        if !resolveScanRequested { central.stopScan() }
    }

    public func connect(to id: UUID) {
        generation += 1
        let attemptGeneration = generation
        cancelDelayedWork()
        pendingConnectID = nil
        connectingID = id
        wantedID = nil
        resolveScanRequested = false
        connectRetries = 0
        uiScanRequested = false
        central.stopScan()

        if let old = peripheral {
            old.delegate = nil
            if old.state != .disconnected { central.cancelPeripheralConnection(old) }
        }
        attempt = nil
        peripheral = nil
        resetDiscovery()

        guard central.state == .poweredOn else {
            pendingConnectID = id
            Log.gatt("Waiting for Bluetooth before connecting to \(id.uuidString)")
            return
        }
        resolveAndConnect(id, generation: attemptGeneration)
    }

    public func disconnect() {
        generation += 1
        cancelDelayedWork()
        pendingConnectID = nil
        connectingID = nil
        wantedID = nil
        resolveScanRequested = false
        uiScanRequested = false
        central.stopScan()
        if let old = peripheral {
            old.delegate = nil
            if old.state != .disconnected { central.cancelPeripheralConnection(old) }
        }
        attempt = nil
        peripheral = nil
        resetDiscovery()
    }

    public func setNotify(_ characteristic: String, enabled: Bool) {
        let key = characteristic.lowercased()
        guard let found = resolved[key], let peripheral else {
            Log.gatt("No characteristic for notify \(Self.short(key))")
            onEvent?(.notifyState(characteristic: key, enabled: false))
            return
        }
        guard found.properties.contains(.notify) || found.properties.contains(.indicate) else {
            Log.gatt("\(Self.short(key)) cannot notify/indicate (\(Self.properties(found.properties)))")
            onEvent?(.notifyState(characteristic: key, enabled: false))
            return
        }
        peripheral.setNotifyValue(enabled, for: found)
    }

    public func read(_ characteristic: String) {
        let key = characteristic.lowercased()
        guard let found = resolved[key], let peripheral else {
            Log.gatt("No characteristic for read \(Self.short(key))")
            onEvent?(.readResult(characteristic: key, success: false))
            return
        }
        guard found.properties.contains(.read) else {
            Log.gatt("\(Self.short(key)) is not readable (\(Self.properties(found.properties)))")
            onEvent?(.readResult(characteristic: key, success: false))
            return
        }
        pendingRead = key
        peripheral.readValue(for: found)
    }

    public func write(_ characteristic: String, _ data: [UInt8], withResponse: Bool) {
        let key = characteristic.lowercased()
        guard let found = resolved[key], let peripheral else {
            Log.gatt("No characteristic for write \(Self.short(key))")
            onEvent?(.writeResult(characteristic: key, success: false))
            return
        }
        let type: CBCharacteristicWriteType
        if withResponse, found.properties.contains(.write) {
            type = .withResponse
        } else if found.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse {
            // Android falls back to no-response for service-one/stats writes. Cluster 0x0303 is
            // excluded because its response is what NavDisplay treats as acknowledgement.
            guard key != Tcu.navInfo else {
                Log.gatt("\(Self.short(key)) needs write-with-response for navigation acknowledgement")
                onEvent?(.writeResult(characteristic: key, success: false))
                return
            }
            type = .withoutResponse
            Log.gatt("\(Self.short(key)) falling back to write-without-response")
        } else {
            Log.gatt("\(Self.short(key)) has no usable write property (\(Self.properties(found.properties)))")
            onEvent?(.writeResult(characteristic: key, success: false))
            return
        }
        let limit = peripheral.maximumWriteValueLength(for: type)
        guard data.count <= limit else {
            Log.gatt("Write \(Self.short(key)) is \(data.count) B, limit \(limit)")
            onEvent?(.writeResult(characteristic: key, success: false))
            return
        }
        Log.gatt("Write \(Self.short(key)) \(data.count) B \(type == .withResponse ? "with" : "without") response")
        peripheral.writeValue(Data(data), for: found, type: type)
        if type == .withoutResponse {
            finishAuthPairing(key: key, kind: .write)
            // CoreBluetooth has no completion callback for this mode. This means "enqueued", not
            // "acknowledged by the TCU"; the session currently requests response writes everywhere.
            onEvent?(.writeResult(characteristic: key, success: true))
        }
    }

    @discardableResult
    public func noteSetupAccepted() -> Bool {
        guard !authPairingActive, pairingCharacteristic == nil else { return false }
        setupAccepted = true
        return true
    }

    // MARK: - Connection lifecycle

    private func resolveAndConnect(_ id: UUID, generation: Int) {
        guard generation == self.generation else { return }
        let target = known[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let target else {
            wantedID = id
            resolveScanRequested = true
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
            return
        }
        startConnection(to: target, id: id, generation: generation)
    }

    private func startConnection(to target: CBPeripheral, id: UUID, generation: Int) {
        guard generation == self.generation else { return }
        guard central.state == .poweredOn else {
            pendingConnectID = id
            return
        }
        wantedID = nil
        resolveScanRequested = false
        central.stopScan()
        attempt?.peripheral.delegate = nil
        let next = PeripheralAttempt(owner: self, peripheral: target, generation: generation)
        attempt = next
        peripheral = target
        target.delegate = next
        armConnectTimeout(target, generation: generation)
        Log.gatt("Connecting to \(target.name ?? id.uuidString) (\(id.uuidString))")
        central.connect(target, options: nil)
    }

    private func armConnectTimeout(_ target: CBPeripheral, generation: Int) {
        connectTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation, self.peripheral === target, target.state != .connected else { return }
            Log.gatt("Connection timed out")
            self.onEvent?(.failure("Scooter did not respond. Keep it on and nearby, then retry."))
            self.central.cancelPeripheralConnection(target)
        }
        connectTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func connected(_ peripheral: CBPeripheral, generation: Int) {
        guard isCurrent(peripheral, generation: generation) else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        resetDiscovery()
        discoveryAttempt = 0
        discoveryErrorRetried = false
        pairingProbeTried = false
        onEvent?(.connected)
        // The TCU is not ready for discovery in the first instant (same wait as Android).
        schedule(1_000, generation: generation, peripheral: peripheral) { [weak self] in
            self?.beginDiscovery(peripheral, generation: generation)
        }
    }

    private func connectionFailed(_ peripheral: CBPeripheral, generation: Int, reason: String?) {
        guard isCurrent(peripheral, generation: generation) else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        retryTransientConnection(peripheral, generation: generation, reason: reason)
    }

    private func disconnected(_ peripheral: CBPeripheral, generation: Int, error: Error?) {
        guard isCurrent(peripheral, generation: generation) else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        let wasReady = setupAccepted
        clearAttempt(peripheral, generation: generation)
        if !wasReady, connectRetries < 1, let id = connectingID {
            connectRetries += 1
            self.generation += 1
            let retryGeneration = self.generation
            Log.gatt("Link dropped during setup; retrying once: \(error?.localizedDescription ?? "disconnected")")
            scheduleReconnect(1_200, generation: retryGeneration) { [weak self] in
                self?.resolveAndConnect(id, generation: retryGeneration)
            }
            return
        }
        let reason = (error as NSError?).map { "GATT \($0.code)" }
        onEvent?(.disconnected(reason))
    }

    private func retryTransientConnection(_ peripheral: CBPeripheral, generation: Int, reason: String?) {
        guard connectRetries < 1, let id = connectingID else {
            clearAttempt(peripheral, generation: generation)
            onEvent?(.disconnected(reason))
            return
        }
        connectRetries += 1
        clearAttempt(peripheral, generation: generation)
        self.generation += 1
        let retryGeneration = self.generation
        Log.gatt("Connect failed; retrying once: \(reason ?? "unknown error")")
        scheduleReconnect(1_200, generation: retryGeneration) { [weak self] in
            self?.resolveAndConnect(id, generation: retryGeneration)
        }
    }

    private func clearAttempt(_ peripheral: CBPeripheral, generation: Int) {
        guard generation == self.generation, self.peripheral === peripheral else { return }
        peripheral.delegate = nil
        attempt = nil
        self.peripheral = nil
        resetDiscovery()
    }

    fileprivate func isCurrent(_ peripheral: CBPeripheral, generation: Int) -> Bool {
        generation == self.generation && self.peripheral === peripheral
    }

    private func schedule(_ ms: Int64, generation: Int, peripheral: CBPeripheral, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation, self.peripheral === peripheral else { return }
            body()
        }
        retryWork?.cancel()
        retryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: item)
    }

    private func scheduleReconnect(_ ms: Int64, generation: Int, _ body: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation else { return }
            body()
        }
        retryWork?.cancel()
        retryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: item)
    }

    private func cancelDelayedWork() {
        connectTimeout?.cancel()
        connectTimeout = nil
        retryWork?.cancel()
        retryWork = nil
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        pairingWatchdog?.cancel()
        pairingWatchdog = nil
        pairingCharacteristic = nil
        authPairingTimeout?.cancel()
        authPairingTimeout = nil
        operationRetryWork?.cancel()
        operationRetryWork = nil
        if authPairingActive {
            authPairingActive = false
            authPairingKey = nil
            authPairingKind = nil
            onEvent?(.pairingRequired(false))
        }
        setupAccepted = false
    }

    // MARK: - Discovery

    private func resetDiscovery() {
        discoveryGeneration += 1
        discoveryActive = false
        discoveryErrorRetried = false
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        pairingWatchdog?.cancel()
        pairingWatchdog = nil
        pairingCharacteristic = nil
        authPairingTimeout?.cancel()
        authPairingTimeout = nil
        operationRetryWork?.cancel()
        operationRetryWork = nil
        if authPairingActive {
            authPairingActive = false
            authPairingKey = nil
            authPairingKind = nil
            onEvent?(.pairingRequired(false))
        }
        setupAccepted = false
        graphServices.removeAll()
        primaryServices.removeAll()
        includedByParent.removeAll()
        visitedServices.removeAll()
        includeQueue.removeAll()
        pendingIncluded = 0
        pendingCharacteristics = 0
        resolved.removeAll()
        availableCharacteristics = []
        pendingRead = nil
    }

    private func beginDiscovery(_ peripheral: CBPeripheral, generation: Int) {
        guard isCurrent(peripheral, generation: generation), peripheral.state == .connected else { return }
        discoveryGeneration += 1
        let pass = discoveryGeneration
        attempt?.peripheral.delegate = nil
        let passAttempt = PeripheralAttempt(
            owner: self, peripheral: peripheral, generation: generation, discoveryPass: pass
        )
        attempt = passAttempt
        peripheral.delegate = passAttempt
        discoveryActive = true
        graphServices.removeAll()
        primaryServices.removeAll()
        includedByParent.removeAll()
        visitedServices.removeAll()
        includeQueue.removeAll()
        pendingIncluded = 0
        pendingCharacteristics = 0
        resolved.removeAll()
        availableCharacteristics = []
        pendingRead = nil

        discoveryWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, pass == self.discoveryGeneration, self.discoveryActive,
                  generation == self.generation, self.peripheral === peripheral else { return }
            self.discoveryActive = false
            Log.gatt("Discovery pass \(pass) timed out")
            if self.pairingCharacteristic != nil {
                self.schedule(1_000, generation: generation, peripheral: peripheral) {
                    self.beginDiscovery(peripheral, generation: generation)
                }
            } else {
                self.onEvent?(.failure("Bluetooth service discovery timed out. Tap Connect to retry."))
            }
        }
        discoveryWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: watchdog)
        Log.gatt("Discovery pass \(pass) start; cached services=\(peripheral.services?.count ?? -1)")
        peripheral.discoverServices(nil)
    }

    fileprivate func servicesDiscovered(_ peripheral: CBPeripheral, services: [CBService], generation: Int, pass: Int) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        guard !services.isEmpty else {
            finishDiscoveryError("No services", peripheral: peripheral, generation: generation, pass: pass)
            return
        }
        graphServices = []
        primaryServices = services
        includedByParent.removeAll()
        visitedServices.removeAll()
        includeQueue = []
        for service in services where visitedServices.insert(ObjectIdentifier(service)).inserted {
            includeQueue.append(service)
        }
        for service in services {
            Log.gatt("Service \(service.uuid.uuidString) primary=\(service.isPrimary)")
        }
        pendingIncluded = 0
        discoverNextIncludes(peripheral, generation: generation, pass: pass)
    }

    /// Breadth-first traversal with a visited set: included services can themselves include services.
    private func discoverNextIncludes(_ peripheral: CBPeripheral, generation: Int, pass: Int) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        guard !includeQueue.isEmpty else {
            pendingIncluded = 0
            buildServiceGraph()
            discoverCharacteristics(peripheral, generation: generation, pass: pass)
            return
        }
        let batch = includeQueue
        includeQueue.removeAll()
        pendingIncluded += batch.count
        for service in batch {
            peripheral.discoverIncludedServices(nil, for: service)
        }
    }

    fileprivate func includedServicesDiscovered(
        _ service: CBService, _ peripheral: CBPeripheral, generation: Int, pass: Int, error: Error?
    ) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        if let error {
            Log.gatt("Included services for \(service.uuid.uuidString) failed: \(Self.error(error))")
        }
        let included = (service.includedServices ?? []).sorted {
            $0.uuid.uuidString.lowercased() < $1.uuid.uuidString.lowercased()
        }
        includedByParent[ObjectIdentifier(service)] = included
        for child in included {
            Log.gatt("Include \(service.uuid.uuidString) → \(child.uuid.uuidString)")
        }
        for child in included where visitedServices.insert(ObjectIdentifier(child)).inserted {
            includeQueue.append(child)
        }
        pendingIncluded -= 1
        if !includeQueue.isEmpty {
            discoverNextIncludes(peripheral, generation: generation, pass: pass)
        } else if pendingIncluded <= 0 {
            pendingIncluded = 0
            buildServiceGraph()
            discoverCharacteristics(peripheral, generation: generation, pass: pass)
        }
    }

    private func buildServiceGraph() {
        graphServices = []
        var seen = Set<ObjectIdentifier>()
        var queue: [CBService] = []
        for service in primaryServices where seen.insert(ObjectIdentifier(service)).inserted {
            graphServices.append(service)
            queue.append(service)
        }
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            for child in includedByParent[ObjectIdentifier(parent)] ?? [] where seen.insert(ObjectIdentifier(child)).inserted {
                graphServices.append(child)
                queue.append(child)
            }
        }
    }

    private func discoverCharacteristics(_ peripheral: CBPeripheral, generation: Int, pass: Int) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        pendingCharacteristics = graphServices.count
        guard pendingCharacteristics > 0 else {
            finishDiscoveryError("No services", peripheral: peripheral, generation: generation, pass: pass)
            return
        }
        for service in graphServices {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    fileprivate func characteristicsDiscovered(
        _ service: CBService, _ peripheral: CBPeripheral, generation: Int, pass: Int, error: Error?
    ) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        if let error {
            Log.gatt("Characteristics for \(service.uuid.uuidString) failed: \(Self.error(error))")
        }
        pendingCharacteristics -= 1
        guard pendingCharacteristics <= 0 else { return }
        finishDiscovery(peripheral, generation: generation, pass: pass)
    }

    fileprivate func finishDiscoveryError(
        _ message: String, peripheral: CBPeripheral, generation: Int, pass: Int
    ) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        discoveryActive = false
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        Log.gatt("Discovery pass \(pass): \(message)")
        if pairingCharacteristic != nil {
            schedule(1_000, generation: generation, peripheral: peripheral) { [weak self] in
                self?.beginDiscovery(peripheral, generation: generation)
            }
            return
        }
        if !discoveryErrorRetried {
            discoveryErrorRetried = true
            schedule(1_000, generation: generation, peripheral: peripheral) { [weak self] in
                self?.beginDiscovery(peripheral, generation: generation)
            }
            return
        }
        onEvent?(.failure("\(message). Tap Connect to retry."))
    }

    private func finishDiscovery(_ peripheral: CBPeripheral, generation: Int, pass: Int) {
        guard isCurrent(peripheral, generation: generation), pass == discoveryGeneration, discoveryActive else { return }
        discoveryActive = false
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil

        // Resolve from the service/characteristic table in BFS order, never callback arrival order.
        var ordered: [(service: CBService, characteristic: CBCharacteristic)] = []
        var seenCharacteristics = Set<ObjectIdentifier>()
        for service in graphServices {
            let list = service.characteristics ?? []
            let description = list.enumerated().map {
                "#\($0.offset) \($0.element.uuid.uuidString)/\(Self.properties($0.element.properties))"
            }.joined(separator: " ")
            Log.gatt("GATT \(service.uuid.uuidString) primary=\(service.isPrimary): \(description)")
            for characteristic in list where seenCharacteristics.insert(ObjectIdentifier(characteristic)).inserted {
                ordered.append((service, characteristic))
            }
        }

        let matches = ordered.map {
            GattResolution.Found(service: $0.service.uuid.uuidString, characteristic: $0.characteristic.uuid.uuidString)
        }
        let chosen = GattResolution.resolve(matches)
        resolved = [:]
        for (characteristic, match) in chosen {
            if let pair = ordered.first(where: {
                $0.characteristic.uuid.uuidString.lowercased() == characteristic
                    && $0.service.uuid.uuidString.lowercased() == match.service
            }) {
                resolved[characteristic] = pair.characteristic
            }
        }

        let required: [(uuid: String, properties: CBCharacteristicProperties, label: String)] = [
            (Tcu.tcuHeartbeat, [.notify, .indicate], "TCU heartbeat"),
            (Tcu.phoneHeartbeat, [.write, .writeWithoutResponse], "phone heartbeat"),
            (Tcu.statsRequest, [.write, .writeWithoutResponse], "stats request"),
            (Tcu.statsUpdate, [.notify, .indicate], "stats update"),
        ]
        var problems: [String] = []
        for item in required {
            guard let characteristic = resolved[item.uuid] else {
                problems.append("\(item.label) \(Self.short(item.uuid)) missing")
                continue
            }
            guard !item.properties.intersection(characteristic.properties).isEmpty else {
                problems.append("\(item.label) \(Self.short(item.uuid)) has \(Self.properties(characteristic.properties))")
                continue
            }
        }

        guard problems.isEmpty else {
            let detail = problems.joined(separator: ", ")
            Log.gatt("Discovery pass \(pass) incomplete: \(detail)")
            handleIncompleteDiscovery(peripheral, generation: generation, detail: detail)
            return
        }

        for item in required {
            if let characteristic = resolved[item.uuid] {
                Log.gatt("Selected \(Self.short(item.uuid)) on \(characteristic.service?.uuid.uuidString ?? "?") \(Self.properties(characteristic.properties))")
            }
        }
        availableCharacteristics = Set(resolved.keys)
        if pairingCharacteristic != nil {
            pairingWatchdog?.cancel()
            pairingWatchdog = nil
            pairingCharacteristic = nil
            onEvent?(.pairingRequired(false))
        }
        Log.gatt("Link ready: \(resolved.count) characteristics (pass \(pass)); write limits with=\(peripheral.maximumWriteValueLength(for: .withResponse)) without=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        onEvent?(.ready)
    }

    private func handleIncompleteDiscovery(_ peripheral: CBPeripheral, generation: Int, detail: String) {
        if pairingCharacteristic != nil {
            // The system PIN sheet may still be open. Keep rediscovering with bounded backoff; the
            // pairing watchdog ends this episode and triggers the final decision.
            discoveryAttempt += 1
            let delay = min(2_000 + discoveryAttempt * 1_000, 8_000)
            schedule(Int64(delay), generation: generation, peripheral: peripheral) { [weak self] in
                self?.beginDiscovery(peripheral, generation: generation)
            }
            return
        }
        if !pairingProbeTried {
            pairingProbeTried = true
            probePairing(peripheral, generation: generation, detail: detail)
            return
        }
        if discoveryAttempt < 2 {
            discoveryAttempt += 1
            Log.gatt("Rediscovering after pairing (attempt \(discoveryAttempt))")
            schedule(2_000, generation: generation, peripheral: peripheral) { [weak self] in
                self?.beginDiscovery(peripheral, generation: generation)
            }
            return
        }
        onEvent?(.failure(
            "This scooter does not expose the Hero TCU link (\(detail)). "
                + "Pair once with My VIDA, then open More › Diagnostics."
        ))
    }

    /// iOS has no bond API. A read of an attribute that requires encryption is the supported way to
    /// make the system show its pairing sheet. Prefer the encrypted command service, then known TCU
    /// attributes, then any readable attribute. Never write arbitrary data just to provoke pairing.
    private func probePairing(_ peripheral: CBPeripheral, generation: Int, detail: String) {
        var ordered: [(service: CBService, characteristic: CBCharacteristic)] = []
        var seen = Set<ObjectIdentifier>()
        for service in graphServices {
            for characteristic in service.characteristics ?? [] where seen.insert(ObjectIdentifier(characteristic)).inserted {
                ordered.append((service, characteristic))
            }
        }
        let readable = ordered.filter { $0.characteristic.properties.contains(.read) }
        let candidate = readable.first { $0.service.uuid.uuidString.lowercased() == Tcu.commandService }
            ?? readable.first { [Tcu.tcuInfo, Tcu.vehicleState, Tcu.esyncState].contains($0.characteristic.uuid.uuidString.lowercased()) }
            ?? readable.first

        guard let candidate else {
            Log.gatt("No readable attribute to prompt pairing; pair once with My VIDA")
            discoveryAttempt = 1
            schedule(2_000, generation: generation, peripheral: peripheral) { [weak self] in
                self?.beginDiscovery(peripheral, generation: generation)
            }
            return
        }

        pairingCharacteristic = candidate.characteristic
        onEvent?(.pairingRequired(true))
        Log.gatt("Pairing probe: read \(candidate.characteristic.uuid.uuidString) on \(candidate.service.uuid.uuidString)")
        peripheral.readValue(for: candidate.characteristic)

        pairingWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation, self.peripheral === peripheral,
                  self.pairingCharacteristic === candidate.characteristic else { return }
            Log.gatt("Pairing probe timed out")
            self.pairingCharacteristic = nil
            self.onEvent?(.pairingRequired(false))
            self.discoveryAttempt = 1
            self.schedule(1_000, generation: generation, peripheral: peripheral) {
                self.beginDiscovery(peripheral, generation: generation)
            }
        }
        pairingWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: watchdog)
    }

    private func pairingReadFinished(
        _ characteristic: CBCharacteristic, _ peripheral: CBPeripheral,
        generation: Int, value: Data?, error: Error?
    ) {
        guard isCurrent(peripheral, generation: generation), pairingCharacteristic === characteristic else { return }
        if let error {
            Log.gatt("Pairing read finished with \(Self.error(error))")
            if Self.isPairingError(error) {
                // The system sheet may still be open. Keep the 75 s pairing episode alive and
                // rediscover with backoff instead of treating the ATT error as completion.
                discoveryAttempt = 1
                schedule(2_000, generation: generation, peripheral: peripheral) { [weak self] in
                    self?.beginDiscovery(peripheral, generation: generation)
                }
                return
            }
        } else {
            Log.gatt("Pairing read finished: \(value?.count ?? 0) B")
        }
        pairingWatchdog?.cancel()
        pairingWatchdog = nil
        pairingCharacteristic = nil
        onEvent?(.pairingRequired(false))
        discoveryAttempt = 1
        schedule(1_000, generation: generation, peripheral: peripheral) { [weak self] in
            self?.beginDiscovery(peripheral, generation: generation)
        }
    }

    fileprivate func servicesModified(_ peripheral: CBPeripheral, generation: Int) {
        guard isCurrent(peripheral, generation: generation) else { return }
        Log.gatt("Peripheral services changed")
        if !availableCharacteristics.isEmpty {
            onEvent?(.failure("Scooter services changed. Reconnecting…"))
        } else {
            discoveryAttempt = 0
            pairingProbeTried = false
            beginDiscovery(peripheral, generation: generation)
        }
    }

    // MARK: - Helpers

    private static func short(_ uuid: String) -> String {
        let first = uuid.lowercased().split(separator: "-").first.map(String.init) ?? uuid.lowercased()
        return String(first.suffix(4))
    }

    private static func properties(_ properties: CBCharacteristicProperties) -> String {
        var out = ""
        if properties.contains(.read) { out += "r" }
        if properties.contains(.write) { out += "w" }
        if properties.contains(.writeWithoutResponse) { out += "W" }
        if properties.contains(.notify) { out += "n" }
        if properties.contains(.indicate) { out += "i" }
        if properties.contains(.authenticatedSignedWrites) { out += "s" }
        if properties.contains(.extendedProperties) { out += "x" }
        if properties.contains(.notifyEncryptionRequired) { out += "N" }
        if properties.contains(.indicateEncryptionRequired) { out += "I" }
        return out.isEmpty ? "-" : out
    }

    private func beginAuthPairing(_ peripheral: CBPeripheral, generation: Int, key: String, kind: AuthKind) {
        guard !authPairingActive else { return }
        authPairingActive = true
        authPairingKey = key
        authPairingKind = kind
        onEvent?(.pairingRequired(true))
        authPairingTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation, self.peripheral === peripheral,
                  self.authPairingActive else { return }
            self.authPairingActive = false
            self.authPairingKey = nil
            self.authPairingKind = nil
            self.authPairingTimeout = nil
            self.onEvent?(.failure("Bluetooth pairing did not finish. Pair once with My VIDA, then retry."))
        }
        authPairingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: timeout)
    }

    private func finishAuthPairing(key: String, kind: AuthKind) {
        guard authPairingActive, authPairingKey == key, authPairingKind == kind else { return }
        authPairingActive = false
        authPairingKey = nil
        authPairingKind = nil
        authPairingTimeout?.cancel()
        authPairingTimeout = nil
        onEvent?(.pairingRequired(false))
    }

    private func scheduleOperationResult(
        after ms: Int64, generation: Int, peripheral: CBPeripheral, _ event: @escaping () -> Void
    ) {
        operationRetryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation, self.peripheral === peripheral else { return }
            event()
        }
        operationRetryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: item)
    }

    fileprivate static func isPairingError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == CBATTErrorDomain {
            return [
                CBATTError.Code.insufficientAuthentication.rawValue,
                CBATTError.Code.insufficientAuthorization.rawValue,
                CBATTError.Code.insufficientEncryption.rawValue,
            ].contains(ns.code)
        }
        return ns.domain == CBErrorDomain && ns.code == CBError.Code.peerRemovedPairingInformation.rawValue
    }

    fileprivate static func error(_ error: Error) -> String {
        let ns = error as NSError
        let text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        return text
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

/// One delegate object per connection attempt. CoreBluetooth callbacks carry no generation, so the
/// proxy drops every callback that belongs to an old peripheral/attempt.
private final class PeripheralAttempt: NSObject, CBPeripheralDelegate {
    weak var owner: BluetoothScooterTransport?
    let peripheral: CBPeripheral
    let generation: Int
    let discoveryPass: Int?

    init(owner: BluetoothScooterTransport, peripheral: CBPeripheral, generation: Int, discoveryPass: Int? = nil) {
        self.owner = owner
        self.peripheral = peripheral
        self.generation = generation
        self.discoveryPass = discoveryPass
        super.init()
    }

    private var isCurrent: Bool {
        guard let owner, owner.attempt === self else { return false }
        return owner.isCurrent(peripheral, generation: generation)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let owner, isCurrent, let pass = discoveryPass else { return }
        if let error {
            owner.finishDiscoveryError("Service discovery failed: \(BluetoothScooterTransport.error(error))", peripheral: peripheral, generation: generation, pass: pass)
        } else {
            owner.servicesDiscovered(peripheral, services: peripheral.services ?? [], generation: generation, pass: pass)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        guard let owner, isCurrent, let pass = discoveryPass else { return }
        owner.includedServicesDiscovered(service, peripheral, generation: generation, pass: pass, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let owner, isCurrent, let pass = discoveryPass else { return }
        owner.characteristicsDiscovered(service, peripheral, generation: generation, pass: pass, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let owner, isCurrent else { return }
        owner.servicesModified(peripheral, generation: generation)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner, isCurrent else { return }
        owner.valueUpdated(characteristic, peripheral, generation: generation, value: characteristic.value, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner, isCurrent else { return }
        owner.valueWritten(characteristic, peripheral, generation: generation, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let owner, isCurrent else { return }
        owner.notificationStateChanged(characteristic, peripheral, generation: generation, error: error)
    }
}

extension BluetoothScooterTransport {
    fileprivate func valueUpdated(
        _ characteristic: CBCharacteristic, _ peripheral: CBPeripheral,
        generation: Int, value: Data?, error: Error?
    ) {
        guard isCurrent(peripheral, generation: generation) else { return }
        if pairingCharacteristic === characteristic {
            pairingReadFinished(characteristic, peripheral, generation: generation, value: value, error: error)
            return
        }
        let key = characteristic.uuid.uuidString.lowercased()
        if let error {
            Log.gatt("Read \(Self.short(key)) on \(characteristic.service?.uuid.uuidString ?? "?") failed: \(Self.error(error))")
            if pendingRead == key {
                pendingRead = nil
                if Self.isPairingError(error) {
                    beginAuthPairing(peripheral, generation: generation, key: key, kind: .read)
                    scheduleOperationResult(after: 20_000, generation: generation, peripheral: peripheral) {
                        self.onEvent?(.readResult(characteristic: key, success: false))
                    }
                } else {
                    onEvent?(.readResult(characteristic: key, success: false))
                }
            }
            return
        }
        if let value {
            onEvent?(.value(characteristic: key, data: [UInt8](value)))
        }
        if pendingRead == key {
            pendingRead = nil
            finishAuthPairing(key: key, kind: .read)
            onEvent?(.readResult(characteristic: key, success: true))
        }
    }

    fileprivate func valueWritten(
        _ characteristic: CBCharacteristic, _ peripheral: CBPeripheral,
        generation: Int, error: Error?
    ) {
        guard isCurrent(peripheral, generation: generation) else { return }
        let key = characteristic.uuid.uuidString.lowercased()
        if let error {
            Log.gatt("Write \(Self.short(characteristic.uuid.uuidString)) on \(characteristic.service?.uuid.uuidString ?? "?") failed: \(Self.error(error))")
            if Self.isPairingError(error) {
                beginAuthPairing(peripheral, generation: generation, key: key, kind: .write)
                scheduleOperationResult(after: 20_000, generation: generation, peripheral: peripheral) {
                    self.onEvent?(.writeResult(characteristic: key, success: false))
                }
                return
            }
        } else {
            finishAuthPairing(key: key, kind: .write)
        }
        onEvent?(.writeResult(
            characteristic: key,
            success: error == nil
        ))
    }

    fileprivate func notificationStateChanged(
        _ characteristic: CBCharacteristic, _ peripheral: CBPeripheral,
        generation: Int, error: Error?
    ) {
        guard isCurrent(peripheral, generation: generation) else { return }
        let key = characteristic.uuid.uuidString.lowercased()
        if let error {
            Log.gatt("Notify \(Self.short(characteristic.uuid.uuidString)) on \(characteristic.service?.uuid.uuidString ?? "?") failed: \(Self.error(error))")
            if Self.isPairingError(error) {
                beginAuthPairing(peripheral, generation: generation, key: key, kind: .notify)
                scheduleOperationResult(after: 20_000, generation: generation, peripheral: peripheral) {
                    self.onEvent?(.notifyState(characteristic: key, enabled: false))
                }
                return
            }
        } else if characteristic.isNotifying {
            finishAuthPairing(key: key, kind: .notify)
        }
        onEvent?(.notifyState(
            characteristic: key,
            enabled: error == nil && characteristic.isNotifying
        ))
    }
}

extension BluetoothScooterTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = Self.bluetoothState(central.state)
        onEvent?(.bluetoothState(state))
        guard central.state == .poweredOn else { return }
        if let id = pendingConnectID {
            pendingConnectID = nil
            connect(to: id)
        } else if resolveScanRequested {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else if uiScanRequested {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        // An exact saved identifier is authoritative even if this advertisement has no local name.
        if wantedID == id {
            known[id] = peripheral
            resolveAndConnect(id, generation: generation)
            return
        }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.uppercased().hasPrefix(Self.namePrefix) else { return }
        known[id] = peripheral
        onEvent?(.discovered(DiscoveredScooter(id: id, name: name, rssi: RSSI.intValue)))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected(peripheral, generation: generation)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionFailed(peripheral, generation: generation, reason: error?.localizedDescription)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, generation: generation, error: error)
    }
}
#endif
