import Foundation
import RutaCore

// Android's characteristic lookup rules: stats prefer a plaintext service, everything else prefers
// the INFO service, duplicates fall back to the last match. The iOS transport must resolve the same
// instance on a TCU that exposes duplicates (the encrypted command service is a fallback only).

func runGattResolution() {
    func match(_ service: String, _ characteristic: String) -> GattResolution.Found {
        GattResolution.Found(service: service, characteristic: characteristic)
    }

    let info = Tcu.infoService
    let command = Tcu.commandService
    let icbt = Tcu.icbtService
    let plain = "f453986a-0000-1000-8000-00805f9b34fb"

    // Non-stats: the INFO service wins over the same UUID elsewhere.
    let phone = GattResolution.resolve([
        match(icbt, Tcu.phoneState),
        match(info, Tcu.phoneState),
    ])
    eq(phone[Tcu.phoneState]?.service, info, "non-stats: INFO service wins")

    // Stats: a plaintext service wins over the encrypted command service.
    let stats = GattResolution.resolve([
        match(command, Tcu.statsRequest),
        match(plain, Tcu.statsRequest),
    ])
    eq(stats[Tcu.statsRequest]?.service, plain, "stats: plaintext wins over command")

    // Stats: the command service is used when it is the only place they exist.
    let onlyCommand = GattResolution.resolve([match(command, Tcu.statsUpdate)])
    eq(onlyCommand[Tcu.statsUpdate]?.service, command, "stats: command fallback")

    // Duplicates across plaintext services: the last match wins, like Android's lastOrNull.
    let duplicate = GattResolution.resolve([
        match(plain, Tcu.statsUpdate),
        match(icbt, Tcu.statsUpdate),
    ])
    eq(duplicate[Tcu.statsUpdate]?.service, icbt, "stats: last plaintext match")

    // Everything else resolves from wherever it lives.
    let nav = GattResolution.resolve([match(icbt, Tcu.navInfo)])
    eq(nav[Tcu.navInfo]?.service, icbt, "non-stats: ICBT channel found")

    // Non-stats fallback: INFO first, then the last match anywhere.
    let withInfo = GattResolution.resolve([
        match(info, Tcu.phoneHeartbeat),
        match(icbt, Tcu.phoneHeartbeat),
        match(plain, Tcu.phoneHeartbeat),
    ])
    eq(withInfo[Tcu.phoneHeartbeat]?.service, info, "non-stats: INFO beats later duplicates")
    let withoutInfo = GattResolution.resolve([
        match(icbt, Tcu.vehicleState),
        match(plain, Tcu.vehicleState),
    ])
    eq(withoutInfo[Tcu.vehicleState]?.service, plain, "non-stats: last match fallback")

    // One entry per characteristic, nothing invented.
    eq(phone.count, 1, "one resolution for one UUID")
    check(GattResolution.resolve([]).isEmpty, "empty discovery resolves to nothing")

    // Included-service traversal: every unique service is visited exactly once, including nested
    // services; cycles and duplicate include edges cannot inflate the callback count.
    eq(GattTraversal.order(primary: ["a", "b"], included: [:]), ["a", "b"],
       "primary-only traversal has one callback per service")
    eq(GattTraversal.order(primary: ["a"], included: ["a": ["b"], "b": ["c"]]), ["a", "b", "c"],
       "nested included services are traversed")
    eq(GattTraversal.order(primary: ["a"], included: ["a": ["b", "b"], "b": ["a", "c"]]),
       ["a", "b", "c"], "cycles and duplicate edges are ignored")
}
