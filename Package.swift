// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatVoiceRecorder",
    platforms: [
        .macOS(.v13) // ScreenCaptureKit audio capture requires macOS 13.0+
    ],
    products: [
        .executable(name: "WeChatVoiceRecorder", targets: ["WeChatVoiceRecorder"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "WeChatVoiceRecorder",
            dependencies: [],
            path: "Sources/WeChatVoiceRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
