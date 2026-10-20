import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// 휠 창이 파일 드롭을 받는 자리. 어느 칸 위인지는 휠 기하(`WheelGeometry`)와 `WheelNavigator`가 계산한다.
/// 보이는 부분은 SwiftUI(`WheelView`)가 그리고, 드롭은 이 AppKit 뷰가 받는다.
@MainActor
final class WheelDropView: NSView {
    var model: WheelModel?
    var onDrop: ((WheelItem, [URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func offset(for sender: NSDraggingInfo) -> CGPoint {
        let point = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let model, model.phase == .choosing else { return [] }
        return model.pointerMoved(to: offset(for: sender)) == nil ? [] : Self.operation(for: sender.draggingSourceOperationMask)
    }

    /// 파일은 읽기만 하니 "복사"로 받는다. ⌘를 누른 채 끌면 Finder가 "이동"만 허락할 때가 있어 그때도 받는다
    /// (받는 쪽이 아무것도 옮기지 않으니 원본은 그대로다).
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for op in [NSDragOperation.copy, .generic, .link, .move] where mask.contains(op) { return op }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model?.pointerLeft()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let model, model.phase == .choosing else { log.info("wheel drop rejected: busy"); return false }
        guard let item = model.pointerMoved(to: offset(for: sender)), item.isDroppable else {
            log.info("wheel drop rejected: not on a preset (over \(model.navigator.hoveredItem?.id ?? "nothing", privacy: .public))")
            return false
        }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { log.info("wheel drop rejected: no file urls"); return false }
        model.committed = model.navigator.hover
        onDrop?(item, urls)
        return true
    }
}

/// 보이는 부분은 마우스 이벤트를 가로채지 않고 아래 `WheelDropView`가 드롭을 받게 한다.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 커서 아래에 휠을 띄우고 닫는다. 창은 Prism 팝업과 같은 비활성 패널이라 지금 쓰던 앱이 그대로 맨 앞에 남는다.
@MainActor
package final class WheelController {
    /// 파일을 칸에 놓았을 때(칸의 스킬과 놓은 파일들)
    package var onDrop: ((_ item: WheelItem, _ urls: [URL]) -> Void)?

    private let model = WheelModel(layout: .image())
    private let panel = PopupPanel()
    private let dropView = WheelDropView(frame: .zero)
    private var closeWork: DispatchWorkItem?
    private var resignObserver: NSObjectProtocol?
    /// 이번에 휠을 띄운 뒤 키 창을 되찾은 적이 있는지(서로 뺏고 빼앗지 않게 한 번만)
    private var rekeyed = false

    // 유리 준비: 맥은 유리를 "처음 그리는 순간" 그릴 준비를 한다. 준비가 덜 된 첫 화면은 그냥 흐린 배경으로
    // 그려지고, 그 휠이 떠 있는 동안엔 다시 안 그려진다(두 번째부터는 정상). 그래서 미리 한 번 몰래 그려 둔다.
    private var isWarm = false
    private var warmWork: DispatchWorkItem?
    private var lastShown = Date.distantPast
    /// 이만큼 안 썼으면 다시 준비가 필요하다고 본다(오래 쉬면 그래픽 자원이 정리될 수 있다)
    private static let coldAfter: TimeInterval = 20 * 60

    package init() {
        dropView.model = model
        dropView.onDrop = { [weak self] item, urls in self?.dropped(item: item, urls: urls) }

        let hosting = PassthroughHostingView(rootView: WheelView(model: model))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)
        panel.contentView = dropView
        // 파일을 받아야 하므로 PopupPanel(마우스를 받는 패널)을 그대로 쓴다. 키 입력은 받지 않는다.

        // 파일을 놓고 나면 Finder가 다시 포커스(키 창)를 가져간다. 그러면 macOS 26 유리가
        // "비활성 창" 모양(그냥 흐린 배경)으로 바뀌어서, 처리 중·✓ 표시 동안 유리가 깨져 보였다.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }
    }

    private func panelResignedKey() {
        guard panel.isVisible, model.isShown else { return }
        let phase: String = {
            switch model.phase {
            case .choosing: return "choosing"
            case .working: return "working"
            case .finished: return "finished"
            }
        }()
        log.info("wheel lost key: phase=\(phase, privacy: .public) rekey=\(!self.rekeyed, privacy: .public)")
        guard !rekeyed else { return }
        rekeyed = true
        panel.makeKey()
    }

    /// 앱을 켤 때·잠자기에서 깰 때 부른다: 휠을 화면 구석에 거의 투명(2%)하게 잠깐 그렸다 닫아서 유리를 준비시킨다.
    /// 마우스는 통과하고 포커스(키 창)도 가져가지 않는다.
    package func prewarm(duration: TimeInterval = 1.5) {
        guard !panel.isVisible else { return }
        isWarm = false
        model.setLayout(.image())
        model.pointerMoved(to: CGPoint(x: 0, y: 100))          // 2단계 링까지 펼쳐서 같이 준비
        let side = model.geometry.side
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visible.minX, y: visible.minY, width: side, height: side), display: true)
        panel.alphaValue = 0.02
        panel.ignoresMouseEvents = true
        model.isShown = true
        panel.orderFrontRegardless()
        log.info("wheel glass warm-up start")
        let work = DispatchWorkItem { [weak self] in self?.finishWarmUp() }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 잠자기에서 깼을 때 등: 다음에 띄울 때 다시 준비가 필요하다
    package func markCold() { isWarm = false }

