import AppKit
import SwiftUI

/// 창의 빈 배경. 여기를 끌면 창이 움직이고, 그 위의 버튼·슬라이더는 자기 동작만 한다.
package struct WindowDragArea: NSViewRepresentable {
    package init() {}
    package final class DragView: NSView {
        override package func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override package var mouseDownCanMoveWindow: Bool { false }
    }
    package func makeNSView(context: Context) -> NSView { DragView() }
    package func updateNSView(_ view: NSView, context: Context) {}
}
