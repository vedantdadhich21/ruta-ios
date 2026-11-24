import Foundation

#if os(iOS)
import UIKit
#endif

/// The scooter link's lifecycle. `ready` means the GATT setup finished and data is flowing.
public enum LinkPhase: String, Sendable {
    case idle, connecting, ready
}

/// Timers the session needs. Injectable so host tests can drive a whole connection with a manual
/// clock instead of waiting in real time.
public protocol SessionScheduler: AnyObject {
    /// Monotonic milliseconds.
    var nowMs: Int64 { get }
    @discardableResult
    func after(_ ms: Int64, _ body: @escaping () -> Void) -> UUID
    func cancel(_ handle: UUID)
    func cancelAll()
}

/// Main-queue scheduler used by the app. Completed work is removed immediately so a long ride does
/// not retain every heartbeat, stats probe and navigation watchdog ever scheduled.
public final class MainScheduler: SessionScheduler {
    private let lock = NSLock()
    private var items: [UUID: DispatchWorkItem] = [:]

    public init() {}

    public var nowMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    @discardableResult
    public func after(_ ms: Int64, _ body: @escaping () -> Void) -> UUID {
        let handle = UUID()
        let item = DispatchWorkItem {
            self.lock.lock()
            self.items.removeValue(forKey: handle)
            self.lock.unlock()
            body()
        }
        lock.lock()
        items[handle] = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(ms, 0))), execute: item)
        return handle
    }

    public func cancel(_ handle: UUID) {
        lock.lock()
        let item = items.removeValue(forKey: handle)
        lock.unlock()
        item?.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let pending = Array(items.values)
        items.removeAll()
        lock.unlock()
        for item in pending { item.cancel() }
    }
}

/// Deterministic scheduler for tests and the offline demo. Time only moves when `advance` is called.
public final class ManualScheduler: SessionScheduler {
    private struct Task {
        let id: UUID
        var due: Int64
        var body: () -> Void
    }

    public private(set) var nowMs: Int64
    private var tasks: [Task] = []

    public init(nowMs: Int64 = 0) {
        self.nowMs = nowMs
    }

    @discardableResult
    public func after(_ ms: Int64, _ body: @escaping () -> Void) -> UUID {
        let id = UUID()
        tasks.append(Task(id: id, due: nowMs + max(ms, 0), body: body))
        return id
    }

    public func cancel(_ handle: UUID) {
        tasks.removeAll { $0.id == handle }
    }

    public func cancelAll() {
        tasks.removeAll()
    }

    /// Runs every task due within `ms`, in time order, moving the clock along.
    public func advance(_ ms: Int64) {
        let target = nowMs + ms
        while let index = tasks.enumerated().filter({ $0.element.due <= target }).min(by: { $0.element.due < $1.element.due })?.offset {
            let task = tasks.remove(at: index)
            nowMs = max(nowMs, task.due)
            task.body()
        }
        nowMs = target
    }

    public var pending: Int { tasks.count }
}

/// Direct client for the scooter's telematics unit. Mirrors the Android `ScooterConnection`:
/// connect → discover → stage A (TCU heartbeat notify, info read, first phone heartbeat) →
/// ~1 s → stage B (vehicle state, OS info, stats notify, BMS request) → ready. Heartbeats are
/// answered with value + 1; no TCU heartbeat for 30 s ends the link. One GATT request runs at a
/// time; periodic writes are replaceable, and turn-by-turn frames use a priority lane.
public final class ScooterSession {
    public static let noResponse = "Scooter did not respond. Keep it on and nearby, close the scooter maker's official app, then try again."
    public static let reconnectFailed = "Lost the scooter link and could not reconnect. Tap Connect to try again."

    public static let reconnectDelaysMs: [Int64] = [2_000, 5_000, 10_000, 15_000]
    public static let reconnectWindowMs = RideMath.linkLostMs + 15_000
    public static let heartbeatTimeoutMs: Int64 = 30_000
    public static let statsSilenceMs: Int64 = 15_000
    public static let bmsSilenceMs: Int64 = 12_000
    public static let frameRepeatMs: Int64 = 900
    public static let setupTimeoutMs: Int64 = 35_000
    public static let autoProbeTags = [2, 3, 5, 6, 10, 11]

    public let transport: ScooterTransport
    public let scheduler: SessionScheduler
    private let diagnostics: DiagnosticsLog
    private let defaults: UserDefaults?

