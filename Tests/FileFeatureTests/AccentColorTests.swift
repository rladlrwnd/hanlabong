import AppCore
import SwiftUI
import Testing

/// 강조색: 설정에서 고른 색이 hex 글자로 저장됐다가 같은 색으로 돌아와야 한다
struct AccentColorTests {
    @Test(arguments: ["#FFB347", "#0A84FF", "#000000", "#FFFFFF"])
    func hexSurvivesRoundTrip(hex: String) {
        #expect(AppAccent.hex(AppAccent.color(hex)) == hex)
    }

    @Test(arguments: ["", "FFB34", "#GGGGGG", "빨강"])
    func brokenValueFallsBackToHanlabongOrange(hex: String) {
        #expect(AppAccent.hex(AppAccent.color(hex)) == AppAccent.defaultHex)
    }
}
