import SwiftUI
import MapKit
import Charts
import RutaCore

/// Stored rides with a map, stats and a speed chart.
public struct RidesScreen: View {
    @Environment(RutaModel.self) private var model

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if model.rides.isEmpty {
                        empty
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(model.rides) { stored in
                                NavigationLink(value: stored.id) {
                                    RideRow(stored: stored)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(RutaTheme.background)
            .navigationTitle("Rides")
            .navigationDestination(for: Int64.self) { id in
                if let stored = model.rides.first(where: { $0.id == id }) {
                    RideDetailScreen(stored: stored)
                } else {
                    Text("This ride was deleted.").foregroundStyle(RutaTheme.onSurfaceVariant)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.refreshRides()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { model.refreshRides() }
        }
    }

    private var summary: some View {
        RutaCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    StatTile("Rides", "\(model.rideStats.rides)")
                    StatTile(
                        "Distance",
                        model.unitMiles
                            ? String(format: "%.0f", model.rideStats.distanceM / 1609.344)
                            : String(format: "%.0f", model.rideStats.distanceM / 1000),
                        unit: model.unitMiles ? "mi" : "km",
                        color: RutaTheme.primary
                    )
                    StatTile("Peak", model.speedText(model.rideStats.peakKmh), unit: model.speedUnit)
                }
                HStack(spacing: 12) {
                    StatTile(
                        "Efficiency",
                        model.rideStats.kmPerPercent.map { String(format: "%.2f", $0) } ?? "—",
                        unit: "km / %",
                        color: RutaTheme.tertiary
                    )
                    StatTile(
                        "Learned",
                        String(format: "%.2f", model.efficiency.kmPerPercent),
                        unit: model.efficiency.learned ? "km / %" : "km / % default",
                        color: model.efficiency.learned ? RutaTheme.tertiary : RutaTheme.onSurfaceVariant
                    )
                    StatTile("Moving", RideMath.formatDuration(seconds: model.rideStats.movingS))
                }
                if model.demoMode {
                    HStack {
                        Image(systemName: "testtube.2")
                        Text("Sample rides — demo mode")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(RutaTheme.tertiary)
                }
            }
        }
    }

    private var empty: some View {
        RutaCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("No rides yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                Text("Connect to the scooter, keep Ruta open and ride. A ride is saved after at least 200 m and a minute of movement. Tracks come from the iPhone's GPS.")
                    .font(.subheadline)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
                Text("Turn on demo mode in More to explore sample rides.")
                    .font(.caption)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
            }
        }
    }
}

private struct RideRow: View {
    let stored: StoredRide
    @Environment(RutaModel.self) private var model

