import AppCore
import AppKit

/// 마우스 버튼이 눌린 동안에만 상태를 확인하는 드래그 감시자.
/// - 평소: 전역 이벤트 감시 하나(leftMouseDown)만 켜 둔다. 이벤트가 올 때만 깨어나므로 쉴 때 CPU는 0이다.
/// - 버튼을 누르는 동안: 30ms마다 버튼·트리거 키·드래그 클립보드를 읽는다. 떼면 바로 멈춘다.
/// 0.015초마다 계속 확인하는 방식(DragShift)은 쓰지 않는다.
/// 읽는 값은 모두 권한 없이 읽을 수 있는 것들이다: 마우스 버튼 상태, 수정키 상태, 드래그 클립보드의 변경 횟수·종류.
@MainActor
package final class DragWatcher {
    package var onShowWheel: ((NSPoint, WheelMode) -> Void)?
    package var onSwitchMode: ((WheelMode) -> Void)?
    package var onCloseWheel: (() -> Void)?
    /// 휠 종류별 트리거 키(설정에서 바꾼다). 버튼을 누를 때마다 다시 읽는다.
    private var triggers: [(WheelMode, CGEventFlags)] = WheelKeys.triggers()

    private var monitor: Any?
    private var timer: DispatchSourceTimer?
    private var tracker = DragTracker()
    private let dragPasteboard = NSPasteboard(name: .drag)

    package init() {}

    package var isWatching: Bool { monitor != nil }

    package func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        log.info("file drag watcher on, monitor=\(self.monitor != nil, privacy: .public)")
    }

    package func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stopTimer()
        if tracker.reset() == .closeWheel { onCloseWheel?() }
        log.info("file drag watcher off")
    }

    private func mouseDown() {
        triggers = WheelKeys.triggers()
        tracker.mouseDown(changeCount: dragPasteboard.changeCount, held: pressedMode())
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let pressed = pressedMode()
        let pasteboard = dragPasteboard
        let action = tracker.update(
            buttonDown: buttonDown,
            pressed: pressed,
            changeCount: pasteboard.changeCount,
            hasFiles: {
                let types = pasteboard.types?.map(\.rawValue) ?? []
                return types.contains("public.file-url") || types.contains("NSFilenamesPboardType")
            }
        )
        switch action {
        case .showWheel(let mode):
            log.info("file drag + trigger key → show wheel mode=\(mode.rawValue, privacy: .public)")
            onShowWheel?(NSEvent.mouseLocation, mode)
        case .switchMode(let mode):
            log.info("wheel mode → \(mode.rawValue, privacy: .public)")
            onSwitchMode?(mode)
        case .closeWheel:
            onCloseWheel?()
        case nil:
            break
        }
        if !buttonDown { stopTimer() }
    }

    private func pressedMode() -> WheelMode? {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return triggers.first { flags.contains($0.1) }?.0
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
