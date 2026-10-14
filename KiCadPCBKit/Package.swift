// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KiCadPCBKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KiCadPCBKit", targets: ["KiCadPCBKit"]),
        .executable(name: "kiql-render", targets: ["kiql-render"]),
    ],
    targets: [
        .target(name: "KiCadPCBKit"),
        .executableTarget(name: "kiql-render", dependencies: ["KiCadPCBKit"]),
        .testTarget(name: "KiCadPCBKitTests", dependencies: ["KiCadPCBKit"]),
    ]
)
