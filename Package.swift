// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "redpen",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "RedpenCore"),
        .executableTarget(name: "Redpen", dependencies: ["RedpenCore"]),
        .executableTarget(name: "redpen-test", dependencies: ["RedpenCore"]),
    ]
)
