// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReKap",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "ReKap", targets: ["ReKap"])],
    targets: [
        .target(name: "ReKapCore"),
        .executableTarget(name: "ReKap", dependencies: ["ReKapCore"], linkerSettings: [.linkedFramework("AVKit")]),
        .testTarget(name: "ReKapCoreTests", dependencies: ["ReKapCore"])
    ]
)
