// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
