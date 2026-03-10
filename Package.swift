// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Cosmodrome",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .executable(name: "CosmodromeApp", targets: ["CosmodromeApp"]),
        .executable(name: "CosmodromeHook", targets: ["CosmodromeHook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: ["SwiftTerm", "Yams"],
            path: "Sources/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CosmodromeApp",
            dependencies: ["Core"],
            path: "Sources/CosmodromeApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CosmodromeHook",
            dependencies: [],
            path: "Sources/CosmodromeHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