    // UI callbacks.
    public var onStatus: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onReading: ((Reading) -> Void)?
    public var onVehicle: ((VehicleState) -> Void)?
    public var onInfo: ((TcuInfo) -> Void)?
    public var onConnected: (() -> Void)?
    /// A scan result, forwarded from the transport (which the session owns).
    public var onDiscovered: ((DiscoveredScooter) -> Void)?
    /// True while iOS may be showing its system pairing sheet.
    public var onPairing: ((Bool) -> Void)?
    public var onBluetoothState: ((BluetoothState) -> Void)?
    /// The link went down. `linkLost` true: it dropped by itself and reconnection retries the same
    /// scooter, so keep ride tracking running. False: it is over.
    public var onEnded: ((Bool) -> Void)?
    public var onHardControl: ((HardControlEvent) -> Void)?

    public private(set) var phase: LinkPhase = .idle
    public private(set) var reconnecting = false
    public private(set) var deviceName: String?
    public private(set) var navigationMissing = false
    public private(set) var navigationSending = false
    public private(set) var navigationAckedAt: Int64 = 0
    public private(set) var navigationError: Int?
    public private(set) var lastHandlebar: String?
    public private(set) var rawStats: [Int: [UInt8]] = [:]
    public private(set) var decodedRangeKm: Double?

    /// Forward turn-by-turn frames to the cluster. Turning it off sends the exit frame.
    public var navigationEnabled = true {
        didSet {
            guard oldValue != navigationEnabled else { return }
            if navigationEnabled { pushNavigation() } else { stopNavigation() }
        }
    }

    /// Phone state mirrored onto the cluster's 0x0301 line (iOS cannot read calls from other apps,
    /// so the app only shows what it knows: clock, battery, and any in-app call).
    public var callState: TcuCallState = .none
    public var missedCalls = 0
    public var unreadMessages = 0
    public var headset = false
    public var callDurationS = 0
    public var caller: CallerInfo?

    private var targetID: UUID?
    private var bluetoothState: BluetoothState = .unknown
    private var generation = 0
    private var decoder = BmsDecoder()
    private var heartbeat = 0
    private var lastTcuHeartbeat: Int64 = 0
    private var lastBmsReadingAt: Int64 = 0
    private var bmsPeriodIndex = 0
    private var probedStats = false
    private var autoProbed = false
    private var lastRawHex = ""
    private var lastRawLogAt: Int64 = 0
    private var lastStatus: PhoneStatus?
    private var lastCallerBytes: [UInt8]?
    private var lastSentFrame: NavFrame?
    private var lastSentFrameAt: Int64 = 0
    private var requestedFrame: NavFrame?
    private var reconnectUntil: Int64 = 0
    private var reconnectAttempts = 0
    private var stageA = false
    private var stageB = false
    private let controlDebouncer = HardControlDebouncer()

    // Serialized GATT operations.
    private enum OpKind { case read, write, descriptor, marker }

    private final class GattOp {
        let kind: OpKind
        let characteristic: String?
        let label: String
        let critical: Bool
        let maxTries: Int
        let replaceable: Bool
        let action: () -> Bool
        var tries = 0

        init(
            kind: OpKind, characteristic: String?, label: String, critical: Bool,
            maxTries: Int, replaceable: Bool = false, action: @escaping () -> Bool
        ) {
            self.kind = kind
            self.characteristic = characteristic
            self.label = label
            self.critical = critical
            self.maxTries = maxTries
            self.replaceable = replaceable
            self.action = action
        }
    }

    private var queue: [GattOp] = []
    private var running: GattOp?
    private var retryPending = false
    private var pendingRetry: GattOp?
    private var retryHandle: UUID?
    private var setupDeadline: UUID?
    private var setupToken = 0
    private var pairingActive = false
    private var awaitingReady = false
    private var verificationPending = false
    private var runningDeadline: UUID?
    private var runningToken = 0

    public init(
        transport: ScooterTransport,
        scheduler: SessionScheduler = MainScheduler(),
        diagnostics: DiagnosticsLog = .shared,
        defaults: UserDefaults? = .standard
    ) {
        self.transport = transport
        self.scheduler = scheduler
        self.diagnostics = diagnostics
        self.defaults = defaults
        transport.onEvent = { [weak self] event in self?.receive(event) }
    }

    // MARK: - Lifecycle

    public func connect(id: UUID, name: String? = nil) {
        guard phase == .idle else { return }
        // An explicit choice supersedes any automatic reconnect ladder.
        stopReconnecting()
        reconnectUntil = 0
        targetID = id
        deviceName = name
        scheduler.cancelAll()
        resetAttempt()
        decoder = BmsDecoder(percentDivisor: savedScale("pct"), temperatureDivisor: savedScale("temp"))
        phase = .connecting
        status("Connecting to \(name ?? "scooter")…")
        log("— Connecting to \(name ?? "scooter") (\(id.uuidString))")
        open()
    }

    public func disconnect() {
        let wasActive = teardown() || reconnecting
        stopReconnecting()
        if wasActive { onEnded?(false) }
        status("Disconnected · saved history is available")
    }

