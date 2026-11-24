import SwiftUI
import RutaCore

/// Root of the app: five tabs over one live model.
@MainActor
public struct RutaRootView: View {
    @State private var model: RutaModel
    @State private var showOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase

    public init(model: RutaModel? = nil) {
        let created = model ?? RutaModel()
        _model = State(initialValue: created)
        _showOnboarding = State(initialValue: !UserDefaults.standard.bool(forKey: "ruta.onboarded"))
    }

    public var body: some View {
        TabView(selection: $model.tab) {
            HomeScreen()
                .tabItem { Label(RutaModel.Tab.home.rawValue, systemImage: RutaModel.Tab.home.symbol) }
                .tag(RutaModel.Tab.home)
            NavigateScreen()
                .tabItem { Label(RutaModel.Tab.navigate.rawValue, systemImage: RutaModel.Tab.navigate.symbol) }
                .tag(RutaModel.Tab.navigate)
            RidesScreen()
                .tabItem { Label(RutaModel.Tab.rides.rawValue, systemImage: RutaModel.Tab.rides.symbol) }
                .tag(RutaModel.Tab.rides)
            BatteryScreen()
                .tabItem { Label(RutaModel.Tab.battery.rawValue, systemImage: RutaModel.Tab.battery.symbol) }
                .tag(RutaModel.Tab.battery)
            MoreScreen()
                .tabItem { Label(RutaModel.Tab.more.rawValue, systemImage: RutaModel.Tab.more.symbol) }
                .tag(RutaModel.Tab.more)
        }
        .tint(RutaTheme.primary)
        .environment(model)
        .preferredColorScheme(.dark)
        .background(RutaTheme.background)
        .alert(alertTitle, isPresented: alertBinding) {
            Button("OK") { model.dismissAlert() }
        } message: {
            Text(model.alert?.text ?? "")
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "ruta.onboarded")
                showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .task { model.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.saveAndPause()
            case .active:
                model.resumeIfNeeded()
            default:
                break
            }
        }
    }

    private var alertTitle: String { model.alert?.title ?? "Ruta" }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.dismissAlert() } }
        )
    }
}
