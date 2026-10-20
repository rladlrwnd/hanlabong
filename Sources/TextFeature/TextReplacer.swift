import AppCore
import AppKit

/// 결과를 원래 글자 자리에 넣는다: 클립보드에 잠깐 결과를 올리고 ⌘V → 원래 클립보드로 복원.
/// ⌘V로 넣기 때문에 원래 앱의 실행 취소(⌘Z)로 되돌릴 수 있다.
package enum TextReplacer {
    @MainActor
    package static func replaceSelection(with text: String, in targetApp: NSRunningApplication?) async {
        // 팝업은 앱을 활성화하지 않으므로 원래 앱이 계속 맨 앞에 있어야 정상이다.
        // 혹시라도 우리 앱이 앞으로 나와 있으면 원래 앱에 자리를 돌려준다.
        if let targetApp, NSWorkspace.shared.frontmostApplication != targetApp {
            log.info("target app is not frontmost, handing activation back")
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(pasteboard)
        pasteboard.writeTransient(text)

        await KeyboardSynth.waitForModifiersReleased(timeout: 0.35)
        // 패널이 사라지고 원래 창이 다시 키보드 입력을 받을 때까지 아주 잠깐 기다린다.
        try? await Task.sleep(nanoseconds: 60_000_000)
        KeyboardSynth.paste()

        // 어떤 앱은 붙여넣을 내용을 한 박자 늦게 읽어서, 너무 빨리 복원하면 옛 클립보드가 붙는다.
        try? await Task.sleep(nanoseconds: 450_000_000)
        snapshot.restore(to: pasteboard)
        log.info("pasted result, length=\(text.count, privacy: .public)")
    }
}
