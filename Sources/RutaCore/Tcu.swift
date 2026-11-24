import Foundation

/// GATT identifiers and wire constants of the Vida TCU. Mirrors `TcuProtocol.kt`.
public enum Tcu {
    public static let infoService = "1e5af1a3-fab3-4e33-aafb-331e781ed789"
    public static let commandService = "02ce005e-2c40-455d-a079-976d3a35c630"
    public static let icbtService = "76f2f660-db96-4e05-a871-53d0e4524e50"

    public static let tcuInfo = uuid16(0x0101)
    public static let osInfo = uuid16(0x0102)
    public static let phoneHeartbeat = uuid16(0x0103)
    public static let tcuHeartbeat = uuid16(0x0104)
    public static let vehicleState = uuid16(0x0105)
    public static let esyncState = uuid16(0x0106)

    public static let phoneState = uuid16(0x0301)
    public static let callerInfo = uuid16(0x0302)
    public static let navInfo = uuid16(0x0303)
    public static let musicInfo = uuid16(0x0304)
    public static let musicMeta = uuid16(0x0305)
    public static let icbtControl = uuid16(0x0306)
    public static let voiceAssist = uuid16(0x0307)

    public static let statsRequest = uuid16(0x0401)
    public static let statsUpdate = uuid16(0x0402)

    public static let cccd = uuid16(0x2902)

    public static let tagBms = 1
    public static let tagVehicleStatus = 13
    public static let osAndroid: UInt8 = 1

    /// Stats periods tried in order; 200 ms streams at ~2 Hz on a VX2.
    public static let bmsPeriodsMs: [Int] = [200, 0]

    /// 16-bit UUID on the Bluetooth base UUID.
    public static func uuid16(_ value: Int) -> String {
        String(format: "%08x-0000-1000-8000-00805f9b34fb", value)
    }

    /// Phone heartbeat: 16-bit big-endian counter.
    public static func heartbeat(_ counter: Int) -> [UInt8] {
        [UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)]
    }

    /// TCU heartbeat value: up to four bytes, big-endian; fewer than two bytes count as zero.
    public static func heartbeatValue(_ value: [UInt8]) -> Int {
        guard value.count >= 2 else { return 0 }
        return value.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Stats subscription `[tag, enable, msb, lsb]`. Only periods 0...255 encode as intended.
    public static func statsRequest(tag: Int, enable: Bool, periodMs: Int) -> [UInt8] {
        precondition(periodMs % 100 == 0, "Period must be a multiple of 100 ms")
        precondition((0...255).contains(periodMs), "Only the low byte of the period is carried")
        return [UInt8(tag & 0xFF), enable ? 1 : 0, UInt8((periodMs >> 56) & 0xFF), UInt8(periodMs & 0xFF)]
    }
}

/// Cluster turn symbols (byte 4 of 0x0303).
public enum NavTurn {
    public static let wrongWay = 0x42
    public static let slightLeft = 0x43
    public static let slightRight = 0x44
    public static let sharpLeft = 0x45
    public static let sharpRight = 0x46
    public static let straight = 0x47
    public static let destination = 0x48
    public static let left = 0x49
    public static let right = 0x4A
    public static let rampLeft = 0x4B
    public static let rampRight = 0x4C
    public static let roundaboutRight = 0x4E
    public static let uTurnLeft = 0x4F
    public static let uTurnRight = 0x50
    public static let forkLeft = 0x51
    public static let forkRight = 0x52
    public static let ferryTrain = 0x54
    public static let roundaboutLeft = 0x55
    public static let merge = 0x56
    public static let keepRight = 0x58
    public static let ferry = 0x59
    public static let keepLeft = 0x5A
}

/// Call state in 0x0301. `ended` is held ~2 s, then `none`.
public enum TcuCallState: Int, CaseIterable, Sendable {
    case none = 0
    case incoming = 1
    case outgoing = 2
    case active = 3
    case ended = 4
    case conference = 5

    /// Caller info (0x0302) is sent only in these states, right after 0x0301.
    public var showsCaller: Bool {
        self == .incoming || self == .outgoing || self == .active
    }
}

/// Voice assistant state for 0x0307.
public enum VoiceAssistState: Int, CaseIterable, Sendable {
    case noAction = 0
    case listening = 1
    case processing = 2
    case responding = 3
    case cancel = 4
    case negativeResponse = 5

    public func encode() -> [UInt8] { [UInt8(rawValue)] }
}

/// Handlebar actions decoded from 0x0306.
public enum HardControlEvent: Equatable, Sendable {
    case callAccept, callReject
    case callVolumeUp, callVolumeDown
    case musicVolumeUp, musicVolumeDown
    case musicPlayPause, musicNext, musicPrevious, musicMute
    case voiceStart, voiceCancel
}

/// What the UI may claim about the cluster's turn-by-turn line. A queued write proves nothing:
/// showing needs the TCU's acknowledgement of the latest completed write.
public enum NavDisplay: String, Sendable {
    case unavailable = "Unavailable"
    case showing = "Sent to scooter"
    case rejected = "Rejected"
    case preparing = "Preparing"

    public static let freshMs: Int64 = 5_000

    /// `ackedAt` 0 = no acknowledged frame yet; `error` = last final 0x0303 failure.
    public static func of(available: Bool, sending: Bool, ackedAt: Int64, error: Int?, now: Int64) -> NavDisplay {
        if !available { return .unavailable }
        if sending, ackedAt > 0, (0...freshMs).contains(now - ackedAt) { return .showing }
        if error != nil { return .rejected }
        return .preparing
    }
}

/// Insertion rule of the GATT priority lane: `op` goes directly after the running op (first when
/// none runs), replacing any queued op in the same lane. It never overtakes a marker. While an op
/// of the same lane is running, one other queued op goes first, so frames alternate with the rest
/// of the queue instead of starving it (heartbeat replies included).
public enum PriorityLane {
    public static func insert<T: AnyObject>(
        queue: [T], op: T, running: T?,
        sameLane: (T) -> Bool, isMarker: (T) -> Bool
    ) -> [T] {
        var ops = queue.filter { $0 === running || !sameLane($0) }
        var index = running == nil ? 0 : 1
        if let lastMarker = ops.lastIndex(where: isMarker) { index = max(index, lastMarker + 1) }
        if let running, sameLane(running) { index += 1 }
        ops.insert(op, at: min(index, ops.count))
        return ops
    }
}
