import AppKit

/// Spotlight·Raycast와 같은 종류의 창: "앱을 활성화하지 않는 패널".
/// - 키보드 입력(⌘1, Esc, 화살표)은 받지만 우리 앱이 맨 앞 앱이 되지는 않는다.
///   → 메모장 같은 원래 앱이 계속 활성 상태로 남아서, 닫은 뒤 ⌘V가 그 앱으로 바로 들어간다.
/// - `.nonactivatingPanel`은 반드시 생성 시점에 줘야 제대로 동작한다(나중에 바꾸면 안 먹는다).
package final class PopupPanel: NSPanel {
    package init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        // 모든 데스크톱(Spaces)과 전체화면 앱 위에도 뜨도록
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // 그림자는 SwiftUI 쪽에서 그려서 애니메이션과 같이 움직이게 한다
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    package override var canBecomeKey: Bool { true }
    package override var canBecomeMain: Bool { false }
}