    /// Re-sends the current BMS request. Vehicle state arrives continuously over its notification;
    /// a second read here would be ambiguous on iOS because reads and notifications share a callback.
    public func refresh() {
        guard phase == .ready else { return }
        requestBms(bmsPeriodIndex, schedule: false)
    }

    private func open() {
        guard let targetID else { return }
        decoder = BmsDecoder(percentDivisor: savedScale("pct"), temperatureDivisor: savedScale("temp"))
        phase = .connecting
        if bluetoothState == .poweredOn {
            armSetup(Self.setupTimeoutMs, Self.noResponse)
        } else {
            status("Waiting for Bluetooth…")
        }
        transport.connect(to: targetID)
    }

    private func teardown() -> Bool {
        generation += 1
        if pairingActive {
            pairingActive = false
            onPairing?(false)
        }
        scheduler.cancelAll()
        setupDeadline = nil
        setupToken += 1
        runningDeadline = nil
        runningToken += 1
        queue.removeAll()
        running = nil
        retryPending = false
        awaitingReady = false
        verificationPending = false
        cancel(retryHandle)
        retryHandle = nil
        pendingRetry = nil
        resetAttempt()
        navigationSending = false
        navigationAckedAt = 0
        navigationError = nil
        navigationMissing = false
        lastSentFrame = nil
        lastSentFrameAt = 0
        requestedFrame = nil
        lastStatus = nil
        lastCallerBytes = nil
        lastRawHex = ""
        lastRawLogAt = 0
        rawStats.removeAll()
        bmsPeriodIndex = 0
        lastBmsReadingAt = 0
        probedStats = false
        autoProbed = false
        lastTcuHeartbeat = 0
        let wasActive = phase != .idle
        phase = .idle
        transport.disconnect()
        return wasActive
    }

    private func fail(_ message: String) {
        let now = scheduler.nowMs
        if phase == .ready && !reconnecting {
            reconnecting = true
            reconnectUntil = now + Self.reconnectWindowMs
            reconnectAttempts = 0
        }
        let wasActive = teardown()
        if reconnecting, targetID != nil, now < reconnectUntil {
            if wasActive { onEnded?(true) }
            log(message)
            status("Scooter link lost · reconnecting…")
            scheduleReconnect()
            return
        }
        let gaveUp = reconnecting
        stopReconnecting()
        if wasActive || gaveUp { onEnded?(false) }
        if gaveUp {
            log(message)
            status(Self.reconnectFailed)
        } else {
            status(message)
        }
    }

    private func scheduleReconnect() {
        let delay = Self.reconnectDelaysMs[min(reconnectAttempts, Self.reconnectDelaysMs.count - 1)]
        scheduler.after(delay) { [weak self] in self?.reconnect() }
    }

    private func reconnect() {
        guard reconnecting, phase == .idle else { return }
        guard targetID != nil, scheduler.nowMs < reconnectUntil else {
            stopReconnecting()
            onEnded?(false)
            status(Self.reconnectFailed)
            return
        }
        reconnectAttempts += 1
        log("Reconnecting (attempt \(reconnectAttempts))")
        _ = teardown()
        open()
    }

    private func stopReconnecting() {
        reconnecting = false
        reconnectAttempts = 0
    }

    private func resetAttempt() {
        stageA = false
        stageB = false
        heartbeat = 0
        lastTcuHeartbeat = 0
    }

    private func cancel(_ handle: UUID?) {
        if let handle { scheduler.cancel(handle) }
    }

    private func armSetup(_ ms: Int64, _ message: String) {
        setupToken += 1
        let token = setupToken
        cancel(setupDeadline)
        setupDeadline = scheduler.after(ms) { [weak self] in
            guard let self, token == self.setupToken, self.phase == .connecting else { return }
            self.setupDeadline = nil
            self.fail(message)
        }
    }

    private func cancelSetup() {
        setupToken += 1
        cancel(setupDeadline)
        setupDeadline = nil
    }

    // MARK: - Transport events

