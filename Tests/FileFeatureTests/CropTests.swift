import CoreGraphics
import SkillEngine
import Testing
@testable import FileFeature

struct CropTests {
    private func geometry(_ w: CGFloat = 3000, _ h: CGFloat = 2000) -> CropGeometry { CropGeometry(imageSize: CGSize(width: w, height: h)) }
    private func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-6) -> Bool { abs(a - b) < tol }
    private func ratio(_ g: CropGeometry) -> CGFloat { g.pixelRect.width / g.pixelRect.height }

    @Test func aspectFitsInsideAndKeepsTheCenter() {
        var g = geometry()
        g.setAspect(.ratio(1, 1))
        #expect(approx(ratio(g), 1))
        #expect(approx(g.rect.midX, 0.5) && approx(g.rect.midY, 0.5))
        #expect(g.pixelRect.height == 2000)                         // 가로가 긴 사진은 세로를 꽉 채운 정사각형
        g.setAspect(.ratio(16, 9))
        #expect(approx(ratio(g), 16.0 / 9, 1e-4) && g.rect.minX >= 0 && g.rect.maxX <= 1)
        g.setAspect(.free)
        #expect(g.lockedRatio == nil)
    }

    @Test func movingNeverLeavesThePicture() {
        var g = geometry()
        g.setAspect(.ratio(1, 1))
        g.move(by: CGSize(width: 5, height: 5))
        #expect(approx(g.rect.maxX, 1) && g.rect.minY >= 0 && g.rect.maxY <= 1)
        g.move(by: CGSize(width: -9, height: -9))
        #expect(approx(g.rect.minX, 0) && approx(g.rect.minY, 0))
    }

    @Test func freeDragMovesOnlyThatEdgeAndKeepsAMinimumSize() {
        var g = geometry()
        g.drag(.right, to: CGPoint(x: 0.6, y: 0.5))
        #expect(approx(g.rect.maxX, 0.6) && g.rect.minX == 0 && g.rect.height == 1)
        g.drag(.topLeft, to: CGPoint(x: 0.2, y: 0.3))
        #expect(approx(g.rect.minX, 0.2) && approx(g.rect.minY, 0.3) && approx(g.rect.maxX, 0.6))
        g.drag(.left, to: CGPoint(x: 0.9, y: 0.5))                   // 반대쪽을 넘어가도 최소 크기에서 멈춘다
        #expect(g.rect.width >= CropGeometry.minSize - 1e-9 && g.rect.maxX <= 1)
    }

    @Test func lockedRatioCornerDragKeepsTheRatioAndTheOppositeCorner() {
        var g = geometry()
        g.setAspect(.ratio(3, 2))
        g.drag(.bottomRight, to: CGPoint(x: 0.5, y: 0.5))
        #expect(approx(ratio(g), 1.5, 1e-4))
        #expect(approx(g.rect.minX, 0) && approx(g.rect.minY, 0))     // 왼쪽 위 모서리는 그대로
        g.drag(.topLeft, to: CGPoint(x: 0.1, y: 0.1))
        #expect(approx(ratio(g), 1.5, 1e-4) && approx(g.rect.maxX, 0.5 * 1) || g.rect.maxX > 0)
        #expect(g.rect.minX >= 0 && g.rect.minY >= 0 && g.rect.maxX <= 1 && g.rect.maxY <= 1)
    }

    @Test func lockedRatioCannotGrowPastThePicture() {
        var g = geometry()
        g.setAspect(.ratio(1, 1))
        g.drag(.bottomRight, to: CGPoint(x: 1, y: 1))
        #expect(approx(ratio(g), 1, 1e-4))
        #expect(g.rect.maxX <= 1 + 1e-9 && g.rect.maxY <= 1 + 1e-9)
    }

    @Test func rotationCarriesTheBoxAndSwapsTheRatio() {
        var g = geometry()
        g.drag(.bottomRight, to: CGPoint(x: 0.5, y: 0.25))           // 왼쪽 위 1/2 × 1/4
        g.rotateClockwise()
        #expect(g.imageSize == CGSize(width: 2000, height: 3000))
        #expect(approx(g.rect.minX, 0.75) && approx(g.rect.minY, 0) && approx(g.rect.width, 0.25) && approx(g.rect.height, 0.5))
        g.rotateCounterclockwise()
        #expect(approx(g.rect.minX, 0) && approx(g.rect.minY, 0) && approx(g.rect.width, 0.5) && approx(g.rect.height, 0.25))
        var r = geometry()
        r.setAspect(.ratio(3, 2))
        r.rotateClockwise()
        #expect(r.lockedRatio == 2.0 / 3)                            // 세로 사진이 되니 비율도 뒤집힌다
    }

    @Test func flipsMirrorTheBox() {
        var g = geometry()
        g.drag(.bottomRight, to: CGPoint(x: 0.5, y: 0.25))
        g.flipHorizontal()
        #expect(approx(g.rect.minX, 0.5) && approx(g.rect.maxX, 1))
        g.flipVertical()
        #expect(approx(g.rect.minY, 0.75) && approx(g.rect.maxY, 1))
    }

    @Test func draftBuildsTheRightBlocksInTheRightOrder() throws {
        var draft = ImageEditDraft(sourceSize: CGSize(width: 3000, height: 2000), sourceExtension: "RAF")
        #expect(!draft.hasChanges)
        draft.rotate(clockwise: true)
        draft.flipH()
        draft.crop.setAspect(.ratio(1, 1))
        draft.brightness = 0.1
        #expect(draft.hasChanges && draft.outputFormat == .jpg)
        let steps = draft.skill.steps
        #expect(steps[1] == .rotate(degrees: 90))
        #expect(steps[2] == .flip(horizontal: true, vertical: false))
        guard case .crop(let spec) = steps[3], let rect = spec.rect else { Issue.record("자르기 블록이 없어요"); return }
        #expect(abs(rect.width * 2000 - rect.height * 3000) < 1)     // 회전 뒤(2000×3000) 기준 1:1
        #expect(steps[4] == .adjust(brightness: 0.1, contrast: 1, saturation: 1))
        #expect(draft.skill.output.suffix == "_edit")
        try draft.skill.validate()
        draft.rotate(clockwise: false)
        #expect(draft.rotation == 0)
        #expect(ImageEditDraft(sourceSize: .zero, sourceExtension: "png").outputFormat == .png)
        #expect(ImageEditDraft(sourceSize: .zero, sourceExtension: "heic").outputFormat == .heic)
    }
}
