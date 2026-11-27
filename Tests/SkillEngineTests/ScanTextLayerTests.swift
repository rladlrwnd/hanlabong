import CoreText
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// (OCRTests와 같은 묶음: 글자 인식 테스트는 차례로 돈다) 스캔한 쪽(글자 없는 그림 쪽)에 보이지 않는 글자 층을 얹는다: 글자가 찾아지고 쪽 크기(A4)는 그대로
extension OCRTests {
    /// 글자를 그림으로만 그린 A4 한 쪽 PDF(진짜 스캔처럼 글자 층이 없다)
    private func scanTextLayerA4() throws -> Data {
        // 글자를 그림으로만 그린다(CGContext라 여러 테스트가 동시에 돌아도 안전하다)
        let context = try #require(CGContext(data: nil, width: 1190, height: 1684, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1190, height: 1684))
        let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, 72, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "가족관계증명서 Hanlabong", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = CGPoint(x: 120, y: 1400)
        CTLineDraw(line, context)
        let image = try #require(context.makeImage())
        // A4(595×842pt) 쪽 하나에 그림만 깐 PDF
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPage(mediaBox: &box)
        pdf.draw(image, in: box)
        pdf.endPage()
        pdf.closePDF()
        return data as Data
    }

    @Test func addsFindableTextAndKeepsA4() throws {
        let data = try scanTextLayerA4()
        let before = try #require(PDFDocument(data: data))
        #expect(ScanTextLayer.scannedPages(before) == [0])
        let out = try #require(try ScanTextLayer.addText(toPage: data))
        let after = try #require(PDFDocument(data: out))
        let page = try #require(after.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
        #expect(!after.findString("Hanlabong", withOptions: .caseInsensitive).isEmpty)
        #expect(ScanTextLayer.scannedPages(after).isEmpty)
    }
}
