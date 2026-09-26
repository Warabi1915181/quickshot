// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickShot",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .target(
            name: "QuickShotCore",
            path: "Sources/QuickShotCore"
        ),
        .executableTarget(
            name: "QuickShot",
            dependencies: ["QuickShotCore"],
            path: "Sources/QuickShot"
        ),
        .testTarget(
            name: "QuickShotCoreTests",
            dependencies: ["QuickShotCore"],
            path: "Tests/QuickShotCoreTests"
        ),
        .testTarget(
            name: "QuickShotUITests",
            dependencies: ["QuickShot"],
            path: "Tests/QuickShotUITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
