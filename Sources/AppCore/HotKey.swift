import Carbon.HIToolbox
import Foundation

/// 시스템 전역 단축키. Carbon의 RegisterEventHotKey는 손쉬운 사용 권한 없이도 동작하고,
/// 눌린 키 이벤트를 다른 앱에 넘기지 않고 우리가 가져간다.
package final class HotKey {
    package var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    package init?(keyCode: Int, modifiers: Int) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x5458_5450), id: id)  // 'TXTP'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
            return nil
        }
        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            DispatchQueue.main.async { HotKey.registry[hotKeyID.id]?.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
