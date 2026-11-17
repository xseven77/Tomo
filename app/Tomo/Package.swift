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
    dependencies: [
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "CTomoKeychain",
            path: "Sources/CTomoKeychain",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Security")]
        ),
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
            dependencies: ["CZSTD", "CTomoKeychain", .product(name: "JWTKit", package: "jwt-kit")],
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
            dependencies: ["Tomo", "CZSTD", "CTomoKeychain"],
            path: "Tests/TomoTests",
            resources: [.copy("Fixtures/RemoteCloudGrantRuby.json"), .copy("Fixtures/RemotePlatformReceiptRuby.json")]
        )
    ]
)
