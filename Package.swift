// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapMark",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SnapMark",
            path: "Sources/SnapMark",
            resources: [
                .copy("Resources/en.lproj"),
                .copy("Resources/zh-Hans.lproj"),
                .copy("Resources/zh-Hant.lproj"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
