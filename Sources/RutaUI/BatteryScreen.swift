import SwiftUI
import RutaCore

/// Both packs: charge, health, temperature, balance, live trends and charging sessions.
public struct BatteryScreen: View {
    @Environment(RutaModel.self) private var model
    @State private var metric: Metric = .soc
    @State private var range: Range = .session

    private enum Range: String, CaseIterable, Identifiable {
        case session = "Session"
        case hour = "1 h"
        case six = "6 h"
        var id: String { rawValue }
        var hours: Double { self == .hour ? 1 : (self == .six ? 6 : 24) }
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    packCards
                    balance
                    trend
                    charges
                    Text("Battery history is kept while Ruta is open. The scooter's own history is not readable by the app.")
                        .font(.caption2)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
                .padding(16)
            }
            .background(RutaTheme.background)
            .navigationTitle("Battery")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.refreshLive() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!model.isConnected)
                }
            }
        }
    }

    private var hero: some View {
        RutaCard(padding: 20) {
            HStack(alignment: .center, spacing: 16) {
                BatteryRing(percent: model.latestSoc, size: 128, lineWidth: 11, charging: model.ride.charging != nil)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.bmsState.label)
                        .font(.headline)
                    if let range = model.range {
                        Text("\(Int(range.km.rounded())) km" + (range.estimated ? " estimated" : " from the scooter"))
                            .font(.subheadline)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                    }
                    if let eta = model.fullChargeEta {
                        Label(eta, systemImage: "bolt.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RutaTheme.charging)
                    }
                    if let health = model.value(pack: 0, .health) {
                        Text(String(format: "Health %.1f %%", health))
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                    }
                    if let session = model.ride.charging {
                        Text(String(format: "+%.0f %% this session · %@", session.gained,
                                    RideMath.formatDuration(seconds: session.durationS)))
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var packCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Packs")
            ForEach(Array(model.packs.prefix(3)), id: \.self) { pack in
                packCard(pack)
            }
            if model.packs.isEmpty {
                RutaCard {
                    Text("No battery frames yet. They start a moment after the scooter link is ready.")
                        .font(.footnote)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
        }
    }

    private func packCard(_ pack: Int) -> some View {
        let soc = model.value(pack: pack, .soc)
        let state = BmsState.of(model.value(pack: pack, .status))
        return RutaCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(pack == 0 ? "Scooter total" : "Battery \(pack)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(soc.map { String(format: "%.1f %%", $0) } ?? "—")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(RutaTheme.battery(soc))
                }
                LevelBar(value: soc, color: RutaTheme.battery(soc))
                HStack(spacing: 14) {
                    packValue("Health", model.value(pack: pack, .health), "%", decimals: 1)
                    packValue("Energy", model.value(pack: pack, .energy), "%", decimals: 1)
                    packValue("Temp", model.value(pack: pack, .temperature), "°C", decimals: 1)
                    Spacer()
                    Text(state.label)
                        .font(.caption2)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(RutaTheme.surfaceHighest))
                }
            }
        }
    }

    private func packValue(_ label: String, _ value: Double?, _ unit: String, decimals: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(RutaTheme.onSurfaceVariant)
            Text(value.map { String(format: "%.\(decimals)f %@", $0, unit) } ?? "—")
                .font(.caption.monospacedDigit())
        }
    }

    private var balance: some View {
        let socs = (1...2).compactMap { model.value(pack: $0, .soc) }
        let imbalance = socs.count >= 2 ? (socs.max() ?? 0) - (socs.min() ?? 0) : nil
        return RutaCard {
            HStack(spacing: 12) {
                Image(systemName: imbalance.map { $0 > 8 ? "exclamationmark.triangle.fill" : "equal.circle" } ?? "equal.circle")
                    .font(.title2)
                    .foregroundStyle(imbalance.map { $0 > 8 ? RutaTheme.warning : RutaTheme.primary } ?? RutaTheme.onSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pack balance")
                        .font(.subheadline.weight(.medium))
                    Text(imbalance.map { String(format: "%.1f %% between packs", $0) } ?? "Waiting for both packs")
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
                Spacer()
                if let temp = model.value(pack: 0, .temperature) {
                    Text(String(format: "%.1f °C", temp))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
        }
    }

    private var trend: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle("Trend")
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                Picker("Metric", selection: $metric) {
                    Text("Charge").tag(Metric.soc)
                    Text("Health").tag(Metric.health)
                    Text("Temp").tag(Metric.temperature)
                }
                .pickerStyle(.segmented)
                TrendChart(
                    points: trendPoints,
                    unit: metric.unit,
                    colors: [RutaTheme.primary, RutaTheme.tertiary, RutaTheme.warning],
                    minValue: metric == .temperature ? nil : 0,
                    height: 170,
                    showLegend: true
                )
            }
        }
    }

    private var trendPoints: [TrendChart.Point] {
        var points: [TrendChart.Point] = []
        for pack in model.packs {
            let buckets = model.history(metric, pack: pack, hours: range.hours, buckets: 90)
            for (index, bucket) in buckets.enumerated() {
                points.append(TrendChart.Point(
                    id: "\(pack)-\(index)",
                    time: Date(timeIntervalSince1970: Double(bucket.time) / 1000),
                    value: bucket.avg,
                    series: pack == 0 ? "Total" : "Pack \(pack)"
                ))
            }
        }
        return points
    }

    private var charges: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Charging sessions")
            if model.charges.isEmpty {
                RutaCard {
                    Text("No charging sessions recorded yet. A session is saved after the charge rises by 1 % and the link drops or the scooter stops charging.")
                        .font(.footnote)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            } else {
                ForEach(Array(model.charges.prefix(8).enumerated()), id: \.offset) { _, session in
                    RutaCard(padding: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(RutaTheme.charging)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Date(timeIntervalSince1970: Double(session.start) / 1000)
                                    .formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                    .font(.subheadline.weight(.medium))
                                Text(String(format: "%.0f %% → %.0f %% · %@", session.socStart, session.socEnd,
                                            RideMath.formatDuration(seconds: session.durationS)))
                                    .font(.caption)
                                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                            }
                            Spacer()
                            Text(String(format: "+%.0f %%", session.gained))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RutaTheme.charging)
                        }
                    }
                }
            }
        }
    }
}
