// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Tomo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Tomo", targets: ["Tomo"]),
        .executable(name: "TomoAgentBridge", targets: ["TomoAgentBridge"])
    ],
    targets: [
        .target(
            name: "CZSTD",
            path: "Sources/CZSTD",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("zstd"),
                .unsafeFlags(["-L", "/opt/homebrew/lib", "-Xlinker", "-w"])
            ]
        ),
        .executableTarget(
            name: "Tomo",
            dependencies: ["CZSTD"],
            path: "Sources/Tomo",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "TomoAgentBridge",
            path: "Sources/TomoAgentBridge"
        ),
        .testTarget(
            name: "TomoTests",
            dependencies: ["Tomo", "CZSTD"],
            path: "Tests/TomoTests"
        )
    ]
)
