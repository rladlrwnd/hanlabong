import SkillEngine
import AppCore
import AppKit
import ApplicationServices
import FileFeature
import Carbon.HIToolbox
import TextFeature

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let skills = SkillStore()
    private let agents = AgentStore()
    private lazy var popup = PopupController(store: skills, agents: agents)
    private lazy var settings: SettingsWindowController = {
        var extras = TextFeatureSettings.generalExtras()
        extras.sections.append(FileFeatureSettings.section)
        return SettingsWindowController(
            tabs: [TextFeatureSettings.skillsTab(store: skills, agents: agents)] + fileFeature.settingsTabs() + [fileFeature.historyTab()],
            agents: agents,
            extras: extras
        )
    }()
    private let permission = PermissionWindowController()
    private lazy var fileFeature = FileFeatureController(agents: agents)
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private let agentMenu = NSMenu()
    private let statusMenu = NSMenu()
    private let undoItem = NSMenuItem(title: L("마지막 파일 변환 되돌리기", "Undo last file conversion"), action: #selector(undoFileConversion), keyEquivalent: "")
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        skills.refresh()
        _ = popup
        setUpStatusItem()
        Task { await agents.refresh() }
        fileFeature.start()

        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey)
        hotKey?.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }
        if hotKey == nil {
            showAlert(L("⌥Space 단축키를 등록하지 못했어", "Couldn't register the ⌥Space shortcut"), L("다른 앱이 이미 같은 단축키를 쓰고 있을 수 있어.", "Another app may already be using it."))
        }

        if !AXIsProcessTrusted() { permission.show() }
        log.info("launched, trusted=\(AXIsProcessTrusted(), privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // DragEdit이 올린 로컬 모델은 끄면서 같이 내려 램을 돌려준다
        AIClient.unloadModelsUsedThisSession()
    }

    private func hotKeyPressed() {
        if popup.isOpen {
            popup.cancel()
            return
        }
        guard AXIsProcessTrusted() else {
            permission.show()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true

        // 팝업을 띄우기 전의 맨 앞 앱 = 결과를 넣을 앱
        let targetApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let selection = await SelectionReader.capture()
            popup.show(selection: selection, targetApp: targetApp)
            isCapturing = false
        }
    }

    // MARK: - 메뉴 막대 아이콘

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = PrismIcon.menuBarImage()

        let menu = statusMenu
        menu.delegate = self
        let hint = NSMenuItem(title: L("글자 드래그 → ⌥Space", "Select text → ⌥Space"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let agentItem = NSMenuItem(title: L("에이전트", "Agents"), action: nil, keyEquivalent: "")
        agentMenu.delegate = self
        agentItem.submenu = agentMenu
        menu.addItem(agentItem)
        menu.addItem(withTitle: L("설정…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("스킬 파일 편집…", "Edit skills file…"), action: #selector(editSkills), keyEquivalent: "").target = self
        menu.addItem(.separator())
        undoItem.target = self
        menu.addItem(undoItem)
        menu.addItem(withTitle: L("파일 변환 기록…", "File history…"), action: #selector(openFileHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("손쉬운 사용 권한…", "Accessibility access…"), action: #selector(openPermission), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let version = NSMenuItem(title: L("한라봉 \(AppVersion.label)", "Hanlabong \(AppVersion.label)"), action: nil, keyEquivalent: "")
        version.isEnabled = false                      // 지금 켜진 게 어느 버전인지 한눈에
        menu.addItem(version)
        menu.addItem(withTitle: L("한라봉 종료", "Quit Hanlabong"), action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    /// "에이전트" 하위 메뉴는 열 때마다 지금 쓸 수 있는 에이전트로 다시 채운다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            // 메뉴를 열 때마다 되돌릴 게 있는지 본다
            let count = fileFeature.undoableCount
            undoItem.isEnabled = count > 0
            undoItem.title = count > 0 ? L("마지막 파일 변환 되돌리기 (결과 \(count)개 → 휴지통)", "Undo last file conversion (\(count) result(s) → Trash)") : L("마지막 파일 변환 되돌리기", "Undo last file conversion")
            return
        }
        guard menu === agentMenu else { return }
        menu.removeAllItems()
        let selectedID = agents.selected?.id
        let local = agents.localAgents
        let cloud = agents.cloudAgents

        if local.isEmpty && cloud.isEmpty {
            let empty = NSMenuItem(title: L("쓸 수 있는 AI가 없어요", "No AI available"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (title, group) in [(L("이 컴퓨터", "This computer"), local), (L("클라우드", "Cloud"), cloud)] where !group.isEmpty {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for agent in group {
                let item = NSMenuItem(title: agent.name, action: #selector(pickAgent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = agent.id
                item.state = agent.id == selectedID ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("에이전트 설정…", "Agent settings…"), action: #selector(openAgentSettings), keyEquivalent: "").target = self
        Task { await agents.refreshIfStale() }
    }

    @objc private func pickAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let agent = agents.allAgents.first(where: { $0.id == id }) else { return }
        agents.select(agent)
    }

    @objc private func openPermission() { permission.show() }
    @objc private func openSettings() { settings.show() }
    @objc private func openAgentSettings() { settings.show(tab: SettingsWindowController.agentsTabID) }
    @objc private func editSkills() { skills.openInEditor() }
    @objc private func undoFileConversion() { fileFeature.undoLastConversion() }
    @objc private func openFileHistory() { settings.show(tab: FileFeatureSettings.historyTabID) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
