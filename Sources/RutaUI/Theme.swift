import SwiftUI
import RutaCore

/// Identity of one live value: a pack and a metric.
public struct MetricKey: Hashable, Sendable {
    public let pack: Int
    public let metric: Metric

    public init(pack: Int, metric: Metric) {
        self.pack = pack
        self.metric = metric
    }
}

/// Ruta's dark palette, taken from the Android build's tonal roles (seed #8BD450, electric lime) so
/// the two apps look like the same product.
public enum RutaTheme {
    public static let primary = Color(hex: 0x98D864)
    public static let onPrimary = Color(hex: 0x1A3700)
    public static let primaryContainer = Color(hex: 0x326B00)
    public static let onPrimaryContainer = Color(hex: 0xB5F57E)
    public static let secondary = Color(hex: 0xE6F6D5)
    public static let tertiary = Color(hex: 0xB1FFF7)
    public static let onTertiary = Color(hex: 0x003734)

    public static let background = Color(hex: 0x10110E)
    public static let surface = Color(hex: 0x1A1C17)
    public static let surfaceContainer = Color(hex: 0x2A2C27)
    public static let surfaceHigh = Color(hex: 0x2F312C)
    public static let surfaceHighest = Color(hex: 0x454842)
    public static let onSurface = Color(hex: 0xFAFDF6)
    public static let onSurfaceVariant = Color(hex: 0xC1C9B9)
    public static let outline = Color(hex: 0x8C9384)
    public static let outlineVariant = Color(hex: 0x42493C)

    public static let error = Color(hex: 0xF2B8B5)
    public static let errorContainer = Color(hex: 0x8C1D18)
    public static let warning = Color(hex: 0xFFB951)
    public static let charging = tertiary

    public static func battery(_ percent: Double?) -> Color {
        guard let percent else { return outline }
        if percent < 20 { return error }
        if percent < 50 { return warning }
        return primary
    }

    public static func metric(_ metric: MetricKey) -> Color {
        switch metric.metric {
        case .soc: return primary
        case .temperature: return warning
        case .health, .energy: return tertiary
        case .status: return secondary
        }
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Card with the app's container colour and a rounded, Material-ish corner.
public struct RutaCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(RutaTheme.surfaceContainer)
            )
    }
}

/// The app's main call to action: lime fill, dark label, full width.
public struct RutaPrimaryButtonStyle: ButtonStyle {
    private let compact: Bool
    public init(compact: Bool = false) { self.compact = compact }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 9 : 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RutaTheme.primary.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .foregroundStyle(RutaTheme.onPrimary)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

public struct SectionTitle: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(RutaTheme.onSurfaceVariant)
    }
}

/// Small labelled value, the tile used across Home and Battery.
public struct StatTile: View {
    private let label: String
    private let value: String
    private let unit: String?
    private let color: Color

    public init(_ label: String, _ value: String, unit: String? = nil, color: Color = RutaTheme.onSurface) {
        self.label = label
        self.value = value
        self.unit = unit
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Est." style pill.
public struct RutaChip: View {
    private let text: String
    private let tint: Color

    public init(_ text: String, tint: Color = RutaTheme.onSurfaceVariant) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
