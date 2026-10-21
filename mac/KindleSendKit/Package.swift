// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindleSendKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KindleSendKit", targets: ["KindleSendKit"]),
    ],
    targets: [
        .target(
            name: "KindleSendKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "KindleSendKitTests",
            dependencies: ["KindleSendKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
