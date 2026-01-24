// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceMemo",
    platforms: [
        .macOS(.v13) // ScreenCaptureKit audio capture requires macOS 13.0+
    ],
    products: [
        .executable(name: "VoiceMemo", targets: ["VoiceMemo"])
    ],
    dependencies: [
        .package(url: "https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2.git", from: "0.1.0-beta"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.14.1"),
        .package(url: "https://github.com/vapor/mysql-kit.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceMemo",
            dependencies: [
                .product(name: "AlibabaCloudOSS", package: "alibabacloud-oss-swift-sdk-v2"),
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "MySQLKit", package: "mysql-kit")
            ],
            path: "Sources/VoiceMemo",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .copy("Resources/AppIcon.icns")
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "VoiceMemoTests",
            dependencies: ["VoiceMemo"],
            path: "Tests/VoiceMemoTests"
        )
    ]
)
