import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import PDFKit

/// 사진·스캔 PDF → PDF. `ocr`이면 보이지 않는 글자 층을 얹어서 검색·복사가 되게 한다(보이는 모양은 원본 그대로).
enum SearchablePDF {
    /// 사진 한 장 → PDF 한 쪽. JPEG 원본 데이터를 그대로 넣어서(다시 압축하지 않아서) 화질·용량이 원본과 같다.
    static func fromImage(_ url: URL, ocr: Bool, cancellation: FileCancellation = .never) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FileSkillError.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = CGImagePropertyOrientation(rawValue: properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1) ?? .up
        let raw = CGSize(width: image.width, height: image.height)
        let upright = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) ? CGSize(width: raw.height, height: raw.width) : raw

        // 쪽 크기: 스캐너가 적어둔 DPI(100 이상)를 믿고, 없거나 72면 긴 변을 A4 긴 변(11.69인치)에 맞춘다
        let dpiTag = properties[kCGImagePropertyDPIWidth as String] as? Double ?? 72
        let dpi = dpiTag >= 100 ? CGFloat(dpiTag) : max(upright.width, upright.height) / 11.69
        let pointsPerPixel = 72 / dpi
        let page = CGRect(x: 0, y: 0, width: upright.width * pointsPerPixel, height: upright.height * pointsPerPixel)

        var ocrPage: OCRPage?
        if ocr {
            try cancellation.check()
            ocrPage = try TextRecognizer.recognize(try OCRSource.uprightImage(url))
        }

        return makePDF(title: url.deletingPathExtension().lastPathComponent) { context in
            context.beginPDFPage([kCGPDFContextMediaBox as String: page] as CFDictionary)
            context.saveGState()
            context.scaleBy(x: pointsPerPixel, y: pointsPerPixel)
            // EXIF 회전을 그리기 변환으로 처리한다(픽셀을 돌려서 다시 만들면 JPEG를 다시 압축하게 된다)
            context.concatenate(CIImage(cgImage: image).orientationTransform(for: orientation))
            context.draw(image, in: CGRect(origin: .zero, size: raw))
            context.restoreGState()
            if let ocrPage {
                drawInvisibleText(ocrPage.lines, pointsPerPixel: page.width / ocrPage.size.width, pageHeight: page.height, in: context)
            }
            context.endPDFPage()
        }
    }

    /// 스캔 PDF → 같은 모양의 PDF + 글자가 없는 쪽에만 보이지 않는 글자 층. 이미 글자가 있는 쪽은 그대로 둔다.
    static func fromPDF(_ document: PDFDocument, title: String, cancellation: FileCancellation = .never) throws -> Data {
        var failure: Error?
        let data = makePDF(title: title) { context in
            for index in 0..<document.pageCount {
                guard failure == nil, let page = document.page(at: index), let pageRef = page.pageRef else { continue }
                let size = OCRSource.uprightSize(of: page)
                context.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(origin: .zero, size: size)] as CFDictionary)
                context.saveGState()
                context.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(pageRef)
                context.restoreGState()
                if PDFTextExtractor.letterCount(page.string ?? "") < 3 {
                    do {
                        try cancellation.check()
                        if let rendered = OCRSource.render(page) {
                            let result = try TextRecognizer.recognize(rendered.image)
                            drawInvisibleText(result.lines, pointsPerPixel: 1 / rendered.pixelsPerPoint, pageHeight: size.height, in: context)
                        }
                    } catch {
                        failure = error
                    }
                }
                context.endPDFPage()
            }
        }
        if let failure { throw failure }
        return data
    }

    /// 보이지 않는 글자를 OCR 상자 위치·너비에 맞춰 얹는다(PDF 뷰어의 선택·검색·복사가 이 글자를 쓴다)
    static func drawInvisibleText(_ lines: [OCRLine], pointsPerPixel k: CGFloat, pageHeight: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: line.rect.minX * k, y: pageHeight - line.rect.maxY * k, width: line.rect.width * k, height: line.rect.height * k)
            guard box.width > 0, box.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, box.height * 0.85), nil)
            let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
            context.scaleBy(x: box.width / width, y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func makePDF(title: String, draw: (CGContext) -> Void) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "DragEdit"] as CFDictionary) else {
            return Data()
        }
        draw(context)
        context.closePDF()
        return data as Data
    }
}
