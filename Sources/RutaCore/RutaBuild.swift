import Foundation

#if os(iOS)
import UIKit
#endif

/// Identifies the exact binary in diagnostics and on the About screen. CI injects the commit and a
/// monotonically increasing build number; local SwiftPM runs fall back to the bundle/package values.
public enum RutaBuild {
    public static var version: String {
        info("CFBundleShortVersionString") ?? "1.0"
    }

    public static var build: String {
        info("CFBundleVersion") ?? "local"
    }

    public static var commit: String {
        let value = info("RutaGitCommit") ?? "local"
        return value.isEmpty ? "local" : value
    }

    public static var device: String {
        #if os(iOS)
        return "\(UIDevice.current.model) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #endif
    }

    public static var header: String {
        "Ruta \(version) (\(build)) commit \(commit)\nDevice \(device)"
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
