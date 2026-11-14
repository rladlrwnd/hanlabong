import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// Hanlabong PDF: 한라봉 애드온. 아크로뱃처럼 PDF를 보고 고친다(PdfCraft를 참고, 맥 PDFKit으로 다시 짬).
/// 한라봉 휠 ⌘ › Hanlabong PDF에 파일을 놓으면 이 앱이 그 파일을 열고 켜진다.
/// 창 하나 = 문서 하나. 창마다 자기 PDFSession을 갖는다
@MainActor
final class PDFWindowController: NSObject, NSWindowDelegate {
    let session = PDFSession()
    let window: NSWindow
    var onClose: ((PDFWindowController) -> Void)?

    init(cascadeFrom previous: NSWindow?) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: PDFAppDelegate.preferredSize(for: nil)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hanlabong PDF"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 560)
        window.tabbingMode = .disallowed
        // 안의 화면(긴 AI 답, 쌓이는 단추)이 창 크기를 늘리거나 최소 크기를 잡지 못하게: 창 크기는 창이 정한다
        let host = NSHostingView(rootView: PDFWindowView(session: session))
        host.sizingOptions = []
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let previous, previous.isVisible, !previous.styleMask.contains(.fullScreen) {
            // 앞 창에서 오른쪽 아래로 조금 비켜서 연다(겹쳐도 둘 다 보이게)
            let topLeft = CGPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: window.cascadeTopLeft(from: topLeft)))
        } else {
            window.center()
        }
        // 새 문서를 열 때마다: 미리보기 앱에서 스페이스를 누른 것처럼 화면의 6/10 정도 크기로, 쪽 모양에 맞춰서.
        // 창이 여러 개라 화면 가운데로 모으지 않고 지금 창 자리를 기준으로 크기만 맞춘다(화면 밖으로는 안 나가게)
        session.onDocumentShown = { [weak self] doc in
            guard let self else { return }
            self.window.title = self.session.title
            guard !self.window.styleMask.contains(.fullScreen) else { return }
            let screen = (self.window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let frame = self.window.frameRect(forContentRect: NSRect(origin: .zero, size: PDFAppDelegate.preferredSize(for: doc)))
            let center = CGPoint(x: self.window.frame.midX, y: self.window.frame.midY)
            var origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
            origin.x = min(max(origin.x, screen.minX), screen.maxX - frame.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - frame.height)
            self.window.animator().setFrame(NSRect(origin: origin, size: frame.size), display: true)
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 저장 안 한 고침이 있으면 이 창을 닫기 전에 묻는다
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.dirty else { return true }
        switch PDFAppDelegate.askUnsaved(L("“\(session.title)”에 저장하지 않은 고침이 있어요", "“\(session.title)” has unsaved changes"), close: L("저장하고 닫기", "Save and close"), discard: L("그냥 닫기", "Close without saving")) {
        case .save: session.save(.normal); return true
        case .discard: return true
        case .cancel: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        session.assistantTask?.cancel()
        session.indexTask?.cancel()
        onClose?(self)
    }
}

/// Hanlabong PDF: 한라봉 애드온. 아크로뱃처럼 PDF를 보고 고친다(PdfCraft를 참고, 맥 PDFKit으로 다시 짬).
/// 한라봉 휠 ⌘ › Hanlabong PDF에 파일을 놓으면 이 앱이 그 파일을 열고 켜진다. 파일마다 창이 따로 뜬다.
@MainActor
final class PDFAppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [PDFWindowController] = []
    private var launchedWithFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 파일을 넘겨받아 켜졌으면 그 창이 이미 떴다. 그냥 켰을 때만 빈 창
        if controllers.isEmpty { newWindow().show() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock 아이콘을 눌렀는데 창이 없으면 빈 창
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { (controllers.first ?? newWindow()).show() }
        return true
    }

    /// 파일 열기: 파일마다 창 하나. 이미 열린 파일이면 그 창을 앞으로, 빈 창이 있으면 거기에, 아니면 새 창에
    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = controllers.first(where: { $0.session.url?.standardizedFileURL == url.standardizedFileURL }) {
                existing.show()
                continue
            }
            let target = controllers.first(where: { $0.session.document == nil && !$0.session.needsPassword }) ?? newWindow()
            target.session.open([url])
            target.show()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = L("열 파일을 골라요 · 여러 개를 고르면 파일마다 창이 따로 떠요", "Choose files · each opens in its own window")
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func newDocumentWindow(_ sender: Any?) { newWindow().show() }

    private func newWindow() -> PDFWindowController {
        let controller = PDFWindowController(cascadeFrom: NSApp.keyWindow ?? controllers.last?.window)
        controller.session.openElsewhere = { [weak self] urls in
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
        let dirty = controllers.filter(\.session.dirty)
        guard !dirty.isEmpty else { return .terminateNow }
        let title = dirty.count == 1
            ? L("“\(dirty[0].session.title)”에 저장하지 않은 고침이 있어요", "“\(dirty[0].session.title)” has unsaved changes")
            : L("저장하지 않은 문서가 \(dirty.count)개 있어요", "\(dirty.count) documents have unsaved changes")
        switch Self.askUnsaved(title, close: L("저장하고 끄기", "Save and quit"), discard: L("그냥 끄기", "Quit without saving")) {
        case .save: dirty.forEach { $0.session.save(.normal) }; return .terminateNow
        case .discard: return .terminateNow
        case .cancel: return .terminateCancel
        }
    }

    enum UnsavedChoice { case save, discard, cancel }

    static func askUnsaved(_ title: String, close: String, discard: String) -> UnsavedChoice {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L("저장하면 원본 옆에 새 파일(_edit)이 생겨요.", "Saving makes a new file (_edit) beside the original.")
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
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var page = document?.page(at: 0)?.bounds(for: .cropBox).size ?? NSSize(width: 595, height: 842)
        if let rotation = document?.page(at: 0)?.rotation, rotation % 180 != 0 { page = NSSize(width: page.height, height: page.width) }
        let height = screen.height * 0.78
        let width = min(max((height - 110) * page.width / max(page.height, 1) + 150, 720), screen.width * 0.6)
        return NSSize(width: width.rounded(), height: height.rounded())
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
    let delegate = PDFAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let menu = AddonMenu.make(appName: "Hanlabong PDF")
    menu.insertItem(PDFAppDelegate.fileMenu(), at: 1)
    app.mainMenu = menu
    app.run()
}
