import SwiftUI
import RutaCore

/// Scooter details, settings, the diagnostics log and the app's notes.
public struct MoreScreen: View {
    @Environment(RutaModel.self) private var model
    @State private var renameText = ""
    @State private var showRename = false
    @State private var confirmForget = false
    @State private var showConnect = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scooterCard
                    settings
                    diagnosticsCard
                    alertsCard
                    about
                }
                .padding(16)
            }
            .background(RutaTheme.background)
            .navigationTitle("More")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showConnect = true } label: { Image(systemName: "scooter") }
                }
            }
            .sheet(isPresented: $showConnect) { ConnectSheet() }
            .alert("Name this scooter", isPresented: $showRename) {
                TextField("e.g. Vida at home", text: $renameText)
                Button("Save") {
                    if let scooter = model.saved.first(where: { $0.displayName == model.connectedName }) {
                        model.rename(scooter, nickname: renameText)
                    } else if let scooter = model.saved.first {
                        model.rename(scooter, nickname: renameText)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Forget this scooter?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) {
                    if let scooter = model.saved.first {
                        model.forget(scooter)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Ruta stops connecting to it. The Bluetooth pairing stays in iOS Settings until you forget it there too.")
            }
        }
    }

    private var scooterCard: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(
                        color: model.isConnected ? RutaTheme.primary : RutaTheme.outline,
                        pulsing: model.reconnecting || model.phase == .connecting
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.connectedName ?? "No scooter connected")
                            .font(.headline)
                        Text(model.statusText)
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                if let info = model.info {
                    Divider().overlay(RutaTheme.outlineVariant)
                    InfoRow("Firmware", info.firmware)
                    InfoRow("BLE protocol", info.bleProtocol)
                    InfoRow("Hardware", info.hardware)
                    InfoRow("VIN", info.vin)
                    InfoRow("IMEI", info.imei)
                }
                if let vehicle = model.vehicle {
                    Divider().overlay(RutaTheme.outlineVariant)
                    InfoRow("Ignition", vehicle.ignitionOn ? "On" : "Off")
                    InfoRow("Ride mode", "\(vehicle.rideMode)")
                    InfoRow("Regen", "\(vehicle.regenLevel)")
                    InfoRow("Acceleration", "\(vehicle.accelerationLevel)")
                    InfoRow("Speed limit", "\(vehicle.speedLimit) km/h")
                }
                HStack(spacing: 10) {
                    Button {
                        model.refreshLive()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isConnected)
                    Button {
                        renameText = model.connectedName ?? ""
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.saved.isEmpty)
                    Spacer()
                    if model.isConnected || model.reconnecting {
                        Button("Disconnect") { model.disconnect() }
                            .buttonStyle(.bordered)
                            .tint(RutaTheme.error)
                    }
                }
                if !model.saved.isEmpty {
                    Button(role: .destructive) {
                        confirmForget = true
                    } label: {
                        Text("Forget scooter").font(.caption)
                    }
                }
                if let handle = model.lastHandlebar {
                    Divider().overlay(RutaTheme.outlineVariant)
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap")
                        Text("Last handlebar: \(handle)")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
        }
    }

    private var settings: some View {
        @Bindable var model = model
        return RutaCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("Settings")
                Toggle(isOn: $model.navigationEnabled) {
                    settingLabel("Turn-by-turn on the cluster", "Sends the next turn while navigating in Ruta")
                }
                .tint(RutaTheme.primary)
                Toggle(isOn: $model.announceCharge) {
                    settingLabel("Charge alerts", "Notify at the charge target and if charging stops")
                }
                .tint(RutaTheme.primary)
                HStack {
                    settingLabel("Charge target", "Alert level")
                    Spacer()
                    Picker("Charge target", selection: $model.chargeTarget) {
                        Text("80 %").tag(80)
                        Text("90 %").tag(90)
                        Text("Full").tag(100)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                Toggle(isOn: $model.unitMiles) {
                    settingLabel("Miles", "Show distances and speed in miles")
                }
                .tint(RutaTheme.primary)
                Toggle(isOn: $model.demoMode) {
                    settingLabel("Demo mode", "Simulated scooter and sample rides")
                }
                .tint(RutaTheme.primary)
                if model.demoMode {
                    Text("Turn demo mode off before pairing a real scooter.")
                        .font(.caption2)
                        .foregroundStyle(RutaTheme.tertiary)
                }
            }
        }
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
        }
    }

    private var diagnosticsCard: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Diagnostics")
                    Spacer()
                    ShareLink(item: model.diagnostics.export(), subject: Text("Ruta diagnostics")) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let lines = model.diagnostics.export().split(separator: "\n").suffix(8)
                    VStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("Nothing logged yet.")
                                .font(.caption2)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(String(line))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                                .lineLimit(1)
                        }
                    }
                }
                HStack {
                    Text("\(model.diagnostics.count) lines")
                        .font(.caption2)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                    Spacer()
                    Button("Clear") { model.diagnostics.clear() }
                        .font(.caption)
                }
            }
        }
    }

    private var alertsCard: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Alerts")
                if model.alertLog.isEmpty {
                    Text("Charge, range and ride alerts appear here.")
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                } else {
                    ForEach(Array(model.alertLog.prefix(6).enumerated()), id: \.offset) { _, alert in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title).font(.subheadline.weight(.medium))
                            Text(alert.line)
                                .font(.caption)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }

    private var about: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("About")
                Text("Ruta \(version)")
                    .font(.subheadline.weight(.semibold))
                Text("An independent companion for Vida scooters, ported from the open-source Android app CODESURGEN/ruta. Not affiliated with or endorsed by Hero MotoCorp or Vida.")
                    .font(.caption)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                Text("Apache License 2.0. The original project's licence and notice are included in the app's source. Your data stays on this iPhone; Apple Maps receives route searches.")
                    .font(.caption2)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                Link(destination: URL(string: "https://github.com/CODESURGEN/ruta")!) {
                    Label("Original Android project", systemImage: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(RutaTheme.primary)
                }
                Link(destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!) {
                    Label("Apache License 2.0", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(RutaTheme.primary)
                }
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "1.0"
        }
    }
}
