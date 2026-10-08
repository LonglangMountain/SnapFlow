// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnapFlow",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SnapFlow",
            path: "Sources/SnapFlow",
            swiftSettings: [
                // Phase 1 AppKit code is main-thread bound; use the Swift 5
                // language mode to keep the Carbon C-callback bridge simple.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage")
            ]
        )
    ]
)
