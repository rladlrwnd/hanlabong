import AppKit
import SkillEngine
import SwiftUI

/// 두 번 누르면 원래 값으로 돌아가는 슬라이더(사진 앱·라이트룸처럼).
/// SwiftUI 슬라이더는 손잡이가 클릭을 먼저 가져가서 두 번 누르기를 못 받으니, 맥 기본 슬라이더를 직접 쓴다.
package struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// 값이 바뀔 때마다(끄는 중에도)
    var onChange: () -> Void = {}
    /// 손을 뗐을 때·두 번 눌러 되돌렸을 때
    var onCommit: () -> Void = {}

    package init(value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double, onChange: @escaping () -> Void = {}, onCommit: @escaping () -> Void = {}) {
        _value = value; self.range = range; self.defaultValue = defaultValue; self.onChange = onChange; self.onCommit = onCommit
    }

    package final class Slider: NSSlider {
        var onDoubleClick: () -> Void = {}
        var onRelease: () -> Void = {}

        override package func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick(); return }
            super.mouseDown(with: event)   // 손을 뗄 때까지 여기서 끌기를 처리한다
            onRelease()
        }
    }

    package final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) {
            parent.value = sender.doubleValue
            parent.onChange()
        }
    }

    package func makeCoordinator() -> Coordinator { Coordinator(self) }

    package func makeNSView(context: Context) -> Slider {
        let slider = Slider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.toolTip = L("두 번 누르면 원래 값으로", "Double-click to reset")
        return slider
    }

    package func updateNSView(_ slider: Slider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.onDoubleClick = { [coordinator = context.coordinator] in
            let parent = coordinator.parent
            parent.value = parent.defaultValue
            slider.doubleValue = parent.defaultValue
            parent.onChange()
            parent.onCommit()
        }
        slider.onRelease = { [coordinator = context.coordinator] in coordinator.parent.onCommit() }
    }
}
