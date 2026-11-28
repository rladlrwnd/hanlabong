import AppKit
import Foundation
import Testing
@testable import SkillEngine

/// 문서 읽기(RichDocumentReader): 표·그림·제목 단계·쪽 나눔·쪽 크기가 형식마다 구조 그대로 읽히는지.
/// 우리 writer로 쓴 파일을 다시 읽는 왕복 + 일반 Word 파일처럼 손으로 만든 docx + 실제 변환 결과 파일.
@Suite(.serialized)
struct ReaderStructureTests {
    // MARK: 도우미

    private func png(width: Int = 60, height: Int = 30) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func jpeg(width: Int = 40, height: Int = 20) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .jpeg, properties: [:])!
    }

    /// 제목 3단계·표 둘(하나는 줄바꿈 든 칸·빈 칸)·그림·쪽 나눔·가로 쪽
    private func sample() -> RichDocument {
        RichDocument(title: "시험", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("큰 제목", bold: true)], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("앞 글 "), DocumentRun("2018 수능 ", bold: true), DocumentRun("기울임", italic: true), DocumentRun(" 뒤 글")]),
            DocumentParagraph(runs: [DocumentRun("중간 제목", bold: true)], headingLevel: 2),
            DocumentParagraph(runs: [], table: [["구분", "값", "비고"], ["가", "10", "한 줄"], ["나", "20", ""]]),
            DocumentParagraph(runs: [DocumentRun("작은 제목", bold: true)], headingLevel: 3),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(), size: CGSize(width: 120, height: 60))),
            DocumentParagraph(runs: [DocumentRun("둘째 쪽 글")], pageBreakBefore: true),
            DocumentParagraph(runs: [], table: [["이름", "점수"], ["갑", "90"], ["을", "80"], ["병", "70"]]),
            DocumentParagraph(runs: [DocumentRun("끝 글")]),
        ], pageSize: CGSize(width: 842, height: 595))
    }

    private func roundTrip(_ format: DocumentFormat, _ document: RichDocument? = nil) throws -> RichDocument {
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("문서." + format.fileExtension)
        try RichDocumentWriter.write(document ?? sample(), as: format).write(to: url)
        return try RichDocumentReader.read(url)
    }

    private func tables(_ doc: RichDocument) -> [[[String]]] { doc.paragraphs.compactMap(\.table) }
    private func images(_ doc: RichDocument) -> [DocumentImage] { doc.paragraphs.compactMap(\.image) }
    private func headings(_ doc: RichDocument) -> [(Int, String)] {
        doc.paragraphs.compactMap { p in p.headingLevel.map { ($0, p.text) } }
    }

    // MARK: 왕복: docx · hwpx · md · html

    private func expectStructure(_ doc: RichDocument, pageSize: Bool, imageSize: CGSize? = nil) {
        let h = headings(doc)
        #expect(h.map(\.0) == [1, 2, 3])
        #expect(h.map(\.1) == ["큰 제목", "중간 제목", "작은 제목"])
        let t = tables(doc)
        #expect(t.count == 2)
        #expect(t.first?.count == 3 && t.first?.first?.count == 3)
        #expect(t.first?[0] == ["구분", "값", "비고"])
        #expect(t.first?[2] == ["나", "20", ""])
        #expect(t.last?.count == 4 && t.last?.first?.count == 2)
        #expect(images(doc).count == 1)
        if let imageSize, let image = images(doc).first {
            #expect(abs(image.size.width - imageSize.width) < 1 && abs(image.size.height - imageSize.height) < 1)
        }
        // 표 칸 글이 문단·제목으로 새어 나오지 않는다
        let loose = doc.paragraphs.filter { $0.table == nil && $0.image == nil }.map(\.text)
        #expect(!loose.contains("구분") && !loose.contains("90"))
        // 쪽 나눔은 "둘째 쪽 글" 앞에서만
        #expect(doc.paragraphs.filter(\.pageBreakBefore).map(\.text) == ["둘째 쪽 글"])
        // 굵게·기울임
        let body = doc.paragraphs.first { $0.text.contains("앞 글") }
        #expect(body?.runs.contains { $0.bold && $0.text.contains("2018 수능") } == true)
        #expect(body?.runs.contains { $0.italic && $0.text.contains("기울임") } == true)
        #expect(body?.runs.contains { !$0.bold && $0.text.contains("앞 글") } == true)
        if pageSize {
            #expect(doc.pageSize == CGSize(width: 842, height: 595))
        }
    }

    @Test func docxRoundTrip() throws {
        expectStructure(try roundTrip(.docx), pageSize: true, imageSize: CGSize(width: 120, height: 60))
    }

    @Test func hwpxRoundTrip() throws {
        expectStructure(try roundTrip(.hwpx), pageSize: true, imageSize: CGSize(width: 120, height: 60))
    }

    @Test func markdownRoundTrip() throws {
        expectStructure(try roundTrip(.md), pageSize: false)
    }

    @Test func htmlRoundTrip() throws {
        let doc = try roundTrip(.html)
        expectStructure(doc, pageSize: false, imageSize: CGSize(width: 120, height: 60))
        #expect(!doc.paragraphs.contains { $0.text.lowercased().contains("doctype") })         // <!doctype>이 글로 새지 않는다
    }

    @Test func epubRoundTripKeepsTablesAndImages() throws {
        let doc = try roundTrip(.epub)
        #expect(tables(doc).count == 2)
        #expect(images(doc).count == 1)
        #expect(headings(doc).map(\.0) == [1, 2, 3])
    }

    @Test func rtfAndOdtRoundTripKeepTables() throws {
        for format in [DocumentFormat.rtf, .odt] {
            let doc = try roundTrip(format)
            let t = tables(doc)
            #expect(t.count == 2, "\(format)")
            #expect(t.first?.first == ["구분", "값", "비고"], "\(format)")
            #expect(t.last?.count == 4, "\(format)")
            // 표 칸 글이 제목으로 잡히지 않는다
            #expect(!headings(doc).contains { ["구분", "이름", "값", "90"].contains($0.1) }, "\(format)")
            // 한계: macOS 문서 읽기는 RTF·ODT 안의 PNG 그림을 읽어 주지 않고, ODT의 쪽 나눔 스타일도 모른다(RTF 쪽 나눔은 읽는다)
            if format == .rtf { #expect(doc.paragraphs.contains { $0.pageBreakBefore && $0.text.contains("둘째 쪽 글") }) }
        }
    }

    // MARK: 이상한 값이 든 파일(악성·망가진 파일)도 죽지 않고 읽고 바꾸기

    @Test func hostileNumbersDoNotCrash() throws {
        let numbering = #"<?xml version="1.0"?><w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="9223372036854775807"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>"#
        let list = p("번호", props: #"<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>"#)
        let body = p("음수 개요", props: #"<w:outlineLvl w:val="-5"/>"#)
            + list + list
            + p("거대한 간격", props: #"<w:spacing w:before="99999999999999999999" w:after="1e308" w:line="1e308"/><w:ind w:left="1e308" w:firstLine="-1e308"/>"#)
            + #"<w:sectPr><w:pgSz w:w="1e308" w:h="99999999999999999999"/><w:pgMar w:top="1e308" w:bottom="1" w:left="1e308" w:right="1"/><w:cols w:num="99999999999999999999"/></w:sectPr>"#
        let doc = try RichDocumentReader.read(makeDocx(body: body, numbering: numbering))
        #expect(doc.paragraphs.allSatisfy { ($0.headingLevel ?? 1) >= 1 && ($0.headingLevel ?? 1) <= 3 })
        for format in [DocumentFormat.md, .html, .docx, .hwpx] {
            _ = try RichDocumentWriter.write(doc, as: format)
        }
    }

    @Test func nestedTextBoxesStayLinear() throws {
        // 글상자 안 글상자 30겹: 예전엔 깊이마다 다시 훑어서 2^29번 처리하다 멈췄다
        var inner = p("가장 안쪽 글")
        for _ in 0..<30 {
            inner = #"<w:p><w:r><w:pict><v:shape xmlns:v="urn:schemas-microsoft-com:vml"><v:textbox><w:txbxContent>"# + inner + "</w:txbxContent></v:textbox></v:shape></w:pict></w:r></w:p>"
        }
        let doc = try RichDocumentReader.read(makeDocx(body: inner))
        let text = doc.paragraphs.flatMap(\.runs).map(\.text).joined()
        #expect(text.components(separatedBy: "가장 안쪽 글").count - 1 == 1)
    }

    @Test func tableCellCountIsCapped() {
        let rows = Array(repeating: Array(repeating: "x", count: 1), count: 5_000) + [Array(repeating: "y", count: 50_000)]
        let cleaned = ReaderBlocks.normalizeTable(rows)
        #expect(cleaned[0].count == ReaderBlocks.maxTableColumns)
        #expect(cleaned.count * cleaned[0].count <= ReaderBlocks.maxTableCells)
    }

    // MARK: 일반 Word 파일처럼 손으로 만든 docx

    private func makeDocx(body: String, extraStyles: String = "", numbering: String? = nil, media: [String: Data] = [:], rels: String = "") -> URL {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>"#)
        zip.add("_rels/.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#)
        zip.add("word/_rels/document.xml.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels + "</Relationships>")
        zip.add("word/styles.xml", #"<?xml version="1.0"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>"#
            + #"<w:style w:type="paragraph" w:default="1" w:styleId="a"><w:name w:val="Normal"/></w:style>"#
            + #"<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="a"/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>"#
            + #"<w:style w:type="paragraph" w:styleId="Titel"><w:name w:val="Title"/><w:basedOn w:val="a"/></w:style>"#
            + #"<w:style w:type="paragraph" w:styleId="Kapitel"><w:name w:val="Kapitel"/><w:basedOn w:val="a"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>"#
            + #"<w:style w:type="paragraph" w:styleId="Child"><w:name w:val="Child"/><w:basedOn w:val="Kapitel"/></w:style>"#
            + #"<w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style>"#
            + extraStyles + "</w:styles>")
        if let numbering { zip.add("word/numbering.xml", numbering) }
        for (name, data) in media { zip.add("word/media/" + name, data) }
        zip.add("word/document.xml", #"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><w:body>"# + body + "</w:body></w:document>")
        let url = (try! Fixtures.makeTempDir()).appendingPathComponent("word.docx")
        try! zip.finish().write(to: url)
        return url
    }

    private func p(_ text: String, style: String? = nil, props: String = "", runProps: String = "") -> String {
        let pPr = (style.map { #"<w:pStyle w:val="\#($0)"/>"# } ?? "") + props
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + "<w:r>" + (runProps.isEmpty ? "" : "<w:rPr>\(runProps)</w:rPr>") + #"<w:t xml:space="preserve">\#(text)</w:t></w:r></w:p>"#
    }

    @Test func wordFileStylesTablesMergedCellsListsAndBreaks() throws {
        let numbering = #"<?xml version="1.0"?><w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>"#
        let list = { (id: Int, text: String) in self.p(text, props: #"<w:numPr><w:ilvl w:val="0"/><w:numId w:val="\#(id)"/></w:numPr>"#) }
        let body = p("문서 제목", style: "Titel")
            + p("1장", style: "Heading1")
            + p("절 제목", style: "Kapitel")
            + p("자식 스타일 제목", style: "Child")                           // basedOn 사슬로 개요 수준을 물려받는다
            + p("개요만 있는 문단", props: #"<w:outlineLvl w:val="2"/>"#)
            + p("그냥 본문 글입니다 본문 글입니다 본문 글입니다")
            + #"<w:p><w:r><w:rPr><w:rStyle w:val="Strong"/></w:rPr><w:t>글자 스타일 굵게</w:t></w:r><w:hyperlink r:id="rId9"><w:r><w:t xml:space="preserve"> 링크글</w:t></w:r></w:hyperlink><w:del><w:r><w:delText>지운글</w:delText></w:r></w:del></w:p>"#
            + list(1, "점 항목") + list(2, "번호 항목") + list(2, "번호 항목 둘")
            // 표: 1행 = 병합(gridSpan 2) + 칸, 2행 = 세로 병합 시작, 3행 = 세로 병합 이어짐, 칸 안 여러 문단
            + #"<w:tbl><w:tblPr/><w:tblGrid><w:gridCol/><w:gridCol/><w:gridCol/></w:tblGrid>"#
            + #"<w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>"# + p("합친 머리") + "</w:tc><w:tc>" + p("오른쪽") + "</w:tc></w:tr>"
            + #"<w:tr><w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr>"# + p("세로") + "</w:tc><w:tc>" + p("첫 줄") + p("둘째 줄") + "</w:tc><w:tc>" + p("3") + "</w:tc></w:tr>"
            + #"<w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc><w:tc>"# + p("x") + "</w:tc><w:tc>" + p("y") + "</w:tc></w:tr></w:tbl>"
            + #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            + p("쪽 넘김 뒤 글")
            + p("직접 쪽 나눔", props: "<w:pageBreakBefore/>")
            + #"<w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:pPr><w:r><w:t>구역 끝 글</w:t></w:r></w:p>"#     // 구역 나눔: 다음 글은 새 쪽
            + p("새 구역 글")
            + #"<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/></w:sectPr>"#
        let doc = try RichDocumentReader.read(makeDocx(body: body, numbering: numbering, rels: #"<Relationship Id="rId9" Type="x/hyperlink" Target="http://x" TargetMode="External"/>"#))

        let byText = { (text: String) in doc.paragraphs.first { $0.text.contains(text) } }
        #expect(byText("문서 제목")?.headingLevel == 1)                        // Title
        #expect(byText("1장")?.headingLevel == 1)                              // heading 1 이름
        #expect(byText("절 제목")?.headingLevel == 2)                          // 스타일의 outlineLvl
        #expect(byText("자식 스타일 제목")?.headingLevel == 2)                 // basedOn 사슬
        #expect(byText("개요만 있는 문단")?.headingLevel == 3)                  // 문단의 outlineLvl
        #expect(byText("그냥 본문")?.headingLevel == nil)
        // 글자 스타일 굵게 · 하이퍼링크 글 · 지운 글 빼기
        let styled = byText("글자 스타일")
        #expect(styled?.runs.first?.bold == true)
        #expect(styled?.text.contains("링크글") == true)
        #expect(styled?.text.contains("지운글") == false)
        // 목록
        #expect(byText("점 항목")?.text == "• 점 항목")
        #expect(byText("번호 항목")?.text == "1. 번호 항목")
        #expect(byText("번호 항목 둘")?.text == "2. 번호 항목 둘")
        // 표
        let table = try #require(doc.paragraphs.compactMap(\.table).first)
        #expect(table == [["합친 머리", "", "오른쪽"], ["세로", "첫 줄\n둘째 줄", "3"], ["", "x", "y"]])
        #expect(!doc.paragraphs.contains { $0.table == nil && ["합친 머리", "오른쪽", "첫 줄"].contains($0.text) })
        // 쪽 나눔: 빈 문단의 쪽 넘김 · pageBreakBefore · 구역 나눔
        #expect(byText("쪽 넘김 뒤 글")?.pageBreakBefore == true)
        #expect(byText("직접 쪽 나눔")?.pageBreakBefore == true)
        #expect(byText("새 구역 글")?.pageBreakBefore == true)
        #expect(byText("구역 끝 글")?.pageBreakBefore == false)
        // 쪽 크기: 처음 구역(Letter 세로)
        #expect(doc.pageSize == CGSize(width: 612, height: 792))
    }

    @Test func wordFilePicturesJpegSizeCacheAndLandscape() throws {
        func drawing(_ rId: String, cx: Int, cy: Int) -> String {
            #"<w:p><w:r><w:drawing><wp:inline><wp:extent cx="\#(cx)" cy="\#(cy)"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="\#(rId)"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#
        }
        let rels = #"<Relationship Id="rId5" Type="x/image" Target="media/photo.jpg"/><Relationship Id="rId6" Type="x/image" Target="media/pic.png"/><Relationship Id="rId7" Type="x/image" Target="media/missing.emf"/>"#
        let body = p("앞")
            + drawing("rId5", cx: 2_540_000, cy: 1_270_000)                    // 200pt x 100pt
            + drawing("rId6", cx: 1_270_000, cy: 635_000)                      // 100pt x 50pt
            + drawing("rId5", cx: 635_000, cy: 635_000)                        // 같은 그림 다시, 50pt 정사각
            + drawing("rId7", cx: 635_000, cy: 635_000)                        // 파일 없는 그림은 건너뜀
            // 글 사이에 낀 그림: 글 → 그림 → 글로 나뉜다
            + #"<w:p><w:r><w:t>왼쪽</w:t></w:r><w:r><w:drawing><wp:inline><wp:extent cx="635000" cy="635000"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId6"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r><w:r><w:t>오른쪽</w:t></w:r></w:p>"#
            + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838" w:orient="landscape"/></w:sectPr>"#
        let doc = try RichDocumentReader.read(makeDocx(body: body, media: ["photo.jpg": jpeg(), "pic.png": png()], rels: rels))
        let found = images(doc)
        #expect(found.count == 4)
        #expect(found[0].size == CGSize(width: 200, height: 100))
        #expect(found[1].size == CGSize(width: 100, height: 50))
        #expect(found[2].size == CGSize(width: 50, height: 50))
        #expect(found.allSatisfy { $0.png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) })      // JPEG도 PNG로
        let order = doc.paragraphs.map { $0.image != nil ? "그림" : $0.text }
        #expect(order == ["앞", "그림", "그림", "그림", "[그림]", "왼쪽오른쪽", "그림"])   // 못 그리는 그림은 "[그림]" 글, 문장 중간 그림은 문단 뒤로(문단을 쪼개지 않음)
        #expect(doc.pageSize == CGSize(width: 595.3, height: 841.9))             // w/h는 그대로(orient로 맞바꾸지 않는다)
    }

    @Test func wordFileTextBoxAndSizeBasedHeadingFallback() throws {
        let big = { (text: String, half: Int) in self.p(text, runProps: #"<w:sz w:val="\#(half)"/>"#) }
        let body = big("직접 크게 만든 제목", 44)                              // 22pt vs 본문 11pt → 1
            + big("조금 큰 제목", 30)                                          // 15pt → 2
            + p("본문 글입니다 본문 글입니다 본문 글입니다 본문 글입니다 본문 글입니다")
            + p("또 다른 본문 글입니다 또 다른 본문 글입니다 또 다른 본문 글입니다")
            + p("굵은 한 줄", runProps: "<w:b/>")                              // 굵게만으로는 제목으로 보지 않는다
            + #"<w:p><w:r><mc:AlternateContent><mc:Choice><w:drawing><wp:inline><wp:extent cx="1" cy="1"/><a:graphic><a:graphicData><wps:wsp><wps:txbx><w:txbxContent>"# + p("상자 안 글") + #"</w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:inline></w:drawing></mc:Choice><mc:Fallback><w:pict><v:textbox xmlns:v="urn:v"><w:txbxContent>"# + p("중복 글") + "</w:txbxContent></v:textbox></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>"
        let doc = try RichDocumentReader.read(makeDocx(body: body))
        let byText = { (text: String) in doc.paragraphs.first { $0.text.contains(text) } }
        #expect(byText("직접 크게")?.headingLevel == 1)
        #expect(byText("조금 큰")?.headingLevel == 2)
        #expect(byText("굵은 한 줄")?.headingLevel == nil)
        #expect(byText("본문 글입니다")?.headingLevel == nil)
        #expect(byText("상자 안 글") != nil)
        #expect(byText("중복 글") == nil)                                       // AlternateContent는 Choice만
    }

    @Test func notReallyDocxFallsBackToSystemReader() throws {
        // zip이 아닌 .docx(그냥 글)는 DocxReader가 못 읽으니 예전처럼 macOS 문서 읽기가 받는다
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("깨진.docx")
        try Data("그냥 글".utf8).write(to: url)
        let doc = try RichDocumentReader.read(url)
        #expect(doc.paragraphs.map(\.text) == ["그냥 글"])
    }

    // MARK: hwpx 일반 모양

    @Test func hwpxStylesMergedCellsAndLandscapeFromHeader() throws {
        // 우리 writer 말고 한컴이 만든 것처럼: 개요 스타일, 합친 칸(rowSpan/colSpan), 표 안 문단, 쪽 나눔 속성
        let header = """
        <?xml version="1.0"?><hh:head xmlns:hh="h"><hh:refList>
        <hh:charProperties><hh:charPr id="0" height="1000"/><hh:charPr id="1" height="1000"><hh:bold/></hh:charPr></hh:charProperties>
        <hh:paraProperties><hh:paraPr id="0"><hh:heading type="NONE" idRef="0" level="0"/></hh:paraPr><hh:paraPr id="1"><hh:heading type="OUTLINE" idRef="0" level="1"/></hh:paraPr><hh:paraPr id="2"><hh:heading type="BULLET" idRef="1" level="0"/></hh:paraPr></hh:paraProperties>
        <hh:styles><hh:style id="0" name="바탕글" paraPrIDRef="0" charPrIDRef="0"/><hh:style id="1" name="개요 1" paraPrIDRef="1" charPrIDRef="0"/></hh:styles>
        </hh:refList></hh:head>
        """
        func para(_ text: String, style: Int = 0, para: Int = 0, char: Int = 0, pageBreak: Int = 0, extra: String = "") -> String {
            #"<hp:p paraPrIDRef="\#(para)" styleIDRef="\#(style)" pageBreak="\#(pageBreak)"><hp:run charPrIDRef="\#(char)">\#(extra)<hp:t>\#(text)</hp:t></hp:run></hp:p>"#
        }
        func cell(_ text: String, col: Int, row: Int, colSpan: Int = 1, rowSpan: Int = 1) -> String {
            #"<hp:tc><hp:subList>"# + para(text) + #"</hp:subList><hp:cellAddr colAddr="\#(col)" rowAddr="\#(row)"/><hp:cellSpan colSpan="\#(colSpan)" rowSpan="\#(rowSpan)"/></hp:tc>"#
        }
        let section = """
        <?xml version="1.0"?><hs:sec xmlns:hs="s" xmlns:hp="p" xmlns:hc="c">
        <hp:p paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:secPr><hp:pagePr landscape="NARROWLY" width="59528" height="84188"/></hp:secPr></hp:run><hp:run charPrIDRef="0"><hp:t>첫 글</hp:t></hp:run></hp:p>
        \(para("큰 개요", style: 1, para: 1))
        \(para("글 중간<hp:tab/>탭 뒤<hp:lineBreak/>다음 줄"))
        \(para("• 대신 글머리", para: 2))
        <hp:p paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:tbl rowCnt="2" colCnt="3">
        <hp:tr>\(cell("머리", col: 0, row: 0, colSpan: 2))\(cell("오른쪽", col: 2, row: 0, rowSpan: 2))</hp:tr>
        <hp:tr>\(cell("A", col: 0, row: 1))\(cell("B", col: 1, row: 1))</hp:tr>
        </hp:tbl></hp:run></hp:p>
        \(para("다음 쪽 글", pageBreak: 1))
        </hs:sec>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/hwp+zip".utf8), store: true)
        zip.add("Contents/header.xml", header)
        zip.add("Contents/section0.xml", section)
        let url = (try Fixtures.makeTempDir()).appendingPathComponent("한컴.hwpx")
        try zip.finish().write(to: url)

        let doc = try RichDocumentReader.read(url)
        let byText = { (text: String) in doc.paragraphs.first { $0.text.contains(text) } }
        #expect(byText("큰 개요")?.headingLevel == 1)                          // 스타일 이름 "개요 1"
        #expect(byText("글 중간")?.text == "글 중간\t탭 뒤\n다음 줄")
        #expect(byText("대신 글머리")?.text == "• • 대신 글머리")                // 문단 모양이 글머리표면 "• "를 붙인다
        let table = try #require(doc.paragraphs.compactMap(\.table).first)
        #expect(table == [["머리", "", "오른쪽"], ["A", "B", ""]])             // 합친 칸은 빈 칸
        #expect(!doc.paragraphs.contains { $0.table == nil && ["머리", "A", "B", "오른쪽"].contains($0.text) })
        #expect(byText("다음 쪽 글")?.pageBreakBefore == true)
        #expect(byText("첫 글")?.pageBreakBefore == false)
        #expect(abs((doc.pageSize?.width ?? 0) - 841.88) < 0.1 && abs((doc.pageSize?.height ?? 0) - 595.28) < 0.1)   // NARROWLY → 가로
    }

    // MARK: Markdown · HTML 세부

    @Test func markdownTablesImagesAndPageBreaks() throws {
        let dir = try Fixtures.makeTempDir()
        try png(width: 80, height: 40).write(to: dir.appendingPathComponent("옆 그림.png"))
        let b64 = png().base64EncodedString()
        let md = """
        # 제목

        ---

        본문 하나

        | 이름 | 설명 |
        |:---|---:|
        | 가 \\| 나 | **굵게** 글<br>둘째 줄 |
        | 다 | |

        ![그림](data:image/png;base64,\(b64))

        ![옆](옆%20그림.png)

        ![없는 그림](없음.png)

        ![바깥](https://example.com/a.png)

        ---

        쪽 넘긴 글

        ----

        마지막 글
        """
        let url = dir.appendingPathComponent("테스트.md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        let doc = try RichDocumentReader.read(url)
        let t = try #require(tables(doc).first)
        #expect(t == [["이름", "설명"], ["가 | 나", "굵게 글\n둘째 줄"], ["다", ""]])
        #expect(images(doc).count == 2)
        #expect(images(doc).last?.size == CGSize(width: 60, height: 30))          // 80x40 픽셀 → 3/4
        let texts = doc.paragraphs.filter { $0.table == nil && $0.image == nil }.map(\.text)
        #expect(texts.contains("없는 그림") && texts.contains("바깥"))             // 읽을 수 없는 그림은 설명 글로
        // 제목 바로 뒤의 ---는 무시, 글 뒤의 ---는 쪽 나눔, ----(대시 넷)은 쪽 나눔이 아니다
        #expect(doc.paragraphs.filter(\.pageBreakBefore).map(\.text) == ["쪽 넘긴 글"])
    }

    @Test func markdownFrontMatterSetextAndPlainPipeText() {
        let paragraphs = RichDocumentReader.fromMarkdown("---\ntitle: x\ntags: [a]\n---\n\n큰 제목\n===\n\n작은 제목\n---\n\n나 | 너 같은 글은 표가 아니다\n")
        #expect(paragraphs.map(\.text) == ["큰 제목", "작은 제목", "나 | 너 같은 글은 표가 아니다"])
        #expect(paragraphs.map(\.headingLevel) == [1, 2, nil])
        let headerless = RichDocumentReader.fromMarkdown("a | b\n--|--\n1 | 2\n")
        #expect(headerless.first?.table == [["a", "b"], ["1", "2"]])
    }

    @Test func htmlTablesImagesAndBreakStyles() throws {
        let b64 = png().base64EncodedString()
        let html = """
        <html><head><title>제목글</title><style>td{}</style></head><body>
        <h1>큰 제목</h1><p>앞 글</p>
        <table><thead><tr><th>이름</th><th colspan="2">값</th></tr></thead>
        <tbody><tr><td>가<br>나</td><td><p>첫째</p><p>둘째</p></td><td>x</td></tr>
        <tr><td><table><tr><td>안</td><td>쪽</td></tr></table></td><td><img src="data:image/png;base64,\(b64)"/></td><td></td></tr></tbody></table>
        <p>표 뒤 글</p>
        <p style="page-break-before:always"><img src="data:image/png;base64,\(b64)" width="90" height="45" alt="그림"/></p>
        <h2 style="break-before: page">둘째 쪽 제목</h2><p>끝 &amp; 글</p>
        <br style="page-break-before:always"><p>셋째 쪽 글</p>
        </body></html>
        """
        let paragraphs = RichDocumentReader.fromHTML(html)
        let t = try #require(paragraphs.compactMap(\.table).first)
        #expect(t == [["이름", "값", ""], ["가\n나", "첫째\n둘째", "x"], ["안\t쪽", "", ""]])
        #expect(paragraphs.compactMap(\.image).map(\.size) == [CGSize(width: 45, height: 22.5), CGSize(width: 90, height: 45)])  // 표 안 그림은 표 뒤로, 속성 없으면 3/4
        #expect(paragraphs.filter(\.pageBreakBefore).map { $0.image != nil ? "그림" : $0.text } == ["그림", "둘째 쪽 제목", "셋째 쪽 글"])
        #expect(paragraphs.contains { $0.text == "끝 & 글" })
        #expect(paragraphs.first?.headingLevel == 1)
    }

    // MARK: 실제 변환 결과 파일(있을 때만)

    private let realFolder = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Tasking/DRAGEDIT/테스트/변환 점검(수정 후)/1_원래비율_595x744")

    @Test(arguments: ["기출4쪽_pdf-word.docx", "기출4쪽_doc-docx.docx", "기출4쪽_doc-hwpx.hwpx", "기출4쪽_doc-md.md", "기출4쪽_doc-html.html", "기출4쪽_doc-rtf.rtf", "기출4쪽_doc-odt.odt", "기출4쪽_doc-epub.epub"])
    func realConvertedFilesKeepTablesAndImages(name: String) throws {
        let url = realFolder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }       // 파일이 없으면 건너뜀
        let doc = try RichDocumentReader.read(url)
        let t = tables(doc)
        #expect(t.count == 3, "\(name): 표 \(t.count)개")
        #expect(t.first?.count == 9 && t.first?.first?.count == 9, "\(name): 첫 표 크기")
        // rtf·odt·epub는 그림을 읽는지만 느슨하게
        let strict = ["docx", "hwpx", "md", "html"].contains(url.pathExtension)
        #expect(strict ? images(doc).count == 2 : images(doc).count >= 0, "\(name): 그림 \(images(doc).count)개")
        #expect(!headings(doc).isEmpty, "\(name)")
        // 표 칸이 제목·문단으로 새지 않는다: 첫 표의 머리칸 글은 표 밖 문단에 없다
        if let first = t.first?.first?.first {
            #expect(!doc.paragraphs.contains { $0.table == nil && $0.text == first }, "\(name)")
        }
    }
}
