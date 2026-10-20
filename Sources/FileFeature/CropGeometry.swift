import CoreGraphics
import Foundation
import SkillEngine

/// 자르기 상자의 모양과 움직임(화면과 분리된 순수 계산). 좌표는 보이는(회전·반전 뒤) 사진 기준 0~1, 왼쪽 위가 원점.
package struct CropGeometry: Equatable {
    package enum Aspect: Equatable, Hashable {
        case free, original
        /// 가로:세로
        case ratio(Double, Double)

        package var title: String {
            switch self {
            case .free: return L("자유", "Free")
            case .original: return L("원본", "Original")
            case .ratio(let w, let h): return "\(Int(w)):\(Int(h))"
            }
        }
    }

    package enum Handle: Equatable { case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }

    package static let minSize: CGFloat = 0.04

    /// 보이는 사진의 픽셀 크기(비율 계산용)
    package var imageSize: CGSize
    package var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    package private(set) var aspect: Aspect = .free

    package init(imageSize: CGSize) { self.imageSize = imageSize }

    package var isFull: Bool { rect.width > 0.9995 && rect.height > 0.9995 }
    package var pixelRect: CGRect {
        CGRect(x: rect.minX * imageSize.width, y: rect.minY * imageSize.height, width: rect.width * imageSize.width, height: rect.height * imageSize.height)
    }

    /// 고른 비율(가로/세로, 픽셀 기준). 자유면 nil.
    package var lockedRatio: Double? {
        switch aspect {
        case .free: return nil
        case .original: return Double(imageSize.width / imageSize.height)
        case .ratio(let w, let h): return w / h
        }
    }

    /// 비율을 바꾸면 지금 상자의 가운데를 지키면서 그 비율로 맞춘다(상자 안에 들어가게 줄인다).
    package mutating func setAspect(_ newAspect: Aspect) {
        aspect = newAspect
        guard let ratio = lockedRatio else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // 현재 상자 안에 들어가는 가장 큰 상자
        var w = rect.width * imageSize.width, h = rect.height * imageSize.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        rect = clamped(CGRect(x: center.x - w / imageSize.width / 2, y: center.y - h / imageSize.height / 2, width: w / imageSize.width, height: h / imageSize.height))
    }

    package mutating func move(by delta: CGSize) {
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        rect = r
    }

    /// 손잡이를 `point`(0~1)까지 끈다. 비율이 정해져 있으면 비율을 지키고, 반대쪽 모서리(또는 변)는 그대로 둔다.
    package mutating func drag(_ handle: Handle, to point: CGPoint) {
        let p = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        guard let ratio = lockedRatio else {
            var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
            switch handle {
            case .topLeft: left = p.x; top = p.y
            case .top: top = p.y
            case .topRight: right = p.x; top = p.y
            case .left: left = p.x
            case .right: right = p.x
            case .bottomLeft: left = p.x; bottom = p.y
            case .bottom: bottom = p.y
            case .bottomRight: right = p.x; bottom = p.y
            }
            left = min(left, right - Self.minSize); top = min(top, bottom - Self.minSize)
            right = max(right, left + Self.minSize); bottom = max(bottom, top + Self.minSize)
            rect = clamped(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            return
        }

        // 비율 고정: 변 손잡이는 가까운 모서리처럼 다루되 반대쪽 변의 가운데를 지킨다
        let sx: CGFloat, sy: CGFloat           // 움직이는 모서리 방향(-1 왼쪽/위, +1 오른쪽/아래)
        var anchor: CGPoint
        switch handle {
        case .topLeft: sx = -1; sy = -1; anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: sx = 1; sy = -1; anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: sx = -1; sy = 1; anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: sx = 1; sy = 1; anchor = CGPoint(x: rect.minX, y: rect.minY)
        case .left: sx = -1; sy = 1; anchor = CGPoint(x: rect.maxX, y: rect.midY)
        case .right: sx = 1; sy = 1; anchor = CGPoint(x: rect.minX, y: rect.midY)
        case .top: sx = 1; sy = -1; anchor = CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom: sx = 1; sy = 1; anchor = CGPoint(x: rect.midX, y: rect.minY)
        }
        let W = imageSize.width, H = imageSize.height
        let sideHandle = [.left, .right, .top, .bottom].contains(handle)
        var w = abs(p.x - anchor.x) * W, h = abs(p.y - anchor.y) * H
        switch handle {
        case .left, .right: h = w / ratio
        case .top, .bottom: w = h * ratio
        default: if w / max(h, 0.0001) > ratio { h = w / ratio } else { w = h * ratio }
        }
        // 사진 밖으로 못 나가게
        var maxW = (sx > 0 ? (1 - anchor.x) : anchor.x) * W
        var maxH = (sy > 0 ? (1 - anchor.y) : anchor.y) * H
        if sideHandle {
            if handle == .left || handle == .right { maxH = min(anchor.y, 1 - anchor.y) * 2 * H } else { maxW = min(anchor.x, 1 - anchor.x) * 2 * W }
        }
        w = min(w, maxW, maxH * ratio)
        h = w / ratio
        w = max(w, Self.minSize * W); h = w / ratio
        let nw = w / W, nh = h / H
        switch handle {
        case .left, .right: rect = CGRect(x: sx > 0 ? anchor.x : anchor.x - nw, y: anchor.y - nh / 2, width: nw, height: nh)
        case .top, .bottom: rect = CGRect(x: anchor.x - nw / 2, y: sy > 0 ? anchor.y : anchor.y - nh, width: nw, height: nh)
        default: rect = CGRect(x: sx > 0 ? anchor.x : anchor.x - nw, y: sy > 0 ? anchor.y : anchor.y - nh, width: nw, height: nh)
        }
        rect = clamped(rect)
    }

    // MARK: 회전·반전: 상자가 사진과 함께 따라 움직인다

    package mutating func rotateClockwise() {
        rect = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        imageSize = CGSize(width: imageSize.height, height: imageSize.width)
        if case .ratio(let w, let h) = aspect { aspect = .ratio(h, w) }
    }

    package mutating func rotateCounterclockwise() {
        rect = CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        imageSize = CGSize(width: imageSize.height, height: imageSize.width)
        if case .ratio(let w, let h) = aspect { aspect = .ratio(h, w) }
    }

    package mutating func flipHorizontal() { rect.origin.x = 1 - rect.maxX }
    package mutating func flipVertical() { rect.origin.y = 1 - rect.maxY }

    private func clamped(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(max(r.width, Self.minSize), 1)
        r.size.height = min(max(r.height, Self.minSize), 1)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        return r
    }
}

/// 사진 편집 창이 만드는 스킬의 재료(화면과 분리해서 테스트한다)
package struct ImageEditDraft: Equatable {
    package var crop: CropGeometry
    package var rotation = 0                  // 시계 방향 0/90/180/270
    package var flipHorizontal = false
    package var flipVertical = false
    package var brightness = 0.0
    package var contrast = 1.0
    package var saturation = 1.0
    /// 원본 사진의 확장자(저장 형식을 정한다)
    package var sourceExtension: String

    package init(sourceSize: CGSize, sourceExtension: String) {
        crop = CropGeometry(imageSize: sourceSize)
        self.sourceExtension = sourceExtension.lowercased()
    }

    package var hasChanges: Bool {
        !crop.isFull || rotation != 0 || flipHorizontal || flipVertical || brightness != 0 || contrast != 1 || saturation != 1
    }

    package mutating func rotate(clockwise: Bool) {
        if clockwise { crop.rotateClockwise() } else { crop.rotateCounterclockwise() }
        rotation = ((rotation + (clockwise ? 90 : 270)) % 360)
    }

    package mutating func flipH() { flipHorizontal.toggle(); crop.flipHorizontal() }
    package mutating func flipV() { flipVertical.toggle(); crop.flipVertical() }

    package mutating func resetAdjustments() { brightness = 0; contrast = 1; saturation = 1 }

    /// 저장 형식: JPG·PNG·HEIC·TIFF는 그대로, 그 밖(RAW 등)은 JPG
    package var outputFormat: OutputFormat {
        switch sourceExtension {
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return .jpg
        }
    }

    package var skill: FileSkill {
        var steps: [FileStep] = [.decode]
        if rotation != 0 { steps.append(.rotate(degrees: rotation)) }
        if flipHorizontal || flipVertical { steps.append(.flip(horizontal: flipHorizontal, vertical: flipVertical)) }
        if !crop.isFull {
            steps.append(.crop(CropSpec(rect: .init(x: crop.rect.minX, y: crop.rect.minY, width: crop.rect.width, height: crop.rect.height))))
        }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            steps.append(.adjust(brightness: brightness, contrast: contrast, saturation: saturation))
        }
        steps.append(.colorspace(.keep))
        steps.append(.metadata(MetadataSpec(mode: .keepAll)))
        steps.append(.encode(EncodeSpec(format: outputFormat, quality: outputFormat.isLossy ? 0.95 : nil)))
        return FileSkill(id: "image-edit", name: L("사진 편집", "Edit photo"), symbol: "crop", input: [.image, .raw], steps: steps, output: FileOutput(suffix: "_edit"))
    }
}
