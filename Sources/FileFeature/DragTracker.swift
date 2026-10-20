import CoreGraphics
import Foundation
import SkillEngine

/// 휠 종류. 끌면서 누른 키에 따라 정해지고, 휠이 떠 있는 동안 다른 키를 누르면 바뀐다.
/// - ⇧ Shift: 변환 · ⌘ Command: 도구 · ⌃ Control: 동작(AirDrop·복사·이동 등)
package enum WheelMode: String, CaseIterable, Equatable, Sendable {
    case convert, tools, actions

    package var title: String {
        switch self {
        case .convert: return L("변환", "Convert")
        case .tools: return L("도구", "Tools")
        case .actions: return L("동작", "Actions")
        }
    }

    package var keySymbol: String { WheelKeys.key(for: self).symbol }
}

/// 휠을 여는 수정키. 설정 › 파일 기능에서 휠마다 고른다(같은 키를 두 휠에 쓰면 서로 바꾼다).
package enum ModifierKey: String, CaseIterable, Sendable {
    case shift, command, control, option, off

    package var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .off: return "–"
        }
    }

    package var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .off: return L("안 씀", "Off")
        }
    }

    package var flag: CGEventFlags? {
        switch self {
        case .shift: return .maskShift
        case .command: return .maskCommand
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .off: return nil
        }
    }
}

package enum WheelKeys {
    package static let defaults: [WheelMode: ModifierKey] = [.convert: .shift, .tools: .command, .actions: .control]
    private static func defaultsKey(_ mode: WheelMode) -> String { "wheelKey.\(mode.rawValue)" }

    package static func key(for mode: WheelMode, store: UserDefaults = .standard) -> ModifierKey {
        store.string(forKey: defaultsKey(mode)).flatMap(ModifierKey.init(rawValue:)) ?? defaults[mode]!
    }

    /// 같은 키를 이미 다른 휠이 쓰고 있으면 그 휠과 키를 서로 바꾼다
    package static func set(_ key: ModifierKey, for mode: WheelMode, store: UserDefaults = .standard) {
        let previous = Self.key(for: mode, store: store)
        if key != .off, let other = WheelMode.allCases.first(where: { $0 != mode && Self.key(for: $0, store: store) == key }) {
            store.set(previous.rawValue, forKey: defaultsKey(other))
        }
        store.set(key.rawValue, forKey: defaultsKey(mode))
    }

    /// 감시자가 보는 순서: ⌘ → ⌃ → ⌥ → ⇧ (여러 개를 같이 누르면 앞쪽이 이긴다)
    package static func triggers(store: UserDefaults = .standard) -> [(WheelMode, CGEventFlags)] {
        let order: [ModifierKey] = [.command, .control, .option, .shift]
        return order.compactMap { key in
            guard let mode = WheelMode.allCases.first(where: { Self.key(for: $0, store: store) == key }), let flag = key.flag else { return nil }
            return (mode, flag)
        }
    }
}


/// "파일을 끌고 있는 중에 트리거 키를 눌렀나"를 판단하는 순수 로직.
/// 화면·시스템과 분리해 둬서 UI 없이 단위 테스트로 검증한다.
///
/// 흐름: 마우스 버튼 누름(armed) → 드래그 클립보드에 파일이 들어옴(fileDragging) → 트리거 키 눌림(wheelOpen)
///       → (떠 있는 동안 다른 트리거 키를 새로 누르면 휠 종류 전환) → 마우스 버튼 뗌(idle, 휠이 열려 있었다면 닫기).
/// 글자·이미지 같은 파일이 아닌 드래그는 fileDragging까지 가지 못하므로 휠이 뜨지 않는다.
/// 휠은 키를 떼도 닫히지 않는다(놓거나 버튼을 뗄 때까지).
package struct DragTracker {
    package enum Phase: Equatable { case idle, armed, fileDragging, wheelOpen }
    package enum Action: Equatable { case showWheel(WheelMode), switchMode(WheelMode), closeWheel }

    package private(set) var phase: Phase = .idle
    package private(set) var mode: WheelMode = .convert
    private var baseline = 0
    /// 지난번에 눌려 있던 트리거 키(새로 누른 순간만 전환한다)
    private var lastPressed: WheelMode?
    /// 버튼을 누르는 순간 이미 눌려 있던 키. ⌃+클릭은 오른쪽 클릭이라, 그 키는 한 번 뗐다 다시 눌러야 센다.
    private var heldAtDown: WheelMode?

    package init() {}

    /// 마우스 버튼을 눌렀을 때. `changeCount`는 그 순간의 드래그 클립보드 변경 횟수.
    package mutating func mouseDown(changeCount: Int, held: WheelMode? = nil) {
        baseline = changeCount
        phase = .armed
        lastPressed = nil
        heldAtDown = held == .convert ? nil : held     // ⇧+클릭(여러 개 고르기) 뒤 끌기는 그대로 변환 휠
    }

    /// 버튼이 눌려 있는 동안 주기적으로 부른다. `pressed`는 지금 눌린 트리거 키(없으면 nil).
    /// `hasFiles`는 드래그 클립보드가 바뀐 뒤에만, 바뀔 때마다 한 번씩 불린다.
    package mutating func update(buttonDown: Bool, pressed rawPressed: WheelMode?, changeCount: Int, hasFiles: () -> Bool) -> Action? {
        if let held = heldAtDown, rawPressed != held { heldAtDown = nil }
        let pressed = rawPressed == heldAtDown ? nil : rawPressed
        defer { lastPressed = pressed }
        guard buttonDown else {
            let wasOpen = phase == .wheelOpen
            phase = .idle
            return wasOpen ? .closeWheel : nil
        }
        if phase == .armed, changeCount != baseline {
            baseline = changeCount
            if hasFiles() { phase = .fileDragging }
        }
        if phase == .fileDragging, let pressed {
            phase = .wheelOpen
            mode = pressed
            return .showWheel(pressed)
        }
        if phase == .wheelOpen, let pressed, pressed != lastPressed, pressed != mode {
            mode = pressed
            return .switchMode(pressed)
        }
        return nil
    }

    /// 예전 방식(트리거 키 하나)
    package mutating func update(buttonDown: Bool, triggerHeld: Bool, changeCount: Int, hasFiles: () -> Bool) -> Action? {
        update(buttonDown: buttonDown, pressed: triggerHeld ? .convert : nil, changeCount: changeCount, hasFiles: hasFiles)
    }

    /// 감시를 끄거나 휠을 강제로 닫을 때.
    package mutating func reset() -> Action? {
        let wasOpen = phase == .wheelOpen
        phase = .idle
        return wasOpen ? .closeWheel : nil
    }
}
