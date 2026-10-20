import AppCore
import AppKit
import ApplicationServices

package struct CapturedSelection {
    package let text: String
    /// 선택 영역의 화면 위치(Cocoa 좌표: 왼쪽 아래가 원점). 모르면 nil → 마우스 위치를 대신 쓴다.
    package let bounds: CGRect?
    package let source: Source

    package enum Source: String { case accessibility, clipboard }
}

/// 다른 앱에서 선택된 글자를 가져온다.
/// 1순위: 손쉬운 사용 API로 직접 읽기 — ⌘C가 필요 없고 선택 영역의 정확한 위치도 알 수 있다.
///       (메모, 텍스트 편집기, Safari, 대부분의 기본 맥 앱)
/// 2순위: ⌘C를 흉내 내서 클립보드로 받기 — 1순위가 안 통하는 앱(일부 Electron·웹 앱 등).
///       이때 원래 클립보드는 바로 되돌려 놓는다.
package enum SelectionReader {
    @MainActor
    package static func capture() async -> CapturedSelection? {
        if let viaAX = readViaAccessibility() {
            log.info("selection via AX, length=\(viaAX.text.count, privacy: .public)")
            return viaAX
        }
        if let text = await readViaClipboard() {
            log.info("selection via clipboard, length=\(text.count, privacy: .public)")
            return CapturedSelection(text: text, bounds: nil, source: .clipboard)
        }
        log.info("no selection found")
        return nil
    }

    // MARK: - 손쉬운 사용 API

    private static func readViaAccessibility() -> CapturedSelection? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        guard let focused: AXUIElement = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)

        guard let text: String = copyAttribute(focused, kAXSelectedTextAttribute), !text.isEmpty else { return nil }
        return CapturedSelection(text: text, bounds: selectionBounds(of: focused), source: .accessibility)
    }

    /// 선택 영역의 화면 위치.
    /// 1) 일반 맥 앱: 글자 범위(AXSelectedTextRange)로 위치를 묻는다.
    /// 2) Safari·Chrome·Electron 앱(Claude, Slack 등 웹 기반): 위 방식을 지원하지 않는 대신
    ///    "텍스트 마커"라는 별도 방식으로 위치를 알려준다.
    private static func selectionBounds(of element: AXUIElement) -> CGRect? {
        if let range: AXValue = copyAttribute(element, kAXSelectedTextRangeAttribute),
           let rect = parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, range) {
            return rect
        }
        if let markerRange: AnyObject = copyAttribute(element, "AXSelectedTextMarkerRange"),
           let rect = parameterizedRect(element, "AXBoundsForTextMarkerRange", markerRange) {
            return rect
        }
        return nil
    }

    private static func parameterizedRect(_ element: AXUIElement, _ attribute: String, _ parameter: AnyObject) -> CGRect? {
        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &boundsRef)
        guard status == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return cocoaRect(fromAccessibility: rect)
    }

    /// 손쉬운 사용 API는 "주 화면 왼쪽 위"가 원점, AppKit은 "왼쪽 아래"가 원점이라 뒤집어준다.
    /// 앱에 따라 엉뚱한 값을 주기도 해서, 어느 화면과도 안 겹치면 버린다.
    private static func cocoaRect(fromAccessibility rect: CGRect) -> CGRect? {
        guard rect.width < 10_000, rect.height > 0, rect.height < 10_000,
              let primary = NSScreen.screens.first else { return nil }
        let flipped = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: max(rect.width, 1), height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return nil }
        return flipped
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: - ⌘C 대체 경로

    @MainActor
    private static func readViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(pasteboard)
        let before = pasteboard.changeCount

        await KeyboardSynth.waitForModifiersReleased()
        KeyboardSynth.copy()

        var copied: String?
        for _ in 0..<25 {  // 최대 0.5초
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { snapshot.restore(to: pasteboard) }

        guard let copied, !copied.isEmpty else { return nil }
        return copied
    }
}
