import Foundation
import Testing
@testable import SkillEngine

/// docx 쓰기 → 읽기 왕복에서 서식이 남는지, 손으로 만든 docx(번호·각주·머리글 …)를 제대로 읽는지,
/// 생성한 XML이 XMLParser로 파싱되는지
@Suite(.serialized)
struct DocxFidelityTests {
    // MARK: 도구

    private func run(_ text: String, _ edit: (inout DocumentRun) -> Void = { _ in }) -> DocumentRun {
        var r = DocumentRun(text)
        edit(&r)
        return r
    }

    private func roundTrip(_ doc: RichDocument) throws -> DocxReader.Result {
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("a.docx")
        try DocxWriter.make(doc).write(to: url)
        return try #require(DocxReader.read(url))
    }

    private func readHand(_ files: [String: String], document: String, extraRels: String = "") throws -> DocxReader.Result {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>"#)
        zip.add("_rels/.rels", DocxWriter.packageRelationships)
        zip.add("word/document.xml", wrap(document))
        zip.add("word/_rels/document.xml.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + extraRels + "</Relationships>")
        for (name, text) in files { zip.add(name, text) }
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("h.docx")
        try zip.finish().write(to: url)
        return try #require(DocxReader.read(url))
    }

    private let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math""#

    private func wrap(_ body: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document \#(ns)><w:body>"# + body + "</w:body></w:document>"
    }

    private func part(_ root: String, _ inner: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:"# + root + " " + ns + ">" + inner + "</w:" + root + ">"
    }

    private final class ParseCheck: NSObject, XMLParserDelegate {
        var error: Error?
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    private func parses(_ text: String) -> Bool {
        let parser = XMLParser(data: Data(text.utf8))
        let check = ParseCheck()
        parser.delegate = check
        return parser.parse() && check.error == nil
    }

    private func sample() -> RichDocument {
        var plain = DocumentParagraph(runs: [
            run("보통 "),
            run("굵게", { $0.bold = true }),
            run(" 밑줄", { $0.underline = true }),
            run(" 취소", { $0.strike = true }),
            run("2", { $0.script = 1 }),
            run("i", { $0.script = -1 }),
            run(" 빨강", { $0.colorHex = "FF0000" }),
            run(" 큰글씨", { $0.fontSize = 14 }),
            run(" 헬베티카", { $0.fontName = "Helvetica" }),
            run(" 끝"),
        ])
        plain.alignment = .center
        plain.leftIndent = 20
        plain.firstLineIndent = 12
        plain.spaceBefore = 4
        plain.spaceAfter = 14
        plain.lineSpacing = 1.5

        var hanging = DocumentParagraph(runs: [run("내어쓰기 문단")])
        hanging.alignment = .justify
        hanging.leftIndent = 30
        hanging.firstLineIndent = -15

        var right = DocumentParagraph(runs: [run("오른쪽")])
        right.alignment = .right

        var tabs = DocumentParagraph(runs: [run("앞\t뒤\n다음 줄")])
        tabs.headingLevel = nil

        var table = DocumentParagraph(runs: [], table: [
            ["머리1", "머리2", "머리3"],
            ["가", "나", "다"],
            ["", "라", ""],
            ["x", "y", "z"],
        ])
        table.tableLayout = DocumentTableLayout(
            columnWidths: [1, 2, 1],
            spans: [DocumentCellSpan(row: 1, column: 0, columns: 1, rows: 2), DocumentCellSpan(row: 2, column: 1, columns: 2, rows: 1)],
            headerRows: 1, borders: false)

        var headerless = DocumentParagraph(runs: [], table: [["a", "b"], ["c", "d"]])
        headerless.tableLayout = DocumentTableLayout(headerRows: 0, borders: true)

        var empty = DocumentParagraph(runs: [], table: [["", ""], ["", ""]])
        empty.tableLayout = DocumentTableLayout(headerRows: 0, borders: true)

        var doc = RichDocument(title: "서식", paragraphs: [
            DocumentParagraph(runs: [run("제목")], headingLevel: 1),
            plain, hanging, right, tabs, table, headerless, empty,
            DocumentParagraph(runs: [run("링크", { $0.linkURL = "https://example.com/a?b=1&c=2" })]),
        ], pageSize: CGSize(width: 595, height: 842))
        doc.margins = DocumentMargins(top: 90, left: 60, bottom: 70, right: 50)
        doc.header = [DocumentParagraph(runs: [run("머리글 글")])]
        doc.footer = [DocumentParagraph(runs: [run("꼬리글 글")])]
        doc.showPageNumber = true
        doc.bodyFontSize = 13
        doc.bodyFontName = "Apple SD Gothic Neo"
        return doc
    }

    // MARK: 쓰기 → 읽기 왕복

    @Test func paragraphShapeSurvives() throws {
        let back = try roundTrip(sample())
        let p = back.paragraphs
        #expect(p[0].headingLevel == 1)
        #expect(p[1].alignment == .center)
        #expect(p[1].leftIndent == 20)
        #expect(p[1].firstLineIndent == 12)
        #expect(p[1].spaceBefore == 4)
        #expect(p[1].spaceAfter == 14)
        #expect(p[1].lineSpacing == 1.5)
        #expect(p[2].alignment == .justify)
        #expect(p[2].leftIndent == 30)
        #expect(p[2].firstLineIndent == -15)
        #expect(p[3].alignment == .right)
    }

    @Test func runStylesSurvive() throws {
        let back = try roundTrip(sample())
        let runs = back.paragraphs[1].runs
        func find(_ text: String) -> DocumentRun? { runs.first { $0.text.contains(text) } }
        #expect(find("굵게")?.bold == true)
        #expect(find("밑줄")?.underline == true)
        #expect(find("취소")?.strike == true)
        #expect(runs.first { $0.text == "2" }?.script == 1)
        #expect(runs.first { $0.text == "i" }?.script == -1)
        #expect(find("빨강")?.colorHex == "FF0000")
        #expect(find("큰글씨")?.fontSize == 14, "\(runs.map { "\($0.text)|\(String(describing: $0.fontSize))" }) body=\(String(describing: back.bodyFontSize))")
        #expect(find("헬베티카")?.fontName == "Helvetica")
        #expect(find("끝")?.fontSize == nil && find("끝")?.fontName == nil)
        #expect(back.paragraphs[8].runs.first?.linkURL == "https://example.com/a?b=1&c=2")
    }

    @Test func tabsAndLineBreaksSurvive() throws {
        let back = try roundTrip(sample())
        #expect(back.paragraphs[4].text == "앞\t뒤\n다음 줄")
        let xml = DocxWriter.build(DocxWriter.Input(paragraphs: [sample().paragraphs[4]], pageSize: CGSize(width: 595, height: 842))).xml
        #expect(xml.contains("<w:tab/>") && xml.contains("<w:br/>"))
    }

    @Test func tableLayoutSurvives() throws {
        let back = try roundTrip(sample())
        let doc = sample()
        let table = back.paragraphs[5]
        #expect(table.table == doc.paragraphs[5].table)
        let layout = try #require(table.tableLayout)
        #expect(layout.headerRows == 1)
        #expect(layout.borders == false)
        #expect(layout.spans == doc.paragraphs[5].tableLayout?.spans)
        #expect(layout.columnWidths.count == 3)
        #expect(abs(layout.columnWidths[0] - 0.25) < 0.01 && abs(layout.columnWidths[1] - 0.5) < 0.01 && abs(layout.columnWidths[2] - 0.25) < 0.01)

        let headerless = try #require(back.paragraphs[6].tableLayout)
        #expect(headerless.headerRows == 0)       // 첫 줄을 머리줄로 강제하지 않는다
        #expect(headerless.borders == true)
        #expect(headerless.spans.isEmpty)

        // 글 없는 표(빈 양식)도 남는다
        #expect(back.paragraphs[7].table == [["", ""], ["", ""]])
    }

    @Test func pageMarginsHeaderFooterBodyFontSurvive() throws {
        let back = try roundTrip(sample())
        #expect(back.pageSize == CGSize(width: 595, height: 842))
        #expect(back.margins == DocumentMargins(top: 90, left: 60, bottom: 70, right: 50))
        #expect(back.header.map(\.text) == ["머리글 글"])
        #expect(back.footer.map(\.text) == ["꼬리글 글"])
        #expect(back.showPageNumber)
        #expect(back.bodyFontSize == 13)
        #expect(back.bodyFontName == "Apple SD Gothic Neo")
    }

    @Test func landscapePageIsKeptAsWritten() throws {
        var doc = RichDocument(title: "가로", paragraphs: [DocumentParagraph(runs: [run("본문")])], pageSize: CGSize(width: 842, height: 595))
        let back = try roundTrip(doc)
        #expect(back.pageSize == CGSize(width: 842, height: 595))
        // 세로 쪽에 orient=landscape가 달려도 w/h를 맞바꾸지 않는다
        doc.pageSize = CGSize(width: 595, height: 842)
        let hand = try readHand([:], document: #"<w:p><w:r><w:t>a</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="11906" w:h="16838" w:orient="landscape"/><w:pgMar w:top="1440" w:right="1000" w:bottom="1440" w:left="1000" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>"#)
        #expect(hand.pageSize == CGSize(width: 595.3, height: 841.9))
        #expect(hand.margins == DocumentMargins(top: 72, left: 50, bottom: 72, right: 50))
    }

    @Test func noMarginsKeepsOldRule() {
        let input = DocxWriter.Input(paragraphs: [], pageSize: CGSize(width: 595, height: 842))
        let m = DocxWriter.margins(for: input)
        #expect(m.top == DocxWriter.margin(for: input.pageSize) && m.left == m.top)
    }

    // MARK: XML 문법

    @Test func generatedPartsParse() throws {
        let doc = sample()
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("p.docx")
        try DocxWriter.make(doc).write(to: url)
        let package = try #require(ZipPackage(url))
        for name in ["[Content_Types].xml", "_rels/.rels", "word/_rels/document.xml.rels", "word/document.xml", "word/styles.xml",
                     "word/header1.xml", "word/footer1.xml", "docProps/core.xml"] {
            let data = try #require(package.data(name), "\(name) 없음")
            #expect(parses(String(decoding: data, as: UTF8.self)), "\(name) 파싱 실패")
        }
        let xml = DocxWriter.build(DocxWriter.Input(paragraphs: doc.paragraphs, pageSize: doc.resolvedPageSize)).xml
        // tblPr 순서(LO docxtableexport.cxx): tblW, tblBorders, tblLayout, tblCellMar, tblLook
        let order = ["<w:tblW ", "<w:tblBorders>", "<w:tblLayout ", "<w:tblCellMar>", "<w:tblLook "]
        var last = xml.startIndex
        for tag in order {
            let range = try #require(xml.range(of: tag, range: last..<xml.endIndex))
            last = range.upperBound
        }
        #expect(!xml.contains("<w:cantSplit/>"))
    }

    @Test func oldStyleTableWithoutLayoutStillGetsHeaderAndBorders() {
        let xml = DocxWriter.tableXML([["h", "i"], ["j", "k"]], width: 9000)
        #expect(xml.contains("<w:tblHeader/>") && xml.contains(#"w:val="single""#))
    }

    // MARK: 손으로 만든 docx 읽기

    private func numbering(_ levels: String) -> [String: String] {
        ["word/numbering.xml": part("numbering", #"<w:abstractNum w:abstractNumId="0">"# + levels + #"</w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>"#)]
    }

    private func numbered(_ fmt: String, _ text: String, count: Int = 3, extraLevels: String = "") -> [String] {
        let lvl = #"<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="\#(fmt)"/><w:lvlText w:val="\#(text)"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>"# + extraLevels
        let body = (0..<count).map { _ in #"<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>항목</w:t></w:r></w:p>"# }.joined()
        let result = try? readHand(numbering(lvl), document: body)
        return result?.paragraphs.map(\.text) ?? []
    }

    @Test func numberFormatsKeepTheirLook() {
        #expect(numbered("ganada", "%1.") == ["가. 항목", "나. 항목", "다. 항목"])
        #expect(numbered("chosung", "%1.") == ["ㄱ. 항목", "ㄴ. 항목", "ㄷ. 항목"])
        #expect(numbered("decimalEnclosedCircle", "%1") == ["① 항목", "② 항목", "③ 항목"])
        #expect(numbered("decimal", "제%1조") == ["제1조 항목", "제2조 항목", "제3조 항목"])
        #expect(numbered("upperRoman", "%1)") == ["I) 항목", "II) 항목", "III) 항목"])
        #expect(numbered("upperLetter", "%1.") == ["A. 항목", "B. 항목", "C. 항목"])
        #expect(numbered("lowerLetter", "(%1)") == ["(a) 항목", "(b) 항목", "(c) 항목"])
        #expect(numbered("bullet", "\u{F0B7}") == ["• 항목", "• 항목", "• 항목"])
    }

    @Test func multiLevelTemplateAndIndentAndStartOverride() throws {
        let levels = #"<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="400" w:hanging="400"/></w:pPr></w:lvl>"#
            + #"<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2"/><w:pPr><w:ind w:left="900" w:hanging="500"/></w:pPr></w:lvl>"#
        var files = numbering(levels)
        files["word/numbering.xml"] = part("numbering", #"<w:abstractNum w:abstractNumId="0">"# + levels + #"</w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="0"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride></w:num>"#)
        func item(_ num: Int, _ lvl: Int) -> String {
            #"<w:p><w:pPr><w:numPr><w:ilvl w:val="\#(lvl)"/><w:numId w:val="\#(num)"/></w:numPr></w:pPr><w:r><w:t>글</w:t></w:r></w:p>"#
        }
        let back = try readHand(files, document: item(1, 0) + item(1, 1) + item(1, 1) + item(1, 0) + item(1, 1) + item(2, 0))
        #expect(back.paragraphs.map(\.text) == ["1. 글", "1.1 글", "1.2 글", "2. 글", "2.1 글", "5. 글"])
        #expect(back.paragraphs[0].leftIndent == 20 && back.paragraphs[0].firstLineIndent == -20)
        #expect(back.paragraphs[1].leftIndent == 45 && back.paragraphs[1].firstLineIndent == -25)
    }

    @Test func numberedHeadingKeepsNumber() throws {
        let styles = part("styles", #"<w:style w:type="paragraph" w:styleId="H1"><w:name w:val="heading 1"/><w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr></w:style>"#)
        var files = numbering(#"<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="제%1장"/></w:lvl>"#)
        files["word/styles.xml"] = styles
        let back = try readHand(files, document: #"<w:p><w:pPr><w:pStyle w:val="H1"/></w:pPr><w:r><w:t>개요</w:t></w:r></w:p>"#)
        #expect(back.paragraphs[0].headingLevel == 1)
        #expect(back.paragraphs[0].text == "제1장 개요")
    }

    @Test func styleInheritanceAndDocDefaults() throws {
        let styles = part("styles", #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:eastAsia="바탕"/><w:sz w:val="20"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="200" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#
            + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>"#
            + #"<w:style w:type="paragraph" w:styleId="Base"><w:name w:val="Base"/><w:pPr><w:jc w:val="center"/><w:ind w:left="400"/></w:pPr><w:rPr><w:b/><w:color w:val="0000FF"/></w:rPr></w:style>"#
            + #"<w:style w:type="paragraph" w:styleId="Child"><w:name w:val="Child"/><w:basedOn w:val="Base"/><w:pPr><w:spacing w:before="120"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>"#)
        let back = try readHand(["word/styles.xml": styles], document: #"<w:p><w:pPr><w:pStyle w:val="Child"/></w:pPr><w:r><w:t>상속</w:t></w:r></w:p><w:p><w:r><w:t>기본</w:t></w:r></w:p>"#)
        let p = back.paragraphs[0]
        #expect(p.alignment == .center && p.leftIndent == 20 && p.spaceBefore == 6)
        #expect(p.runs[0].bold && p.runs[0].italic && p.runs[0].colorHex == "0000FF")
        #expect(p.spaceAfter == 10 && p.lineSpacing == 1.5)        // 문서 기본값
        #expect(back.paragraphs[1].lineSpacing == 1.5 && back.paragraphs[1].spaceAfter == 10)
    }

    @Test func exactLineSpacingBecomesMultiple() throws {
        let back = try readHand([:], document: #"<w:p><w:pPr><w:spacing w:line="480" w:lineRule="exact"/></w:pPr><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>고정 줄간격</w:t></w:r></w:p>"#)
        // 24pt 고정 / (10pt * 1.2) = 2배
        #expect(back.paragraphs[0].lineSpacing == 2)
    }

    @Test func mergedCellsWidthsHeaderRowsAndBorders() throws {
        let tbl = #"""
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="nil"/><w:left w:val="none"/><w:bottom w:val="nil"/><w:right w:val="nil"/><w:insideH w:val="nil"/><w:insideV w:val="nil"/></w:tblBorders></w:tblPr>
        <w:tblGrid><w:gridCol w:w="1000"/><w:gridCol w:w="3000"/><w:gridCol w:w="1000"/></w:tblGrid>
        <w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>머리</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>끝</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>세로</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc><w:tc><w:p><w:r><w:t>d</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>e</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """#
        let back = try readHand([:], document: tbl)
        let t = back.paragraphs[0]
        #expect(t.table == [["머리", "", "끝"], ["세로", "b", "c"], ["", "d", "e"]])
        let layout = try #require(t.tableLayout)
        #expect(layout.headerRows == 1)
        #expect(layout.borders == false)
        #expect(layout.spans.contains(DocumentCellSpan(row: 0, column: 0, columns: 2, rows: 1)))
        #expect(layout.spans.contains(DocumentCellSpan(row: 1, column: 0, columns: 1, rows: 2)))
        #expect(layout.columnWidths.count == 3 && abs(layout.columnWidths[1] - 0.6) < 0.001)
    }

    @Test func firstRowStyleBoldNeedsTblLookAndLongHeaderListIsIgnored() throws {
        let styles = part("styles", #"<w:style w:type="table" w:styleId="T"><w:name w:val="T"/><w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr><w:tblStylePr w:type="firstRow"><w:rPr><w:b/></w:rPr></w:tblStylePr></w:style>"#)
        func table(look: String) -> String {
            #"<w:tbl><w:tblPr><w:tblStyle w:val="T"/>"# + look + #"</w:tblPr><w:tblGrid><w:gridCol w:w="500"/></w:tblGrid><w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"#
        }
        let on = try readHand(["word/styles.xml": styles], document: table(look: #"<w:tblLook w:firstRow="1"/>"#))
        #expect(on.paragraphs[0].tableLayout?.headerRows == 1 && on.paragraphs[0].tableLayout?.borders == true)
        let off = try readHand(["word/styles.xml": styles], document: table(look: #"<w:tblLook w:firstRow="0"/>"#))
        #expect(off.paragraphs[0].tableLayout?.headerRows == 0)
        let many = (0..<12).map { _ in #"<w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc></w:tr>"# }.joined()
        let long = try readHand([:], document: "<w:tbl><w:tblGrid><w:gridCol w:w=\"500\"/></w:tblGrid>" + many + "</w:tbl>")
        #expect(long.paragraphs[0].tableLayout?.headerRows == 0)
    }

    @Test func footnotesEquationsLinksSymbolsRubyTextBoxes() throws {
        let footnotes = part("footnotes", #"<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> 각주 내용</w:t></w:r></w:p></w:footnote>"#)
        let body = #"""
        <w:p><w:r><w:t>본문</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r></w:p>
        <w:p><m:oMathPara><m:oMath><m:r><m:t>x=1</m:t></m:r></m:oMath></m:oMathPara></w:p>
        <w:p><w:hyperlink r:id="rId7"><w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>사이트</w:t></w:r></w:hyperlink></w:p>
        <w:p><w:r><w:sym w:font="Wingdings" w:char="F0FE"/></w:r><w:r><w:t xml:space="preserve"> 확인 </w:t></w:r><w:r><w:sym w:font="Wingdings" w:char="F0A8"/></w:r></w:p>
        <w:p><w:ruby><w:rt><w:r><w:t>한자</w:t></w:r></w:rt><w:rubyBase><w:r><w:t>漢字</w:t></w:r></w:rubyBase></w:ruby></w:p>
        <w:p><w:r><w:pict><v:shape xmlns:v="urn:schemas-microsoft-com:vml"><v:textbox><w:txbxContent><w:p><w:r><w:t>글상자 글</w:t></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></w:r></w:p>
        <w:tbl><w:tblGrid><w:gridCol w:w="500"/></w:tblGrid><w:tr><w:tc><w:p><w:r><w:t>칸</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """#
        let rels = #"<Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com" TargetMode="External"/>"#
        let back = try readHand(["word/footnotes.xml": footnotes], document: body, extraRels: rels)
        let texts = back.paragraphs.map(\.text)
        #expect(texts[0] == "본문1")
        #expect(back.paragraphs[0].runs.last?.script == 1)
        #expect(texts.contains("(수식) x=1"))
        let link = try #require(back.paragraphs.first { $0.text == "사이트" })
        #expect(link.runs[0].linkURL == "https://example.com" && link.runs[0].underline)
        #expect(texts.contains("☑ 확인 ☐"))
        #expect(texts.contains("漢字"))
        #expect(texts.contains("글상자 글"))
        #expect(texts.last == "각주 1. 각주 내용")
    }

    @Test func textBoxInsideTableCellIsNotLost() throws {
        let cell = #"<w:tbl><w:tblGrid><w:gridCol w:w="500"/></w:tblGrid><w:tr><w:tc><w:p><w:r><w:t>칸</w:t></w:r><w:r><w:pict><w:txbxContent><w:p><w:r><w:t>안쪽 상자</w:t></w:r></w:p></w:txbxContent></w:pict></w:r></w:p></w:tc></w:tr></w:tbl>"#
        let back = try readHand([:], document: cell)
        #expect(back.paragraphs[0].table?[0][0].contains("안쪽 상자") == true)
    }

    @Test func headerFooterAndPageNumberFromHandFile() throws {
        let header = part("hdr", #"<w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>회사 문서</w:t></w:r></w:p>"#)
        let footer = part("ftr", #"<w:p><w:r><w:t xml:space="preserve">- </w:t></w:r><w:fldSimple w:instr=" PAGE "><w:r><w:t>3</w:t></w:r></w:fldSimple><w:r><w:t xml:space="preserve"> -</w:t></w:r></w:p>"#)
        let rels = #"<Relationship Id="rId8" Type="x/header" Target="header1.xml"/><Relationship Id="rId9" Type="x/footer" Target="footer1.xml"/>"#
        let section = #"<w:sectPr><w:headerReference w:type="default" r:id="rId8"/><w:footerReference w:type="default" r:id="rId9"/><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>"#
        let back = try readHand(["word/header1.xml": header, "word/footer1.xml": footer],
                                document: #"<w:p><w:r><w:t>본문</w:t></w:r></w:p>"# + section, extraRels: rels)
        #expect(back.header.map(\.text) == ["회사 문서"] && back.header[0].alignment == .right)
        #expect(back.footer.isEmpty)
        #expect(back.showPageNumber)
    }

    @Test func imageAndMissingPicture() throws {
        // 못 그리는 그림(PNG 아님)은 "[그림]" 글로 남는다
        let drawing = #"<w:p><w:r><w:t>앞</w:t></w:r><w:r><w:drawing><wp:inline xmlns:wp="x" xmlns:a="y"><wp:extent cx="1270000" cy="635000"/><a:graphic><a:graphicData><a:blip r:embed="rId5"/></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#
        let rels = #"<Relationship Id="rId5" Type="x/image" Target="media/image1.emf"/>"#
        let back = try readHand(["word/media/image1.emf": "not an image"], document: drawing, extraRels: rels)
        #expect(back.paragraphs[0].text == "앞[그림]")
    }

    @Test func imageInMiddleOfSentenceKeepsParagraphTogether() throws {
        let png = try Self.tinyPNG()
        let drawing = #"<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>앞 </w:t></w:r><w:r><w:drawing><wp:inline xmlns:wp="x" xmlns:a="y"><wp:extent cx="254000" cy="254000"/><a:graphic><a:graphicData><a:blip r:embed="rId5"/></a:graphicData></a:graphic></wp:inline></w:drawing></w:r><w:r><w:t xml:space="preserve"> 뒤</w:t></w:r></w:p>"#
        let rels = #"<Relationship Id="rId5" Type="x/image" Target="media/image1.png"/>"#
        var zip = ZipWriter()
        zip.add("_rels/.rels", DocxWriter.packageRelationships)
        zip.add("word/document.xml", wrap(drawing))
        zip.add("word/_rels/document.xml.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels + "</Relationships>")
        zip.add("word/media/image1.png", png)
        let url = try Fixtures.makeTempDir().appendingPathComponent("i.docx")
        try zip.finish().write(to: url)
        let back = try #require(DocxReader.read(url))
        #expect(back.paragraphs.count == 2)
        #expect(back.paragraphs[0].text == "앞  뒤" && back.paragraphs[0].alignment == .center)
        #expect(back.paragraphs[1].image != nil && back.paragraphs[1].alignment == .center)
    }

    private static func tinyPNG() throws -> Data {
        // 1x1 투명 PNG
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
    }

    /// 한라봉이 쓴 docx에서 큰 글자 짧은 한 줄은 다시 열어도 제목으로 바뀌지 않는다
    @Test func bigShortLineStaysBodyInOwnDocx() throws {
        let doc = RichDocument(title: "크기", paragraphs: [
            DocumentParagraph(runs: [run("큰 글자 한 줄") { $0.fontSize = 28 }]),
            DocumentParagraph(runs: [run(String(repeating: "본문 글자입니다. ", count: 20))]),
        ])
        let back = try roundTrip(doc)
        #expect(back.paragraphs.first?.headingLevel == nil)
        #expect(back.paragraphs.first?.runs.first?.fontSize == 28)
    }
}
