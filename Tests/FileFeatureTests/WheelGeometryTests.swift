import CoreGraphics
import Testing
@testable import FileFeature

/// 휠 위의 위치 → 칸 번호 계산 (0번이 12시, 시계 방향)
struct WheelGeometryTests {
    let geometry = WheelGeometry()  // 칸 8개, 안쪽 50, 바깥 140, 빈틈 5도

    /// 12시 기준 `degrees`(시계 방향), 중심에서 `radius` 떨어진 점
    private func point(_ degrees: Double, _ radius: CGFloat = 100) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: radius * CGFloat(sin(r)), y: radius * CGFloat(cos(r)))  // y는 위쪽이 +
    }

    @Test(arguments: 0..<8)
    func slotCentersMapToTheirOwnSlot(slot: Int) {
        #expect(geometry.slot(at: point(Double(slot) * 45)) == slot)
    }

    @Test func clockPositions() {
        #expect(geometry.slot(at: CGPoint(x: 0, y: 100)) == 0)    // 12시
        #expect(geometry.slot(at: CGPoint(x: 100, y: 0)) == 2)    // 3시
        #expect(geometry.slot(at: CGPoint(x: 0, y: -100)) == 4)   // 6시
        #expect(geometry.slot(at: CGPoint(x: -100, y: 0)) == 6)   // 9시
    }

    @Test func centerCircleAndOutsideAreNotSlots() {
        #expect(geometry.slot(at: .zero) == nil)
        #expect(geometry.slot(at: point(0, 49)) == nil)
        #expect(geometry.slot(at: point(0, 51)) == 0)
        #expect(geometry.slot(at: point(0, 140)) == 0)
        #expect(geometry.slot(at: point(0, 141)) == nil)
    }

    @Test func gapsBetweenSlotsAreNotSlots() {
        // 칸 경계(22.5도) 바로 위·아래 2.5도씩이 빈틈
        #expect(geometry.slot(at: point(22.5)) == nil)
        #expect(geometry.slot(at: point(22.5 + 2.4)) == nil)
        #expect(geometry.slot(at: point(22.5 - 2.4)) == nil)
        #expect(geometry.slot(at: point(22.5 + 2.6)) == 1)
        #expect(geometry.slot(at: point(22.5 - 2.6)) == 0)
    }

    @Test func wrapsAroundAtTwelveOClock() {
        #expect(geometry.slot(at: point(-10)) == 0)     // 12시 왼쪽도 0번
        #expect(geometry.slot(at: point(350)) == 0)
        #expect(geometry.slot(at: point(-45)) == 7)
    }

    @Test func anglesLeaveTheGap() {
        let a = geometry.angles(of: 1)                  // 중심 45도
        #expect(abs(a.start - 25) < 1e-9)
        #expect(abs(a.end - 65) < 1e-9)
    }

    @Test func otherSlotCounts() {
        let six = WheelGeometry(slotCount: 6)
        #expect(six.slot(at: point(60)) == 1)
        #expect(six.slot(at: point(180)) == 3)
    }
}
