import SwiftUI
import AppKit
import RutaUI
import RutaCore

/// Renders the app's screens to PNGs on a Mac, so the layout can be checked without Xcode or an
/// iPhone. Usage: `swift run RutaSnapshot [output-directory]`.
@main
@MainActor
struct RutaSnapshot {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/screenshots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "ruta.snapshot") ?? .standard
        defaults.set(true, forKey: "ruta.onboarded")
        let model = RutaModel(demo: true, defaults: defaults)
        model.start()

        // Let the simulated scooter connect and send a few battery frames.
        try? await Task.sleep(nanoseconds: 3_500_000_000)

        render(HomeScreen(), model: model, name: "home", folder: folder)
        render(BatteryScreen(), model: model, name: "battery", folder: folder)
        render(RidesScreen(), model: model, name: "rides", folder: folder)
        render(MoreScreen(), model: model, name: "more", folder: folder)
        render(NavigateScreen(), model: model, name: "navigate", folder: folder)
        render(OnboardingView(done: {}), model: model, name: "onboarding", folder: folder)
        render(ConnectSheet(), model: model, name: "connect", folder: folder)

        if let ride = model.rides.first {
            render(RideDetailScreen(stored: ride), model: model, name: "ride-detail", folder: folder)
        }
        print("Snapshots written to \(folder.path)")
    }

    private static func render<V: View>(_ view: V, model: RutaModel, name: String, folder: URL) {
        let content = view
            .environment(model)
            .frame(width: 402, height: 874)
            .background(RutaTheme.background)
            .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Let async content (charts, symbol effects) settle before the capture.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("Could not render \(name)")
            window.orderOut(nil)
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = folder.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        window.orderOut(nil)
        print("Wrote \(url.lastPathComponent)")
    }
}
