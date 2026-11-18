import SwiftUI
import Charts
import RutaCore

/// SF Symbol for a cluster turn code.
public struct TurnGlyph: View {
    private let turn: Int
    private let size: CGFloat
    private let color: Color

    public init(turn: Int, size: CGFloat = 44, color: Color = RutaTheme.onSurface) {
        self.turn = turn
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(systemName: Symbol.turn(turn))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
            .frame(width: size * 1.3, height: size * 1.3)
    }
}

public enum Symbol {
    public static func turn(_ code: Int) -> String {
        switch code {
        case NavTurn.left, NavTurn.rampLeft, NavTurn.forkLeft: return "arrow.turn.up.left"
        case NavTurn.right, NavTurn.rampRight, NavTurn.forkRight: return "arrow.turn.up.right"
        case NavTurn.slightLeft: return "arrow.up.left"
        case NavTurn.slightRight: return "arrow.up.right"
        case NavTurn.sharpLeft: return "arrow.down.left"
        case NavTurn.sharpRight: return "arrow.down.right"
        case NavTurn.uTurnLeft, NavTurn.uTurnRight: return "arrow.uturn.left"
        case NavTurn.roundaboutLeft, NavTurn.roundaboutRight: return "arrow.trianglehead.counterclockwise"
        case NavTurn.keepLeft: return "arrow.up.left"
        case NavTurn.keepRight: return "arrow.up.right"
        case NavTurn.merge: return "arrow.merge"
        case NavTurn.ferry, NavTurn.ferryTrain: return "ferry.fill"
        case NavTurn.destination: return "flag.checkered"
        default: return "arrow.up"
        }
    }

    public static func battery(_ percent: Double?) -> String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Circular battery gauge used on Home and Battery.
public struct BatteryRing: View {
    private let percent: Double?
    private let size: CGFloat
    private let lineWidth: CGFloat
    private let charging: Bool

    public init(percent: Double?, size: CGFloat = 120, lineWidth: CGFloat = 10, charging: Bool = false) {
        self.percent = percent
        self.size = size
        self.lineWidth = lineWidth
        self.charging = charging
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(RutaTheme.outlineVariant.opacity(0.5), lineWidth: lineWidth)
            if let percent {
                Circle()
                    .trim(from: 0, to: min(max(percent / 100, 0.005), 1))
                    .stroke(
                        RutaTheme.battery(percent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: percent)
            }
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 1) {
                    Text(percent.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: size * 0.31, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(RutaTheme.battery(percent))
                    Text("%")
                        .font(.system(size: size * 0.13, weight: .semibold))
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                        .padding(.top, size * 0.05)
                }
                if charging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.system(size: size * 0.09, weight: .semibold))
                        .foregroundStyle(RutaTheme.charging)
                } else {
                    Text("battery")
                        .font(.system(size: size * 0.09))
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal level bar for individual packs.
public struct LevelBar: View {
    private let value: Double?
    private let maximum: Double
    private let color: Color

    public init(value: Double?, maximum: Double = 100, color: Color = RutaTheme.primary) {
        self.value = value
        self.maximum = maximum
        self.color = color
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(RutaTheme.outlineVariant.opacity(0.4))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max((value ?? 0) / maximum, 0), 1))
            }
        }
        .frame(height: 7)
    }
}

/// Small connection state dot in headers.
public struct StatusDot: View {
    private let color: Color
    private let pulsing: Bool
    @State private var dim = false

    public init(color: Color, pulsing: Bool = false) {
        self.color = color
        self.pulsing = pulsing
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = pulsing }
    }
}

/// A line chart with a soft fill, downsample-friendly and empty-state aware.
public struct TrendChart: View {
    public struct Point: Identifiable {
        public let id: String
        public let time: Date
        public let value: Double
        public let series: String

        public init(id: String, time: Date, value: Double, series: String = "") {
            self.id = id
            self.time = time
            self.value = value
            self.series = series
        }
    }

    private let points: [Point]
    private let unit: String
    private let colors: [Color]
    private let minValue: Double?
    private let height: CGFloat
    private let showTime: Bool
    private let showLegend: Bool

    public init(
        points: [Point], unit: String, colors: [Color] = [RutaTheme.primary], minValue: Double? = nil,
        height: CGFloat = 150, showTime: Bool = true, showLegend: Bool = false
    ) {
        self.points = points
        self.unit = unit
        self.colors = colors
        self.minValue = minValue
        self.height = height
        self.showTime = showTime
        self.showLegend = showLegend
    }

    public var body: some View {
        if points.isEmpty {
            Text("No data yet — it appears while the scooter is connected.")
                .font(.footnote)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
                .frame(maxWidth: .infinity, minHeight: height / 2)
        } else {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value(unit, point.value)
                )
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartForegroundStyleScale(domain: domains, range: colorRange)
            .chartLegend(showLegend ? .visible : .hidden)
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(RutaTheme.outlineVariant.opacity(0.35))
                    AxisValueLabel().foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
            .chartXAxis(showTime ? .automatic : .hidden)
            .frame(height: height)
        }
    }

    private var domains: [String] {
        var seen: [String] = []
        for point in points where !seen.contains(point.series) { seen.append(point.series) }
        return seen
    }

    private var colorRange: [Color] {
        domains.enumerated().map { index, _ in colors[index % colors.count] }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let low = minValue ?? (values.min() ?? 0)
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.12, unit == "%" ? 2 : 1)
        return (low - pad)...(high + pad)
    }
}

/// The card shown while navigation is active, reused on Home.
public struct TurnCard: View {
    private let turn: Int
    private let distance: String
    private let instruction: String
    private let road: String
    private let remaining: String?
    private let arrival: String?

    public init(turn: Int, distance: String, instruction: String, road: String, remaining: String?, arrival: String?) {
        self.turn = turn
        self.distance = distance
        self.instruction = instruction
        self.road = road
        self.remaining = remaining
        self.arrival = arrival
    }

    public var body: some View {
        HStack(spacing: 14) {
            TurnGlyph(turn: turn, size: 38, color: RutaTheme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(distance)
                    .font(.title2.bold().monospacedDigit())
                Text(instruction.isEmpty ? road : instruction)
                    .font(.subheadline)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                    .lineLimit(2)
                if let remaining, let arrival {
                    Text("\(remaining) · \(arrival)")
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(RutaTheme.primary.opacity(0.12))
        )
    }
}

/// A label/value row used on detail screens.
public struct InfoRow: View {
    private let label: String
    private let value: String
    private let color: Color

    public init(_ label: String, _ value: String, color: Color = RutaTheme.onSurface) {
        self.label = label
        self.value = value
        self.color = color
    }

    public var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
