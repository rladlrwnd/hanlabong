import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// Hanlabong Developing: 한라봉 애드온. 라이트룸처럼 사진을 현상한다(LightCraft를 참고, 맥 Core Image로 다시 짬).
/// 한라봉 휠 ⌘ › 현상 › …에 사진을 놓으면 이 앱이 그 사진을 열고 켜진다.
@MainActor
final class DevelopingDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session = DevelopSession()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
    }

    /// Finder·한라봉 휠에서 넘겨받은 사진
    func application(_ application: NSApplication, open urls: [URL]) {
        session.open(urls)
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hanlabong Developing"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = NSHostingView(rootView: DevelopView(session: session))
        window.center()
        window.setFrameAutosaveName("HanlabongDeveloping")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }
}

MainActor.assumeIsolated {
    AddonBootstrap.syncFromMainApp()      // 언어·강조색을 한라봉 본체에 맞춘 뒤에 화면 글자를 만든다
    let app = NSApplication.shared
    let delegate = DevelopingDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = AddonMenu.make(appName: "Hanlabong Developing")
    app.run()
}
