import Foundation

/// One turn-by-turn update for 0x0303 (27 bytes): turn distance in metres below 1 km, else tenths
/// of a km; remaining distance always tenths of a km; arrival clock in 12-hour form with an AM/PM
/// flag; roundabout exit and speed limit 0.
public struct NavFrame: Equatable, Sendable {
    public var active: Bool
    public var turn: Int
    public var distanceMeters: Int
    public var nextTurn: Int
    public var arrivalHour24: Int
    public var arrivalMinute: Int
    public var remainingMeters: Int
    public var remainingMinutes: Int
    public var road: String

    public init(
        active: Bool, turn: Int, distanceMeters: Int, nextTurn: Int,
        arrivalHour24: Int, arrivalMinute: Int, remainingMeters: Int, remainingMinutes: Int, road: String
    ) {
        self.active = active
        self.turn = turn
        self.distanceMeters = distanceMeters
        self.nextTurn = nextTurn
        self.arrivalHour24 = arrivalHour24
        self.arrivalMinute = arrivalMinute
        self.remainingMeters = remainingMeters
        self.remainingMinutes = remainingMinutes
        self.road = road
    }

    /// Exactly what the 14-byte road field carries, for the in-app TFT preview.
    public var roadText: String {
        let bytes = Self.roadBytes(road)
        let end = bytes.lastIndex(where: { $0 != 0 }).map { $0 + 1 } ?? 0
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    public func encode() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 27)
        let metres = max(distanceMeters, 0)
        let unit = metres < 1000 ? 1 : 0
        let distance = min(metres < 1000 ? metres : metres / 100, 65535)
        let hour12raw = arrivalHour24 % 12
        let hour12 = hour12raw == 0 ? 12 : hour12raw
        let pm = (arrivalHour24 % 24) >= 12 ? 1 : 0
        let remaining = min(max(remainingMinutes, 0), 15 * 60 + 59)
        let tenths = min(max(remainingMeters, 0) / 100, 65535)

        bytes[0] = UInt8(unit | ((active ? 1 : 0) << 2) | (hour12 << 4))
        bytes[1] = UInt8(min(max(arrivalMinute, 0), 59))
        bytes[2] = UInt8((distance >> 8) & 0xFF)
        bytes[3] = UInt8(distance & 0xFF)
        bytes[4] = UInt8(truncatingIfNeeded: turn)
        bytes[5] = UInt8((pm << 4) & 0xFF)
        bytes[6] = UInt8((remaining / 60) & 0xFF)
        bytes[7] = UInt8(truncatingIfNeeded: nextTurn)
        bytes[8] = UInt8((tenths >> 8) & 0xFF)
        bytes[9] = UInt8(tenths & 0xFF)
        bytes[10] = UInt8(remaining % 60)
        bytes[11] = 0
        bytes[12] = 0
        let road = Self.roadBytes(road)
        for i in 0..<14 { bytes[13 + i] = road[i] }
        return bytes
    }

    /// Characters outside `[letters, digits, whitespace, +]` become `_`; 14 bytes, zero padded.
    public static func roadBytes(_ road: String) -> [UInt8] {
        IcbtText.encode(road, length: 14, replacement: "_")
    }

    /// Exit frame: metres, not active, 12 AM, distance 0, straight, empty road (byte 0 = 0xC1).
    public static let exit = NavFrame(
        active: false, turn: NavTurn.straight, distanceMeters: 0, nextTurn: NavTurn.straight,
        arrivalHour24: 0, arrivalMinute: 0, remainingMeters: 0, remainingMinutes: 0, road: ""
    )
}

/// Smartphone state for 0x0301 (8 bytes), sent at 1 Hz. It tells the cluster a phone is connected
/// (bit 2 always set) and syncs its clock. Every field is clamped to its bit width.
public struct PhoneStatus: Equatable, Sendable {
    public var batteryPercent: Int?
    public var signalLevel: Int
    public var hour: Int
    public var minute: Int
    public var second: Int
    public var headset: Bool
    public var missedCallAlert: Bool
    public var callState: TcuCallState
    public var smsFlag: Bool
    public var smsCount: Int
    public var missedCount: Int
    public var callDurationS: Int

