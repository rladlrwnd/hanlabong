import AppKit

/// 메뉴 막대 아이콘: 한라봉을 자른 단면. 껍질 고리 안에 과육 8조각(= 휠 8칸).
/// 템플릿 이미지라서 메뉴 막대의 라이트/다크에 맞춰 알아서 색이 바뀐다.
/// (이름 PrismIcon은 Prism 시절 흔적으로 남겨 둠. 모양은 Resources/Icon/hanlabong-template.svg와 같다.)
package enum PrismIcon {
    package static func menuBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let center = NSPoint(x: 9, y: 9)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // 껍질
            let rind = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16))
            rind.lineWidth = 1.2
            rind.stroke()

            // 과육 8조각: 모서리를 둥글리려고 조금 줄인 조각에 같은 색 선을 두른다
            let corner: CGFloat = 0.45
            for index in 0..<8 {
                let wedge = roundedWedge(center: center, inner: 0.8, outer: 6.0, middleDegrees: Double(index) * 45, gap: 1.2, corner: corner)
                wedge.fill()
                wedge.lineWidth = corner * 2
                wedge.lineJoinStyle = .round
                wedge.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hanlabong"
        return image
    }

    /// 45도짜리 조각 하나. 옆 변은 가운데 선과 평행하게 gap/2만큼 띄워서 조각 사이 틈이 일정하다.
    /// 안쪽 끝은 두 변이 만나기 전에 잘라서 뾰족하지 않게 한다.
    static func roundedWedge(center: NSPoint, inner: CGFloat, outer: CGFloat, middleDegrees: Double, gap: CGFloat, corner: CGFloat) -> NSBezierPath {
        let offset = gap / 2 + corner
        let half = 22.5 * Double.pi / 180
        let middle = (90 - middleDegrees) * Double.pi / 180   // 0도 = 위쪽, 시계방향
        let innerRadius = max(inner + corner, offset / CGFloat(sin(half)) * 1.08)
        let outerRadius = outer - corner

        // sign -1: 시계방향 쪽 변, +1: 반시계방향 쪽 변
        func point(side sign: Double, radius: CGFloat) -> NSPoint {
            let phi = middle + sign * half
            let along = (radius * radius - offset * offset).squareRoot()
            let inward = (x: CGFloat(sin(phi) * sign), y: CGFloat(-cos(phi) * sign))
            return NSPoint(x: center.x + offset * inward.x + along * CGFloat(cos(phi)),
                           y: center.y + offset * inward.y + along * CGFloat(sin(phi)))
        }
        func degrees(_ p: NSPoint) -> CGFloat { atan2(p.y - center.y, p.x - center.x) * 180 / .pi }

        let a0 = point(side: -1, radius: innerRadius), a1 = point(side: -1, radius: outerRadius)
        let b1 = point(side: 1, radius: outerRadius), b0 = point(side: 1, radius: innerRadius)
        let path = NSBezierPath()
        path.move(to: a0)
        path.line(to: a1)
        path.appendArc(withCenter: center, radius: outerRadius, startAngle: degrees(a1), endAngle: degrees(b1), clockwise: false)
        path.line(to: b0)
        path.appendArc(withCenter: center, radius: innerRadius, startAngle: degrees(b0), endAngle: degrees(a0), clockwise: true)
        path.close()
        return path
    }
}
