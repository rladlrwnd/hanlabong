import AppKit
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// 문서 틀의 새 필드(문단 모양·글자 모양·표 모양·여백·머리글/꼬리글)가
/// 화면 글(NSAttributedString) 왕복과 html·md·rtf·pdf 쓰기에 반영되는지
@Suite(.serialized)
struct RichStyleRoundTripTests {
    private let pageSize = CGSize(width: 595, height: 842)

    private func run(_ text: String, _ edit: (inout DocumentRun) -> Void = { _ in }) -> DocumentRun {
        var r = DocumentRun(text)
        edit(&r)
        return r
    }

    private func styledParagraph() -> DocumentParagraph {
        var p = DocumentParagraph(runs: [
            run("보통 "),
            run("굵게", { $0.bold = true }),
            run(" 밑줄", { $0.underline = true }),
            run(" 취소", { $0.strike = true }),
            run("2", { $0.script = 1 }),
            run("i", { $0.script = -1 }),
            run(" 빨강", { $0.colorHex = "FF0000" }),
            run(" 큰글씨", { $0.fontSize = 14 }),
            run(" 헬베티카", { $0.fontName = "Helvetica" }),
            run(" 링크", { $0.linkURL = "https://example.com" }),
            run(" 끝"),
        ])
        p.alignment = .center
        p.leftIndent = 20
        p.firstLineIndent = 12
        p.spaceBefore = 4
        p.spaceAfter = 14
        p.lineSpacing = 1.5
        return p
    }

    private func tableParagraph() -> DocumentParagraph {
        var p = DocumentParagraph(runs: [], table: [
            ["머리1", "머리2", "머리3"],
            ["가", "나", "다"],
            ["", "라", ""],
            ["x", "y", "z"],
        ])
        p.tableLayout = DocumentTableLayout(
            columnWidths: [1, 2, 1],
            spans: [DocumentCellSpan(row: 1, column: 0, columns: 1, rows: 2), DocumentCellSpan(row: 2, column: 1, columns: 2, rows: 1)],
            headerRows: 1, borders: false)
        return p
    }

    private func sample() -> RichDocument {
        var heading = DocumentParagraph(runs: [DocumentRun("가운데 제목")], headingLevel: 2)
        heading.alignment = .right
        var headerless = DocumentParagraph(runs: [], table: [["a", "b"], ["c", "d"]])
        headerless.tableLayout = DocumentTableLayout(headerRows: 0, borders: true)
        var plainTable = DocumentParagraph(runs: [], table: [["h", "i"], ["j", "k"]])
        plainTable.tableLayout = nil
        var doc = RichDocument(title: "서식", paragraphs: [
            heading, styledParagraph(), tableParagraph(), headerless, plainTable,
            DocumentParagraph(runs: [DocumentRun("그냥 본문")]),
        ], pageSize: pageSize)
        doc.margins = DocumentMargins(top: 90, left: 60, bottom: 70, right: 50)
        doc.header = [DocumentParagraph(runs: [DocumentRun("머리글 글")])]
        doc.footer = [DocumentParagraph(runs: [DocumentRun("꼬리글 글")])]
        doc.showPageNumber = true
        return doc
    }

    private func screen(_ doc: RichDocument) -> NSAttributedString {
        let content = RichDocumentWriter.metrics(doc).content
        return RichDocumentWriter.attributedString(paragraphs: doc.paragraphs, content: content, target: .pdf,
                                                   bodyFontSize: doc.bodyFontSize, bodyFontName: doc.bodyFontName).0
    }

    private func back(_ doc: RichDocument) -> RichDocument {
        RichDocumentEditing.document(from: screen(doc), title: doc.title, pageSize: doc.pageSize, basedOn: doc)
    }

    // MARK: 왕복

