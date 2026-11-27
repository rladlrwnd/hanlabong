import Foundation
import Testing
@testable import SkillEngine

/// 한글(.hwpx 쓰기→읽기 왕복, 옛 .hwp 레코드 읽기)에서 모양이 남는지.
struct HangulFidelityTests {
    // MARK: hwpx 왕복

    private func roundTrip(_ document: RichDocument) throws -> (back: RichDocument, section: String, header: String) {
        let url = try Fixtures.makeTempDir().appendingPathComponent("왕복.hwpx")
        try HwpxWriter.make(document).write(to: url)
        let section = try #require(RichDocumentReader.unzip(["-p", url.path, "Contents/section0.xml"]))
        let header = try #require(RichDocumentReader.unzip(["-p", url.path, "Contents/header.xml"]))
        return (try RichDocumentReader.read(url), section, header)
    }

    private func wellFormed(_ xml: String) -> Bool {
        let parser = XMLParser(data: Data(xml.utf8))
        return parser.parse()
    }

    @Test func paragraphShapeCharShapeTabsAndPageSurvive() throws {
        var styled = DocumentParagraph(runs: [
            DocumentRun("보통 "),
            { var r = DocumentRun("밑줄"); r.underline = true; return r }(),
            { var r = DocumentRun("취소"); r.strike = true; return r }(),
            { var r = DocumentRun("윗"); r.script = 1; return r }(),
            { var r = DocumentRun("아랫"); r.script = -1; return r }(),
            { var r = DocumentRun("빨강큰"); r.colorHex = "FF0000"; r.fontSize = 16; r.bold = true; return r }(),
            { var r = DocumentRun("글꼴"); r.fontName = "맑은 고딕"; return r }(),
        ])
        styled.alignment = .center
        styled.leftIndent = 20
        styled.firstLineIndent = -10
        styled.spaceBefore = 6
        styled.spaceAfter = 12
        styled.lineSpacing = 1.3
        var right = DocumentParagraph(runs: [DocumentRun("오른쪽 글")])
        right.alignment = .right
        let tabbed = DocumentParagraph(runs: [DocumentRun("가\t나\t다")])
        var document = RichDocument(title: "왕복", paragraphs: [styled, right, tabbed], pageSize: CGSize(width: 595.28, height: 841.89))
        document.margins = DocumentMargins(top: 50, left: 60, bottom: 70, right: 80)
        document.header = [{ var h = DocumentParagraph(runs: [DocumentRun("머리글 글")]); h.alignment = .right; return h }()]
        document.footer = [DocumentParagraph(runs: [DocumentRun("꼬리글 글")])]
        document.showPageNumber = true
        document.bodyFontSize = 11
        document.bodyFontName = "바탕"

        let (back, section, header) = try roundTrip(document)
        #expect(wellFormed(section) && wellFormed(header))
        #expect(section.contains("<hp:tab "))
        let first = try #require(back.paragraphs.first { $0.text.contains("밑줄") })
        #expect(first.alignment == .center)
        #expect(abs(first.leftIndent - 20) < 0.01 && abs(first.firstLineIndent + 10) < 0.01)
        #expect(first.spaceBefore == 6 && first.spaceAfter == 12)
        #expect(abs((first.lineSpacing ?? 0) - 1.3) < 0.001)
        func run(_ text: String) -> DocumentRun? { first.runs.first { $0.text.contains(text) } }
        #expect(run("밑줄")?.underline == true && run("보통")?.underline == false)
        #expect(run("취소")?.strike == true)
        #expect(run("윗")?.script == 1 && run("아랫")?.script == -1)
        let red = try #require(run("빨강큰"))
        #expect(red.colorHex == "FF0000" && red.fontSize == 16 && red.bold)
        #expect(run("글꼴")?.fontName == "맑은 고딕")
        #expect(run("보통")?.fontSize == nil && run("보통")?.fontName == nil)        // 본문 크기·글꼴은 기본으로
        #expect(back.paragraphs.first { $0.text.contains("오른쪽") }?.alignment == .right)
        #expect(back.paragraphs.first { $0.text.contains("가\t나\t다") } != nil)
        #expect(back.bodyFontSize == 11 && back.bodyFontName == "바탕")
        let margins = try #require(back.margins)
        #expect(margins.top == 50 && margins.left == 60 && margins.bottom == 70 && margins.right == 80)
        #expect(back.header.map(\.text) == ["머리글 글"] && back.header.first?.alignment == .right)
        #expect(back.footer.map(\.text) == ["꼬리글 글"])
        #expect(back.showPageNumber)
        #expect(abs((back.pageSize?.width ?? 0) - 595.28) < 0.1)
        // 머리글·꼬리글 글은 본문에 섞이지 않는다
        #expect(!back.paragraphs.contains { $0.text.contains("머리글") || $0.text.contains("꼬리글") })
    }