    public init(
        batteryPercent: Int?, signalLevel: Int, hour: Int, minute: Int, second: Int,
        headset: Bool = false, missedCallAlert: Bool = false, callState: TcuCallState = .none,
        smsFlag: Bool = false, smsCount: Int = 0, missedCount: Int = 0, callDurationS: Int = 0
    ) {
        self.batteryPercent = batteryPercent
        self.signalLevel = signalLevel
        self.hour = hour
        self.minute = minute
        self.second = second
        self.headset = headset
        self.missedCallAlert = missedCallAlert
        self.callState = callState
        self.smsFlag = smsFlag
        self.smsCount = smsCount
        self.missedCount = missedCount
        self.callDurationS = callDurationS
    }

    public func encode() -> [UInt8] {
        let bars: Int
        if let battery = batteryPercent, battery > 0, battery <= 100 {
            if battery < 20 { bars = 0 }
            else if battery < 40 { bars = 1 }
            else if battery < 60 { bars = 2 }
            else if battery < 80 { bars = 3 }
            else { bars = 4 }
        } else {
            bars = 4
        }
        let duration = callState == .active ? min(max(callDurationS, 0), 65535) : 0
        return [
            UInt8((headset ? 1 : 0) | ((missedCallAlert ? 1 : 0) << 1) | 0x04 | (bars << 3)),
            UInt8(min(max(signalLevel, 0), 4) | (callState.rawValue << 3) | ((smsFlag ? 1 : 0) << 6)),
            UInt8(0x01 | (min(max(second, 0), 59) << 1)),
            UInt8(min(max(minute, 0), 59)),
            UInt8(min(max(hour, 0), 23)),
            UInt8(min(max(smsCount, 0), 15) | (min(max(missedCount, 0), 15) << 4)),
            UInt8((duration >> 8) & 0xFF),
            UInt8(duration & 0xFF),
        ]
    }
}

/// Music state for 0x0304 (3 bytes). Byte 0 holds volume in bits 3-6 and an inverted play flag
/// (bit 7 clear while playing); byte 1 is progress percent; byte 2 bit 0 marks an active session.
public struct MusicInfo: Equatable, Sendable {
    public static let volumeSteps = 10

    public var active: Bool
    public var playing: Bool
    public var volume: Int
    public var elapsedPercent: Int

    public init(active: Bool, playing: Bool, volume: Int, elapsedPercent: Int = 0) {
        self.active = active
        self.playing = playing
        self.volume = volume
        self.elapsedPercent = elapsedPercent
    }

    public func encode() -> [UInt8] {
        let level = min(max(volume, 0), 15)
        let progress = min(max(elapsedPercent, 0), 255)
        return [
            UInt8((level << 3) | (playing ? 0 : 0x80)),
            UInt8(progress),
            UInt8(active ? 1 : 0),
        ]
    }

    /// From `PlaybackState.STATE_*`: playing/buffering/transient states play; paused is active but
    /// paused; anything else is inactive.
    public static func of(playbackState: Int?, volume: Int, elapsedPercent: Int = 0) -> MusicInfo {
        switch playbackState {
        case 3, 6, 4, 5, 8, 9, 10, 11:
            return MusicInfo(active: true, playing: true, volume: volume, elapsedPercent: elapsedPercent)
        case 2:
            return MusicInfo(active: true, playing: false, volume: volume, elapsedPercent: elapsedPercent)
        default:
            return MusicInfo(active: false, playing: false, volume: volume, elapsedPercent: elapsedPercent)
        }
    }

    /// Stream volume → the cluster's 0...10 scale, rounded.
    public static func volumeLevel(current: Int, max maximum: Int) -> Int {
        guard maximum > 0 else { return 0 }
        let level = (Double(current) * Double(volumeSteps) / Double(maximum)).rounded()
        return min(max(Int(level), 0), volumeSteps)
    }

    /// Track progress 0...100; 0 when the duration is unknown.
    public static func progressPercent(positionMs: Int64, durationMs: Int64) -> Int {
        guard durationMs > 0 else { return 0 }
        let value = max(positionMs, 0) * 100 / durationMs
        return min(max(Int(value), 0), 100)
    }
}

/// Song for 0x0305 (28 bytes): title in bytes 0-13, artist in 14-27. Disallowed characters are
/// removed, unlike caller/road fields.
public struct MusicMeta: Equatable, Sendable {
    public static let clear = MusicMeta("", "")

