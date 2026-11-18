import Foundation

/// An in-memory scooter for the simulator, the macOS preview and host tests. It answers the GATT
/// sequence like a VX2 TCU: reads return plausible info, notifications are acknowledged, writes
/// succeed, heartbeats are echoed, and a BMS stream carries slowly changing battery data.
public final class FakeScooterTransport: ScooterTransport {
    public var onEvent: ((TransportEvent) -> Void)?
    public private(set) var availableCharacteristics: Set<String> = []

    public struct Write: Equatable {
        public var characteristic: String
        public var data: [UInt8]
    }

    /// Every write, in order, for tests and diagnostics.
    public private(set) var writes: [Write] = []
    public private(set) var connectedID: UUID?
    public private(set) var scanning = false

    /// Emit a BMS frame about once a second while subscribed.
    public var streamBms = true
    /// Battery percentage the simulated pack reports (drifts down while riding in the demo).
    public var socPercent = 57.81
    public var speedLimit = 60

    private let scheduler: SessionScheduler
    private var tcuCounter = 0x1200
    private var bmsTimerScheduled = false
    private var bmsActive = false
    private var generation = 0
    private var lastTransition: Int64 = 0

    public init(scheduler: SessionScheduler = MainScheduler()) {
        self.scheduler = scheduler
    }

    public func startScan() {
        scanning = true
        scheduler.after(300) { [weak self] in
            guard let self, self.scanning else { return }
            self.onEvent?(.discovered(DiscoveredScooter(
                id: Self.demoID, name: "HMC VX2", rssi: -48
            )))
        }
    }

    public func stopScan() {
        scanning = false
    }

    public static let demoID = UUID(uuidString: "7E57D000-0000-4000-8000-000000000001")!

    public func connect(to id: UUID) {
        stopScan()
        connectedID = id
        generation += 1
        let attempt = generation
        scheduler.after(150) { [weak self] in
            guard let self, attempt == self.generation else { return }
            self.availableCharacteristics = Self.characteristics
            self.onEvent?(.connected)
            self.onEvent?(.ready)
            self.scheduleHeartbeat()
        }
    }

    /// The TCU sends its own heartbeat about once a second; the phone answers each one.
    private func scheduleHeartbeat() {
        let attempt = generation
        scheduler.after(1_000) { [weak self] in
            guard let self, attempt == self.generation, self.connectedID != nil else { return }
            self.tcuCounter = (self.tcuCounter + 1) & 0xFFFF
            self.onEvent?(.value(characteristic: Tcu.tcuHeartbeat, data: Tcu.heartbeat(self.tcuCounter)))
            self.scheduleHeartbeat()
        }
    }

    public func disconnect() {
        generation += 1
        connectedID = nil
        bmsActive = false
        bmsTimerScheduled = false
        availableCharacteristics = []
    }

    /// The link dropped by itself (out of range, scooter switched off).
    public func dropLink(reason: String? = "link lost") {
        guard connectedID != nil else { return }
        generation += 1
        connectedID = nil
        bmsActive = false
        bmsTimerScheduled = false
        availableCharacteristics = []
        onEvent?(.disconnected(reason))
    }

    public func setNotify(_ characteristic: String, enabled: Bool) {
        let attempt = generation
        scheduler.after(5) { [weak self] in
            guard let self, attempt == self.generation else { return }
            self.onEvent?(.notifyState(characteristic: characteristic, enabled: self.connectedID != nil))
            if characteristic == Tcu.statsUpdate {
                self.bmsActive = true
                self.scheduleBms()
            }
        }
    }

    public func read(_ characteristic: String) {
        let attempt = generation
        let data = Self.readValue(characteristic, speedLimit: speedLimit)
        scheduler.after(20) { [weak self] in
            guard let self, attempt == self.generation else { return }
            if let data {
                self.onEvent?(.value(characteristic: characteristic, data: data))
                self.onEvent?(.readResult(characteristic: characteristic, success: true))
            } else {
                self.onEvent?(.readResult(characteristic: characteristic, success: false))
            }
        }
    }

    public func write(_ characteristic: String, _ data: [UInt8], withResponse: Bool) {
        writes.append(Write(characteristic: characteristic, data: data))
        let attempt = generation
        scheduler.after(10) { [weak self] in
            guard let self, attempt == self.generation else { return }
            self.onEvent?(.writeResult(characteristic: characteristic, success: true))
            self.react(to: characteristic, data)
        }
    }

    private func react(to characteristic: String, _ data: [UInt8]) {
        switch characteristic.lowercased() {
        case Tcu.statsRequest:
            guard let tag = data.first.map(Int.init), tag == Tcu.tagBms else { return }
            bmsActive = data.count >= 2 && data[1] == 1
            if bmsActive { scheduleBms() }
        default:
            break
        }
    }

    private func scheduleBms() {
        guard streamBms, bmsActive, !bmsTimerScheduled else { return }
        bmsTimerScheduled = true
        let attempt = generation
        scheduler.after(1_000) { [weak self] in
            guard let self, attempt == self.generation else { return }
            self.bmsTimerScheduled = false
            guard self.bmsActive, self.connectedID != nil else { return }
            self.onEvent?(.value(characteristic: Tcu.statsUpdate, data: self.bmsFrame()))
            self.scheduleBms()
        }
    }

    /// A 30-byte live-shaped BMS frame. SOC drifts by 0.01 % per frame so charts move.
    public func bmsFrame() -> [UInt8] {
        func u16(_ value: Int) -> [UInt8] {
            [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        let soc = Int((socPercent * 100).rounded())
        var bytes: [UInt8] = [UInt8(Tcu.tagBms)]
        bytes += u16(9945)          // SOH 99.45 %
        bytes += u16(soc)           // pack 0 SOC
        bytes += u16(6930)          // 29.3 °C
        bytes += [0x00, 0x04, 0x44] // charge time 0, drive status on every pack
        bytes += u16(9947)          // pack 1 SOH
        bytes += u16(max(soc - 1, 0))
        bytes += u16(4899)          // pack 1 SOE
        bytes += u16(6890)          // 28.9 °C
        bytes += u16(9943)          // pack 2 SOH
        bytes += u16(soc + 1)
        bytes += u16(4902)          // pack 2 SOE
        bytes += u16(6930)          // 29.3 °C
        bytes += [0, 0, 0, 0]       // 30 bytes, like the live VX2 frame
        return bytes
    }

    private static let characteristics: Set<String> = [
        Tcu.tcuInfo, Tcu.osInfo, Tcu.phoneHeartbeat, Tcu.tcuHeartbeat, Tcu.vehicleState, Tcu.esyncState,
        Tcu.phoneState, Tcu.callerInfo, Tcu.navInfo, Tcu.musicInfo, Tcu.musicMeta, Tcu.icbtControl,
        Tcu.voiceAssist, Tcu.statsRequest, Tcu.statsUpdate,
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    private static func readValue(_ characteristic: String, speedLimit: Int) -> [UInt8]? {
        switch characteristic.lowercased() {
        case Tcu.vehicleState:
            return [0b1000_0100, 0, 0x30, 0x52, UInt8(speedLimit), 0]
        case Tcu.osInfo:
            return [Tcu.osAndroid]
        case Tcu.tcuInfo:
            var bytes = Array("000000000000001".utf8)
            bytes += Array("MBLDEMO0000000001".utf8)
            bytes += [1, 2, 3, 0, 1, 4, 0, 0x42]
            bytes += Array("DEMO-PART-001".utf8)
            return bytes
        default:
            return nil
        }
    }
}
