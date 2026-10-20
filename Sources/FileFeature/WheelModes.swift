import Foundation
import SkillEngine

/// 도구 휠(⌘)과 동작 휠(⌃), 그리고 휠 종류를 고르는 규칙
extension WheelLayout {
    /// 도구 휠: 파일 종류에 맞는 손질 도구(편집·회전·반전·용량 줄이기 등)
    package static func tools(forDraggedFileExtensions extensions: [String], ai: AIDestination? = nil) -> WheelLayout {
        let kinds = Set(extensions.compactMap { FileKindGuess.kind(forExtension: $0) })
        func group(_ id: String, _ title: String, _ symbol: String, _ skills: [FileSkill]) -> WheelItem {
            WheelItem(id: id, title: title, symbol: symbol, children: skills.map(WheelItem.init(skill:)))
        }
        if kinds.contains(.image) || kinds.contains(.raw) {
            return WheelLayout(slots: [
                WheelItem(id: "crop", title: L("편집", "Edit"), symbol: "crop", subtitle: L("자르기·회전·보정", "Crop · rotate · adjust"), edit: .image),
                group("rotate", L("회전", "Rotate"), "rotate.right", [DefaultFileSkills.rotateRight, DefaultFileSkills.rotateLeft, DefaultFileSkills.rotateHalf]),
                group("flip", L("반전", "Flip"), "arrow.left.and.right.righttriangle.left.righttriangle.right", [DefaultFileSkills.flipHorizontal, DefaultFileSkills.flipVertical]),
                group("shrink", L("용량 줄이기", "Shrink"), "arrow.down.right.and.arrow.up.left", [DefaultFileSkills.shrinkGentle, DefaultFileSkills.shrink2MB, DefaultFileSkills.shrink500KB]),
            ], mode: .tools)
        }
        if kinds.contains(.video) {
            return WheelLayout(slots: [
                WheelItem(id: "vedit", title: L("편집", "Edit"), symbol: "scissors", subtitle: L("구간 자르기·소리 끄기", "Trim · mute"), edit: .video),
                WheelItem(skill: DefaultFileSkills.videoMute),
                WheelItem(skill: DefaultFileSkills.videoShrink),
            ], mode: .tools)
        }
        if kinds.contains(.pdf) {
            return WheelLayout(slots: [
                WheelItem(skill: DefaultFileSkills.pdfAddText),
                whatIsItem(ai),
            ], mode: .tools)
        }
        if kinds.contains(.text) {
            return WheelLayout(slots: [whatIsItem(ai)], mode: .tools)
        }
        return WheelLayout(slots: [], emptyMessage: L("이 파일에 쓸 도구가 없어요 · ⌃ 동작 휠", "No tools for this file · ⌃ Actions"), mode: .tools)
    }

    /// 동작 휠: 어떤 파일·폴더에도 쓴다. 복사·이동은 최근에 쓴 폴더가 있으면 2단계로 펼친다.
    package static func actions(recentFolders: [URL] = []) -> WheelLayout {
        func destinations(_ make: (URL?) -> FileAction, title: String, symbol: String, id: String) -> WheelItem {
            let pick = WheelItem(id: "\(id)-pick", title: L("폴더 고르기…", "Choose folder…"), symbol: "folder.badge.plus",
                                 subtitle: L("어디로 \(title)할지 골라요", "Pick a destination"), fileAction: make(nil))
            guard !recentFolders.isEmpty else {
                return WheelItem(id: id, title: title, symbol: symbol, subtitle: L("폴더를 골라서 \(title)해요", "Pick a folder"), fileAction: make(nil))
            }
            let recents = recentFolders.prefix(4).map { folder in
                WheelItem(id: "\(id)-\(folder.path)", title: folder.lastPathComponent, symbol: "folder",
                          subtitle: folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), fileAction: make(folder))
            }
            return WheelItem(id: id, title: title, symbol: symbol, children: Array(recents) + [pick])
        }
        return WheelLayout(slots: [
            WheelItem(id: "airdrop", title: "AirDrop", symbol: "airplayaudio", subtitle: L("근처 애플 기기로 보내요", "Send to a nearby Apple device"), fileAction: .airDrop),
            WheelItem(id: "float", title: L("띄워두기", "Float"), symbol: "pin", subtitle: L("화면 위에 띄워두고 나중에 끌어 쓰기", "Keep it on screen and drag it out later"), fileAction: .float),
            destinations({ .copy(to: $0) }, title: L("복사", "Copy"), symbol: "doc.on.doc", id: "copy"),
            destinations({ .move(to: $0) }, title: L("이동", "Move"), symbol: "folder", id: "move"),
            WheelItem(id: "copypath", title: L("경로 복사", "Copy path"), symbol: "link", subtitle: L("파일 위치를 글자로 복사해요", "Copies the file location as text"), fileAction: .copyPath),
            WheelItem(id: "terminal", title: L("터미널", "Terminal"), symbol: "terminal", subtitle: L("이 폴더에서 터미널을 열어요", "Opens Terminal in this folder"), fileAction: .terminal),
        ], mode: .actions)
    }

    /// 키로 고른 휠 종류 + 끌고 있는 것 → 보여줄 휠.
    /// 폴더가 섞였거나 변환·도구가 없는 파일이면 동작 휠로 바로 연다.
    package static func layout(mode: WheelMode, extensions: [String], containsFolders: Bool, ai: AIDestination?,
                               whatIsAI: AIDestination? = nil, config: WheelConfig = .default, recentFolders: [URL] = []) -> WheelLayout {
        if mode == .actions || containsFolders { return actions(recentFolders: recentFolders) }
        let layout: WheelLayout
        switch mode {
        case .convert: layout = WheelLayout.layout(forDraggedFileExtensions: extensions, ai: ai, config: config)
        case .tools: layout = tools(forDraggedFileExtensions: extensions, ai: whatIsAI ?? ai)
        case .actions: layout = actions(recentFolders: recentFolders)
        }
        return layout.slots.allSatisfy({ $0 == nil }) ? actions(recentFolders: recentFolders) : layout
    }
}

/// 복사·이동에 최근 쓴 폴더(최대 4개, 이 맥에만 저장)
package enum RecentFolders {
    private static let key = "recentActionFolders"

    package static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    package static func remember(_ folder: URL) {
        var list = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != folder.path }
        list.insert(folder.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(4)), forKey: key)
    }
}
