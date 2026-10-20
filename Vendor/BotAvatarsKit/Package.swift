// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BotAvatarsKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),  // PATCHED(TextPopup): macOS support, see VENDORED.txt
    ],
    products: [
        .library(name: "BotAvatarsKit", targets: ["BotAvatarsKit"])
    ],
    targets: [
        .target(
            name: "BotAvatarsKit",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
    ]
)
