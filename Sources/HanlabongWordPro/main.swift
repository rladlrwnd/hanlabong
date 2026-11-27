import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// Hanlabong WordPro: 한라봉 애드온. 앱은 하나인데 파일 형식마다 켜지는 "영역"이 다르다(WorkspaceContract.swift의 DocumentArea).
/// PDF 영역은 아크로뱃처럼 PDF를 보고 고치고(예전 Hanlabong PDF), 워드·한글·노트 영역은 문서를 쓴다.
/// 창 하나 = 문서 하나. 창마다 자기 영역의 세션을 하나 갖고, 안 쓰는 영역은 그 창이 열릴 때까지 만들지 않는다.
@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    /// 이 창이 지금 띄운 영역과 그 세션
    enum Pane {
        case pdf(PDFSession)
        case document(DocumentSession, DocumentArea)
    }

    private(set) var pane: Pane
    let window: NSWindow
    var onClose: ((WorkspaceWindowController) -> Void)?
    /// 이 창에 다른 파일(이미 문서가 있거나 영역이 다른 파일)이 오면 앱이 다른 창에 열도록 넘긴다
    var openElsewhere: (([URL]) -> Void)?

    init(area: DocumentArea, cascadeFrom previous: NSWindow?) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: WordProAppDelegate.preferredSize(for: nil)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        pane = Self.makePane(area)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hanlabong WordPro"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 560)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        install()
        if let previous, previous.isVisible, !previous.styleMask.contains(.fullScreen) {
            // 앞 창에서 오른쪽 아래로 조금 비켜서 연다(겹쳐도 둘 다 보이게)
            let topLeft = CGPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: window.cascadeTopLeft(from: topLeft)))
        } else {
            window.center()
        }
    }

    private static func makePane(_ area: DocumentArea) -> Pane {
        area == .pdf ? .pdf(PDFSession()) : .document(DocumentSession(area: area), area)
    }

    // MARK: 세션 정보(영역과 상관없이)

    var area: DocumentArea {
        switch pane {
        case .pdf: return .pdf
        case .document(_, let area): return area
        }
    }

    var url: URL? {
        switch pane {
        case .pdf(let session): return session.url
        case .document(let session, _): return session.url
        }
    }

    /// 아직 아무 파일도 안 연 빈 창인가(암호를 묻는 중인 PDF 창은 빈 창이 아니다)
    var isEmpty: Bool {
        switch pane {
        case .pdf(let session): return session.document == nil && !session.needsPassword
        case .document(let session, _): return session.url == nil
        }
    }

    var dirty: Bool {
        switch pane {
        case .pdf(let session): return session.dirty
        case .document(let session, _): return session.dirty
        }
    }

    var title: String {
        switch pane {
        case .pdf(let session): return session.title
        case .document(let session, _): return session.title
        }
    }

    /// 저장. 문서 영역은 끝날 때까지 기다렸다가 성공했는지 돌려준다(실패하면 창을 닫거나 앱을 끄지 않게). PDF는 예전처럼 늘 true
    @discardableResult
    func save() -> Bool {
        switch pane {
        case .pdf(let session): session.save(.normal); return true
        case .document(let session, _): return session.save()
        }
    }

    // MARK: 열기

    /// 이 창에 파일 하나를 연다. 빈 창인데 영역이 다르면 그 영역 화면으로 갈아 끼운 뒤에 연다
    func open(_ url: URL) {
        let wanted = DocumentArea.of(url) ?? .pdf     // 사진 등 모르는 형식은 PDF 영역이 한 쪽짜리로 연다
        if wanted != area, isEmpty {
            stopWork()
            pane = Self.makePane(wanted)
            install()
        }
        switch pane {
        case .pdf(let session): session.open([url])
        case .document(let session, _): session.open(url)
        }
    }

    /// 지금 세션의 화면을 창에 붙이고, 문서가 뜨면 창 제목·크기를 맞추게 묶는다
    private func install() {
        let root: AnyView
        switch pane {
        case .pdf(let session):
            root = AnyView(PDFWindowView(session: session))
            session.openElsewhere = { [weak self] urls in self?.openElsewhere?(urls) }
            session.onDocumentShown = { [weak self, weak session] doc in
                guard let self, let session else { return }
                self.documentShown(title: session.title, size: WordProAppDelegate.preferredSize(for: doc))
            }
        case .document(let session, _):
            root = AnyView(DocumentWindowView(session: session))
            session.openElsewhere = { [weak self] url in self?.openElsewhere?([url]) }
            session.onDocumentShown = { [weak self, weak session] in
                guard let self, let session else { return }
                self.documentShown(title: session.title, size: WordProAppDelegate.preferredDocumentSize())
            }
        }
        // 안의 화면(긴 AI 답, 쌓이는 단추)이 창 크기를 늘리거나 최소 크기를 잡지 못하게: 창 크기는 창이 정한다
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.title = title
    }

    /// 새 문서를 열 때마다: 미리보기 앱에서 스페이스를 누른 것처럼 화면의 6/10 정도 크기로, 쪽 모양에 맞춰서.
    /// 창이 여러 개라 화면 가운데로 모으지 않고 지금 창 자리를 기준으로 크기만 맞춘다(화면 밖으로는 안 나가게)
    private func documentShown(title: String, size: NSSize) {
        window.title = title
        guard !window.styleMask.contains(.fullScreen) else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        var origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - frame.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - frame.height)
        window.animator().setFrame(NSRect(origin: origin, size: frame.size), display: true)
    }

    private func stopWork() {
        switch pane {
        case .pdf(let session):
            session.assistantTask?.cancel()
            session.indexTask?.cancel()
        case .document(let session, _):
            session.stopAssistant()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 저장 안 한 고침이 있으면 이 창을 닫기 전에 묻는다
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        switch WordProAppDelegate.askUnsaved(L("“\(title)”에 저장하지 않은 고침이 있어요", "“\(title)” has unsaved changes"),
                                         note: WordProAppDelegate.saveNote(for: [area]),
                                         close: L("저장하고 닫기", "Save and close"), discard: L("그냥 닫기", "Close without saving")) {
        case .save: return save()
        case .discard: return true
        case .cancel: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopWork()
        onClose?(self)
    }
}

/// 한라봉 휠 ⌘ › Hanlabong WordPro에 파일을 놓으면 이 앱이 그 파일을 열고 켜진다. 파일마다 창이 따로 뜨고,
/// 파일 형식(DocumentArea.of)에 따라 그 창이 PDF 영역이 될지 워드·한글·노트 영역이 될지 정해진다.
@MainActor
final class WordProAppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [WorkspaceWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 파일을 넘겨받아 켜졌으면 그 창이 이미 떴다. 그냥 켰을 때만 빈 창
        if controllers.isEmpty { newWindow(.pdf).show() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock 아이콘을 눌렀는데 창이 없으면 빈 창
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { (controllers.first ?? newWindow(.pdf)).show() }
        return true
    }

    /// 파일 열기: 파일마다 창 하나. 이미 열린 파일이면 그 창을 앞으로,
    /// 빈 창이 있으면 거기에(같은 영역의 빈 창을 먼저, 없으면 다른 영역의 빈 창을 그 영역으로 바꿔서), 아니면 새 창에
    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = controllers.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                existing.show()
                continue
            }
            let area = DocumentArea.of(url) ?? .pdf
            let target = controllers.first(where: { $0.isEmpty && $0.area == area })
                ?? controllers.first(where: \.isEmpty)
                ?? newWindow(area)
            target.open(url)
            target.show()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        // 형식을 막지 않는다: PDF·워드·한글·노트 + 사진처럼 PDF 영역이 바꿔서 여는 파일도 고를 수 있게
        panel.message = L("열 파일을 골라요 · PDF·워드·한글·노트 · 여러 개를 고르면 파일마다 창이 따로 떠요",
                          "Choose files · PDF, Word, Hangul, notes · each opens in its own window")
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func newDocumentWindow(_ sender: Any?) { newWindow(.pdf).show() }

    private func newWindow(_ area: DocumentArea) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(area: area, cascadeFrom: NSApp.keyWindow ?? controllers.last?.window)
        controller.openElsewhere = { [weak self] urls in
            self?.open(urls)
        }
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        return controller
    }

    /// 저장 안 한 고침이 있으면 끄기 전에 묻는다(창 여러 개면 한꺼번에)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = controllers.filter(\.dirty)
        guard !dirty.isEmpty else { return .terminateNow }
        let title = dirty.count == 1
            ? L("“\(dirty[0].title)”에 저장하지 않은 고침이 있어요", "“\(dirty[0].title)” has unsaved changes")
            : L("저장하지 않은 문서가 \(dirty.count)개 있어요", "\(dirty.count) documents have unsaved changes")
        switch Self.askUnsaved(title, note: Self.saveNote(for: dirty.map(\.area)),
                               close: L("저장하고 끄기", "Save and quit"), discard: L("그냥 끄기", "Quit without saving")) {
        case .save:
            let saved = dirty.map { $0.save() }
            return saved.allSatisfy { $0 } ? .terminateNow : .terminateCancel
        case .discard: return .terminateNow
        case .cancel: return .terminateCancel
        }
    }

    enum UnsavedChoice { case save, discard, cancel }

    /// 저장하면 어떻게 되는지 한 줄. PDF·문서 영역 모두 원본 옆 _edit 파일(원본은 그대로)
    static func saveNote(for areas: [DocumentArea]) -> String? {
        L("저장하면 원본 옆에 새 파일(_edit)이 생겨요.", "Saving makes a new file (_edit) beside the original.")
    }

    static func askUnsaved(_ title: String, note: String?, close: String, discard: String) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = title
        if let note { alert.informativeText = note }
        alert.addButton(withTitle: close)
        alert.addButton(withTitle: discard)
        alert.addButton(withTitle: L("취소", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// 창 크기: 화면 높이의 78%를 기준으로 쪽 가로세로 비율에 맞추고, 가로는 화면의 60%를 넘지 않게
    static func preferredSize(for document: PDFDocument?) -> NSSize {
        var page = document?.page(at: 0)?.bounds(for: .cropBox).size ?? a4
        if let rotation = document?.page(at: 0)?.rotation, rotation % 180 != 0 { page = NSSize(width: page.height, height: page.width) }
        return preferredSize(page: page)
    }

    /// 워드·한글·노트 창 크기: A4 세로 비율로 PDF와 같은 규칙
    static func preferredDocumentSize() -> NSSize { preferredSize(page: a4) }

    private static let a4 = NSSize(width: 595, height: 842)

    private static func preferredSize(page: NSSize) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let height = screen.height * 0.78
        let width = min(max((height - 110) * page.width / max(page.height, 1) + 150, 720), screen.width * 0.6)
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// 찾기 메뉴: 글 칸이 가진 찾기 막대(NSTextFinder)를 그대로 부른다. 받는 쪽은 마우스·키보드가 가 있는 글 칸(문서 종이)이라,
    /// 요청칸 같은 다른 칸에 가 있으면 저절로 꺼진다(⌘F만 창의 숨은 단추가 받아 종이로 옮겨서 연다)
    static func findMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("찾기", "Find"))
        func add(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ mask: NSEvent.ModifierFlags = [.command]) {
            let entry = NSMenuItem(title: title, action: Selector(("performTextFinderAction:")), keyEquivalent: key)
            entry.tag = action.rawValue
            entry.keyEquivalentModifierMask = mask
            menu.addItem(entry)
        }
        add(L("찾기…", "Find…"), .showFindInterface, "f")
        add(L("찾아 바꾸기…", "Find and Replace…"), .showReplaceInterface, "f", [.command, .option])
        add(L("다음 찾기", "Find Next"), .nextMatch, "g")
        add(L("이전 찾기", "Find Previous"), .previousMatch, "g", [.command, .shift])
        item.submenu = menu
        return item
    }

    /// 파일 메뉴: 새 창 ⌘N, 열기 ⌘O (열면 파일마다 새 창)
    static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("파일", "File"))
        menu.addItem(withTitle: L("새 창", "New Window"), action: #selector(newDocumentWindow(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: L("열기…", "Open…"), action: #selector(openDocument(_:)), keyEquivalent: "o")
        item.submenu = menu
        return item
    }
}

MainActor.assumeIsolated {
    AddonBootstrap.syncFromMainApp()
    let app = NSApplication.shared
    let delegate = WordProAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let menu = AddonMenu.make(appName: "Hanlabong WordPro")
    menu.insertItem(WordProAppDelegate.fileMenu(), at: 1)
    // 편집 메뉴(파일 다음) 바로 뒤에 찾기 메뉴
    menu.insertItem(WordProAppDelegate.findMenu(), at: min(3, menu.numberOfItems))
    app.mainMenu = menu
    app.run()
}
