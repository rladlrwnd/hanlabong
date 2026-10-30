import AppKit
import PDFKit
import Testing
@testable import SkillEngine

/// 가리기: 저장한 파일에서 가린 글자가 정말 없어지는지(복사·검색으로도 안 나오는지)
struct PDFRedactionTests {
    private func document(_ lines: [String]) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for line in lines {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)]).draw(at: CGPoint(x: 30, y: 200))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }

    @Test func redactedTextIsGoneButOtherPagesStay() throws {
        let doc = document(["SECRET 1234", "PUBLIC TEXT"])
        let page = doc.page(at: 0)!
        let box = PDFAnnotation(bounds: CGRect(x: 20, y: 190, width: 360, height: 40), forType: .square, withProperties: nil)
        box.userName = PDFRedaction.tag
        page.addAnnotation(box)
        let burned = try #require(PDFRedaction.burned(doc))
        let bytes = try #require(burned.dataRepresentation())
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(reopened.pageCount == 2)
        #expect(!(reopened.string ?? "").contains("SECRET"))
        #expect(reopened.findString("1234", withOptions: []).isEmpty)
        let second = reopened.page(at: 1)?.string ?? ""
        #expect(second.contains("PUBLIC"))     // 안 가린 쪽은 글자 그대로
    }

    @Test func nothingToRedactReturnsNil() {
        #expect(PDFRedaction.burned(document(["hello"])) == nil)
    }
}
