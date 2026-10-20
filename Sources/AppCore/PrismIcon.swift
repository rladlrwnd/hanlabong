import AppKit

/// 메뉴 막대 아이콘: 한 줄기 빛이 삼각 프리즘을 지나 세 갈래로 갈라지는 모양.
/// 템플릿 이미지라서 메뉴 막대의 라이트/다크에 맞춰 알아서 색이 바뀐다.
package enum PrismIcon {
    package static func menuBarImage() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // 프리즘(삼각형)
            let prism = NSBezierPath()
            prism.move(to: NSPoint(x: 9, y: 14.5))
            prism.line(to: NSPoint(x: 15, y: 2))
            prism.line(to: NSPoint(x: 3, y: 2))
            prism.close()
            prism.lineWidth = 1.5
            prism.lineJoinStyle = .round
            prism.stroke()

            // 들어오는 빛
            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: 0.5, y: 6.5))
            beam.line(to: NSPoint(x: 6.3, y: 8.6))
            beam.lineWidth = 1.3
            beam.lineCapStyle = .round
            beam.stroke()

            // 갈라져 나가는 빛 세 줄기
            for (index, endY) in [11.0, 8.0, 5.0].enumerated() {
                let ray = NSBezierPath()
                ray.move(to: NSPoint(x: 12.2, y: 8.2))
                ray.line(to: NSPoint(x: 19.5, y: endY))
                ray.lineWidth = index == 1 ? 1.3 : 1.0
                ray.lineCapStyle = .round
                ray.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DragEdit"
        return image
    }
}
