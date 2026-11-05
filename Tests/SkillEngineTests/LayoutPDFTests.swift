import AppKit
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// 워드 → PDF가 모양(가로 용지·단·줄 간격)을 살리는지. 예전엔 글만 뽑아 세로 A4 한 단으로 다시 앉혀서 다 사라졌다.
struct LayoutPDFTests {
    /// 가로 A4, 2단(넓은 왼쪽·좁은 오른쪽), 1.5줄 간격 문단이 든 최소 워드 파일
    private func docx(columns: String, paragraphs: Int = 60) throws -> URL {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#)
        zip.add("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#)
        let body = (1...paragraphs).map { #"<w:p><w:pPr><w:spacing w:after="120" w:line="360" w:lineRule="auto"/></w:pPr><w:r><w:t>Paragraph \#($0) of a long exam passage that keeps going.</w:t></w:r></w:p>"# }.joined()
        zip.add("word/document.xml", #"<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + body +
                #"<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/><w:pgMar w:top="283" w:right="720" w:bottom="283" w:left="454"/>"# + columns + "</w:sectPr></w:body></w:document>")
        let url = try Fixtures.makeTempDir().appendingPathComponent("exam.docx")
        try zip.finish().write(to: url)
        return url
    }

    @Test func readsUnequalColumnsFromTheSection() throws {
        let url = try docx(columns: #"<w:cols w:space="720" w:num="2" w:equalWidth="0"><w:col w:w="9672" w:space="720"/><w:col w:w="5006" w:space="0"/></w:cols>"#)
        let cols = LayoutPDF.docxColumns(url, bodyWidth: 783)
        #expect(cols == [LayoutPDF.Column(width: 483.6, gap: 36), LayoutPDF.Column(width: 250.3, gap: 0)])
    }

    @Test func equalColumnsAreSplitEvenly() throws {
        let url = try docx(columns: #"<w:cols w:space="720" w:num="3"/>"#)
        let cols = LayoutPDF.docxColumns(url, bodyWidth: 780)
        #expect(cols.count == 3 && abs(cols[0].width - 236) < 0.5 && cols[2].gap == 0)
    }

    @Test func wordToPDFKeepsLandscapeAndUsesBothColumns() throws {
        let url = try docx(columns: #"<w:cols w:space="720" w:num="2"/>"#)
        let result = try FileSkillExecutor().run(DefaultFileSkills.toDocument(.pdf), input: url)
        let pdf = try #require(PDFDocument(data: result.data))
        let size = try #require(pdf.page(at: 0)).bounds(for: .mediaBox).size
        #expect(size.width > size.height)                               // 가로 그대로
        // 첫 쪽 오른쪽 절반에도 글이 있다(2단으로 흘렀다)
        let page = try #require(pdf.page(at: 0))
        let right = page.selection(for: CGRect(x: size.width / 2 + 10, y: 0, width: size.width / 2 - 20, height: size.height))?.string ?? ""
        #expect(right.contains("Paragraph"))
        #expect((pdf.string ?? "").contains("Paragraph 60"))            // 글이 빠지지 않았다
    }

    @Test func noColumnsMeansOneColumn() throws {
        let url = try docx(columns: "")
        #expect(LayoutPDF.docxColumns(url, bodyWidth: 700).isEmpty)
        #expect(LayoutPDF.make(from: url) != nil)
    }
}
