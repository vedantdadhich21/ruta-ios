import Foundation
import RutaCore

// Port of the Android host test `tests/IcbtProtocolTest.kt`. The expected bytes there were
// captured from a real VX2. This runner exists because the Command Line Tools ship neither XCTest
// nor Swift Testing; `swift run RutaTests` is the local and CI entry point.

var failures = 0

func fail(_ message: String, line: Int) {
    failures += 1
    print("FAIL line \(line): \(message)")
}

func check(_ condition: Bool, _ what: @autoclosure () -> String = "", line: Int = #line) {
    if !condition { fail(what(), line: line) }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ what: String = "", line: Int = #line) {
    if actual != expected { fail("\(what) got \(actual), want \(expected)", line: line) }
}

func expect(_ actual: [UInt8], _ expected: [UInt8], _ what: String, line: Int = #line) {
    if actual != expected { fail("\(what): got \(actual.hexString), want \(expected.hexString)", line: line) }
}

func bytes(_ values: Int...) -> [UInt8] {
    values.map { UInt8(truncatingIfNeeded: $0) }
}

func ascii(_ text: String, _ length: Int) -> [UInt8] {
    var out = Array(text.utf8)
    if out.count > length { out = Array(out.prefix(length)) }
    if out.count < length { out += Array(repeating: 0, count: length - out.count) }
    return out
}

func runUUIDs() {
    eq(Tcu.phoneState, "00000301-0000-1000-8000-00805f9b34fb", "phone state UUID")
    eq(Tcu.callerInfo, "00000302-0000-1000-8000-00805f9b34fb", "caller UUID")
    eq(Tcu.navInfo, "00000303-0000-1000-8000-00805f9b34fb", "nav UUID")
    eq(Tcu.musicInfo, "00000304-0000-1000-8000-00805f9b34fb", "music UUID")
    eq(Tcu.musicMeta, "00000305-0000-1000-8000-00805f9b34fb", "meta UUID")
    eq(Tcu.icbtControl, "00000306-0000-1000-8000-00805f9b34fb", "control UUID")
    eq(Tcu.voiceAssist, "00000307-0000-1000-8000-00805f9b34fb", "voice UUID")
    eq(Tcu.icbtService, "76f2f660-db96-4e05-a871-53d0e4524e50", "ICBT service UUID")
}

