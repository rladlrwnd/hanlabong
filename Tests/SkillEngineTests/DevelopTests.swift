import CoreImage
import Foundation
import Testing
@testable import SkillEngine

/// 현상: 값마다 방향이 맞는지(따뜻하게 = 빨강↑파랑↓ 등), 크기가 그대로인지
struct DevelopTests {
    private let context = CIContext()
    private let gray = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))

    /// 가운데 한 점의 RGB(0~255)
    private func center(_ image: CIImage) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let e = image.extent
        context.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: e.midX, y: e.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    private func with(_ change: (inout DevelopSettings) -> Void) -> CIImage {
        var s = DevelopSettings(); change(&s)
        return Developer.apply(s, to: gray)
    }

    @Test func neutralChangesNothing() {
        #expect(Developer.apply(DevelopSettings(), to: gray) == gray)
    }

    @Test func warmIsRedderCoolIsBluer() {
        let warm = center(with { $0.temperature = 50 }), cool = center(with { $0.temperature = -50 })
        #expect(warm.r > warm.b + 5)
        #expect(cool.b > cool.r + 5)
    }

    @Test func exposureAndBlacksMoveBrightness() {
        let base = center(gray).r
        #expect(center(with { $0.exposure = 1 }).r > base + 20)
        #expect(center(with { $0.exposure = -1 }).r < base - 20)
    }

    @Test func blackAndWhiteHasNoColor() {
        let c = center(with { $0.temperature = 60; $0.blackAndWhite = true })
        #expect(abs(c.r - c.b) <= 2 && abs(c.r - c.g) <= 2)
    }

    @Test func everyEffectKeepsTheSize() {
        let out = with { s in
            s.exposure = 0.3; s.contrast = 30; s.highlights = -50; s.shadows = 40; s.whites = 20; s.blacks = -20
            s.temperature = 10; s.tint = -10; s.vibrance = 30; s.saturation = -20; s.clarity = 40; s.vignette = -40; s.grain = 50
        }
        #expect(out.extent == gray.extent)
    }

    @Test func vignetteDarkensCorners() {
        let out = with { $0.vignette = -80 }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(Int(px[0]) < center(out).r - 10)
    }

    @Test func settingsAndPresetsSurviveJSON() throws {
        var s = DevelopSettings(); s.exposure = 0.5; s.blackAndWhite = true
        let step = FileStep.develop(s)
        #expect(try JSONDecoder().decode(FileStep.self, from: JSONEncoder().encode(step)) == step)
        // 빠진 값은 0으로
        let partial = try JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":1}"#.utf8))
        #expect(partial.exposure == 1 && partial.contrast == 0 && !partial.blackAndWhite)
        #expect(DevelopPreset.defaults.count == 3)
    }

    @Test func developSkillRunsOnAPhoto() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.rgb(width: 120, height: 80) { x, _ in (UInt8(x * 2), 100, 150, 255) }, to: dir.appendingPathComponent("p.jpg"), type: .jpeg)
        let skill = FileSkill(id: "d", name: "d", input: [.image], steps: [.decode, .develop(DevelopPreset.defaults[2].settings), .encode(EncodeSpec(format: .jpg, sameAsInput: true))], output: FileOutput(suffix: "_dev"))
        let result = try FileSkillExecutor().run(skill, input: url)
        #expect(result.width == 120 && result.height == 80 && result.fileExtension == "jpg")
    }
}

/// 톤 커브·색조 편집(8색)
struct CurveAndMixerTests {
    private let context = CIContext()
    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    private func px(_ image: CIImage) -> (r: Int, g: Int, b: Int) {
        var p = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    @Test func curveGoesThroughItsPointsWithoutOvershoot() {
        let s = [CurvePoint(0, 0), CurvePoint(0.25, 0.15), CurvePoint(0.75, 0.85), CurvePoint(1, 1)]
        #expect(abs(ToneCurve.evaluate(s, at: 0.25) - 0.15) < 0.001)
        #expect(abs(ToneCurve.evaluate(s, at: 0.5) - 0.5) < 0.02)
        let values = stride(from: 0.0, through: 1.0, by: 0.01).map { ToneCurve.evaluate(s, at: $0) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })     // 계단이 거꾸로 가지 않는다
    }

    @Test func sCurveDarkensShadowsAndBrightensHighlights() {
        var s = DevelopSettings()
        s.curve.rgb = [CurvePoint(0, 0), CurvePoint(0.25, 0.15), CurvePoint(0.75, 0.85), CurvePoint(1, 1)]
        #expect(px(Developer.apply(s, to: solid(0.2, 0.2, 0.2))).r < px(solid(0.2, 0.2, 0.2)).r - 5)
        #expect(px(Developer.apply(s, to: solid(0.8, 0.8, 0.8))).r > px(solid(0.8, 0.8, 0.8)).r + 5)
    }

    @Test func redChannelCurveOnlyMovesRed() {
        var s = DevelopSettings()
        s.curve.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        let before = px(solid(0.5, 0.5, 0.5)), after = px(Developer.apply(s, to: solid(0.5, 0.5, 0.5)))
        #expect(after.r > before.r + 10 && abs(after.g - before.g) <= 2 && abs(after.b - before.b) <= 2)
    }

    @Test func mixerTouchesOnlyItsColorAndLeavesGray() {
        var s = DevelopSettings()
        s.mixer.saturation[ColorMixer.Band.red.rawValue] = -100
        let red = px(Developer.apply(s, to: solid(0.8, 0.15, 0.15)))
        #expect(abs(red.r - red.g) < 12)                                  // 빨강이 회색에 가깝게
        let blue = px(Developer.apply(s, to: solid(0.15, 0.2, 0.8)))
        #expect(blue.b > blue.r + 60)                                     // 파랑은 그대로
        let gray = px(Developer.apply(s, to: solid(0.5, 0.5, 0.5)))
        #expect(abs(gray.r - gray.b) <= 2)
    }

    @Test func redHueSliderPushesTowardOrange() {
        var s = DevelopSettings()
        s.mixer.hue[ColorMixer.Band.red.rawValue] = 100
        let out = px(Developer.apply(s, to: solid(0.8, 0.1, 0.1)))
        #expect(out.g > 40)                                               // 초록 성분이 늘어 주황 쪽으로
    }

    @Test func oldPresetFilesStillOpen() throws {
        let s = try JSONDecoder().decode(DevelopSettings.self, from: Data(#"{"exposure":0.5,"contrast":10}"#.utf8))
        #expect(s.curve.isIdentity && s.mixer.isNeutral)
    }
}