    @Test func pageNumberAloneAndNoHeaderStayEmpty() throws {
        var document = RichDocument(title: "쪽번호", paragraphs: [DocumentParagraph(runs: [DocumentRun("본문")])])
        document.showPageNumber = true
        let (back, section, _) = try roundTrip(document)
        #expect(wellFormed(section) && section.contains("<hp:pageNum "))
        #expect(back.showPageNumber && back.header.isEmpty && back.footer.isEmpty)
        let plain = try roundTrip(RichDocument(title: "없음", paragraphs: [DocumentParagraph(runs: [DocumentRun("본문")])]))
        #expect(!plain.back.showPageNumber)
    }

    @Test func tableWidthsMergedCellsHeaderAndBorders() throws {
        var table = DocumentParagraph(runs: [], table: [["제목", "", "오른쪽"], ["가", "나", ""], ["다", "라", "마"]])
        table.tableLayout = DocumentTableLayout(
            columnWidths: [0.2, 0.3, 0.5],
            spans: [DocumentCellSpan(row: 0, column: 0, columns: 2, rows: 1), DocumentCellSpan(row: 0, column: 2, columns: 1, rows: 2)],
            headerRows: 0, borders: false)
        var bordered = DocumentParagraph(runs: [], table: [["머리", "머리2"], ["a", "b"]])
        bordered.tableLayout = DocumentTableLayout(columnWidths: [], spans: [], headerRows: 1, borders: true)
        let empty = DocumentParagraph(runs: [], table: [["", ""], ["", ""]])
        let document = RichDocument(title: "표", paragraphs: [table, DocumentParagraph(runs: [DocumentRun("사이 글")]), bordered, empty])
        let (back, section, _) = try roundTrip(document)
        #expect(wellFormed(section))
        let tables = back.paragraphs.filter { $0.table != nil }
        #expect(tables.count == 3)                                                       // 글 없는 표도 남는다
        let first = try #require(tables.first)
        #expect(first.table == [["제목", "", "오른쪽"], ["가", "나", ""], ["다", "라", "마"]])
        let layout = try #require(first.tableLayout)
        #expect(layout.borders == false && layout.headerRows == 0)
        #expect(Set(layout.spans.map { "\($0.row),\($0.column),\($0.columns),\($0.rows)" }) == ["0,0,2,1", "0,2,1,2"])
        let sum = layout.columnWidths.reduce(0, +)
        #expect(layout.columnWidths.count == 3)
        #expect(abs(layout.columnWidths[0] / sum - 0.2) < 0.01 && abs(layout.columnWidths[1] / sum - 0.3) < 0.01 && abs(layout.columnWidths[2] / sum - 0.5) < 0.01)
        let second = try #require(tables.dropFirst().first?.tableLayout)
        #expect(second.borders == true && second.headerRows == 1)
        #expect(tables.last?.table == [["", ""], ["", ""]])
    }

    @Test func tableWithoutLayoutKeepsOldHeaderRowLook() throws {
        let plain = DocumentParagraph(runs: [], table: [["이름", "값"], ["a", "1"]])
        let (back, section, _) = try roundTrip(RichDocument(title: "옛표", paragraphs: [plain]))
        #expect(wellFormed(section) && section.contains("header=\"1\""))
        #expect(back.paragraphs.first?.tableLayout?.headerRows == 1)
    }