    var body: some View {
        RutaCard(padding: 14) {
            HStack(spacing: 12) {
                RideThumbnail(points: stored.points)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(stored.ride.endPlace ?? stored.ride.endLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                    HStack(spacing: 8) {
                        Text(model.distanceText(stored.ride.distanceM))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RutaTheme.primary)
                        Text(RideMath.formatDuration(seconds: stored.ride.durationS))
                            .font(.caption)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                        if let used = stored.ride.batteryUsed, used > 0 {
                            Text(String(format: "−%.0f%%", used))
                                .font(.caption)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
            }
        }
    }

    private var dateText: String {
        let date = Date(timeIntervalSince1970: Double(stored.ride.start) / 1000)
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

/// A small route drawing from stored points.
public struct RideThumbnail: View {
    private let points: [RidePoint]

    public init(points: [RidePoint]) {
        self.points = points
    }

    public var body: some View {
        Canvas { context, size in
            let thinned = RideMath.thin(points, max: 300)
            guard thinned.count > 1 else { return }
            let projected = RideMath.project(thinned, width: Float(size.width), height: Float(size.height), padding: 8)
            guard projected.count >= 4 else { return }
            var path = Path()
            path.move(to: CGPoint(x: CGFloat(projected[0]), y: CGFloat(projected[1])))
            for index in stride(from: 2, to: projected.count, by: 2) {
                path.addLine(to: CGPoint(x: CGFloat(projected[index]), y: CGFloat(projected[index + 1])))
            }
            context.stroke(
                path,
                with: .color(RutaTheme.primary),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
            if let startX = projected.first, let end = projected.last {
                let start = CGPoint(x: CGFloat(startX), y: CGFloat(projected[1]))
                let finish = CGPoint(x: CGFloat(projected[projected.count - 2]), y: CGFloat(end))
                context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(RutaTheme.tertiary))
                context.fill(Path(ellipseIn: CGRect(x: finish.x - 3.5, y: finish.y - 3.5, width: 7, height: 7)), with: .color(RutaTheme.primary))
            }
        }
        .background(RutaTheme.surfaceHigh)
    }
}

/// One ride in detail: route map, numbers and speed over time.
public struct RideDetailScreen: View {
    @Environment(RutaModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private let stored: StoredRide

    public init(stored: StoredRide) {
        self.stored = stored
    }

    private var ride: Ride { stored.ride }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                routeMap
                stats
                speedChart
                places
                HStack {
                    if let url = URL(string: RideMath.routeUrl(stored.points) ?? "") {
                        Link(destination: url) {
                            Label("Open route in Maps", systemImage: "map")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(RutaTheme.primary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .foregroundStyle(RutaTheme.error)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(RutaTheme.background)
        .navigationTitle(Date(timeIntervalSince1970: Double(ride.start) / 1000)
            .formatted(.dateTime.day().month(.wide)))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .alert("Delete this ride?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteRide(ride.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its track and speed chart are removed from this iPhone.")
        }
    }

    private var routeMap: some View {
        Map(initialPosition: .rect(mapRect)) {
            if stored.points.count > 1 {
                MapPolyline(coordinates: stored.points.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                })
                .stroke(RutaTheme.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            if let first = stored.points.first {
                Marker("Start", coordinate: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng))
                    .tint(RutaTheme.tertiary)
            }
            if let last = stored.points.last {
                Marker(ride.endPlace ?? "End", coordinate: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lng))
                    .tint(RutaTheme.primary)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(true)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var mapRect: MKMapRect {
        guard let first = stored.points.first else { return MKMapRect.world }
        var minLat = first.lat, maxLat = first.lat, minLng = first.lng, maxLng = first.lng
        for point in stored.points {
            minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
            minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
        }
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLng))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLng))
        let rect = MKMapRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                             width: abs(bottomRight.x - topLeft.x), height: abs(bottomRight.y - topLeft.y))
        return rect.insetBy(dx: -rect.size.width * 0.25 - 200, dy: -rect.size.height * 0.25 - 200)
    }

    private var stats: some View {
        RutaCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    StatTile("Distance", String(format: "%.1f", model.unitMiles ? ride.distanceKm * 0.621371 : ride.distanceKm),
                             unit: model.unitMiles ? "mi" : "km", color: RutaTheme.primary)
                    StatTile("Time", RideMath.formatDuration(seconds: ride.durationS))
                    StatTile("Moving", RideMath.formatDuration(seconds: ride.movingS))
                }
                HStack(spacing: 12) {
                    StatTile("Average", model.speedText(ride.avgKmh), unit: model.speedUnit)
                    StatTile("Peak", model.speedText(ride.peakKmh), unit: model.speedUnit)
                    StatTile(
                        "Battery",
                        ride.batteryUsed.map { String(format: "−%.1f", $0) } ?? "—",
                        unit: "%",
                        color: RutaTheme.battery((ride.socEnd ?? 100))
                    )
                }
                if let kmPerPercent = ride.kmPerPercent {
                    InfoRow("Efficiency", String(format: "%.2f km per %%", kmPerPercent), color: RutaTheme.tertiary)
                }
                if let start = ride.socStart, let end = ride.socEnd {
                    InfoRow("Charge", String(format: "%.0f %% → %.0f %%", start, end))
                }
            }
        }
    }

    private var speedChart: some View {
        let buckets = RideMath.speedSeries(stored.points, buckets: 80)
        let points = buckets.enumerated().map { index, bucket in
            TrendChart.Point(
                id: "\(index)",
                time: Date(timeIntervalSince1970: Double(bucket.time) / 1000),
                value: bucket.avg
            )
        }
        return RutaCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Speed")
                    Spacer()
                    Text(model.speedUnit).font(.caption).foregroundStyle(RutaTheme.onSurfaceVariant)
                }
                TrendChart(points: points, unit: model.speedUnit, colors: [RutaTheme.primary], minValue: 0, height: 150, showTime: false)
            }
        }
    }

    private var places: some View {
        RutaCard {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(RutaTheme.tertiary).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start").font(.caption).foregroundStyle(RutaTheme.onSurfaceVariant)
                        Text(ride.startPlace ?? ride.startLabel).font(.subheadline)
                    }
                    Spacer()
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 13)).foregroundStyle(RutaTheme.primary).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("End").font(.caption).foregroundStyle(RutaTheme.onSurfaceVariant)
                        Text(ride.endPlace ?? ride.endLabel).font(.subheadline)
                    }
                    Spacer()
                }
            }
        }
    }
}
