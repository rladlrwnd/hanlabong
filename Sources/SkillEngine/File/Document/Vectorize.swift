import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import Vision

/// 스캔·사진 찍은 문서를 벡터로 다시 짓는다.
/// 1. 종이를 찾아 반듯하게 펴고(사진으로 찍어 기울어진 경우), 그림자·얼룩을 걷어 바탕을 고르게 한다.
/// 2. 글자는 글자 인식(OCR)으로 읽어서 **진짜 글꼴 글자**로 같은 자리·크기에 쓴다 → 또렷하고 검색·복사된다.
/// 3. 글자가 아닌 것(도표의 상자·선·로고·도장)만 윤곽을 따서 벡터 모양으로 그린다.
public enum VectorFormat: String, Codable, Sendable {
    case svg, pdf
}

public enum Vectorizer {
    struct TextLine {
        var text: String
        var rect: CGRect      // 픽셀, 왼쪽 위 원점
    }

    struct Scene {
        var width: Double
        var height: Double
        var lines: [TextLine]
        /// 픽셀 좌표(왼쪽 위 원점)의 닫힌 다각형들. 짝홀 규칙으로 채우면 구멍이 뚫린다.
        var polygons: [[CGPoint]]
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: 1. 종이 펴기 + 바탕 고르게

    /// 사진 속 종이(문서)를 찾으면 그 네 귀퉁이로 반듯하게 편다. 못 찾거나 이미 꽉 찬 스캔이면 그대로.
    static func flatten(_ image: CGImage) -> CIImage {
        let input = CIImage(cgImage: image)
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let doc = request.results?.first, doc.confidence > 0.6 else { return input }
        let w = Double(image.width), h = Double(image.height)
        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * w, y: n.y * h) }
        let quad = [doc.topLeft, doc.topRight, doc.bottomRight, doc.bottomLeft].map(p)
        // 거의 전체를 덮으면(이미 스캔본) 펴지 않는다
        let area = abs(Vectorizer.area(quad))
        guard area > w * h * 0.3, area < w * h * 0.97 else { return input }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = input
        filter.topLeft = p(doc.topLeft); filter.topRight = p(doc.topRight)
        filter.bottomLeft = p(doc.bottomLeft); filter.bottomRight = p(doc.bottomRight)
        guard let out = filter.outputImage else { return input }
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
    }

    /// 흑백으로 바꾸고, 크게 흐린 판(조명·그림자)으로 나눠서 바탕을 하얗게 고른 다음 문턱값으로 흑백 두 색만 남긴다.
    static func binarize(_ image: CIImage) -> CGImage? {
        let gray = image.applyingFilter("CIPhotoEffectMono")
        // 종이 밝기(조명·그림자): 크게 흐린 판. 글자 획은 가늘어서 거의 묻히고 조명만 남는다.
        let side = max(image.extent.width, image.extent.height)
        let paper = gray.clampedToExtent().applyingGaussianBlur(sigma: side / 40).cropped(to: gray.extent)
        // 나누기 혼합은 "바탕 ÷ 입력"이라, 바탕 자리에 원래 그림을, 입력 자리에 종이 밝기를 둔다(= 원래 ÷ 종이)
        let divided = CIFilter.divideBlendMode()
        divided.inputImage = paper
        divided.backgroundImage = gray
        guard let normalized = divided.outputImage else { return nil }
        // 잉크 = 주변 종이보다 확실히 어두운 곳 + (넓게 칠한 검은 도형처럼) 원래부터 아주 어두운 곳
        let relative = CIFilter.colorThreshold()
        relative.inputImage = normalized
        relative.threshold = 0.78
        let absolute = CIFilter.colorThreshold()
        absolute.inputImage = gray
        absolute.threshold = 0.28
        guard let a = relative.outputImage, let b = absolute.outputImage else { return nil }
        let both = CIFilter.darkenBlendMode()
        both.inputImage = a
        both.backgroundImage = b
        guard let bw = both.outputImage else { return nil }
        return context.createCGImage(bw, from: gray.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: 2·3. 글자 읽기 + 나머지 윤곽

    static func build(_ image: CGImage, cancellation: FileCancellation) throws -> Scene {
        let flat = flatten(image)
        guard let clean = binarize(flat), let flatCG = context.createCGImage(flat, from: flat.extent) else {
            throw FileSkillError.encodeFailed(L("그림을 정리하지 못했어요", "Couldn't clean up the image"))
        }
        let w = Double(clean.width), h = Double(clean.height)
        // 글자는 원래 그림(펴진 것)에서 읽는 게 더 정확하다
        let page = try TextRecognizer.recognize(flatCG)
        try cancellation.check()
        let lines = evenSizes(page.lines.filter {
            // 동그라미·네모 같은 도형을 글자 "O"·"ㅁ"로 잘못 읽은 한 글자짜리는 글자로 치지 않는다(도형으로 남긴다)
            $0.rect.width > 2 && $0.rect.height > 2 && $0.confidence >= 0.3 && {
                let letters = $0.text.filter { $0.isLetter || $0.isNumber }.count
                // 아주 큰 한두 글자(그림 높이의 10% 넘게)는 로고·도형일 가능성이 커서 모양으로 남긴다
                return letters >= 1 && ($0.rect.height < CGFloat(flatCG.height) * 0.1 || letters >= 4)
            }($0)
        }.map { TextLine(text: $0.text, rect: $0.rect) })

        // 글자 자리를 흰색으로 지운 그림에서 나머지(선·상자·로고)만 윤곽을 딴다
        guard let masked = CGContext(data: nil, width: clean.width, height: clean.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FileSkillError.encodeFailed("context")
        }
        masked.draw(clean, in: CGRect(x: 0, y: 0, width: w, height: h))
        masked.setFillColor(CGColor(gray: 1, alpha: 1))
        for line in lines {
            let pad = line.rect.height * 0.18
            let r = line.rect.insetBy(dx: -pad, dy: -pad)
            masked.fill(CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height))   // CG는 왼쪽 아래 원점
        }
        guard let shapesImage = masked.makeImage() else { throw FileSkillError.encodeFailed("mask") }
        let polygons = try trace(shapesImage, cancellation: cancellation)
        return Scene(width: w, height: h, lines: lines, polygons: polygons)
    }

    /// 글자 인식 상자 높이는 줄마다 조금씩 달라서 그대로 쓰면 글자 크기가 들쭉날쭉하다.
    /// 높이가 비슷한 줄끼리(35% 안쪽) 묶어서 그 묶음의 가운데 높이로 맞춘다(제목처럼 확실히 큰 줄은 따로 남는다).
    static func evenSizes(_ lines: [TextLine]) -> [TextLine] {
        var groups: [[Int]] = []
        for index in lines.indices.sorted(by: { lines[$0].rect.height < lines[$1].rect.height }) {
            let height = lines[index].rect.height
            if let last = groups.last, let first = last.first, height <= lines[first].rect.height * 1.35 { groups[groups.count - 1].append(index) }
            else { groups.append([index]) }
        }
        var result = lines
        for group in groups {
            let heights = group.map { lines[$0].rect.height }.sorted()
            let median = heights[heights.count / 2]
            for index in group {
                let r = lines[index].rect
                result[index].rect = CGRect(x: r.minX, y: r.midY - median / 2, width: r.width, height: median)
            }
        }
        return result
    }

    static func trace(_ image: CGImage, cancellation: FileCancellation) throws -> [[CGPoint]] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = min(4096, max(64, image.width, image.height))
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try cancellation.check()
        guard let observation = request.results?.first else { return [] }
        let w = Double(image.width), h = Double(image.height)
        var polygons: [[CGPoint]] = []
        for contour in observation.topLevelContours { collect(contour, into: &polygons, width: w, height: h) }
        return polygons
    }

    private static func collect(_ contour: VNContour, into polygons: inout [[CGPoint]], width: Double, height: Double) {
        let simple = (try? contour.polygonApproximation(epsilon: 0.0003)) ?? contour
        let points = simple.normalizedPoints.map { CGPoint(x: Double($0.x) * width, y: (1 - Double($0.y)) * height) }
        // 가루 같은 잡티만 버린다(그림의 0.0005% 미만)
        if points.count >= 3, abs(area(points)) > width * height * 0.00002 { polygons.append(points) }
        for child in contour.childContours { collect(child, into: &polygons, width: width, height: height) }
    }

    static func area(_ p: [CGPoint]) -> Double {
        var sum = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; sum += Double(a.x * b.y - b.x * a.y) }
        return sum / 2
    }

    // MARK: 쓰기

    /// 상자는 곧게 남기도록 꼭짓점을 그대로 잇는다(곡선으로 펴면 모서리가 둥글게 녹는다)
    static func polygonPath(_ polygons: [[CGPoint]], flipY height: Double? = nil) -> CGPath {
        let path = CGMutablePath()
        for raw in polygons {
            let p = height.map { h in raw.map { CGPoint(x: $0.x, y: h - $0.y) } } ?? raw
            path.addLines(between: p)
            path.closeSubpath()
        }
        return path
    }

    static let fontName = "AppleSDGothicNeo-Medium"

    /// 줄 상자에 꼭 맞는 글자 크기와 가로 늘이기 비율
    static func fit(_ line: TextLine) -> (size: CGFloat, stretch: CGFloat) {
        let size = line.rect.height * 0.82
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attr = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
        let stretch = width > 0 ? min(max(line.rect.width / CGFloat(width), 0.6), 1.6) : 1
        return (size, stretch)
    }

    static func svg(_ scene: Scene) -> Data {
        func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
        var d = ""
        for p in scene.polygons {
            d += "M" + p.map { "\(f($0.x)) \(f($0.y))" }.joined(separator: "L") + "Z"
        }
        let texts = scene.lines.map { line -> String in
            let size = line.rect.height * 0.82
            let baseline = line.rect.maxY - line.rect.height * 0.2
            return "<text x=\"\(f(line.rect.minX))\" y=\"\(f(baseline))\" font-size=\"\(f(size))\" textLength=\"\(f(line.rect.width))\" lengthAdjust=\"spacingAndGlyphs\">\(RichDocumentWriter.escape(line.text))</text>"
        }.joined(separator: "\n")
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(scene.width)) \(Int(scene.height))" width="\(Int(scene.width))" height="\(Int(scene.height))">
        <rect width="100%" height="100%" fill="#fff"/>
        <path fill="#000" fill-rule="evenodd" d="\(d)"/>
        <g fill="#000" font-family="Apple SD Gothic Neo, Noto Sans KR, sans-serif">
        \(texts)
        </g>
        </svg>

        """
        return Data(svg.utf8)
    }

    /// PDF 쪽 크기는 A4 폭(595pt)에 맞춰 줄인다(픽셀 그대로면 종이가 지나치게 크다)
    static func pdf(_ scene: Scene, title: String) -> Data {
        let scale = 595 / scene.width
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: scene.width * scale, height: scene.height * scale)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.scaleBy(x: scale, y: scale)
        ctx.addPath(polygonPath(scene.polygons, flipY: scene.height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath(using: .evenOdd)
        for line in scene.lines {
            let (size, stretch) = fit(line)
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let attr = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            let baseline = scene.height - (line.rect.maxY - line.rect.height * 0.2)
            ctx.textMatrix = .identity
            ctx.translateBy(x: line.rect.minX, y: baseline)
            ctx.scaleBy(x: stretch, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    public static func run(_ input: URL, format: VectorFormat, cancellation: FileCancellation) throws -> FileResult {
        let image = try OCRSource.uprightImage(input)
        let scene = try build(image, cancellation: cancellation)
        guard !scene.polygons.isEmpty || !scene.lines.isEmpty else {
            throw FileSkillError.encodeFailed(L("다시 그릴 글자나 선을 찾지 못했어요", "No text or shapes found"))
        }
        let data = format == .svg ? svg(scene) : pdf(scene, title: input.deletingPathExtension().lastPathComponent)
        return FileResult(data: data, fileExtension: format.rawValue, width: Int(scene.width), height: Int(scene.height))
    }
}