func runPhoneStatus() {
    expect(
        PhoneStatus(batteryPercent: 75, signalLevel: 4, hour: 15, minute: 30, second: 20).encode(),
        bytes(0x1C, 0x04, 0x29, 30, 15, 0, 0, 0),
        "defaults"
    )
    expect(
        PhoneStatus(
            batteryPercent: 70, signalLevel: 4, hour: 14, minute: 5, second: 30,
            missedCallAlert: true, callState: .incoming, smsFlag: true, smsCount: 2, missedCount: 3
        ).encode(),
        bytes(0x1E, 0x4C, 0x3D, 0x05, 0x0E, 0x32, 0x00, 0x00),
        "spec incoming"
    )
    expect(
        PhoneStatus(
            batteryPercent: 90, signalLevel: 3, hour: 14, minute: 6, second: 0,
            headset: true, callState: .active, callDurationS: 125
        ).encode(),
        bytes(0x25, 0x1B, 0x01, 0x06, 0x0E, 0x00, 0x00, 0x7D),
        "spec active"
    )

    let bars: [(Int?, Int)] = [
        (0, 4), (1, 0), (19, 0), (20, 1), (39, 1), (40, 2), (59, 2),
        (60, 3), (79, 3), (80, 4), (100, 4), (101, 4), (-5, 4), (nil, 4),
    ]
    for (percent, want) in bars {
        let actual = Int(PhoneStatus(batteryPercent: percent, signalLevel: 0, hour: 0, minute: 0, second: 0).encode()[0] >> 3)
        eq(actual, want, "battery \(String(describing: percent))%")
    }

    for state in TcuCallState.allCases {
        let actual = Int(PhoneStatus(batteryPercent: 50, signalLevel: 0, hour: 0, minute: 0, second: 0, callState: state).encode()[1])
        eq(actual, state.rawValue << 3, "call state \(state)")
    }
    eq(TcuCallState.allCases.filter { $0.showsCaller }, [.incoming, .outgoing, .active], "caller states")

    let active = PhoneStatus(batteryPercent: 50, signalLevel: 0, hour: 0, minute: 0, second: 0, callState: .active, callDurationS: 3725).encode()
    eq(Int(active[6]), 0x0E, "duration hi")
    eq(Int(active[7]), 0x8D, "duration lo")
    let long = PhoneStatus(batteryPercent: 50, signalLevel: 0, hour: 0, minute: 0, second: 0, callState: .active, callDurationS: 70_000).encode()
    eq(Int(long[6]), 0xFF, "duration clamp hi")
    eq(Int(long[7]), 0xFF, "duration clamp lo")
    let ended = PhoneStatus(batteryPercent: 50, signalLevel: 0, hour: 0, minute: 0, second: 0, callState: .ended, callDurationS: 125).encode()
    eq(Int(ended[6]), 0, "ended duration hi")
    eq(Int(ended[7]), 0, "ended duration lo")

    eq(
        Int(PhoneStatus(batteryPercent: 50, signalLevel: 0, hour: 0, minute: 0, second: 0, smsCount: 16, missedCount: 3).encode()[5]),
        0x3F,
        "unmasked SMS would spill"
    )
    eq(Int(PhoneStatus(batteryPercent: 50, signalLevel: 0, hour: 0, minute: 0, second: 0, smsCount: -1, missedCount: 40).encode()[5]), 0xF0, "count clamps")
}

func runCallerInfo() {
    expect(
        CallerInfo("+91 98765 43210").encode(),
        bytes(0x2B, 0x39, 0x31, 0x20, 0x39, 0x38, 0x37, 0x36, 0x35, 0x20, 0x34, 0x33, 0x32, 0x31),
        "spec number"
    )
    expect(
        CallerInfo("Mom", "9876543210").encode(),
        bytes(0x4D, 0x6F, 0x6D, 0, 0, 0, 0, 0x39, 0x38, 0x37, 0x36, 0x35, 0x34, 0x33),
        "spec two-field"
    )
    expect(CallerInfo("Ravi").encode(), ascii("Ravi", 14), "padded")
    expect(CallerInfo("Abcdefghijklmn").encode(), ascii("Abcdefghijklmn", 14), "exactly 14")
    expect(CallerInfo("Dr. O'Brien (Work)").encode(), ascii("Dr_ O_Brien _W", 14), "punctuation")
    expect(CallerInfo("Mom 😀!").encode(), ascii("Mom __", 14), "emoji is one code point")
    expect(CallerInfo("राम").encode(), ascii("???", 14), "devanagari")
    expect(CallerInfo("José Müller").encode(), ascii("Jose Muller", 14), "accents")
    expect(CallerInfo("Jose\u{0301}").encode(), ascii("Jose", 14), "decomposed accent")
    expect(CallerInfo("A\tB C").encode(), ascii("A B C", 14), "whitespace")
    eq(CallerInfo("x").encode().count, CallerInfo.length, "single field length")
    eq(CallerInfo("x", "y").encode().count, CallerInfo.length, "two field length")

    eq(CallerInfo.forCall(name: "  Amma ", number: "+91 98765 43210"), CallerInfo("Amma"), "contact name wins")
    eq(CallerInfo.forCall(name: nil, number: "+91 98765 43210"), CallerInfo("+919876543210"), "number fallback")
    expect(CallerInfo.forCall(name: "", number: "+91-98765-43210")!.encode(), ascii("+919876543210", 14), "clean number")
    eq(CallerInfo.forCall(name: "UnKnown", number: "(040) 2345 6789"), CallerInfo("04023456789"), "unknown is not a name")
    check(CallerInfo.forCall(name: nil, number: nil) == nil, "nothing to show")
    check(CallerInfo.forCall(name: " ", number: "Private") == nil, "private number")
    expect(CallerInfo.forCall(name: "+91 98765 43210", number: nil)!.encode(), ascii("+919876543210", 14), "number-like name")
    eq(CallerInfo.forCall(name: "(040) 2345-6789", number: nil), CallerInfo("04023456789"), "formatted number name")
    eq(CallerInfo.forCall(name: "Dr. Rao 2", number: nil), CallerInfo("Dr. Rao 2"), "name with one digit")
    eq(CallerInfo.forCall(name: "911", number: nil), CallerInfo("911"), "short number")
}

