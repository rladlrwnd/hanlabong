import AppCore
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// ⌘C / ⌘V 흉내.
/// Tauri 때 겪은 버그: ⌥Space를 누른 직후 ⌘C를 보내면 아직 안 뗀 ⌥가 섞여서 ⌘⌥C가 되어
/// 복사가 씹혔다. 그래서 (1) 실제 키보드 상태와 분리된 private 이벤트 소스를 쓰고,
/// (2) 수정키 플래그를 ⌘ 하나로 못박고, (3) 보내기 전에 손이 수정키에서 떨어질 때까지 잠깐 기다린다.
package enum KeyboardSynth {
    package static func copy() { pressCommand(CGKeyCode(kVK_ANSI_C)) }
    package static func paste() { pressCommand(CGKeyCode(kVK_ANSI_V)) }

    private static func pressCommand(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// 사용자가 ⌥/⌘/⌃/⇧에서 손을 뗄 때까지 최대 `timeout`초 기다린다.
    package static func waitForModifiersReleased(timeout: TimeInterval = 0.4) async {
        let held: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}
