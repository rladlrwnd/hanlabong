// swift-tools-version:6.0
import PackageDescription

// DragEdit = Prism(글자 팝업) + 파일 기능. 앱은 하나이고 안에서 모듈로 나눈다.
//   SkillEngine  블록 실행 엔진 (UI와 분리, 테스트 대상)
//   AppCore      메뉴 막대·단축키·비활성 패널·권한 창·설정 창 틀·AI 레이어·키체인
//   TextFeature  글자 팝업 (선택 글자 읽기·붙여넣기·클립보드·스킬)
//   FileFeature  파일 기능 (드래그 감지·휠·파일 블록·진행/검토/기록) — 아직 빈 틀
//   DragEdit     앱 타깃. 위 모듈을 묶기만 하는 얇은 층
let package = Package(
    name: "DragEdit",
    platforms: [.macOS("26.0")],
    dependencies: [
        // libraries.dev Border Beam의 공식 SwiftUI 포트 (MIT). 출처는 Vendor/BorderBeamKit/VENDORED.txt.
        // .metal 셰이더는 Xcode 빌드 시스템이 컴파일하므로 scripts/build-app.sh는 xcodebuild를 쓴다.
        .package(path: "Vendor/BorderBeamKit"),
        // 같은 저장소의 thinking-orbs(AI 처리 중 표시)와 bot-avatars(에이전트 아바타, macOS용으로 수정).
        .package(path: "Vendor/ThinkingOrbsKit"),
        .package(path: "Vendor/BotAvatarsKit"),
    ],
    targets: [
        // 기본 블록·조건·문장 나누기·스킬 JSON. UI와 분리해서 테스트한다.
        .target(
            name: "SkillEngine",
            path: "Sources/SkillEngine"
        ),
        .target(
            name: "AppCore",
            dependencies: [
                "SkillEngine",
                .product(name: "BotAvatarsKit", package: "BotAvatarsKit"),
            ],
            path: "Sources/AppCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .target(
            name: "TextFeature",
            dependencies: [
                "AppCore",
                "SkillEngine",
                .product(name: "BorderBeamKit", package: "BorderBeamKit"),
                .product(name: "ThinkingOrbsKit", package: "ThinkingOrbsKit"),
                .product(name: "BotAvatarsKit", package: "BotAvatarsKit"),
            ],
            path: "Sources/TextFeature",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .target(
            name: "FileFeature",
            dependencies: [
                "AppCore",
                "SkillEngine",
                .product(name: "BorderBeamKit", package: "BorderBeamKit"),
                .product(name: "ThinkingOrbsKit", package: "ThinkingOrbsKit"),
                .product(name: "BotAvatarsKit", package: "BotAvatarsKit"),
            ],
            path: "Sources/FileFeature",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "DragEdit",
            dependencies: ["AppCore", "TextFeature", "FileFeature", "SkillEngine"],
            path: "Sources/DragEdit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FileFeatureTests",
            dependencies: ["FileFeature", "SkillEngine", "AppCore"],
            path: "Tests/FileFeatureTests"
        ),
        .testTarget(
            name: "SkillEngineTests",
            dependencies: ["SkillEngine"],
            path: "Tests/SkillEngineTests"
        ),
    ]
)