func runMusicInfo() {
    expect(MusicInfo.of(playbackState: 3, volume: 7).encode(), bytes(0x38, 0x00, 0x01), "playing vol 7")
    expect(MusicInfo.of(playbackState: 2, volume: 10).encode(), bytes(0xD0, 0x00, 0x01), "paused vol 10")
    expect(MusicInfo.of(playbackState: 1, volume: 10).encode(), bytes(0xD0, 0x00, 0x00), "stopped vol 10")
    expect(MusicInfo.of(playbackState: 6, volume: 7).encode(), bytes(0x38, 0x00, 0x01), "buffering")
    for state in [nil, 0, 7] as [Int?] {
        expect(MusicInfo.of(playbackState: state, volume: 10).encode(), bytes(0xD0, 0x00, 0x00), "inactive \(String(describing: state))")
    }
    for state in [4, 5, 8, 9, 10, 11] {
        expect(MusicInfo.of(playbackState: state, volume: 4).encode(), bytes(0x20, 0x00, 0x01), "transient \(state)")
    }
    expect(MusicInfo.of(playbackState: 3, volume: 5, elapsedPercent: 42).encode(), bytes(0x28, 42, 0x01), "progress")
    expect(MusicInfo(active: true, playing: true, volume: 99, elapsedPercent: 300).encode(), bytes(0x78, 0xFF, 0x01), "clamped")
    expect(MusicInfo(active: false, playing: true, volume: -1).encode(), bytes(0x00, 0x00, 0x00), "initial all-zero")

    eq(MusicInfo.volumeLevel(current: 7, max: 15), 5, "volume 7/15")
    eq(MusicInfo.volumeLevel(current: 1, max: 15), 1, "volume 1/15")
    eq(MusicInfo.volumeLevel(current: 15, max: 15), 10, "volume 15/15")
    eq(MusicInfo.volumeLevel(current: 0, max: 15), 0, "volume 0/15")
    eq(MusicInfo.volumeLevel(current: 20, max: 15), 10, "volume over max")
    eq(MusicInfo.volumeLevel(current: 5, max: 0), 0, "volume max 0")

    eq(MusicInfo.progressPercent(positionMs: 30_000, durationMs: 120_000), 25, "progress 25")
    eq(MusicInfo.progressPercent(positionMs: 0, durationMs: 0), 0, "progress unknown duration")
    eq(MusicInfo.progressPercent(positionMs: 200_000, durationMs: 120_000), 100, "progress clamped")
    eq(MusicInfo.progressPercent(positionMs: -5, durationMs: 100), 0, "progress negative")
}

