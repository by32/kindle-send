// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindleSendKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KindleSendKit", targets: ["KindleSendKit"]),
        .executable(name: "KindleSendSmoke", targets: ["KindleSendSmoke"]),
    ],
    targets: [
        .target(
            name: "KindleSendKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "KindleSendSmoke", dependencies: ["KindleSendKit"]),
        .testTarget(
            name: "KindleSendKitTests",
            dependencies: ["KindleSendKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
