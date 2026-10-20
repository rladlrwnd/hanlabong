import CoreGraphics
import Foundation

/// 휠의 칸 배치와 각도 계산. 0번 칸이 12시 방향이고 시계 방향으로 번호가 늘어난다.
/// 1단계는 안쪽 링(최대 8칸), 2단계는 1단계 칸 하나에서 바깥쪽으로 펼쳐지는 링이다.
package struct WheelGeometry: Equatable {
    package var slotCount = 8
    /// 가운데 원의 반지름(이 안쪽은 어느 칸도 아님)
    package var innerRadius: CGFloat = 50
    package var outerRadius: CGFloat = 140
    /// 칸과 칸 사이의 빈틈(도). 빈틈에 놓으면 아무 칸에도 안 들어간다.
    package var gapDegrees: Double = 5

    /// 2단계 링: 눌러 열린 1단계 칸의 방향을 가운데로 부채꼴로 펼쳐진다.
    package var childInnerRadius: CGFloat = 150
    package var childOuterRadius: CGFloat = 222
    package var childWidthDegrees: Double = 38
    package var childGapDegrees: Double = 5

    package init(slotCount: Int = 8, innerRadius: CGFloat = 50, outerRadius: CGFloat = 140, gapDegrees: Double = 5) {
        self.slotCount = slotCount
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.gapDegrees = gapDegrees
    }

    package var slotWidthDegrees: Double { 360 / Double(slotCount) }

    /// 휠 창 한 변의 길이(2단계까지 들어가는 크기)
    package var side: CGFloat { childOuterRadius * 2 + 40 }

    /// 커서가 어디에 있는지
    package enum Hit: Equatable {
        case slot(Int)
        case child(parent: Int, index: Int)
    }

    // MARK: 1단계

    /// 칸의 시작·끝 각도(12시 기준, 시계 방향, 도). 빈틈은 뺀 값.
    package func angles(of slot: Int) -> (start: Double, end: Double) {
        let center = Double(slot) * slotWidthDegrees
        let half = slotWidthDegrees / 2 - gapDegrees / 2
        return (center - half, center + half)
    }

    /// 휠 중심에서 본 위치(`offset`, y는 위쪽이 +)가 어느 1단계 칸 위인지. 가운데 원·바깥·빈틈이면 nil.
    package func slot(at offset: CGPoint) -> Int? {
        let radius = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard radius >= innerRadius, radius <= outerRadius else { return nil }
        let degrees = Self.degrees(of: offset)
        let width = slotWidthDegrees
        let shifted = (degrees + width / 2).truncatingRemainder(dividingBy: 360)
        let slot = Int(shifted / width) % slotCount
        return Self.angularDistance(degrees, Double(slot) * width) <= width / 2 - gapDegrees / 2 ? slot : nil
    }

    // MARK: 2단계

    /// `parentSlot`의 자식 `count`개 중 `index`번째 칸의 시작·끝 각도. 부모 방향을 가운데로 좌우로 펼친다.
    package func childAngles(parentSlot: Int, index: Int, count: Int) -> (start: Double, end: Double) {
        let pitch = childWidthDegrees + childGapDegrees
        let span = Double(count - 1) * pitch
        let center = Double(parentSlot) * slotWidthDegrees - span / 2 + Double(index) * pitch
        return (center - childWidthDegrees / 2, center + childWidthDegrees / 2)
    }

    package func child(at offset: CGPoint, parent: Int, count: Int) -> Int? {
        let radius = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard count > 0, radius >= childInnerRadius, radius <= childOuterRadius else { return nil }
        let degrees = Self.degrees(of: offset)
        for index in 0..<count {
            let angles = childAngles(parentSlot: parent, index: index, count: count)
            let center = (angles.start + angles.end) / 2
            if Self.angularDistance(degrees, center) <= childWidthDegrees / 2 { return index }
        }
        return nil
    }

    /// 펼쳐진 부모가 있으면 2단계 칸을 먼저, 없으면(또는 2단계 위가 아니면) 1단계 칸을 찾는다.
    package func hit(at offset: CGPoint, expandedParent: Int?, childCount: Int) -> Hit? {
        if let parent = expandedParent, let index = child(at: offset, parent: parent, count: childCount) {
            return .child(parent: parent, index: index)
        }
        return slot(at: offset).map { .slot($0) }
    }

    // MARK: 각도 도우미

    /// 12시 = 0도, 시계 방향으로 늘어나는 각도(0..<360)
    private static func degrees(of offset: CGPoint) -> Double {
        var degrees = atan2(Double(offset.x), Double(offset.y)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// 두 각도 사이의 작은 쪽 차이(0...180)
    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        var distance = abs(a - b).truncatingRemainder(dividingBy: 360)
        if distance > 180 { distance = 360 - distance }
        return distance
    }
}
