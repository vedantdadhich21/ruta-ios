import SwiftUI
import RutaUI
import RutaCore

/// Desktop shell for working on the UI without an iPhone: demo mode on, simulated scooter, sample
/// rides. Run with `swift run RutaPreview`.
@main
@MainActor
struct RutaPreviewApp: App {
    @State private var model = RutaModel(demo: true, defaults: previewDefaults())

    var body: some Scene {
        WindowGroup {
            RutaRootView(model: model)
                .frame(minWidth: 390, idealWidth: 430, minHeight: 780, idealHeight: 900)
        }
        .windowResizability(.contentSize)
    }

    private static func previewDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ruta.preview") ?? .standard
        defaults.set(true, forKey: "ruta.onboarded")
        return defaults
    }
}
