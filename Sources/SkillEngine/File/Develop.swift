import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 사진 현상 값(라이트룸의 기본 패널 정도). 0이 "그대로"이고 대부분 -100~100.
/// 휠의 현상 프리셋과 Hanlabong Developing 앱이 같은 값을 쓴다.
public struct DevelopSettings: Codable, Equatable, Hashable, Sendable {
    // 빛
    public var exposure = 0.0      // EV, -5~5
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var whites = 0.0
    public var blacks = 0.0
    // 색
    public var temperature = 0.0   // + 따뜻하게, - 차갑게
    public var tint = 0.0          // + 자주, - 초록
    public var vibrance = 0.0
    public var saturation = 0.0
    // 효과
    public var clarity = 0.0
    public var vignette = 0.0      // - 가장자리 어둡게, + 밝게
    public var grain = 0.0         // 0~100
    public var blackAndWhite = false
    // 톤 커브·색조 편집(8색)
    public var curve = ToneCurve()
    public var mixer = ColorMixer()

    public init() {}

    public var isNeutral: Bool { self == DevelopSettings() }

    /// 저장할 때 빠진 값은 0으로 읽는다(예전 프리셋 파일에 새 값이 없어도 열리게)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        exposure = try v(.exposure); contrast = try v(.contrast); highlights = try v(.highlights); shadows = try v(.shadows)
        whites = try v(.whites); blacks = try v(.blacks); temperature = try v(.temperature); tint = try v(.tint)
        vibrance = try v(.vibrance); saturation = try v(.saturation); clarity = try v(.clarity); vignette = try v(.vignette)
        grain = try v(.grain); blackAndWhite = try c.decodeIfPresent(Bool.self, forKey: .blackAndWhite) ?? false
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve) ?? ToneCurve()
        mixer = try c.decodeIfPresent(ColorMixer.self, forKey: .mixer) ?? ColorMixer()
    }
}

/// 현상 프리셋 하나(휠의 한 칸)
public struct DevelopPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var settings: DevelopSettings

    public init(id: String, name: String, settings: DevelopSettings) {
        self.id = id; self.name = name; self.settings = settings
    }

    /// 처음 깔았을 때 휠에 들어 있는 세 칸
    public static var defaults: [DevelopPreset] {
        var natural = DevelopSettings()
        natural.exposure = 0.1; natural.contrast = 10; natural.highlights = -25; natural.shadows = 20; natural.vibrance = 15
        var film = DevelopSettings()
        film.temperature = 35; film.tint = 6; film.contrast = 12; film.blacks = 14; film.highlights = -15; film.saturation = -12
        film.grain = 22; film.vignette = -18
        var mono = DevelopSettings()
        mono.blackAndWhite = true; mono.contrast = 25; mono.clarity = 15; mono.shadows = 10; mono.grain = 15
        return [
            DevelopPreset(id: "develop-1", name: L("자연스럽게", "Natural"), settings: natural),
            DevelopPreset(id: "develop-2", name: L("따뜻한 필름", "Warm Film"), settings: film),
            DevelopPreset(id: "develop-3", name: L("흑백", "B&W"), settings: mono),
        ]
    }
}

