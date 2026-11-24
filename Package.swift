// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ruta",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RutaCore", targets: ["RutaCore"]),
        .library(name: "RutaUI", targets: ["RutaUI"]),
        .executable(name: "RutaPreview", targets: ["RutaPreview"]),
    ],
    targets: [
        .target(name: "RutaCore"),
        .target(name: "RutaUI", dependencies: ["RutaCore"]),
        .executableTarget(name: "RutaPreview", dependencies: ["RutaUI"]),
        .executableTarget(name: "RutaSnapshot", dependencies: ["RutaUI"]),
        .executableTarget(name: "RutaTests", dependencies: ["RutaCore", "RutaUI"], path: "Tests/RutaTests"),
    ],
    swiftLanguageModes: [.v5]
)