    private func receive(_ event: TransportEvent) {
        switch event {
        case .bluetoothState(let state):
            let previous = bluetoothState
            bluetoothState = state
            onBluetoothState?(state)
            if state == .poweredOff {
                if phase == .ready {
                    fail("Bluetooth was turned off.")
                } else if phase == .connecting {
                    cancelSetup()
                    status("Waiting for Bluetooth…")
                }
            } else if state == .poweredOn, previous != .poweredOn, phase == .connecting, setupDeadline == nil {
                armSetup(Self.setupTimeoutMs, Self.noResponse)
            } else if state == .unauthorized, phase == .connecting {
                cancelSetup()
                status("Allow Bluetooth for Ruta in Settings, then tap Connect.")
            }
        case .discovered(let scooter):
            onDiscovered?(scooter)
        case .connected:
            status("Connected · preparing scooter link…")
        case .ready:
            onServicesReady()
        case .pairingRequired(let required):
            if required {
                guard !pairingActive else { return }
                pairingActive = true
                onPairing?(true)
                status("Confirm Bluetooth pairing with your scooter…")
                armSetup(90_000, "Bluetooth pairing did not finish. Pair the scooter in Settings, then retry.")
            } else if pairingActive {
                pairingActive = false
                onPairing?(false)
                if phase == .connecting {
                    armSetup(Self.setupTimeoutMs, Self.noResponse)
                    if awaitingReady {
                        let attempt = generation
                        scheduler.after(0) { [weak self] in
                            guard let self, attempt == self.generation else { return }
                            self.tryReady()
                        }
                    }
                }
            }
        case .disconnected(let reason):
            linkDown(reason)
        case .failure(let message):
            fail(message)
        case .value(let characteristic, let data):
            handle(characteristic, data)
        case .writeResult(let characteristic, let success):
            complete(.write, characteristic, success: success)
        case .readResult(let characteristic, let success):
            complete(.read, characteristic, success: success)
        case .notifyState(let characteristic, let enabled):
            complete(.descriptor, characteristic, success: enabled)
        }
    }

    private func linkDown(_ reason: String?) {
        if reconnecting && phase == .idle { // a reconnect attempt failed
            fail(reason ?? "Connection failed.")
            return
        }
        let code = reason.map { " (\($0))" } ?? ""
        switch phase {
        case .ready: fail("Scooter disconnected\(code).")
        case .connecting: fail("Connection failed\(code). Close the scooter maker's official app, then retry.")
        case .idle: break
        }
    }

    private func has(_ characteristic: String) -> Bool {
        transport.availableCharacteristics.contains(characteristic.lowercased())
    }

    private func onServicesReady() {
        guard phase == .connecting else { return }
        let required = [Tcu.tcuHeartbeat, Tcu.phoneHeartbeat, Tcu.statsRequest, Tcu.statsUpdate]
        let missing = required.filter { !has($0) }
        guard missing.isEmpty else {
            fail("This scooter does not expose the Hero TCU link (\(missing.map { short($0) }.joined(separator: ", ")) missing).")
            return
        }
        armSetup(Self.setupTimeoutMs, "Scooter did not finish setup. Tap Connect to retry.")
        startStageA()
    }

    private func startStageA() {
        if stageA { return }
        stageA = true
        notify(Tcu.tcuHeartbeat, critical: true)
        read(Tcu.tcuInfo, critical: false)
        sendHeartbeat(1)
        marker { [weak self] in
            guard let self else { return }
            self.scheduler.after(1_000) { [weak self] in self?.startStageB() }
        }
    }

    private func startStageB() {
        guard stageB == false else { return }
        stageB = true
        if has(Tcu.esyncState) { notify(Tcu.esyncState, critical: false) }
        if has(Tcu.osInfo) { write(Tcu.osInfo, [Tcu.osAndroid], critical: false) }
        // On iOS reads and notifications share didUpdateValueFor. Finish the one-shot read before
        // enabling notifications so a notification cannot be mistaken for the read response.
        read(Tcu.vehicleState, critical: false)
        notify(Tcu.vehicleState, critical: false)
        notify(Tcu.statsUpdate, critical: true)
        // The TCU treats the phone as a cluster client only once this CCCD is set.
        if has(Tcu.icbtControl) { notify(Tcu.icbtControl, critical: false) }
        requestBms(0, schedule: true)
        marker { [weak self] in self?.onReady() }
    }

    private func onReady() {
        guard phase == .connecting else { return }
        awaitingReady = true
        tryReady()
    }

    private func tryReady() {
        guard phase == .connecting, awaitingReady else { return }
        guard transport.noteSetupAccepted() else {
            if !pairingActive { armSetup(90_000, "Bluetooth pairing did not finish. Pair once with My VIDA, then retry.") }
            if !verificationPending, has(Tcu.tcuInfo) {
                verificationPending = true
                read(Tcu.tcuInfo, critical: false, maxTries: 1)
            }
            return
        }
        awaitingReady = false
        verificationPending = false
        cancelSetup()
        if pairingActive {
            pairingActive = false
            onPairing?(false)
        }
        phase = .ready
        lastTcuHeartbeat = scheduler.nowMs
        if reconnecting {
            log("Reconnected after \(reconnectAttempts) attempt(s)")
            stopReconnecting()
        }
        onConnected?()
        status(lastBmsReadingAt != 0 ? "Connected · battery data live" : "Connected · waiting for battery data")
        watchHeartbeat(generation)
        keepStatsFlowing(generation)
        navigationMissing = !has(Tcu.navInfo)
        if navigationMissing { log("No 0x0303 characteristic: turn-by-turn is unavailable on this scooter") }
        let attempt = generation
        scheduler.after(0) { [weak self] in self?.clusterTick(attempt) }
        scheduler.after(10_000) { [weak self] in self?.autoProbe(attempt) }
    }

