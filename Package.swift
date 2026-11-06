// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SequoiaHotspot",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "SequoiaHotspot", targets: ["SequoiaHotspot"])],
    targets: [
        .target(name: "HotspotCore"),
        .executableTarget(name: "SequoiaHotspot", dependencies: ["HotspotCore"]),
        .executableTarget(name: "HotspotCoreChecks", dependencies: ["HotspotCore"], path: "Tests/HotspotCoreTests"),
    ]
)
