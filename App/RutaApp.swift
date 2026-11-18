import SwiftUI
import RutaUI

@main
struct RutaApp: App {
    @State private var model = RutaModel()

    var body: some Scene {
        WindowGroup {
            RutaRootView(model: model)
        }
    }
}
