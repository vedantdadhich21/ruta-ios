import SwiftUI
import MapKit
import RutaCore

/// In-app navigation. Search a destination, preview the route, start: the map follows the ride and
/// the cluster receives the next turn.
public struct NavigateScreen: View {
    @Environment(RutaModel.self) private var model
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @FocusState private var fieldFocused: Bool

    public init() {}

    private var nav: NavigationModel { model.navigation }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 10) {
                    if nav.isNavigating {
                        guidance
                    } else {
                        searchPanel
                    }
                    Spacer()
                    if !nav.isNavigating, nav.route != nil {
                        routePreview
                    }
                    if nav.isNavigating {
                        bottomBar
                    }
                }
                .padding(14)
            }
            .background(RutaTheme.background)
            .navigationTitle("Navigate")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if nav.isNavigating {
                        Button("End") { end() }
                            .foregroundStyle(RutaTheme.error)
                    }
                }
            }
            .onAppear { model.location.start() }
            .onChange(of: nav.routeRevision) { _, _ in fitRoute() }
            .onChange(of: nav.isNavigating) { _, navigating in
                if navigating {
                    camera = .userLocation(followsHeading: true, fallback: .automatic)
                } else {
                    fitRoute()
                }
            }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let route = nav.route {
                MapPolyline(route.polyline)
                    .stroke(RutaTheme.primary, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let destination = nav.destination {
                Marker(destination.name, coordinate: destination.coordinate)
                    .tint(RutaTheme.tertiary)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    private var searchPanel: some View {
        @Bindable var nav = nav
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                TextField("Where to?", text: $nav.query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .submitLabel(.search)
                if nav.calculating {
                    ProgressView().controlSize(.small)
                } else if !nav.query.isEmpty {
                    Button {
                        nav.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(RutaTheme.surfaceContainer))

            if !nav.completions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(nav.completions.prefix(6).enumerated()), id: \.offset) { _, completion in
                        Button {
                            fieldFocused = false
                            model.location.start()
                            nav.select(completion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(RutaTheme.onSurface)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        if completion.title != nav.completions.prefix(6).last?.title {
                            Divider().overlay(RutaTheme.outlineVariant.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 16).fill(RutaTheme.surfaceContainer))
            }

            if let error = nav.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(RutaTheme.warning)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RutaTheme.surfaceContainer))
            }

            if locationBlocked {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash")
                    Text("Allow location access for Ruta to route from where you are.")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(RutaTheme.warning)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(RutaTheme.surfaceContainer))
            }
        }
    }

    private var routePreview: some View {
        RutaCard(padding: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(nav.destinationName ?? "Destination")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let distance = nav.routeDistanceText {
                            Label(distance, systemImage: "road.lanes")
                        }
                        if let time = nav.routeTimeText {
                            Label(time, systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
                Spacer()
                Button {
                    start()
                } label: {
                    Text("Start")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(RutaTheme.primary))
                        .foregroundStyle(RutaTheme.onPrimary)
                }
                .disabled(nav.calculating)
            }
        }
    }

    private var guidance: some View {
        VStack(spacing: 6) {
            TurnCard(
                turn: nav.turn,
                distance: nav.maneuverText,
                instruction: nav.instruction,
                road: nav.road,
                remaining: nav.remainingText,
                arrival: nav.arrivalText
            )
            if nav.rerouting {
                Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(RutaTheme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(RutaTheme.surfaceContainer))
            }
        }
    }

    private var bottomBar: some View {
        RutaCard(padding: 14) {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(nav.remainingText) left")
                            .font(.title3.weight(.semibold).monospacedDigit())
                        if let arrival = nav.arrivalText {
                            Text("Arrive \(arrival)")
                                .font(.caption)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }
                    Spacer()
                    Button {
                        end()
                    } label: {
                        Label("End", systemImage: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(RutaTheme.errorContainer))
                    }
                    .foregroundStyle(RutaTheme.onSurface)
                }
                clusterLine
            }
        }
    }

    private var clusterLine: some View {
        HStack(spacing: 8) {
            Image(systemName: clusterSymbol)
                .foregroundStyle(clusterColor)
            Text(clusterText)
                .font(.caption)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
            Spacer()
        }
    }

    private var clusterSymbol: String {
        guard model.navigationEnabled else { return "display.slash" }
        switch model.session.navigationDisplay() {
        case .showing: return "checkmark.circle.fill"
        case .rejected: return "exclamationmark.triangle.fill"
        case .unavailable: return "display.slash"
        case .preparing: return "clock"
        }
    }

    private var clusterColor: Color {
        switch model.session.navigationDisplay() {
        case .showing: return RutaTheme.primary
        case .rejected: return RutaTheme.error
        case .preparing: return RutaTheme.warning
        case .unavailable: return RutaTheme.onSurfaceVariant
        }
    }

    private var clusterText: String {
        guard !model.isConnected else {
            return model.session.navigationDisplay().rawValue
        }
        return "Not connected — directions stay on this screen."
    }

    private var locationBlocked: Bool {
        model.ride.gps == .noPermission || model.ride.gps == .disabled
    }

    private func start() {
        model.location.start()
        model.beginNavigation()
        camera = .userLocation(followsHeading: true, fallback: .automatic)
    }

    private func end() {
        model.endNavigation()
        camera = .userLocation(fallback: .automatic)
    }

    private func fitRoute() {
        guard let route = nav.route else { return }
        let rect = route.polyline.boundingMapRect
        camera = .rect(rect.insetBy(dx: -rect.size.width * 0.25, dy: -rect.size.height * 0.35))
    }
}
