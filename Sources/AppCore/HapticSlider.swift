import AppKit
import SwiftUI

/// 한 칸 움직일 때마다 트랙패드가 "톡" 하는 슬라이더 (Arc 브라우저처럼). 끝에 닿으면 다른 느낌.
package struct HapticSlider: View {
    package let title: String
    @Binding package var value: Double
    package var disabled = false
    package let onEditing: (Bool) -> Void

    package var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 34, alignment: .leading)
            Slider(value: $value, in: 0...1, step: 0.05, onEditingChanged: onEditing)
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .disabled(disabled)
        .onChange(of: value) { _, newValue in
            let atEdge = newValue <= 0.0001 || newValue >= 0.9999
            NSHapticFeedbackManager.defaultPerformer.perform(atEdge ? .alignment : .levelChange, performanceTime: .now)
        }
    }
}
