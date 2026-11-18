import SwiftUI
import RutaCore

/// First-run explanation: what works on iOS, what needs the system pairing sheet, and what the
/// iPhone simply cannot do.
public struct OnboardingView: View {
    private let done: () -> Void

    public init(done: @escaping () -> Void) {
        self.done = done
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "scooter")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(RutaTheme.primary)
                    Text("Ruta")
                        .font(.largeTitle.bold())
                    Text("Your Vida's live battery, rides and turn-by-turn on the iPhone.")
                        .font(.title3)
                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                }
                .padding(.top, 30)

                Feature(
                    symbol: "battery.75percent",
                    title: "Both packs, live",
                    text: "Charge, health, temperature and balance for the scooter and each battery, read straight from the BMS, with charge alerts."
                )
                Feature(
                    symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Rides and range",
                    text: "GPS rides with a map, speed chart and place names. Ruta learns your km per percent and estimates real range."
                )
                Feature(
                    symbol: "location.north.line.fill",
                    title: "Directions on the cluster",
                    text: "Search a place, start the in-app map, and the next turn, distance and arrival time are mirrored to the scooter's screen."
                )

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Before you connect")
                    Bullet("Turn the scooter on and keep it close.")
                    Bullet("Close the scooter maker's official app, so it is not holding the Bluetooth link.")
                    Bullet("Tap Connect. iOS shows its own Bluetooth pairing sheet: enter the 4–8 digit PIN the official app uses. Ruta never sees it, and iOS remembers the pairing.")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22).fill(RutaTheme.surfaceContainer))

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("What iOS does differently")
                    Bullet("Calls and music: iOS gives apps no access to other apps' calls or to the media session. The cluster's call and music screens are not fed by Ruta.")
                    Bullet("Navigation uses Ruta's own Apple Maps screen, not a Google Maps notification.")
                    Bullet("Keep Ruta open while riding. The screen stays awake, and rides save when you stop.")
                    Bullet("Everything stays on this iPhone. The only network use is Apple Maps for searches and routes.")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22).fill(RutaTheme.surfaceContainer))

                Button(action: done) {
                    Text("Get started")
                }
                .buttonStyle(RutaPrimaryButtonStyle())
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 22)
        }
        .background(RutaTheme.background)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(RutaTheme.primary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(RutaTheme.onSurfaceVariant)
            }
        }
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(RutaTheme.primary).frame(width: 5, height: 5).padding(.top, 7)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(RutaTheme.onSurfaceVariant)
        }
    }
}

/// Scanning, remembered scooters and demo mode.
public struct ConnectSheet: View {
    @Environment(RutaModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.demoMode {
                        RutaCard {
                            HStack(spacing: 12) {
                                Image(systemName: "testtube.2").font(.title2).foregroundStyle(RutaTheme.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Demo mode is on").font(.headline)
                                    Text("A simulated scooter answers instead of Bluetooth. Turn it off to use real hardware.")
                                        .font(.caption)
                                        .foregroundStyle(RutaTheme.onSurfaceVariant)
                                }
                            }
                        }
                    }

                    if let name = model.connectedName, model.isConnected {
                        RutaCard {
                            HStack(spacing: 12) {
                                StatusDot(color: RutaTheme.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).font(.headline)
                                    Text("Connected").font(.caption).foregroundStyle(RutaTheme.onSurfaceVariant)
                                }
                                Spacer()
                                Button("Disconnect") { model.disconnect() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionTitle("Bluetooth")
                            Spacer()
                            if model.scanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Scan") { model.startScan() }
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        if let problem = bluetoothProblem {
                            Text(problem)
                                .font(.footnote)
                                .foregroundStyle(RutaTheme.warning)
                        }
                        if model.discovered.isEmpty {
                            Text(model.scanning
                                 ? "Looking for a scooter named HMC…"
                                 : "Turn the scooter on, close the official app, then Scan.")
                                .font(.footnote)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(model.discovered) { scooter in
                                Button {
                                    model.connect(scooter)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: "scooter")
                                            .foregroundStyle(RutaTheme.primary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(scooter.name).foregroundStyle(RutaTheme.onSurface)
                                            Text("Signal \(scooter.rssi) dBm")
                                                .font(.caption)
                                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                    }

                    if !model.saved.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Remembered")
                            ForEach(model.saved, id: \.id) { scooter in
                                Button {
                                    model.connect(scooter)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: "scooter")
                                        Text(scooter.displayName).foregroundStyle(RutaTheme.onSurface)
                                        Spacer()
                                        Text("Connect")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(RutaTheme.primary)
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                            Text("iOS identifies a scooter by a private Bluetooth ID, so the address changes if you pair from another iPhone.")
                                .font(.caption2)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Pairing")
                        Text("The first connection shows iOS's Bluetooth pairing sheet. Enter the PIN from the official scooter app (usually 4–8 digits). If no sheet appears, forget the scooter in Settings › Bluetooth and try again.")
                            .font(.footnote)
                            .foregroundStyle(RutaTheme.onSurfaceVariant)
                    }

                    Toggle(isOn: $model.demoMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Demo mode")
                            Text("Simulated scooter and sample rides")
                                .font(.caption)
                                .foregroundStyle(RutaTheme.onSurfaceVariant)
                        }
                    }
                    .tint(RutaTheme.primary)

                    Button {
                        model.demoMode = true
                        model.startScan()
                        dismiss()
                    } label: {
                        Label("Explore with demo data", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .background(RutaTheme.background)
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                guard !appeared else { return }
                appeared = true
                model.startScan()
            }
            .onDisappear { model.stopScan() }
        }
    }

    private var bluetoothProblem: String? {
        switch model.bluetooth {
        case .poweredOff: return "Bluetooth is off. Turn it on in Settings or Control Centre."
        case .unauthorized: return "Ruta has no Bluetooth permission. Allow it in Settings › Ruta."
        case .unsupported: return "This device has no Bluetooth LE."
        default: return nil
        }
    }
}
