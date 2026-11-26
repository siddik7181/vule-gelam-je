// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vule",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Vule", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