/// 현상 값을 그림에 입힌다. 미리보기(작은 그림)와 저장(원본 크기)이 같은 코드를 지나서 결과가 같다.
/// 선명도 반경·그레인 크기는 그림 긴 변에 비례해서, 작은 미리보기와 큰 원본이 같은 느낌으로 나온다.
public enum Developer {
    public static func apply(_ settings: DevelopSettings, to image: CIImage) -> CIImage {
        guard !settings.isNeutral else { return image }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        var out = image

        // 1. 화이트밸런스: 기준 6500K에서 옮긴다
        if settings.temperature != 0 || settings.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: max(2500, 6500 - settings.temperature * 60), y: -settings.tint * 0.8)
            out = f.outputImage ?? out
        }
        // 2. 노출
        if settings.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = out
            f.ev = Float(min(max(settings.exposure, -5), 5))
            out = f.outputImage ?? out
        }
        // 여기부터는 눈에 보이는 밝기 단계(sRGB 감마)에서 다룬다. Core Image 안쪽 값(선형)에서 대비·곡선을 걸면
        // 어두운 쪽이 한꺼번에 뭉개진다(실제 RAW로 돌려보니 프리셋이 전부 시커멓게 나왔다)
        out = out.applyingFilter("CILinearToSRGBToneCurve")
        // 3. 하이라이트 낮추기·섀도 올리기: 주변을 보고 밝기를 고르는 방식(단순 곡선보다 회색 테두리가 덜 생긴다)
        let recoverHighlights = min(settings.highlights, 0), liftShadows = max(settings.shadows, 0)
        if recoverHighlights != 0 || liftShadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = out
            f.radius = Float(longEdge / 200)
            f.highlightAmount = Float(1 + recoverHighlights / 100)
            f.shadowAmount = Float(liftShadows / 100)
            out = f.outputImage ?? out
        }
        // 4. 톤 곡선: 블랙·섀도(반대 방향)·하이라이트(반대 방향)·화이트
        let pushHighlights = max(settings.highlights, 0), crushShadows = min(settings.shadows, 0)
        if settings.blacks != 0 || settings.whites != 0 || pushHighlights != 0 || crushShadows != 0 {
            func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
            let f = CIFilter.toneCurve()
            f.inputImage = out
            f.point0 = CGPoint(x: 0, y: clamp(settings.blacks * 0.0015))
            f.point1 = CGPoint(x: 0.25, y: clamp(0.25 + crushShadows * 0.0012 + settings.blacks * 0.0005))
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: clamp(0.75 + pushHighlights * 0.0012 + settings.whites * 0.0005))
            f.point4 = CGPoint(x: 1, y: clamp(1 + settings.whites * 0.0015))
            out = f.outputImage ?? out
        }
        // 5. 대비·채도
        if settings.contrast != 0 || settings.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.contrast = Float(1 + settings.contrast / 250)
            f.saturation = Float(max(0, 1 + settings.saturation / 100))
            out = f.outputImage ?? out
        }
        // 6. 생동감: 이미 진한 색·피부색은 덜 건드린다
        if settings.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = out
            f.amount = Float(settings.vibrance / 100)
            out = f.outputImage ?? out
        }
        // 6-1. 톤 커브 + 색조 편집(8색): 둘 다 "이 색은 저 색으로"라서 색 표(3D LUT) 하나로 합쳐 한 번에 입힌다
        if !settings.curve.isIdentity || !settings.mixer.isNeutral {
            let size = ColorLUT.size
            let f = CIFilter.colorCube()
            f.inputImage = out
            f.cubeDimension = Float(size)
            f.cubeData = ColorLUT.cube(curve: settings.curve, mixer: settings.mixer)
            out = f.outputImage ?? out
        }
        // 7. 선명도(중간 톤 대비): 반경이 큰 언샤프 마스크. 음수면 부드럽게
        if settings.clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = out.clampedToExtent()
            f.radius = Float(longEdge / 60)
            f.intensity = Float(settings.clarity / 100 * 0.7)
            out = (f.outputImage ?? out).cropped(to: extent)
        }
        // 8. 흑백: 밝기 비율(Rec.709)대로 회색으로
        if settings.blackAndWhite {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.saturation = 0
            out = f.outputImage ?? out
        }
        // 9. 비네트: 음수면 가장자리를 어둡게
        if settings.vignette != 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = out
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(longEdge * 0.62)
            f.intensity = Float(min(max(-settings.vignette / 100, -1), 1))
            f.falloff = 0.6
            out = (f.outputImage ?? out).cropped(to: extent)
        }
        // 10. 필름 그레인: 그림 크기에 맞춘 흑백 잡티를 은은하게 섞는다
        if settings.grain > 0 {
            out = grained(out, amount: settings.grain / 100, longEdge: longEdge)
        }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    private static func grained(_ image: CIImage, amount: Double, longEdge: CGFloat) -> CIImage {
        let extent = image.extent
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        // 긴 변 3000px 기준 알갱이 1px 정도. 작은 미리보기에선 알갱이도 같이 작게
        let scale = max(longEdge / 3000, 0.25)
        let mono = CIFilter.colorControls()
        mono.inputImage = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        mono.saturation = 0
        mono.brightness = 0
        guard let grain = mono.outputImage?.cropped(to: extent) else { return image }
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        guard let mixed = blend.outputImage else { return image }
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = mixed
        dissolve.time = Float(min(max(amount * 0.6, 0), 1))
        return dissolve.outputImage?.cropped(to: extent) ?? image
    }
}