func runMusicMeta() {
    expect(
        MusicMeta("Believer", "Imagine Dragons").encode(),
        bytes(
            0x42, 0x65, 0x6C, 0x69, 0x65, 0x76, 0x65, 0x72, 0, 0, 0, 0, 0, 0,
            0x49, 0x6D, 0x61, 0x67, 0x69, 0x6E, 0x65, 0x20, 0x44, 0x72, 0x61, 0x67, 0x6F, 0x6E
        ),
        "spec song"
    )
    expect(MusicMeta.clear.encode(), [UInt8](repeating: 0, count: 28), "no music")
    expect(MusicMeta("Don't Stop Me Now", "Queen").encode(), ascii("Dont Stop Me N", 14) + ascii("Queen", 14), "removed")
    expect(MusicMeta("Café del Mar (Remix)", "Beyoncé").encode(), ascii("Cafe del Mar R", 14) + ascii("Beyonce", 14), "accents")
    expect(MusicMeta("Tum Hi Ho – Live", "🎵 Arijit").encode(), ascii("Tum Hi Ho  Liv", 14) + ascii(" Arijit", 14), "symbols")

    eq(MusicMeta.of(title: "T", artist: nil, album: "Album"), MusicMeta("T", "Album"), "album fallback")
    eq(MusicMeta.of(title: "T", artist: " ", album: "Album"), MusicMeta("T", "Album"), "blank artist")
    eq(MusicMeta.of(title: "T", artist: "Artist", album: "Album"), MusicMeta("T", "Artist"), "artist wins")
    eq(MusicMeta.of(title: nil, artist: nil, album: nil), MusicMeta.clear, "empty metadata")
}

func runVoiceAssist() {
    expect(VoiceAssistState.listening.encode(), bytes(0x01), "listening")
    expect(VoiceAssistState.noAction.encode(), bytes(0x00), "idle")
    eq(VoiceAssistState.allCases.map { $0.rawValue }, Array(0...5), "voice states")
}

func runHardControl() {
    func events(_ values: Int...) -> [HardControlEvent] {
        HardControlFrame.parse(values.map { UInt8(truncatingIfNeeded: $0) })?.events ?? []
    }

    eq(events(0xF1, 0x38, 0x00), [.callAccept], "accept only")
    var accepted = HardControlFrame.noAction
    accepted.callAction = 1
    check(HardControlFrame.parse(bytes(0xF1, 0x38, 0x00)) == accepted, "accept frame equality")
    expect(HardControlFrame.noAction.encode(), bytes(0xF0, 0x38, 0x00), "no action")
    check(HardControlFrame.parse(HardControlFrame.noAction.encode())!.events.isEmpty, "no action events")

    eq(events(0, 0, 0), [.callVolumeUp, .musicVolumeUp, .musicPlayPause], "zero is a real action")
    eq(events(0xF2, 0x38, 0), [.callReject], "reject")
    eq(events(0xC0, 0x38, 0), [.callVolumeUp], "call volume up")
    eq(events(0xD0, 0x38, 0), [.callVolumeDown], "call volume down")
    eq(events(0x30, 0x38, 0), [.musicVolumeUp], "music volume up")
    eq(events(0x70, 0x38, 0), [.musicVolumeDown], "music volume down")
    eq(events(0xF0, 0x00, 0), [.musicPlayPause], "play pause")
    eq(events(0xF0, 0x08, 0), [.musicNext], "next")
    eq(events(0xF0, 0x10, 0), [.musicPrevious], "previous")
    eq(events(0xF0, 0x18, 0), [.musicMute], "mute")
    eq(events(0xF0, 0x38, 1), [.voiceStart], "voice start")
    eq(events(0xF0, 0x38, 2), [.voiceCancel], "voice cancel")

    eq(events(0xA3, 0x20, 3), [], "unmapped fields")
    eq(events(0xFF, 0x3F, 0xFF), [], "all unmapped")

    let sms = HardControlFrame.parse(bytes(0xF0, 0xFF, 0x00))!
    eq(sms.musicDataConfig, 7, "music data config")
    eq(sms.smsTrigger, 3, "sms trigger")
    eq(sms.musicControl, 7, "music control")
    eq(sms.events, [], "config is not an event")

    check(HardControlFrame.parse(bytes(0xF1, 0x38)) == nil, "short frame ignored")
    check(HardControlFrame.parse([]) == nil, "empty frame ignored")
    eq(events(0xF1, 0x38, 0x00, 0xFF), [.callAccept], "extra bytes ignored")

    outer: for b0 in 0..<256 {
        for b1 in 0..<256 {
            for b2 in 0..<8 {
                let frame = HardControlFrame.parse([UInt8(b0), UInt8(b1), UInt8(b2)])!
                let ok = frame.callAction == (b0 & 15)
                    && frame.callVolume == ((b0 >> 4) & 3)
                    && frame.musicVolume == ((b0 >> 6) & 3)
                    && frame.musicDataConfig == (b1 & 7)
                    && frame.musicControl == ((b1 >> 3) & 7)
                    && frame.smsTrigger == ((b1 >> 6) & 3)
                    && frame.voiceControl == b2
                    && frame.encode() == [UInt8(b0), UInt8(b1), UInt8(b2)]
                if !ok {
                    check(false, "hard control decode mismatch for \(b0) \(b1) \(b2)")
                    break outer
                }
            }
        }
    }

    let accept = bytes(0xF1, 0x38, 0x00)
    let idle = HardControlFrame.noAction.encode()
    let debouncer = HardControlDebouncer()
    check(debouncer.accept(accept, now: 1_000), "debounce first")
    check(!debouncer.accept(accept, now: 1_100), "debounce 100 ms")
    check(!debouncer.accept(accept, now: 1_350), "debounce sliding")
    check(debouncer.accept(accept, now: 1_700), "debounce window passed")
    check(debouncer.accept(idle, now: 1_710), "different frame")
    check(debouncer.accept(accept, now: 1_720), "re-armed")
    check(debouncer.accept(accept, now: 1_000), "clock backwards")
}