    // MARK: - Periodic cluster feed

    private func clusterTick(_ attempt: Int) {
        guard attempt == generation, phase == .ready else { return }
        sendPhoneStatus()
        pushNavigation()
        scheduler.after(1_000) { [weak self] in self?.clusterTick(attempt) }
    }

    private func sendPhoneStatus() {
        guard has(Tcu.phoneState) else { return }
        let now = Date()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.hour, .minute, .second], from: now)
        let status = PhoneStatus(
            batteryPercent: Self.batteryPercent(),
            signalLevel: 3,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0,
            headset: headset,
            missedCallAlert: missedCalls > 0,
            callState: callState,
            smsFlag: unreadMessages > 0,
            smsCount: unreadMessages,
            missedCount: missedCalls,
            callDurationS: callDurationS
        )
        if status != lastStatus {
            write(Tcu.phoneState, status.encode(), critical: false, maxTries: 1, replaceable: true)
            lastStatus = status
        }
        let callerInfo = callState.showsCaller ? caller : nil
        if let callerInfo, has(Tcu.callerInfo) {
            let bytes = callerInfo.encode()
            if bytes != lastCallerBytes {
                write(Tcu.callerInfo, bytes, critical: false, maxTries: 1, replaceable: true)
                lastCallerBytes = bytes
            }
        }
    }

    private static func batteryPercent() -> Int? {
        #if os(iOS)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
        #else
        return nil
        #endif
    }

    // MARK: - Turn-by-turn

    /// Sends the current frame now; the 1 Hz tick repeats it so a countdown keeps moving even
    /// without new MapKit updates. Identical frames within 900 ms are skipped.
    public func pushNavigation(_ frame: NavFrame? = nil) {
        if let frame { requestedFrame = frame }
        guard phase == .ready, has(Tcu.navInfo), navigationEnabled else { return }
        let now = scheduler.nowMs
        guard let frame = requestedFrame else { return }
        if frame == lastSentFrame, now - lastSentFrameAt < Self.frameRepeatMs { return }
        let bytes = frame.encode()
        if !navigationSending {
            log("Turn-by-turn started")
            navigationAckedAt = 0
            navigationError = nil
        }
        write(Tcu.navInfo, bytes, critical: false, maxTries: 2, replaceable: true, priority: true)
        navigationSending = true
        lastSentFrame = frame
        lastSentFrameAt = now
        if loggerChanged(frame) {
            log("TBT: \(bytes.hexString) · '\(frame.roadText)'")
        }
    }

    private var lastNavLogKey: String?

    private func loggerChanged(_ frame: NavFrame) -> Bool {
        let key = "\(frame.active)|\(frame.turn)|\(frame.roadText)|\(frame.distanceMeters / 10)"
        guard key != lastNavLogKey else { return false }
        lastNavLogKey = key
        return true
    }

    public func stopNavigation() {
        requestedFrame = nil
        guard navigationSending, phase == .ready, has(Tcu.navInfo) else {
            navigationSending = false
            return
        }
        write(Tcu.navInfo, NavFrame.exit.encode(), critical: false, maxTries: 2, replaceable: true, priority: true)
        log("Turn-by-turn stopped")
        navigationSending = false
        lastSentFrame = nil
        lastNavLogKey = nil
    }

    public func navigationDisplay() -> NavDisplay {
        NavDisplay.of(
            available: !navigationMissing && phase == .ready,
            sending: navigationSending,
            ackedAt: navigationAckedAt,
            error: navigationError,
            now: scheduler.nowMs
        )
    }

    // MARK: - Stats

    private func keepStatsFlowing(_ attempt: Int) {
        scheduler.after(Self.statsSilenceMs) { [weak self] in
            guard let self, attempt == self.generation, self.phase == .ready else { return }
            if self.lastBmsReadingAt == 0 || self.scheduler.nowMs - self.lastBmsReadingAt > Self.statsSilenceMs {
                self.log("No usable BMS readings; switching to the next period")
                self.requestBms((self.bmsPeriodIndex + 1) % Tcu.bmsPeriodsMs.count, schedule: false)
            }
            self.keepStatsFlowing(attempt)
        }
    }

    private func watchHeartbeat(_ attempt: Int) {
        scheduler.after(5_000) { [weak self] in
            guard let self, attempt == self.generation, self.phase == .ready else { return }
            if self.scheduler.nowMs - self.lastTcuHeartbeat > Self.heartbeatTimeoutMs {
                self.fail("Scooter stopped sending heartbeats. Tap Connect to retry.")
            } else {
                self.watchHeartbeat(attempt)
            }
        }
    }

    private func requestBms(_ index: Int, schedule: Bool) {
        guard Tcu.bmsPeriodsMs.indices.contains(index) else { return }
        bmsPeriodIndex = index
        let period = Tcu.bmsPeriodsMs[index]
        let payload = Tcu.statsRequest(tag: Tcu.tagBms, enable: true, periodMs: period)
        log("Requesting BMS stream: \(payload.hexString) (period \(period))")
        write(Tcu.statsRequest, payload, critical: false)
        guard schedule else { return }
        let attempt = generation
        scheduler.after(Self.bmsSilenceMs) { [weak self] in
            guard let self, attempt == self.generation, self.phase != .idle, self.lastBmsReadingAt == 0 else { return }
            if index + 1 < Tcu.bmsPeriodsMs.count {
                self.log("No BMS frame after 12 s; trying next period")
                self.requestBms(index + 1, schedule: true)
            } else {
                self.noBmsFrames()
            }
        }
    }

    private func noBmsFrames() {
        status("Connected · the scooter has not sent battery frames. Open More › Diagnostics and share the log.")
        guard !probedStats else { return }
        probedStats = true
        log("Probing stats service with a vehicle-status request (tag 13)")
        let payload = Tcu.statsRequest(tag: Tcu.tagVehicleStatus, enable: true, periodMs: 0)
        write(Tcu.statsRequest, payload, critical: false)
    }

    private func autoProbe(_ attempt: Int) {
        guard !autoProbed else { return }
        autoProbed = true
        log("Auto-probe: asking once for stats tags \(Self.autoProbeTags)")
        for (index, tag) in Self.autoProbeTags.enumerated() {
            scheduler.after(Int64(index) * 1_500) { [weak self] in
                guard let self, attempt == self.generation, self.phase == .ready else { return }
                self.write(Tcu.statsRequest, Tcu.statsRequest(tag: tag, enable: true, periodMs: 0), critical: false)
            }
        }
        scheduler.after(Int64(Self.autoProbeTags.count) * 1_500 + 3_000) { [weak self] in
            guard let self, attempt == self.generation, self.phase == .ready else { return }
            for tag in Self.autoProbeTags {
                self.write(Tcu.statsRequest, Tcu.statsRequest(tag: tag, enable: false, periodMs: 0), critical: false)
            }
            if self.lastBmsReadingAt == 0 || self.scheduler.nowMs - self.lastBmsReadingAt > 5_000 {
                self.log("BMS frames paused during the auto-probe; requesting the stream again")
                self.requestBms(self.bmsPeriodIndex, schedule: false)
            }
        }
    }

    // MARK: - Incoming frames

    private func handle(_ characteristic: String, _ value: [UInt8]) {
        switch characteristic.lowercased() {
        case Tcu.tcuHeartbeat:
            lastTcuHeartbeat = scheduler.nowMs
            sendHeartbeat(Tcu.heartbeatValue(value) + 1)
        case Tcu.tcuInfo:
            if let info = TcuParser.info(value) {
                log("TCU firmware \(info.firmware), BLE protocol \(info.bleProtocol), hardware \(info.hardware)")
                onInfo?(info)
            }
        case Tcu.vehicleState:
            if let state = TcuParser.vehicleState(value, time: scheduler.nowMs) {
                onVehicle?(state)
            } else {
                log("Vehicle state unreadable: \(value.hexString)")
            }
        case Tcu.esyncState:
            log("ESYNC: \(value.hexString)")
        case Tcu.icbtControl:
            onHardControlFrame(value)
        case Tcu.statsUpdate:
            onStats(value)
        default:
            break
        }
    }

    private func onHardControlFrame(_ value: [UInt8]) {
        let hex = value.hexString
        guard let frame = HardControlFrame.parse(value) else {
            log("Handlebar \(hex): too short, ignored")
            return
        }
        guard controlDebouncer.accept(value, now: scheduler.nowMs) else {
            log("Handlebar \(hex): repeat, ignored")
            return
        }
        let events = frame.events
        guard let event = events.first else {
            log("Handlebar \(hex): no action")
            return
        }
        lastHandlebar = name(event)
        log("Handlebar \(hex): \(lastHandlebar ?? "")")
        onHardControl?(event)
    }

    private func name(_ event: HardControlEvent) -> String {
        switch event {
        case .callAccept: return "accept call"
        case .callReject: return "reject call"
        case .callVolumeUp: return "call volume up"
        case .callVolumeDown: return "call volume down"
        case .musicVolumeUp: return "volume up"
        case .musicVolumeDown: return "volume down"
        case .musicPlayPause: return "play/pause"
        case .musicNext: return "next track"
        case .musicPrevious: return "previous track"
        case .musicMute: return "mute"
        case .voiceStart: return "voice assistant"
        case .voiceCancel: return "voice cancel"
        }
    }

    private func onStats(_ value: [UInt8]) {
        let now = scheduler.nowMs
        guard let tag = value.first.map(Int.init) else { return }
        rawStats[tag] = value
        let hex = value.hexString
        if tag != Tcu.tagBms || hex != lastRawHex || now - lastRawLogAt > 10_000 {
            log("Stats tag \(tag) (\(value.count) B): \(hex)")
            if tag == Tcu.tagBms {
                lastRawHex = hex
                lastRawLogAt = now
            }
        }
        if tag == Tcu.tagVehicleStatus, probedStats {
            write(Tcu.statsRequest, Tcu.statsRequest(tag: Tcu.tagVehicleStatus, enable: false, periodMs: 0), critical: false)
            return
        }
        guard tag == Tcu.tagBms else { return }
        guard let frame = TcuParser.bms(value) else {
            log("BMS frame too short (\(value.count) B)")
            return
        }
        let firstUsable = lastBmsReadingAt == 0
        let before = "\(decoder.percentDivisor ?? 0)-\(decoder.temperatureDivisor ?? 0)"
        let readings = decoder.readings(frame, time: Int64(Date().timeIntervalSince1970 * 1000))
        for reading in readings {
            onReading?(reading)
        }
        if !readings.isEmpty { lastBmsReadingAt = now }
        let after = "\(decoder.percentDivisor ?? 0)-\(decoder.temperatureDivisor ?? 0)"
        if before != after {
            log("Scale latched: percent ÷\(decoder.percentDivisor.map(String.init) ?? "?"), temperature ÷\(decoder.temperatureDivisor.map(String.init) ?? "?")")
            saveScale()
        }
        if firstUsable && phase == .ready { status("Connected · battery data live") }
    }

    private func sendHeartbeat(_ counter: Int) {
        heartbeat = counter & 0xFFFF
        write(Tcu.phoneHeartbeat, Tcu.heartbeat(heartbeat), critical: false)
    }

    public func sendVoice(_ state: VoiceAssistState) {
        guard phase == .ready, has(Tcu.voiceAssist) else { return }
        write(Tcu.voiceAssist, state.encode(), critical: false, maxTries: 1, replaceable: true)
    }

    // MARK: - GATT queue

    private func marker(_ action: @escaping () -> Void) {
        enqueue(GattOp(kind: .marker, characteristic: nil, label: "marker", critical: false, maxTries: 1) {
            action()
            return true
        })
    }

    private func notify(_ characteristic: String, critical: Bool) {
        guard has(characteristic) else { return }
        enqueue(GattOp(
            kind: .descriptor, characteristic: characteristic, label: "notify \(short(characteristic))",
            critical: critical, maxTries: 3
        ) { [weak self] in
            guard let self, self.transport.availableCharacteristics.contains(characteristic) else { return false }
            self.transport.setNotify(characteristic, enabled: true)
            return true
        })
    }

    private func read(_ characteristic: String, critical: Bool, maxTries: Int = 3) {
        guard has(characteristic) else { return }
        enqueue(GattOp(
            kind: .read, characteristic: characteristic, label: "read \(short(characteristic))",
            critical: critical, maxTries: maxTries
        ) { [weak self] in
            guard let self, self.transport.availableCharacteristics.contains(characteristic) else { return false }
            self.transport.read(characteristic)
            return true
        })
    }

    private func write(
        _ characteristic: String, _ value: [UInt8], critical: Bool,
        maxTries: Int = 3, replaceable: Bool = false, priority: Bool = false
    ) {
        let op = GattOp(
            kind: .write, characteristic: characteristic, label: "write \(short(characteristic))",
            critical: critical, maxTries: maxTries, replaceable: replaceable
        ) { [weak self] in
            guard let self, self.transport.availableCharacteristics.contains(characteristic) else { return false }
            self.transport.write(characteristic, value, withResponse: true)
            return true
        }
        enqueue(op, priority: priority)
    }

    private func enqueue(_ op: GattOp, priority: Bool = false) {
        guard phase != .idle else { return }
        if priority {
            let same: (GattOp) -> Bool = { $0.replaceable && $0.kind == .write && $0.characteristic == op.characteristic }
            let isMarker: (GattOp) -> Bool = { $0.kind == .marker }
            queue.removeAll { same($0) }
            if let pending = pendingRetry, same(pending) {
                cancel(retryHandle)
                retryHandle = nil
                pendingRetry = nil
                retryPending = false
            }
            // `queue` contains pending work only; `running` is separate. A priority frame goes first,
            // except it never crosses a marker, and it leaves one ordinary op ahead when another
            // frame in the same lane is already running (so heartbeats cannot starve).
            var index = running.map { same($0) ? 1 : 0 } ?? 0
            if let lastMarker = queue.lastIndex(where: isMarker) { index = max(index, lastMarker + 1) }
            queue.insert(op, at: min(index, queue.count))
        } else if op.replaceable, let stale = queue.firstIndex(where: {
            $0.replaceable && $0.kind == op.kind && $0.characteristic == op.characteristic
        }) {
            queue[stale] = op
        } else {
            queue.append(op)
        }
        pump()
    }

    private func pump() {
        guard running == nil, !retryPending, phase != .idle else { return }
        while let op = queue.first {
            queue.removeFirst()
            if op.kind == .marker {
                _ = op.action()
                if running != nil || retryPending { return }
                continue
            }
            op.tries += 1
            running = op
            let started = op.action()
            // A test/demo transport may complete synchronously. In that case `complete` already
            // cleared `running` and advanced the queue; do not install a watchdog for stale work.
            guard running === op else { return }
            if started {
                runningToken += 1
                let token = runningToken
                let attempt = generation
                cancel(runningDeadline)
                runningDeadline = scheduler.after(Self.setupTimeoutMs) { [weak self] in
                    guard let self, token == self.runningToken, attempt == self.generation, self.running === op else { return }
                    self.runningDeadline = nil
                    self.fail("Scooter stopped answering (\(op.label)). Tap Connect to retry.")
                }
                return
            }
            running = nil
            runningToken += 1
            cancel(runningDeadline)
            runningDeadline = nil
            if op.tries < op.maxTries {
                scheduleRetry(op, attempt: generation)
                return
            }
            writeOutcome(op, failure: -1)
            giveUp(op, "could not start")
            if phase == .idle { return }
        }
    }

    private func complete(_ kind: OpKind, _ characteristic: String, success: Bool) {
        guard let op = running, op.kind == kind, op.characteristic?.lowercased() == characteristic.lowercased() else {
            log("Ignored unexpected \(kind) callback for \(short(characteristic))")
            return
        }
        running = nil
        runningToken += 1
        cancel(runningDeadline)
        runningDeadline = nil
        if success {
            writeOutcome(op, failure: nil)
        } else if op.tries < op.maxTries {
            log("\(op.label) failed; retrying")
            scheduleRetry(op, attempt: generation)
            return
        } else {
            writeOutcome(op, failure: 1)
            giveUp(op, "failed")
        }
        if awaitingReady, op.kind == .read, op.characteristic?.lowercased() == Tcu.tcuInfo {
            verificationPending = false
        }
        pump()
        if awaitingReady, running == nil, queue.isEmpty { tryReady() }
    }

    private func scheduleRetry(_ op: GattOp, attempt: Int) {
        retryPending = true
        pendingRetry = op
        cancel(retryHandle)
        retryHandle = scheduler.after(250) { [weak self] in
            guard let self, attempt == self.generation, self.pendingRetry === op else { return }
            self.retryPending = false
            self.pendingRetry = nil
            self.retryHandle = nil
            self.queue.insert(op, at: 0)
            self.pump()
        }
    }

    private func writeOutcome(_ op: GattOp, failure: Int?) {
        guard op.kind == .write, let characteristic = op.characteristic?.lowercased() else { return }
        if characteristic == Tcu.navInfo {
            if failure == nil {
                navigationAckedAt = scheduler.nowMs
                navigationError = nil
            } else {
                navigationError = failure
            }
        }
    }

    private func giveUp(_ op: GattOp, _ why: String) {
        log("\(op.label) \(why)")
        if op.critical {
            fail("Scooter link setup failed: \(op.label) \(why). Tap Connect to retry.")
        }
    }

    // MARK: - Persistence and helpers

    private func savedScale(_ kind: String) -> Int? {
        guard let defaults, let id = targetID else { return nil }
        let value = defaults.integer(forKey: "ruta.scale.\(kind).\(id.uuidString)")
        return [1, 10, 100].contains(value) ? value : nil
    }

    private func saveScale() {
        guard let defaults, let id = targetID else { return }
        if let percent = decoder.percentDivisor {
            defaults.set(percent, forKey: "ruta.scale.pct.\(id.uuidString)")
        }
        if let temperature = decoder.temperatureDivisor {
            defaults.set(temperature, forKey: "ruta.scale.temp.\(id.uuidString)")
        }
    }

    private func log(_ message: String) {
        diagnostics.log(message)
        onLog?(message)
    }

    private func status(_ message: String) {
        log(message)
        onStatus?(message)
    }

    private func short(_ uuid: String) -> String {
        let parts = uuid.split(separator: "-")
        return parts.first.map { String($0.suffix(4)) } ?? uuid
    }
}