    @Test func paragraphShapeAndRunStylesSurviveScreenRoundTrip() {
        let doc = sample()
        let result = back(doc)
        #expect(result.paragraphs.count == doc.paragraphs.count)
        let heading = result.paragraphs[0]
        #expect(heading.headingLevel == 2)
        #expect(heading.alignment == .right)
        #expect(heading.spaceAfter == nil && heading.spaceBefore == nil)

        let got = result.paragraphs[1], want = doc.paragraphs[1]
        #expect(got.alignment == .center)
        #expect(got.leftIndent == 20)
        #expect(got.firstLineIndent == 12)
        #expect(got.spaceBefore == 4)
        #expect(got.spaceAfter == 14)
        #expect(got.lineSpacing == 1.5)
        #expect(got.runs.count == want.runs.count)
        for (g, w) in zip(got.runs, want.runs) { #expect(g == w, "\(w.text)") }

        let plain = result.paragraphs[5]
        #expect(plain.alignment == nil && plain.leftIndent == 0 && plain.firstLineIndent == 0)
        #expect(plain.spaceBefore == nil && plain.spaceAfter == nil && plain.lineSpacing == nil)
        #expect(plain.runs == [DocumentRun("그냥 본문")])
        #expect(plain.headingLevel == nil)
    }

    @Test func tableLayoutSurvivesScreenRoundTrip() throws {
        let doc = sample()
        let result = back(doc)
        let table = result.paragraphs[2]
        #expect(table.table == doc.paragraphs[2].table)
        let layout = try #require(table.tableLayout)
        #expect(layout.headerRows == 1)
        #expect(layout.borders == false)
        #expect(layout.spans == doc.paragraphs[2].tableLayout?.spans)
        #expect(layout.columnWidths.count == 3)
        #expect(abs(layout.columnWidths[0] - 0.25) < 0.001 && abs(layout.columnWidths[1] - 0.5) < 0.001 && abs(layout.columnWidths[2] - 0.25) < 0.001)

        let headerless = try #require(result.paragraphs[3].tableLayout)
        #expect(headerless.headerRows == 0)
        #expect(headerless.borders == true)
        #expect(headerless.columnWidths.isEmpty && headerless.spans.isEmpty)

        // 틀 없는 옛 표(첫 줄 머리줄·테두리 있음)는 되돌려도 틀이 없다
        #expect(result.paragraphs[4].tableLayout == nil)
        #expect(result.paragraphs[4].table == [["h", "i"], ["j", "k"]])
    }

    @Test func documentLevelFieldsAreCarriedOver() {
        var doc = sample()
        doc.bodyFontSize = 13
        let result = back(doc)
        #expect(result.margins == doc.margins)
        #expect(result.header == doc.header && result.footer == doc.footer)
        #expect(result.showPageNumber)
        #expect(result.bodyFontSize == 13)
    }

    @Test func bodyFontSizeChangesBodyAndHeadingBaseButNotRunSize() throws {
        var doc = RichDocument(title: "크기", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("제목")], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("본문 글이 더 길게 이어진다. 본문 글이 더 길게 이어진다."), run("큰 글", { $0.fontSize = 20 })]),
        ], pageSize: pageSize)
        doc.bodyFontSize = 14
        let text = screen(doc)
        let bodyAt = (text.string as NSString).range(of: "본문").location
        #expect((text.attribute(.font, at: bodyAt, effectiveRange: nil) as? NSFont)?.pointSize == 14)
        let titleFont = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(titleFont.pointSize == 28)
        let result = back(doc)
        #expect(result.paragraphs[0].headingLevel == 1)
        #expect(result.paragraphs[0].runs == [DocumentRun("제목")])
        #expect(result.paragraphs[1].runs.last?.fontSize == 20)
        #expect(result.paragraphs[1].runs.first?.fontSize == nil)
        #expect(result.bodyFontSize == 14)
    }

    @Test func headingMarkBeatsSizeGuessAndBodyMarkBlocksIt() {
        // 큰 글자 크기를 직접 준 본문 문단은 제목으로 짐작하지 않는다
        let big = DocumentParagraph(runs: [run("큰 본문", { $0.fontSize = 22 })])
        let doc = RichDocument(title: "큼", paragraphs: [DocumentParagraph(runs: [DocumentRun("보통 글 보통 글 보통 글 보통 글")]), big], pageSize: pageSize)
        let result = back(doc)
        #expect(result.paragraphs[1].headingLevel == nil)
        #expect(result.paragraphs[1].runs.first?.fontSize == 22)
        // 표시가 없는 화면 글(다른 곳에서 붙여 넣은 글)은 크기로 제목을 짐작한다
        let pasted = NSMutableAttributedString()
        pasted.append(NSAttributedString(string: "붙여 넣은 큰 글\n", attributes: [.font: NSFont.systemFont(ofSize: 22)]))
        pasted.append(NSAttributedString(string: "보통 글 보통 글 보통 글 보통 글 보통 글\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let guessed = RichDocumentEditing.document(from: pasted, title: "t", pageSize: nil)
        #expect(guessed.paragraphs.first?.headingLevel == 1)
    }

    @Test func mergesAdjacentRunsOnlyWhenWholeStyleMatches() {
        let doc = RichDocument(title: "합침", paragraphs: [DocumentParagraph(runs: [
            run("가", { $0.underline = true }), run("나", { $0.underline = true }), run("다"),
        ])], pageSize: pageSize)
        let result = back(doc)
        #expect(result.paragraphs[0].runs.count == 2)
        #expect(result.paragraphs[0].runs[0].text == "가나")
        #expect(result.paragraphs[0].runs[0].underline)
    }

    // MARK: 쓰기

    @Test func htmlCarriesShapesStylesAndTables() throws {
        let html = String(decoding: try RichDocumentWriter.write(sample(), as: .html), as: UTF8.self)
        #expect(html.contains("text-align:center"))
        #expect(html.contains("margin-left:20pt") && html.contains("text-indent:12pt"))
        #expect(html.contains("margin-top:4pt") && html.contains("margin-bottom:14pt") && html.contains("line-height:1.5"))
        #expect(html.contains("<u>") && html.contains("<s>") && html.contains("<sup>") && html.contains("<sub>"))
        #expect(html.contains("color:#FF0000") && html.contains("font-size:14pt") && html.contains("font-family:'Helvetica'"))
        #expect(html.contains("<a href=\"https://example.com\">"))
        #expect(html.contains("colspan=\"2\"") && html.contains("rowspan=\"2\""))
        #expect(html.contains("class=\"nb\""))
        #expect(html.contains("<colgroup>") && html.contains("width:25%") && html.contains("width:50%"))
        #expect(html.contains("<header") && html.contains("머리글 글") && html.contains("<footer") && html.contains("꼬리글 글"))
        // 머리줄 0인 표에는 thead가 없고, 틀 없는 표는 옛 모양 그대로
        #expect(html.contains("<table><thead><tr><th>h</th><th>i</th></tr></thead>"))
        #expect(html.contains("<table><tbody><tr><td>a</td>"))
    }

    @Test func htmlDropsUnsafeLinks() throws {
        let doc = RichDocument(title: "링크", paragraphs: [DocumentParagraph(runs: [run("나쁜", { $0.linkURL = "javascript:alert(1)" })])])
        let html = String(decoding: try RichDocumentWriter.write(doc, as: .html), as: UTF8.self)
        #expect(!html.contains("javascript:"))
    }

    @Test func markdownUsesHtmlTagsForUnderlineAndScripts() throws {
        let md = String(decoding: try RichDocumentWriter.write(sample(), as: .md), as: UTF8.self)
        #expect(md.contains("<u>밑줄</u>") || md.contains("<u>"))
        #expect(md.contains("~~취소~~"))
        #expect(md.contains("<sup>2</sup>") && md.contains("<sub>i</sub>"))
        #expect(md.contains("[링크](https://example.com)"))
        #expect(md.contains("**굵게**"))
    }

    @Test func rtfCarriesStylesAndHeaderFooter() throws {
        let rtf = String(decoding: try RichDocumentWriter.write(sample(), as: .rtf), as: UTF8.self)
        #expect(rtf.contains("\\ul"))
        #expect(rtf.contains("\\strike"))
        #expect(rtf.contains("\\qc"))
        #expect(rtf.contains("\\super") || rtf.contains("\\up"))
        #expect(rtf.contains("{\\header") && rtf.contains("{\\footer") && rtf.contains("PAGE"))
        // 쪽 여백: 위 90pt = 1800 twip, 왼쪽 60pt = 1200 twip
        #expect(rtf.contains("\\margt1800") && rtf.contains("\\margl1200"))
        #expect(NSAttributedString(rtf: Data(rtf.utf8), documentAttributes: nil) != nil)
    }

    @Test func pdfUsesMarginsHeaderFooterAndPageNumber() throws {
        let data = try RichDocumentWriter.write(sample(), as: .pdf)
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        let text = pdf.string ?? ""
        #expect(text.contains("머리글 글") && text.contains("꼬리글 글"))
        #expect(text.contains("1"))
        // 본문 첫 줄은 위 여백(90pt) 아래에서 시작한다
        let bounds = page.bounds(for: .mediaBox)
        let heading = try #require(pdf.findString("가운데 제목", withOptions: []).first)
        let top = bounds.maxY - heading.bounds(for: page).maxY
        #expect(top >= 88, "본문이 위 여백 안쪽에서 시작: \(top)")
        // 머리글은 위 여백 안쪽
        let header = try #require(pdf.findString("머리글 글", withOptions: []).first)
        #expect(bounds.maxY - header.bounds(for: page).maxY < 90)
    }

    @Test func odtAndEpubStillWriteWithNewFields() throws {
        let odt = try RichDocumentWriter.write(sample(), as: .odt)
        let zip = try #require(MiniZipReader(odt))
        let styles = String(decoding: try #require(zip.entries.first { $0.name == "styles.xml" }).data, as: UTF8.self)
        #expect(styles.contains("fo:margin-top=\"90pt\"") && styles.contains("fo:margin-left=\"60pt\""))
        let epub = try RichDocumentWriter.write(sample(), as: .epub)
        #expect(!epub.isEmpty)
    }

    @Test func marginsFallBackToEightPercentWhenAbsent() {
        var doc = RichDocument(title: "여백", paragraphs: [], pageSize: CGSize(width: 600, height: 800))
        #expect(RichDocumentWriter.metrics(doc).margins == DocumentMargins(top: 48, left: 48, bottom: 48, right: 48))
        doc.margins = DocumentMargins(top: 10, left: 20, bottom: 30, right: 40)
        let m = RichDocumentWriter.metrics(doc)
        #expect(m.margins == doc.margins)
        #expect(m.content == CGSize(width: 540, height: 760))
    }
}
