import AppCore
import AppKit
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hanlabong PDF"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = NSHostingView(rootView: PDFWindowView(session: session))
        window.center()
        window.setFrameAutosaveName("HanlabongPDF")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
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
