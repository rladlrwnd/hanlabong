import AppCore
import AppKit
import SkillEngine

/// 한라봉 애드온(따로 된 앱). 휠에서 파일을 넘겨 연다.
package enum Addon: String, Equatable, Sendable, CaseIterable {
    case developing, wordPro

    /// 식별자는 한라봉 본체처럼 예전 이름(dragedit) 흔적을 남긴다
    package var bundleIdentifier: String {
        switch self {
        case .developing: return "app.dragedit.Developing"
        case .wordPro: return "app.dragedit.PDF"   // 옛 Hanlabong PDF와 같은 식별자(권한·설정·기본 앱 지정이 이어진다)
        }
    }

    /// 업데이트 전에 깔려 있던 옛 앱 이름(새 이름이 없을 때만 찾는다)
    var legacyAppName: String? {
        switch self {
        case .developing: return nil
        case .wordPro: return "Hanlabong PDF"
        }
    }

    package var appName: String {
        switch self {
        case .developing: return "Hanlabong Developing"
        case .wordPro: return "Hanlabong WordPro"
        }
    }
}

@MainActor
enum AddonLauncher {
    /// 한라봉 바로 옆(같은 폴더: 응용 프로그램 또는 개발용 build 폴더)에 있는 걸 먼저, 없으면 맥이 아는 곳에서 찾는다
    static func appURL(_ addon: Addon) -> URL? {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        for name in [addon.appName] + (addon.legacyAppName.map { [$0] } ?? []) {
            let sibling = folder.appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: addon.bundleIdentifier)
    }

    /// 열었으면 true. 설치돼 있지 않으면 false(부르는 쪽에서 안내한다)
    @discardableResult
    static func open(_ addon: Addon, files: [URL]) -> Bool {
        guard let app = appURL(addon) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration) { _, error in
            if let error { log.error("addon open failed: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }
}
