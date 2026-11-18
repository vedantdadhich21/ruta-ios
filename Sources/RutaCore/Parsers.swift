import Foundation

public struct TcuInfo: Equatable, Sendable {
    public let imei: String
    public let vin: String
    public let firmware: String
    public let bleProtocol: String
    public let hardware: String

    public init(imei: String, vin: String, firmware: String, bleProtocol: String, hardware: String) {
        self.imei = imei
        self.vin = vin
        self.firmware = firmware
        self.bleProtocol = bleProtocol
        self.hardware = hardware
    }
}

public struct VehicleState: Equatable, Sendable {
    public let ignitionOn: Bool
    public let immobilised: Bool
    public let handleLocked: Bool
    public let rideMode: Int
    public let regenLevel: Int
    public let accelerationLevel: Int
    public let speedLimit: Int
    public let time: Int64

    public init(
        ignitionOn: Bool, immobilised: Bool, handleLocked: Bool,
        rideMode: Int, regenLevel: Int, accelerationLevel: Int, speedLimit: Int, time: Int64
    ) {
        self.ignitionOn = ignitionOn
        self.immobilised = immobilised
        self.handleLocked = handleLocked
        self.rideMode = rideMode
        self.regenLevel = regenLevel
        self.accelerationLevel = accelerationLevel
        self.speedLimit = speedLimit
        self.time = time
    }
}

/// Raw service-four BMS frame (tag 1). Units are inferred by the decoder layer.
public struct BmsFrame: Equatable, Sendable {
    public let soh: Int
    public let soc: Int
    public let packTemp: Int
    public let chargeTimeRaw: Int
    public let bmsStatus: Int
    public let pack1Status: Int
    public let pack2Status: Int
    public let pack1Soh: Int
    public let pack1Soc: Int
    public let pack1Soe: Int
    public let pack1Temp: Int
    public let pack2Soh: Int
    public let pack2Soc: Int
    public let pack2Soe: Int
    public let pack2Temp: Int

    public init(
        soh: Int, soc: Int, packTemp: Int, chargeTimeRaw: Int,
        bmsStatus: Int, pack1Status: Int, pack2Status: Int,
        pack1Soh: Int, pack1Soc: Int, pack1Soe: Int, pack1Temp: Int,
        pack2Soh: Int, pack2Soc: Int, pack2Soe: Int, pack2Temp: Int
    ) {
        self.soh = soh
        self.soc = soc
        self.packTemp = packTemp
        self.chargeTimeRaw = chargeTimeRaw
        self.bmsStatus = bmsStatus
        self.pack1Status = pack1Status
        self.pack2Status = pack2Status
        self.pack1Soh = pack1Soh
        self.pack1Soc = pack1Soc
        self.pack1Soe = pack1Soe
        self.pack1Temp = pack1Temp
        self.pack2Soh = pack2Soh
        self.pack2Soc = pack2Soc
        self.pack2Soe = pack2Soe
        self.pack2Temp = pack2Temp
    }

    /// A frame with selected fields replaced (the Kotlin tests' `copy`).
    public func copy(
        soh: Int? = nil, soc: Int? = nil, packTemp: Int? = nil, chargeTimeRaw: Int? = nil,
        bmsStatus: Int? = nil, pack1Status: Int? = nil, pack2Status: Int? = nil,
        pack1Soh: Int? = nil, pack1Soc: Int? = nil, pack1Soe: Int? = nil, pack1Temp: Int? = nil,
        pack2Soh: Int? = nil, pack2Soc: Int? = nil, pack2Soe: Int? = nil, pack2Temp: Int? = nil
    ) -> BmsFrame {
        BmsFrame(
            soh: soh ?? self.soh, soc: soc ?? self.soc, packTemp: packTemp ?? self.packTemp,
            chargeTimeRaw: chargeTimeRaw ?? self.chargeTimeRaw,
            bmsStatus: bmsStatus ?? self.bmsStatus,
            pack1Status: pack1Status ?? self.pack1Status,
            pack2Status: pack2Status ?? self.pack2Status,
            pack1Soh: pack1Soh ?? self.pack1Soh, pack1Soc: pack1Soc ?? self.pack1Soc,
            pack1Soe: pack1Soe ?? self.pack1Soe, pack1Temp: pack1Temp ?? self.pack1Temp,
            pack2Soh: pack2Soh ?? self.pack2Soh, pack2Soc: pack2Soc ?? self.pack2Soc,
            pack2Soe: pack2Soe ?? self.pack2Soe, pack2Temp: pack2Temp ?? self.pack2Temp
        )
    }
}

