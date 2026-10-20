import Foundation
import Testing
@testable import FileFeature

/// "파일을 끌고 있는 중에 트리거 키를 눌렀을 때만 휠이 뜬다"는 규칙 확인 (화면·시스템 없이)
struct DragTrackerTests {
    /// 한 번의 클릭·드래그를 한 단계씩 흉내 내는 도우미
    private struct Run {
        var tracker = DragTracker()
        var changeCount = 10
        var fileChecks = 0

        mutating func down() { tracker.mouseDown(changeCount: changeCount) }

        /// `files`: 드래그 클립보드가 바뀌었다면 거기 파일이 들어 있는지
        mutating func tick(button: Bool = true, trigger: Bool = false, newDrag files: Bool? = nil) -> DragTracker.Action? {
            if files != nil { changeCount += 1 }
            return tracker.update(buttonDown: button, triggerHeld: trigger, changeCount: changeCount) {
                fileChecks += 1
                return files ?? false
            }
        }
    }

    @Test func fileDragThenTriggerOpensWheelAndMouseUpCloses() {
        var run = Run()
        run.down()
        #expect(run.tick() == nil)
        #expect(run.tick(newDrag: true) == nil)                // 파일 드래그 시작, 아직 트리거 키 안 누름
        #expect(run.tracker.phase == .fileDragging)
        #expect(run.tick(trigger: true) == .showWheel(.convert))
        #expect(run.tick(trigger: true) == nil)                // 이미 열렸으니 다시 열지 않음
        #expect(run.tick(button: false) == .closeWheel)
        #expect(run.tracker.phase == .idle)
    }

    @Test func triggerHeldBeforeDragStartsStillOpens() {
        var run = Run()
        run.down()
        #expect(run.tick(trigger: true) == nil)                // 키만 눌려 있고 아직 드래그 아님
        #expect(run.tick(trigger: true, newDrag: true) == .showWheel(.convert))
    }

    @Test func triggerWithoutFileDragNeverOpens() {
        // 창 이동·글자 선택 중에 Shift를 눌러도 휠이 뜨면 안 된다
        var run = Run()
        run.down()
        for _ in 0..<20 { #expect(run.tick(trigger: true) == nil) }
        #expect(run.fileChecks == 0)                           // 클립보드가 안 바뀌면 읽지도 않는다
        #expect(run.tick(button: false) == nil)
    }

    @Test func nonFileDragNeverOpens() {
        // 글자·이미지 드래그: 클립보드는 바뀌지만 파일이 아님
        var run = Run()
        run.down()
        #expect(run.tick(trigger: true, newDrag: false) == nil)
        for _ in 0..<10 { #expect(run.tick(trigger: true) == nil) }
        #expect(run.fileChecks == 1)                           // 바뀐 한 번만 확인한다
        #expect(run.tick(button: false) == nil)
    }

    @Test func wheelStaysOpenAfterTriggerReleasedUntilMouseUp() {
        var run = Run()
        run.down()
        _ = run.tick(trigger: true, newDrag: true)
        #expect(run.tick(trigger: false) == nil)
        #expect(run.tracker.phase == .wheelOpen)
        #expect(run.tick(button: false) == .closeWheel)
    }

    @Test func mouseUpWithoutWheelDoesNothing() {
        var run = Run()
        run.down()
        _ = run.tick(newDrag: true)
        #expect(run.tick(button: false) == nil)
    }

    @Test func buttonDownWithoutMouseDownIsIgnored() {
        var run = Run()
        #expect(run.tick(trigger: true, newDrag: true) == nil)
        #expect(run.tracker.phase == .idle)
    }

    @Test func nextClickStartsFresh() {
        var run = Run()
        run.down()
        _ = run.tick(trigger: true, newDrag: true)
        _ = run.tick(button: false)
        run.down()                                             // 두 번째 클릭
        #expect(run.tracker.phase == .armed)
        #expect(run.tick(trigger: true) == nil)                // 지난번 파일 드래그가 남아 있으면 안 된다
    }

    @Test func resetClosesAnOpenWheel() {
        var run = Run()
        run.down()
        _ = run.tick(trigger: true, newDrag: true)
        #expect(run.tracker.reset() == .closeWheel)
        #expect(run.tracker.reset() == nil)
    }

    @Test func modifierKeysPickTheWheelAndSwitchWhileOpen() {
        var tracker = DragTracker()
        var count = 1
        tracker.mouseDown(changeCount: count)
        count += 1
        #expect(tracker.update(buttonDown: true, pressed: nil, changeCount: count) { true } == nil)
        #expect(tracker.update(buttonDown: true, pressed: .tools, changeCount: count) { true } == .showWheel(.tools))
        #expect(tracker.update(buttonDown: true, pressed: .tools, changeCount: count) { true } == nil)        // 계속 누르고 있어도 한 번
        #expect(tracker.update(buttonDown: true, pressed: nil, changeCount: count) { true } == nil)           // 떼도 휠은 그대로
        #expect(tracker.phase == .wheelOpen)
        #expect(tracker.update(buttonDown: true, pressed: .actions, changeCount: count) { true } == .switchMode(.actions))
        #expect(tracker.update(buttonDown: true, pressed: nil, changeCount: count) { true } == nil)
        #expect(tracker.update(buttonDown: true, pressed: .convert, changeCount: count) { true } == .switchMode(.convert))
        #expect(tracker.update(buttonDown: false, pressed: nil, changeCount: count) { true } == .closeWheel)
    }

    @Test func keyHeldAtClickDoesNotCountUntilPressedAgain() {
        // ⌃+클릭(오른쪽 클릭)으로 시작한 경우: ⌃는 한 번 뗐다 다시 눌러야 동작 휠
        var tracker = DragTracker()
        tracker.mouseDown(changeCount: 1, held: .actions)
        #expect(tracker.update(buttonDown: true, pressed: .actions, changeCount: 2) { true } == nil)
        #expect(tracker.update(buttonDown: true, pressed: nil, changeCount: 2) { true } == nil)
        #expect(tracker.update(buttonDown: true, pressed: .actions, changeCount: 2) { true } == .showWheel(.actions))
        // ⇧+클릭(여러 개 고르기) 뒤 끌기는 바로 변환 휠
        var shift = DragTracker()
        shift.mouseDown(changeCount: 1, held: .convert)
        #expect(shift.update(buttonDown: true, pressed: .convert, changeCount: 2) { true } == .showWheel(.convert))
    }

    @Test func wheelKeysSwapWhenReused() {
        let store = UserDefaults(suiteName: "wheelkeys-\(UUID().uuidString)")!
        #expect(WheelKeys.key(for: .tools, store: store) == .command)
        WheelKeys.set(.shift, for: .tools, store: store)                      // ⇧를 도구에 주면 변환은 ⌘로
        #expect(WheelKeys.key(for: .tools, store: store) == .shift && WheelKeys.key(for: .convert, store: store) == .command)
        WheelKeys.set(.option, for: .actions, store: store)
        #expect(WheelKeys.triggers(store: store).map(\.0) == [.convert, .actions, .tools])   // ⌘ → ⌥ → ⇧ 순서
        WheelKeys.set(.off, for: .actions, store: store)
        #expect(!WheelKeys.triggers(store: store).contains { $0.0 == .actions })
    }
}