    // MARK: hwpx 읽기(한컴이 만든 것처럼)

    @Test func hwpxReadsNoBorderTableEquationAndTextBox() throws {
        let header = """
        <?xml version="1.0"?><hh:head xmlns:hh="h" xmlns:hp="p" xmlns:hc="c"><hh:refList>
        <hh:fontfaces><hh:fontface lang="HANGUL"><hh:font id="0" face="함초롬바탕"/><hh:font id="1" face="나눔고딕"/></hh:fontface></hh:fontfaces>
        <hh:borderFills><hh:borderFill id="1"><hh:leftBorder type="NONE"/><hh:rightBorder type="NONE"/><hh:topBorder type="NONE"/><hh:bottomBorder type="NONE"/></hh:borderFill>
        <hh:borderFill id="2"><hh:leftBorder type="SOLID"/><hh:rightBorder type="SOLID"/><hh:topBorder type="SOLID"/><hh:bottomBorder type="SOLID"/></hh:borderFill></hh:borderFills>
        <hh:charProperties><hh:charPr id="0" height="1000" textColor="#000000"><hh:fontRef hangul="0" latin="0"/></hh:charPr>
        <hh:charPr id="1" height="1400" textColor="#0000FF"><hh:fontRef hangul="1" latin="1"/><hh:underline type="BOTTOM" shape="SOLID"/></hh:charPr></hh:charProperties>
        <hh:paraProperties><hh:paraPr id="0"><hh:align horizontal="CENTER"/><hh:switch><hh:case><hh:margin><hc:intent value="0"/><hc:left value="1500"/><hc:prev value="100"/><hc:next value="200"/></hh:margin><hh:lineSpacing type="FIXED" value="1800"/></hh:case><hh:default><hh:margin><hc:left value="3000"/></hh:margin></hh:default></hh:switch></hh:paraPr></hh:paraProperties>
        </hh:refList></hh:head>
        """
        func cell(_ text: String, col: Int, row: Int, border: Int, header: Int = 0) -> String {
            #"<hp:tc header="\#(header)" borderFillIDRef="\#(border)"><hp:subList><hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>\#(text)</hp:t></hp:run></hp:p></hp:subList><hp:cellAddr colAddr="\#(col)" rowAddr="\#(row)"/><hp:cellSpan colSpan="1" rowSpan="1"/><hp:cellSz width="\#(col == 0 ? 3000 : 9000)" height="100"/></hp:tc>"#
        }
        let section = """
        <?xml version="1.0"?><hs:sec xmlns:hs="s" xmlns:hp="p" xmlns:hc="c">
        <hp:p paraPrIDRef="0"><hp:run charPrIDRef="1"><hp:t>파란 글</hp:t></hp:run><hp:run charPrIDRef="0"><hp:t>본문으로 쓰이는 긴 글이 여기 있다</hp:t><hp:equation><hp:script>x^2 + y</hp:script></hp:equation><hp:rect><hp:drawText><hp:subList><hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>글상자 안 글</hp:t></hp:run></hp:p></hp:subList></hp:drawText></hp:rect></hp:run></hp:p>
        <hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:tbl rowCnt="1" colCnt="2" borderFillIDRef="1"><hp:tr>\(cell("A", col: 0, row: 0, border: 1))\(cell("B", col: 1, row: 0, border: 1))</hp:tr></hp:tbl></hp:run></hp:p>
        <hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:tbl rowCnt="2" colCnt="2" borderFillIDRef="2"><hp:tr>\(cell("H1", col: 0, row: 0, border: 2, header: 1))\(cell("H2", col: 1, row: 0, border: 2, header: 1))</hp:tr><hp:tr>\(cell("x", col: 0, row: 1, border: 2))\(cell("y", col: 1, row: 1, border: 2))</hp:tr></hp:tbl></hp:run></hp:p>
        </hs:sec>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/hwp+zip".utf8), store: true)
        zip.add("Contents/header.xml", header)
        zip.add("Contents/section0.xml", section)
        let url = (try Fixtures.makeTempDir()).appendingPathComponent("한컴2.hwpx")
        try zip.finish().write(to: url)
        let doc = try RichDocumentReader.read(url)

        let blue = try #require(doc.paragraphs.first { $0.text.contains("파란 글") })
        let blueRun = try #require(blue.runs.first { $0.text.contains("파란") })
        #expect(blueRun.underline && blueRun.colorHex == "0000FF" && blueRun.fontName == "나눔고딕")
        #expect(blue.alignment == .center)
        #expect(blue.leftIndent == 15 && blue.spaceBefore == 1 && blue.spaceAfter == 2)       // case 쪽 값(HWPUNIT ÷ 100)
        #expect(blue.text.contains("x^2 + y"))                                               // 수식 글 그대로
        #expect(doc.paragraphs.contains { $0.text == "글상자 안 글" })                           // 글상자 글
        let tables = doc.paragraphs.filter { $0.table != nil }
        #expect(tables.count == 2)
        #expect(tables[0].tableLayout?.borders == false && tables[0].tableLayout?.headerRows == 0)
        let widths = try #require(tables[0].tableLayout?.columnWidths)
        #expect(widths.count == 2 && abs(widths[1] / widths[0] - 3) < 0.01)                  // 3000 : 9000
        #expect(tables[1].tableLayout?.borders == true && tables[1].tableLayout?.headerRows == 1)
    }

    // MARK: 옛 hwp 레코드

    private func cat(_ parts: Data...) -> Data { parts.reduce(Data()) { $0 + $1 } }
    private func rec(_ tag: UInt32, _ level: UInt32, _ payload: Data) -> Data {
        var head: UInt32 = (UInt32(payload.count) << 20) | (level << 10) | tag
        return Data(bytes: &head, count: 4) + payload
    }
    private func u16(_ v: Int) -> Data { var x = UInt16(v); return Data(bytes: &x, count: 2) }
    private func u32(_ v: Int) -> Data { var x = UInt32(truncatingIfNeeded: v); return Data(bytes: &x, count: 4) }
    private func units(_ u: [UInt16]) -> Data { u.withUnsafeBufferPointer { Data(buffer: $0) } }
    private func id(_ s: String) -> Data {
        var v: UInt32 = 0
        for b in s.utf8 { v = (v << 8) | UInt32(b) }
        return u32(Int(v))
    }
    private func paraHeader(_ chars: Int, shape: Int, shapes: Int) -> Data {
        cat(u32(chars), u32(0), u16(shape), Data([0, 0]), u16(shapes), u16(0), u16(0), u32(0))
    }
    /// 문단: PARA_HEADER + 글 + 글자 모양 구간
    private func para(_ level: UInt32, _ text: [UInt16], shape: Int = 0) -> Data {
        var out = rec(66, level, paraHeader(text.count, shape: shape, shapes: 1))
        if !text.isEmpty { out += rec(67, level + 1, units(text)) }
        out += rec(68, level + 1, cat(u32(0), u32(0)))
        return out
    }

    @Test func oldHwpTreeGivesTableTabHeaderFooterAndPage() throws {
        func charShape(height: Int, prop: Int, color: Int) -> Data {
            cat(Data(count: 42), u32(height), u32(prop), Data(count: 2), u32(color), Data(count: 18))
        }
        func paraShape(prop: Int, left: Int) -> Data {
            cat(u32(prop), u32(left), u32(0), u32(0), u32(0), u32(0), u32(160), Data(count: 26))
        }
        let lines = cat(Data(count: 2), Data(count: 30))
        let side = Data([1, 1, 0, 0, 0, 0])
        let solid = cat(Data(count: 2), side, side, side, side, Data(count: 14))
        let docInfo = cat(
            rec(21, 1, charShape(height: 1000, prop: 0, color: 0)),
            rec(21, 1, charShape(height: 1400, prop: 0b110, color: 0x0000FF)),
            rec(25, 1, paraShape(prop: 3 << 2, left: 4000)),
            rec(20, 1, lines), rec(20, 1, solid))

        func cell(col: Int, row: Int, colSpan: Int, rowSpan: Int, width: Int, text: String) -> Data {
            let payload = cat(u16(1), u16(0), u16(0), u16(0), u16(col), u16(row), u16(colSpan), u16(rowSpan),
                              u32(width), u32(1000), Data(count: 8), u16(2), Data(count: 13))
            return rec(72, 2, payload) + para(2, Array(text.utf16) + [13])
        }
        let ext: [UInt16] = [11, 0x6C20, 0x7462, 0, 0, 0, 0, 11]
        let tab: [UInt16] = [9, 0, 0, 0, 0, 0, 0, 9]
        let secd: [UInt16] = [2, 0x6364, 0x7365, 0, 0, 0, 0, 2]
        let head: [UInt16] = [16, 0x6461, 0x6568, 0, 0, 0, 0, 16]
        let mainText: [UInt16] = secd + head + Array("본문".utf16) + tab + Array("뒤".utf16) + [13]
        let pageDef = cat(u32(59528), u32(84189), u32(6000), u32(8000), u32(5000), u32(7000), u32(0), u32(0), u32(0), u32(0))
        let main = cat(
            rec(66, 0, paraHeader(mainText.count, shape: 0, shapes: 2)),
            rec(67, 1, units(mainText)),
            rec(68, 1, cat(u32(0), u32(0), u32(18), u32(1))),
            rec(71, 1, cat(id("secd"), Data(count: 40))), rec(73, 2, pageDef),
            rec(71, 1, cat(id("head"), u32(0))), rec(72, 2, Data(count: 6)), para(2, Array("머리말".utf16) + [13]))
        let tableText = ext + [13]
        let tableInfo = cat(u32(0), u16(2), u16(2), Data(count: 18), u16(1))
        let tableParagraph = cat(
            rec(66, 0, paraHeader(tableText.count, shape: 0, shapes: 1)),
            rec(67, 1, units(tableText)), rec(68, 1, cat(u32(0), u32(0))),
            rec(71, 1, cat(id("tbl "), Data(count: 42))), rec(77, 2, tableInfo),
            cell(col: 0, row: 0, colSpan: 2, rowSpan: 1, width: 12000, text: "제목칸"),
            cell(col: 0, row: 1, colSpan: 1, rowSpan: 1, width: 3000, text: "왼"),
            cell(col: 1, row: 1, colSpan: 1, rowSpan: 1, width: 9000, text: "오른"))
        let body = main + tableParagraph

        let doc = HwpReader.structured(docInfo: docInfo, sections: [body]) { _ in nil }
        let first = try #require(doc.paragraphs.first { $0.text.contains("본문") })
        #expect(first.text == "본문\t뒤")                                              // 탭
        #expect(first.alignment == .center && first.leftIndent == 20)
        #expect(first.runs.contains { $0.text.contains("뒤") && $0.bold && $0.underline && $0.colorHex == "FF0000" && $0.fontSize == 14 })
        #expect(doc.header.map(\.text) == ["머리말"])
        #expect(!doc.paragraphs.contains { $0.text.contains("머리말") })               // 머리글은 본문에서 빠진다
        let size = try #require(doc.pageSize)
        #expect(abs(size.width - 595.28) < 0.01 && abs(size.height - 841.89) < 0.01)
        let margins = try #require(doc.margins)
        #expect(margins.left == 60 && margins.right == 80 && margins.top == 50 && margins.bottom == 70)
        let table = try #require(doc.paragraphs.first { $0.table != nil })
        #expect(table.table == [["제목칸", ""], ["왼", "오른"]])
        let layout = try #require(table.tableLayout)
        #expect(layout.spans == [DocumentCellSpan(row: 0, column: 0, columns: 2, rows: 1)])
        #expect(layout.columnWidths.count == 2 && abs(layout.columnWidths[1] / layout.columnWidths[0] - 3) < 0.01)
        #expect(layout.borders == true)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Downloads/문서/@@@@@@ 결석신고서(2026).hwp")))
    func realHwpWithTablesReadsStructure() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/문서/@@@@@@ 결석신고서(2026).hwp")
        let doc = try RichDocumentReader.read(url)
        #expect(doc.paragraphs.contains { $0.table != nil })
        #expect(doc.pageSize != nil && doc.margins != nil)
    }
}