    public var title: String
    public var artist: String

    public init(_ title: String, _ artist: String) {
        self.title = title
        self.artist = artist
    }

    public func encode() -> [UInt8] {
        IcbtText.encode(title, length: 14, replacement: "")
            + IcbtText.encode(artist, length: 14, replacement: "")
    }

    /// Artist, else album, else "".
    public static func of(title: String?, artist: String?, album: String?) -> MusicMeta {
        let candidate = artist ?? ""
        let hasArtist = !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return MusicMeta(title ?? "", hasArtist ? candidate : (album ?? ""))
    }
}

/// One 0x0306 indication. Extra bytes are ignored; every mapped field becomes its own event.
public struct HardControlFrame: Equatable, Sendable {
    public var callAction: Int
    public var callVolume: Int
    public var musicVolume: Int
    public var musicDataConfig: Int
    public var musicControl: Int
    public var smsTrigger: Int
    public var voiceControl: Int

    public init(
        callAction: Int, callVolume: Int, musicVolume: Int,
        musicDataConfig: Int, musicControl: Int, smsTrigger: Int, voiceControl: Int
    ) {
        self.callAction = callAction
        self.callVolume = callVolume
        self.musicVolume = musicVolume
        self.musicDataConfig = musicDataConfig
        self.musicControl = musicControl
        self.smsTrigger = smsTrigger
        self.voiceControl = voiceControl
    }

    /// In order: call action, call volume, music volume, music control, voice.
    public var events: [HardControlEvent] {
        var result: [HardControlEvent] = []
        switch callAction {
        case 1: result.append(.callAccept)
        case 2: result.append(.callReject)
        default: break
        }
        switch callVolume {
        case 0: result.append(.callVolumeUp)
        case 1: result.append(.callVolumeDown)
        default: break
        }
        switch musicVolume {
        case 0: result.append(.musicVolumeUp)
        case 1: result.append(.musicVolumeDown)
        default: break
        }
        switch musicControl {
        case 0: result.append(.musicPlayPause)
        case 1: result.append(.musicNext)
        case 2: result.append(.musicPrevious)
        case 3: result.append(.musicMute)
        default: break
        }
        switch voiceControl {
        case 1: result.append(.voiceStart)
        case 2: result.append(.voiceCancel)
        default: break
        }
        return result
    }

    public func encode() -> [UInt8] {
        [
            UInt8((callAction & 15) | ((callVolume & 3) << 4) | ((musicVolume & 3) << 6)),
            UInt8((musicDataConfig & 7) | ((musicControl & 7) << 3) | ((smsTrigger & 3) << 6)),
            UInt8(voiceControl & 7),
        ]
    }

    public static let minLength = 3

    /// Every field at a value that maps to no action (`F0 38 00`).
    public static let noAction = HardControlFrame(
        callAction: 0, callVolume: 3, musicVolume: 3,
        musicDataConfig: 0, musicControl: 7, smsTrigger: 0, voiceControl: 0
    )

    public static func parse(_ data: [UInt8]) -> HardControlFrame? {
        guard data.count >= minLength else { return nil }
        let b0 = Int(data[0])
        let b1 = Int(data[1])
        let b2 = Int(data[2])
        return HardControlFrame(
            callAction: b0 & 15,
            callVolume: (b0 >> 4) & 3,
            musicVolume: (b0 >> 6) & 3,
            musicDataConfig: b1 & 7,
            musicControl: (b1 >> 3) & 7,
            smsTrigger: (b1 >> 6) & 3,
            voiceControl: b2 & 7
        )
    }
}

/// Drops an indication identical to the previous one within `windowMs`; the window slides with
/// each repeat, so a burst from one press acts once. Not thread-safe.
public final class HardControlDebouncer {
    private let windowMs: Int64
    private var last: [UInt8]?
    private var lastAt: Int64 = 0

    public init(windowMs: Int64 = 300) {
        self.windowMs = windowMs
    }

    public func accept(_ data: [UInt8], now: Int64) -> Bool {
        let delta = now - lastAt
        let repeatFrame = last == data && delta >= 0 && delta < windowMs
        last = data
        lastAt = now
        return !repeatFrame
    }
}
