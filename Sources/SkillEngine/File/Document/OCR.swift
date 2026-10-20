import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import Vision

/// 글자 인식(OCR) 한 줄. 좌표는 똑바로 세운 그림의 픽셀 기준, 위쪽이 0.
struct OCRLine: Equatable {
    var text: String
    var rect: CGRect
    /// 0~1. 줄 전체의 확신도(Vision은 단어별 확신도를 주지 않는다)
    var confidence: Float
    /// 2·3순위로 읽은 다른 후보들. 1순위와 다르게 읽은 단어가 "불확실한 곳"이다.
    var alternatives: [String] = []
}

struct OCRPage {
    /// 똑바로 세운 그림의 픽셀 크기
    var size: CGSize
    var lines: [OCRLine]
}

/// macOS에 들어 있는 Vision으로 한국어·영어 글자를 읽는다. 이 컴퓨터 밖으로 나가지 않는다.
enum TextRecognizer {
    static let languages = ["ko-KR", "en-US"]
    /// OCR에 넘기는 그림의 긴 변 상한(이보다 크면 줄인다 — 더 키워도 인식률은 비슷하고 느려진다)
    static let maxPixels: CGFloat = 4000

    static func recognize(_ image: CGImage) throws -> OCRPage {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
            let candidates = observation.topCandidates(3)
            guard let candidate = candidates.first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let box = observation.boundingBox   // 0~1, 왼쪽 아래가 원점
            return OCRLine(
                text: candidate.string,
                rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height),
                confidence: candidate.confidence,
                alternatives: candidates.dropFirst().map(\.string)
            )
        }
        return OCRPage(size: CGSize(width: width, height: height), lines: readingOrder(lines))
    }

    /// 위에서 아래로, 같은 줄 높이면 왼쪽에서 오른쪽으로
    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        guard !lines.isEmpty else { return lines }
        let heights = lines.map(\.rect.height).sorted()
        let tolerance = heights[heights.count / 2] * 0.5
        var rows: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let last = rows.last?.last, abs(last.rect.midY - line.rect.midY) < tolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// 문단 짜기용 줄로. `pointsPerPixel`로 PDF 포인트 단위로 바꾼다(그림이면 1).
    /// OCR 글자 높이는 줄마다 조금씩 흔들리니, 본문 높이 근처는 하나로 맞춘다(안 그러면 줄마다 문단이 끊긴다).
    static func pdfLines(from page: OCRPage, pageIndex: Int, pointsPerPixel scale: CGFloat = 1) -> [PDFLine] {
        guard !page.lines.isEmpty else { return [] }
        let heights = page.lines.map(\.rect.height).sorted()
        let median = heights[heights.count / 2]
        return page.lines.map { line in
            let height = abs(line.rect.height - median) < median * 0.25 ? median : line.rect.height
            return PDFLine(
                page: pageIndex, runs: [DocumentRun(line.text)],
                minX: line.rect.minX * scale, top: line.rect.minY * scale, bottom: line.rect.maxY * scale,
                width: line.rect.width * scale, fontSize: height * 0.75 * scale, pageHeight: page.size.height * scale
            )
        }
    }
}

/// OCR에 넘길 그림 만들기
enum OCRSource {
    /// 사진 파일 → 똑바로 세운(EXIF 회전 적용) 그림, 긴 변은 상한까지. RAW도 된다.
    static func uprightImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FileSkillError.unreadable(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: TextRecognizer.maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        // RAW 등 썸네일이 안 되는 경우: Core Image로 풀어서 그린다
        if let raw = CIRAWFilter(imageURL: url)?.outputImage {
            let scale = min(1, TextRecognizer.maxPixels / max(raw.extent.width, raw.extent.height))
            let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let image = CIContext().createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                return image
            }
        }
        throw FileSkillError.unreadable(url.lastPathComponent)
    }

    /// PDF 쪽의 똑바로 선 크기(쪽 회전 반영, 포인트)
    static func uprightSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox).size
        return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// PDF 쪽 → 흰 바탕 그림(긴 변 상한, 쪽 회전 반영). 돌려준 배율 = 픽셀 / 포인트.
    static func render(_ page: PDFPage) -> (image: CGImage, pixelsPerPoint: CGFloat)? {
        guard let pageRef = page.pageRef else { return nil }
        let size = uprightSize(of: page)
        let scale = min(300.0 / 72.0, TextRecognizer.maxPixels / max(size.width, size.height))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pageRef)
        return context.makeImage().map { ($0, scale) }
    }
}

/// 글자가 없는(스캔한) PDF 쪽을 OCR해서 문단 짜기용 줄로 만든다
enum PDFPageOCR {
    static func lines(of page: PDFPage, index: Int, cancellation: FileCancellation = .never) throws -> [PDFLine] {
        try cancellation.check()
        guard let rendered = OCRSource.render(page) else { return [] }
        let result = try TextRecognizer.recognize(rendered.image)
        return TextRecognizer.pdfLines(from: result, pageIndex: index, pointsPerPixel: 1 / rendered.pixelsPerPoint)
    }
}
