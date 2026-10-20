// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "redpen",
    platforms: [.macOS("14.0")],
    dependencies: [
        // Sparkle, the updater most Mac apps outside the App Store use: one-click updates, each checked against Redpen's key.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "RedpenCore"),
        .executableTarget(name: "Redpen", dependencies: ["RedpenCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "redpen-test", dependencies: ["RedpenCore"]),
    ]
)
