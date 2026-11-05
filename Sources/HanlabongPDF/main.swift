import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// Hanlabong PDF: 한라봉 애드온. 아크로뱃처럼 PDF를 보고 고친다(PdfCraft를 참고, 맥 PDFKit으로 다시 짬).
/// 한라봉 휠 ⌘ › Hanlabong PDF에 파일을 놓으면 이 앱이 그 파일을 열고 켜진다.
@MainActor
final class PDFAppDelegate: NSObject, NSApplicationDelegate {
    let session = PDFSession()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) { showWindow() }

    func application(_ application: NSApplication, open urls: [URL]) {
        session.open(urls)
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 저장 안 한 고침이 있으면 끄기 전에 묻는다
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.dirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("저장하지 않은 고침이 있어요", "You have unsaved changes")
        alert.informativeText = L("저장하면 원본 옆에 새 파일(_edit)이 생겨요.", "Saving makes a new file (_edit) beside the original.")
        alert.addButton(withTitle: L("저장하고 끄기", "Save and quit"))
        alert.addButton(withTitle: L("그냥 끄기", "Quit without saving"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: session.save(.normal); return .terminateNow
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.preferredSize(for: nil)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hanlabong PDF"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = NSHostingView(rootView: PDFWindowView(session: session))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // 새 문서를 열 때마다: 미리보기 앱에서 스페이스를 누른 것처럼 화면의 6/10 정도 크기로, 쪽 모양에 맞춰 가운데
        session.onDocumentShown = { [weak self, weak window] doc in
            guard let window, let size = self.map({ _ in Self.preferredSize(for: doc) }), !window.styleMask.contains(.fullScreen) else { return }
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let origin = CGPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            window.animator().setFrame(NSRect(origin: origin, size: frame.size), display: true)
        }
        NSApp.activate()
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
}

MainActor.assumeIsolated {
    AddonBootstrap.syncFromMainApp()
    let app = NSApplication.shared
    let delegate = PDFAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = AddonMenu.make(appName: "Hanlabong PDF")
    app.run()
}
