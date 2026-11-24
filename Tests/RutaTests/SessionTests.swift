import Foundation
import RutaCore

private final class ScriptedTransport: ScooterTransport {
    var onEvent: ((TransportEvent) -> Void)?
    var availableCharacteristics: Set<String> = []
    var operations: [String] = []
    var failFirstNotify: String?
    var failAlways: String?
    var autoReady = true
    var respondToOperations = true

    func startScan() {}
    func stopScan() {}
    func connect(to id: UUID) {
        onEvent?(.connected)
        if autoReady { onEvent?(.ready) }
    }
    func disconnect() {}
    func setNotify(_ characteristic: String, enabled: Bool) {
        let key = characteristic.lowercased()
        operations.append("notify \(Self.short(key))")
        guard respondToOperations else { return }
        if failAlways == key || (failFirstNotify == key) {
            failFirstNotify = nil
            onEvent?(.notifyState(characteristic: key, enabled: false))
        } else {
            onEvent?(.notifyState(characteristic: key, enabled: true))
        }
    }
    func read(_ characteristic: String) {
        operations.append("read \(Self.short(characteristic.lowercased()))")
        guard respondToOperations else { return }
        onEvent?(.readResult(characteristic: characteristic.lowercased(), success: true))
    }
    func write(_ characteristic: String, _ data: [UInt8], withResponse: Bool) {
        operations.append("write \(Self.short(characteristic.lowercased()))")
        guard respondToOperations else { return }
        onEvent?(.writeResult(characteristic: characteristic.lowercased(), success: true))
    }

    private static func short(_ uuid: String) -> String {
        String(uuid.split(separator: "-").first.map(String.init)?.suffix(4) ?? "")
    }
}

func runGattRetry() {
    let clock = ManualScheduler()
    let transport = ScriptedTransport()
    transport.availableCharacteristics = [
        Tcu.tcuInfo, Tcu.osInfo, Tcu.phoneHeartbeat, Tcu.tcuHeartbeat,
        Tcu.vehicleState, Tcu.esyncState, Tcu.statsRequest, Tcu.statsUpdate,
        Tcu.icbtControl,
    ]
    transport.failFirstNotify = Tcu.tcuHeartbeat
    let session = ScooterSession(transport: transport, scheduler: clock, defaults: nil)
    var ready = 0
    session.onConnected = { ready += 1 }

    session.connect(id: UUID(), name: "Test VX2")
    check(session.phase == .connecting, "setup starts before the retry delay")
    eq(transport.operations, ["notify 0104"], "failed operation does not let later work run")
    clock.advance(250)
    check(Array(transport.operations.prefix(3)) == ["notify 0104", "notify 0104", "read 0101"],
          "failed operation retries at the head before pending work")
    clock.advance(1_000)
    check(session.phase == .ready && ready == 1, "setup completes after the retry")
    check(transport.operations.contains("notify 0402"), "stats notification still runs")
    session.disconnect()

    // Exhausting retries on a critical setup operation must fail instead of silently skipping it.
    let failingClock = ManualScheduler()
    let failing = ScriptedTransport()
    failing.availableCharacteristics = transport.availableCharacteristics
    failing.failAlways = Tcu.tcuHeartbeat
    let failedSession = ScooterSession(transport: failing, scheduler: failingClock, defaults: nil)
    var ended = 0
    failedSession.onEnded = { _ in ended += 1 }
    failedSession.connect(id: UUID(), name: "Failing VX2")
    failingClock.advance(250)
    failingClock.advance(250)
    check(failedSession.phase == .idle, "critical failure ends setup")
    eq(failing.operations, ["notify 0104", "notify 0104", "notify 0104"],
       "critical operation is retried three times, never skipped")
    check(ended == 1, "terminal setup failure is reported")
}

func runSetupTimeoutReplacement() {
    let clock = ManualScheduler()
    let transport = ScriptedTransport()
    transport.autoReady = false
    transport.respondToOperations = false
    transport.availableCharacteristics = [
        Tcu.tcuInfo, Tcu.osInfo, Tcu.phoneHeartbeat, Tcu.tcuHeartbeat,
        Tcu.vehicleState, Tcu.esyncState, Tcu.statsRequest, Tcu.statsUpdate,
    ]
    let session = ScooterSession(transport: transport, scheduler: clock, defaults: nil)
    session.connect(id: UUID(), name: "Slow VX2")
    clock.advance(30_000)
    transport.onEvent?(.ready)
    // The original 35 s connection deadline must have been replaced by the Stage A/B deadline.
    clock.advance(6_000)
    check(session.phase == .connecting, "old setup deadline does not fire after services are ready")
    session.disconnect()
}