func runText() {
    eq(IcbtText.sanitize("a+b c", replacement: "_"), "a+b c", "allowed characters")
    eq(IcbtText.sanitize("a/b-c", replacement: ""), "abc", "removed characters")
    eq(IcbtText.sanitize("x😀y", replacement: "_"), "x_y", "emoji")
    expect(IcbtText.encode("abc", length: 2, replacement: "_"), ascii("ab", 2), "truncate")
    eq(String(decoding: NavFrame.roadBytes("MG Road/NH-65"), as: UTF8.self), "MG Road_NH_65\u{0}", "road punctuation")
    eq(String(decoding: NavFrame.roadBytes("Śivājī Nagar"), as: UTF8.self), "Sivaji Nagar\u{0}\u{0}", "road accents")
}

func runNavFrame() {
    let exit = NavFrame.exit.encode()
    eq(exit.count, 27, "exit length")
    eq(exit[0], 0xC1, "exit first byte")
    eq(Int(exit[4]), NavTurn.straight, "exit turn")
    eq(exit[0] & 0x04, 0, "exit inactive")

    let frame = NavFrame(
        active: true, turn: NavTurn.left, distanceMeters: 250, nextTurn: NavTurn.right,
        arrivalHour24: 14, arrivalMinute: 5, remainingMeters: 12_300, remainingMinutes: 42, road: "MG Road"
    ).encode()
    eq(frame.count, 27, "nav length")
    eq(Int(frame[0] & 0x01), 1, "nav metres unit")
    eq(Int((frame[0] >> 2) & 1), 1, "nav active")
    eq(Int(frame[0] >> 4), 2, "nav 12h hour")
    eq(Int(frame[5] >> 4), 1, "nav PM")
    eq(Int(frame[2]) << 8 | Int(frame[3]), 250, "nav turn distance")
    eq(Int(frame[4]), NavTurn.left, "nav turn symbol")
    eq(Int(frame[8]) << 8 | Int(frame[9]), 123, "nav remaining tenths")
    eq(Int(frame[10]), 42, "nav remaining minutes")
}

runUUIDs()
runPhoneStatus()
runCallerInfo()
runMusicInfo()
runMusicMeta()
runVoiceAssist()
runHardControl()
runText()
runNavFrame()
runRideMath()
runRange()
runNavigation()
runBatteryAnalytics()
runSession()
runRideRecorder()
runGattResolution()

if failures == 0 {
    print("RutaTests: all checks passed")
    exit(0)
} else {
    print("RutaTests: \(failures) failure(s)")
    exit(1)
}
