// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Treemap",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TreemapCore", targets: ["TreemapCore"]),
        .executable(name: "treemap-bench", targets: ["treemap-bench"]),
        .executable(name: "make-icon", targets: ["make-icon"]),
    ],
    targets: [
        .target(name: "TreemapCore"),
        .executableTarget(name: "treemap-bench", dependencies: ["TreemapCore"]),
        .executableTarget(name: "make-icon", dependencies: ["TreemapCore"]),
        .testTarget(name: "TreemapCoreTests", dependencies: ["TreemapCore"]),
    ],
    swiftLanguageModes: [.v6]
)