    private func finishWarmUp() {
        warmWork?.cancel()
        warmWork = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        model.isShown = false
        model.setLayout(.image())
        isWarm = true
        log.info("wheel glass warm-up done")
    }

    package var isOpen: Bool { panel.isVisible }
    /// 마지막으로 휠이 떠 있던 자리(화면 좌표, 휠 가운데). 진행 카드가 이 자리에 이어서 뜬다.
    package private(set) var lastCenter: NSPoint?
    /// 놓은 뒤 처리 중이면 마우스를 놓았다고 휠을 닫지 않는다
    private var isBusy: Bool { model.phase != .choosing }

    package func show(at mouse: NSPoint, layout: WheelLayout) {
        closeWork?.cancel()
        // 준비 중이었으면 그 준비를 끝내고(창을 한 번 닫았다가) 바로 이어서 띄운다 → 이게 "두 번째로 띄우기"가 된다
        if warmWork != nil { finishWarmUp() }
        if Date().timeIntervalSince(lastShown) > Self.coldAfter { isWarm = false }
        let cold = !isWarm
        lastShown = Date()
        model.setLayout(layout)
        panel.ignoresMouseEvents = false
        panel.alphaValue = cold ? 0.02 : 1
        rekeyed = false

        let side = model.geometry.side
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: min(max(mouse.x - side / 2, visible.minX), visible.maxX - side),
            y: min(max(mouse.y - side / 2, visible.minY), visible.maxY - side)
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)), display: true)
        lastCenter = NSPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        panel.orderFrontRegardless()
        // 팝업과 똑같이 키 창으로 만든다. 키 창이 아니면 macOS 26 유리가 "비활성" 모양(그냥 흐린 배경)으로 그려졌다.
        // 비활성 패널이라 지금 쓰던 앱(Finder)이 맨 앞 앱으로 남는 건 그대로다.
        panel.makeKey()
        // 한 박자 뒤(SwiftUI가 첫 화면을 그린 다음)에 등장 애니메이션을 켠다
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            // 두 번째 이후에 키 창이 안 되는 경우가 있어 한 번 더 시도한다
            if !self.panel.isKeyWindow { self.panel.makeKey() }
            self.model.isShown = true
            log.info("wheel shown, key=\(self.panel.isKeyWindow, privacy: .public) cold=\(cold, privacy: .public)")
        }
        if cold { revealAfterWarmUp() }
    }

    /// 준비가 안 된 채로 불렸을 때(앱을 켠 직후·오래 쉰 뒤): 거의 투명하게 먼저 그려서 준비시키고,
    /// 0.35초 뒤 창을 한 번 닫았다 다시 띄워서 보여준다. 흐린 배경이 보이는 대신 조금 늦게 뜬다.
    private func revealAfterWarmUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.panel.isVisible, self.panel.alphaValue < 1 else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.orderFrontRegardless()
            self.panel.makeKey()
            self.isWarm = true
            log.info("wheel revealed after warm-up")
        }
    }

    /// 지금 떠 있는 휠 종류
    package var mode: WheelMode { model.navigator.layout.mode }

    /// 휠 종류를 바꾼다(⇧/⌘/⌃). 고르는 중일 때만.
    package func switchLayout(_ layout: WheelLayout) {
        guard panel.isVisible, model.phase == .choosing, model.navigator.layout != layout else { return }
        model.setLayout(layout)
    }

    /// 떠 있는 휠의 칸 내용을 바꾼다(예: AI 목록을 새로 받았을 때). 고르는 중일 때만.
    package func updateLayout(_ layout: WheelLayout) {
        guard panel.isVisible, model.phase == .choosing, model.navigator.layout != layout else { return }
        model.setLayout(layout)
        model.isShown = true
    }

    /// 마우스를 놓거나 감시를 끌 때. 처리 중이면 끝날 때까지 남겨둔다.
    package func close() {
        guard panel.isVisible, !isBusy else { return }
        hide(after: 0.05)
    }

    // MARK: 놓은 뒤 처리 상황 (가운데 원에 보여준다)

    package func beginWork(total: Int, ai: Bool = false) {
        closeWork?.cancel()
        model.phase = .working(done: 0, total: total)
        model.aiWorking = ai
        // 처리하는 동안 휠 뒤의 창을 누를 수 있게 마우스를 통과시킨다
        panel.ignoresMouseEvents = true
    }

    package func progress(done: Int, total: Int) {
        guard isOpen, case .working = model.phase else { return }
        model.phase = .working(done: done, total: total)
    }

    /// 오래 걸리는 작업은 진행 카드가 이어받으니 휠은 바로 닫는다
    package func handOff() {
        guard isOpen, case .working = model.phase else { return }
        hide(after: 0)
    }

    package func finish(succeeded: Int, failed: Int) {
        guard isOpen, case .working = model.phase else { return }
        model.phase = .finished(succeeded: succeeded, failed: failed)
        hide(after: failed == 0 ? 0.9 : 1.8)
    }

    private func dropped(item: WheelItem, urls: [URL]) {
        // 파일 이름이나 경로는 로그에 남기지 않고 개수만 남긴다.
        log.info("wheel drop: item=\(item.id, privacy: .public) files=\(urls.count, privacy: .public)")
        onDrop?(item, urls)
    }

    private func hide(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.isShown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                guard let self, !self.model.isShown else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.model.phase = .choosing
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
