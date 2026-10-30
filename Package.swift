// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Canopy",
            path: "Sources/Canopy",
            exclude: ["Resources/AppIcon.icns"],
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(
            name: "CanopyTests",
            dependencies: ["Canopy"],
            path: "Tests/CanopyTests"
        ),
    ]
)