// Session state machine, GATT sequence, the priority lane and NavDisplay, driven by a manual
// clock and the in-memory scooter. This is the closest local proof of the iOS link without a phone.

private final class Op {
    let name: String
    let lane: Bool
    let marker: Bool

    init(_ name: String, lane: Bool = false, marker: Bool = false) {
        self.name = name
        self.lane = lane
        self.marker = marker
    }
}

func runSession() {
    // Priority lane.
    func insert(_ queue: [Op], _ op: Op, _ running: Op?) -> [Op] {
        PriorityLane.insert(queue: queue, op: op, running: running, sameLane: { $0.lane }, isMarker: { $0.marker })
    }
    func names(_ ops: [Op]) -> String { ops.map(\.name).joined(separator: " ") }

    let status = Op("0301"), music = Op("0304"), heartbeat = Op("0103")
    let nav1 = Op("nav1", lane: true), nav2 = Op("nav2", lane: true), marker = Op("marker", marker: true)
    eq(names(insert([status, music, heartbeat], nav1, status)), "0301 nav1 0304 0103", "lane: right after the running op")
    eq(names(insert([music, heartbeat], nav1, nil)), "nav1 0304 0103", "lane: first when idle")
    eq(names(insert([status, music, nav1, heartbeat], nav2, status)), "0301 nav2 0304 0103", "lane: stale frame replaced")
    eq(names(insert([nav1, heartbeat, music], nav2, nav1)), "nav1 0103 nav2 0304", "lane: running frame kept")
    eq(names(insert([nav1], nav2, nav1)), "nav1 nav2", "lane: after the running frame")
    eq(names(insert([status, marker, music], nav1, status)), "0301 marker nav1 0304", "lane: never ahead of a marker")

    var laneQueue = [status, heartbeat, music]
    var done: [String] = []
    for i in 0..<12 {
        laneQueue = insert(laneQueue, Op("nav\(i)", lane: true), laneQueue.first)
        done.append(laneQueue.first!.name)
        laneQueue.removeFirst()
    }
    check((0...3).contains(done.firstIndex(of: "0103") ?? -1) && done.contains("0304") && done.contains("0301"), "lane: no starvation \(done)")

    // NavDisplay.
    check(NavDisplay.of(available: true, sending: true, ackedAt: 1_000, error: nil, now: 6_000) == .showing, "showing")
    check(NavDisplay.of(available: true, sending: true, ackedAt: 1_000, error: nil, now: 6_001) == .preparing, "stale ack")
    check(NavDisplay.of(available: true, sending: true, ackedAt: 0, error: nil, now: 100) == .preparing, "no ack")
    check(NavDisplay.of(available: true, sending: true, ackedAt: 1_000, error: 3, now: 9_000) == .rejected, "rejected")
    check(NavDisplay.of(available: true, sending: false, ackedAt: 0, error: -1, now: 100) == .rejected, "failed to start")
    check(NavDisplay.of(available: true, sending: false, ackedAt: 1_000, error: nil, now: 2_000) == .preparing, "not sending")
    check(NavDisplay.of(available: false, sending: false, ackedAt: 0, error: nil, now: 100) == .unavailable, "unavailable")

    // A whole connection over the fake TCU.
    let clock = ManualScheduler()
    let transport = FakeScooterTransport(scheduler: clock)
    let session = ScooterSession(transport: transport, scheduler: clock, defaults: nil)
    var statuses: [String] = []
    var readings: [Reading] = []
    var vehicles: [VehicleState] = []
    var connections = 0
    var endings: [Bool] = []
    session.onStatus = { statuses.append($0) }
    session.onReading = { readings.append($0) }
    session.onVehicle = { vehicles.append($0) }
    session.onConnected = { connections += 1 }
    session.onEnded = { endings.append($0) }

    check(session.phase == .idle, "starts idle")
    session.connect(id: FakeScooterTransport.demoID, name: "HMC VX2")
    check(session.phase == .connecting, "connecting")
    clock.advance(200)
    clock.advance(2_500)

    check(session.phase == .ready, "ready after the GATT sequence")
    check(connections == 1, "connected once")
    check(vehicles.first?.ignitionOn == true && vehicles.first?.rideMode == 3, "vehicle state read")

    // Stage A and B wrote what the protocol requires.
    func writes(_ uuid: String) -> [[UInt8]] {
        transport.writes.filter { $0.characteristic.lowercased() == uuid }.map(\.data)
    }
    check(writes(Tcu.phoneHeartbeat).contains(Tcu.heartbeat(1)), "first phone heartbeat")
    check(writes(Tcu.osInfo) == [[Tcu.osAndroid]], "OS info write")
    check(writes(Tcu.statsRequest).first == Tcu.statsRequest(tag: Tcu.tagBms, enable: true, periodMs: 200), "BMS stream request")

    // The fake echoes heartbeats; the session answers with value + 1.
    clock.advance(1_000)
    check(writes(Tcu.phoneHeartbeat).contains(Tcu.heartbeat(0x1202)), "heartbeat answered with value + 1")

    // The BMS stream reaches the decoder.
    clock.advance(2_000)
    let pack0Soc = readings.last { $0.pack == 0 && $0.metric == .soc }?.value
    check(pack0Soc != nil && abs(pack0Soc! - 57.81) < 1e-9, "live battery reading")
    check(readings.contains { $0.pack == 1 && $0.metric == .temperature && abs($0.value - 28.9) < 1e-9 }, "pack 1 temperature")
    check(statuses.contains("Connected · battery data live"), "battery status")
    check(writes(Tcu.phoneState).last?.count == 8, "phone status at 1 Hz")

    // Turn-by-turn: 0x0303 through the priority lane, acknowledged by the TCU.
    check(!session.navigationMissing, "nav characteristic present")
    let frame = MapsCue(
        turn: NavTurn.left, distanceMeters: 120, instruction: "Turn left", road: "Swami Vidyananda Ln",
        arrivalHour24: 15, arrivalMinute: 45, remainingMeters: 3389, rerouting: false
    ).frame(now: Date())
    session.pushNavigation(frame)
    clock.advance(50)
    check(writes(Tcu.navInfo).last == frame.encode(), "nav frame bytes")
    check(session.navigationDisplay() == .showing, "nav acknowledged")

    // The 1 Hz tick repeats the frame rather than dropping it.
    clock.advance(2_500)
    check((writes(Tcu.navInfo).count) >= 2, "nav frame repeated")

    // Music-less: the phone status still carries call state.
    session.callState = .incoming
    session.caller = CallerInfo("Asha", "9876543210")
    clock.advance(1_100)
    check(writes(Tcu.phoneState).last.map { Int($0[1]) >> 3 & 7 } == TcuCallState.incoming.rawValue, "call state on 0x0301")
    check(writes(Tcu.callerInfo).last == CallerInfo("Asha", "9876543210").encode(), "caller on 0x0302")

    // A dropped link reconnects by itself; the ride keeps its state.
    transport.dropLink()
    check(session.reconnecting, "reconnecting after a drop")
    clock.advance(2_200)
    clock.advance(2_500)
    check(session.phase == .ready && connections == 2, "reconnected")
    check(endings == [true], "link-lost ending reported")

    // A user disconnect ends it for good.
    session.disconnect()
    check(session.phase == .idle && !session.reconnecting, "disconnected")
    check(endings == [true, false], "user disconnect ending")

    // Scan results must reach the app through the session, not just the transport: the session
    // owns `transport.onEvent`, so a swallowed .discovered leaves the scan list empty (the bug
    // found on a real iPhone while nRF Connect showed the scooter).
    var found: [DiscoveredScooter] = []
    session.onDiscovered = { found.append($0) }
    transport.startScan()
    clock.advance(350)
    check(found.count == 1, "discovery forwarded to the app once")
    check(found.first?.name.hasPrefix("HMC") == true, "discovery keeps the advertised name")
    transport.stopScan()
}
