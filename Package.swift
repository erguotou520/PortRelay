// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PortRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PortRelay", targets: ["PortRelay"]),
        .executable(name: "PortRelayAskPass", targets: ["PortRelayAskPass"])
    ],
    targets: [
        .executableTarget(
            name: "PortRelay",
            path: "Sources/PortRelay",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "PortRelayAskPass",
            path: "Sources/PortRelayAskPass",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "PortRelayTests",
            dependencies: ["PortRelay"],
            path: "Tests/PortRelayTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