public enum TcuParser {
    private static func u8(_ data: [UInt8], _ index: Int) -> Int {
        Int(data[index])
    }

    private static func u16(_ data: [UInt8], _ index: Int) -> Int {
        (u8(data, index) << 8) | u8(data, index + 1)
    }

    /// ASCII slice trimmed of leading/trailing control characters and NULs.
    private static func ascii(_ data: [UInt8], _ from: Int, _ length: Int) -> String {
        guard from < data.count else { return "" }
        var start = from
        var end = min(from + length, data.count)
        while start < end && (data[start] <= 32 || data[start] == 0) { start += 1 }
        while end > start && (data[end - 1] <= 32 || data[end - 1] == 0) { end -= 1 }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    /// TCU info (0x0101): 53+ bytes. IMEI 15, VIN 17, firmware 3, BLE protocol 4, hardware 1, part 13.
    public static func info(_ data: [UInt8]) -> TcuInfo? {
        guard data.count >= 53 else { return nil }
        let hardware = (ascii(data, 39, 1) + " " + ascii(data, 40, 13))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TcuInfo(
            imei: ascii(data, 0, 15),
            vin: ascii(data, 15, 17),
            firmware: "\(u8(data, 32)).\(u8(data, 33)).\(u8(data, 34))",
            bleProtocol: "\(u8(data, 36)).\(u8(data, 37)).\(u8(data, 38))",
            hardware: hardware
        )
    }

    /// Vehicle state (0x0105): 6 bytes.
    public static func vehicleState(_ data: [UInt8], time: Int64) -> VehicleState? {
        guard data.count >= 6 else { return nil }
        let flags = u8(data, 0)
        return VehicleState(
            ignitionOn: ((flags >> 7) & 1) == 1,
            immobilised: ((flags >> 6) & 1) == 1,
            handleLocked: ((flags >> 2) & 15) == 1,
            rideMode: u8(data, 2) >> 4,
            regenLevel: u8(data, 3) >> 4,
            accelerationLevel: u8(data, 3) & 15,
            speedLimit: u8(data, 4),
            time: time
        )
    }

    /// Service-four BMS frame: tag 1 followed by 25 bytes (26 in total).
    public static func bms(_ data: [UInt8]) -> BmsFrame? {
        guard data.count >= 26, u8(data, 0) == Tcu.tagBms else { return nil }
        return BmsFrame(
            soh: u16(data, 1),
            soc: u16(data, 3),
            packTemp: u16(data, 5),
            chargeTimeRaw: (u8(data, 7) << 4) | (u8(data, 8) >> 4),
            bmsStatus: u8(data, 8) & 15,
            pack1Status: u8(data, 9) >> 4,
            pack2Status: u8(data, 9) & 15,
            pack1Soh: u16(data, 10),
            pack1Soc: u16(data, 12),
            pack1Soe: u16(data, 14),
            pack1Temp: u16(data, 16),
            pack2Soh: u16(data, 18),
            pack2Soc: u16(data, 20),
            pack2Soe: u16(data, 22),
            pack2Temp: u16(data, 24)
        )
    }
}

public extension Collection where Element == UInt8 {
    /// Uppercase space-separated hex, the format used in the Android diagnostics log.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
