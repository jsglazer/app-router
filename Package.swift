// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "app-router",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppRouterCore", targets: ["AppRouterCore"]),
        .executable(name: "app-router", targets: ["AppRouter"])
    ],
    targets: [
        // Platform-agnostic domain logic. No AppKit / UIKit / SwiftUI, no file/network I/O.
        .target(
            name: "AppRouterCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        // OS shell: AppKit UI, Launch Services + Process adapters, file watcher, CLI entry.
        .executableTarget(
            name: "AppRouter",
            dependencies: ["AppRouterCore"],
            // Info.plist is embedded via the linker flag below, not bundled as a resource.
            exclude: ["Info.plist"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                // Embed Info.plist (declared document types + URL schemes) into the binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AppRouter/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "AppRouterCoreTests",
            dependencies: ["AppRouterCore"]
        )
    ]
)
