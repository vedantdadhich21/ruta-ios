import SwiftUI
import RutaCore

/// Live dashboard: speed, charge, range, the current ride and the next turn.
public struct HomeScreen: View {
    @Environment(RutaModel.self) private var model
    @State private var showConnect = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if model.isConnected || model.reconnecting {
                        hero
                    } else {
                        connectCard
                    }
                    if model.navigation.isNavigating {
                        TurnCard(
                            turn: model.navigation.turn,
                            distance: model.navigation.maneuverText,
                            instruction: model.navigation.instruction,
                            road: model.navigation.road,
                            remaining: model.navigation.remainingText,
                            arrival: model.navigation.arrivalText
                        )
                    }
                    if model.demoMode {
                        demoBanner
                    }
                    metrics
                    if model.ride.riding || model.ride.charging != nil {
                        rideCard
                    }
                    packsCard
                    if !model.alertLog.isEmpty {
                        recentAlerts
                    }
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background(RutaTheme.background)
            .navigationTitle("Ruta")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showConnect = true
                    } label: {
                        Image(systemName: model.isConnected ? "scooter" : "scooter")
                    }
                }
            }
            .sheet(isPresented: $showConnect) {
                ConnectSheet()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(
                color: model.isConnected ? RutaTheme.primary : (model.reconnecting ? RutaTheme.warning : RutaTheme.outline),
                pulsing: model.phase == .connecting || model.reconnecting
            )
            Text(model.connectedName ?? "No scooter")
                .font(.subheadline.weight(.semibold))
            if model.demoMode {
                RutaChip("DEMO", tint: RutaTheme.tertiary)
            }
            Spacer()
            if model.bmsState != .unknown {
                RutaChip(model.bmsState.label, tint: model.bmsState == .drive ? RutaTheme.primary : RutaTheme.onSurfaceVariant)
            }
        }
    }

    private var connectCard: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "scooter")
                        .font(.system(size: 34))
                        .foregroundStyle(RutaTheme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.reconnecting ? "Reconnecting…" : "Connect your scooter")
                            .font(.title3.weight(.semibold))
                        Text(model.statusText)
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                            .lineLimit(2)
                    }
                }
                Button {
                    showConnect = true
                } label: {
                    Label("Find my scooter", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(RutaPrimaryButtonStyle())
                Text("Keep the scooter on and the official app closed. The first pairing asks for the scooter's PIN in iOS's own sheet.")
                    .font(.caption2)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
            }
        }
    }

    private var hero: some View {
        RutaCard(padding: 20) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.speedText(model.ride.speedKmh))
                        .font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(RutaTheme.onSurface)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(model.speedUnit)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                    if model.ride.riding {
                        Label("Ride in progress", systemImage: "record.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RutaTheme.primary)
                            .padding(.top, 8)
                    } else if model.vehicle?.ignitionOn == true {
                        Label("Ignition on", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                            .padding(.top, 8)
                    } else if model.phase == .connecting {
                        Label("Preparing link…", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                            .padding(.top, 8)
                    }
                }
                Spacer(minLength: 4)
                VStack(spacing: 8) {
                    BatteryRing(
                        percent: model.latestSoc,
                        size: 112,
                        lineWidth: 9,
                        charging: model.ride.charging != nil
                    )
                    if let range = model.range {
                        Text("\(Int(range.km.rounded())) km" + (range.estimated ? " est." : ""))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "testtube.2")
            Text("Demo mode — simulated scooter, sample history")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(RutaTheme.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(RutaTheme.tertiary.opacity(0.1)))
    }

    private var metrics: some View {
        RutaCard {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(
                        "Range",
                        model.range.map { String(format: "%.0f", $0.km) } ?? "—",
                        unit: "km" + ((model.range?.estimated ?? true) ? " est." : ""),
                        color: RutaTheme.primary
                    )
                    StatTile(
                        "Charge",
                        model.latestSoc.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "%",
                        color: RutaTheme.battery(model.latestSoc)
                    )
                    StatTile(
                        "Pack temp",
                        model.value(pack: 0, .temperature).map { String(format: "%.1f", $0) } ?? "—",
                        unit: "°C",
                        color: RutaTheme.onSurface
                    )
                }
                Divider().overlay(RutaTheme.outlineVariant)
                HStack(spacing: 12) {
                    StatTile(
                        "Health",
                        model.value(pack: 0, .health).map { String(format: "%.1f", $0) } ?? "—",
                        unit: "%"
                    )
                    StatTile("BMS", model.bmsState.label)
                    StatTile(
                        "Efficiency",
                        String(format: "%.2f", model.efficiency.kmPerPercent),
                        unit: "km / %",
                        color: model.efficiency.learned ? RutaTheme.tertiary : RutaTheme.onSurface
                    )
                }
                if let eta = model.fullChargeEta {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").foregroundStyle(RutaTheme.charging)
                        Text(eta).font(.subheadline.weight(.medium))
                        Spacer()
                        if let session = model.ride.charging {
                            Text(String(format: "+%.0f %%", session.gained))
                                .font(.caption)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }

    private var rideCard: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle("This ride")
                    Spacer()
                    if let charging = model.ride.charging {
                        RutaChip(String(format: "CHARGING +%.0f%%", charging.gained), tint: RutaTheme.charging)
                    }
                }
                HStack(spacing: 12) {
                    StatTile("Distance", model.distanceValueText(model.ride.distanceM),
                             unit: model.unitMiles ? "mi" : "km", color: RutaTheme.primary)
                    StatTile("Time", RideMath.formatDuration(seconds: model.ride.durationS))
                    StatTile("Average", model.speedText(model.ride.averageKmh), unit: model.speedUnit)
                    StatTile("Peak", model.speedText(model.ride.peakKmh), unit: model.speedUnit)
                }
                HStack(spacing: 6) {
                    Image(systemName: model.ride.gps == .fix ? "location.fill" : "location.slash")
                    Text(model.ride.gps.rawValue)
                    Spacer()
                    if let start = model.ride.socStart {
                        Text(String(format: "started at %.0f %%", start))
                    }
                }
                .font(.caption)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
            }
        }
    }

    private var packsCard: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle("Batteries")
                    Spacer()
                    Button("Battery tab") { model.tab = .battery }
                        .font(.caption.weight(.semibold))
                }
                ForEach(Array(model.packs.prefix(3)), id: \.self) { pack in
                    HStack(spacing: 10) {
                        Text(pack == 0 ? "Total" : "Pack \(pack)")
                            .font(.subheadline)
                            .frame(width: 56, alignment: .leading)
                        LevelBar(
                            value: model.value(pack: pack, .soc),
                            color: RutaTheme.battery(model.value(pack: pack, .soc))
                        )
                        Text(model.value(pack: pack, .soc).map { String(format: "%.0f%%", $0) } ?? "—")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                        Text(model.value(pack: pack, .temperature).map { String(format: "%.1f°", $0) } ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if model.packs.isEmpty {
                    Text("Battery frames appear a moment after the link is ready.")
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
        }
    }

    private var recentAlerts: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Alerts")
                ForEach(Array(model.alertLog.prefix(3).enumerated()), id: \.offset) { _, alert in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title).font(.subheadline.weight(.medium))
                        if let text = alert.text {
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}
