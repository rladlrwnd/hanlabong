import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// 설정에서 유리 모양 슬라이더를 움직이는 동안, 설정 창 옆에 진짜 팝업을 띄워 바로 보여준다.
/// 팝업은 같은 설정값(UserDefaults)을 읽으니 슬라이더를 움직이면 실시간으로 바뀐다.
@MainActor
package final class AppearancePreview {
    package static let shared = AppearancePreview()

    private let panel = PopupPanel()
    private let model = PopupModel()
    private let hosting: FittingHostingView<PopupView>
    private var hideWork: DispatchWorkItem?

    package init() {
        hosting = FittingHostingView(rootView: PopupView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.ignoresMouseEvents = true

        model.selectedText = L("미리보기 — 실제 팝업이 이렇게 보여요", "Preview — this is how the popup looks")
        model.allActions = DefaultSkills.all.prefix(4).enumerated().map { PopupAction.skill($1, number: $0 + 1) }
        model.agent = Agent(provider: .anthropic, model: "claude-sonnet-5", detail: "")
    }

    /// 슬라이더를 잡았을 때(true)/놓았을 때(false)
    package func editing(_ active: Bool) {
        hideWork?.cancel()
        if active {
            show()
        } else {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    private func show() {
        guard !panel.isVisible || !model.isShown else { return }
        model.isPresented = true
        model.isShown = false
        // 내용이 실제로 그려진 다음(한 박자 뒤)에 크기를 재야 한다 — 바로 재면 0×0이라 안 보였다.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.isPresented else { return }
            self.hosting.layoutSubtreeIfNeeded()
            let size = self.hosting.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            self.panel.setFrame(NSRect(origin: self.origin(for: size), size: size), display: true)
            self.panel.orderFrontRegardless()
            DispatchQueue.main.async { self.model.isShown = true }
        }
    }

    private func hide() {
        model.isShown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.model.isShown else { return }
            self.panel.orderOut(nil)
            self.model.isPresented = false
        }
    }

    /// 설정 창 오른쪽에(자리가 없으면 왼쪽에) 세로 가운데로.
    private func origin(for size: NSSize) -> NSPoint {
        let settings = NSApp.windows.first { $0.isVisible && $0.title.hasSuffix(L("설정", "Settings")) }?.frame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let visible = NSScreen.main?.visibleFrame ?? settings
        var x = settings.maxX - 16
        if x + size.width > visible.maxX { x = settings.minX - size.width + 16 }
        let y = settings.midY - size.height / 2
        return NSPoint(x: max(visible.minX, x), y: min(max(visible.minY, y), visible.maxY - size.height))
    }
}
