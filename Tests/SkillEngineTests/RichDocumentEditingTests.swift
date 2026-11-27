import AppKit
import Foundation
import Testing
@testable import SkillEngine

/// 편집 화면: RichDocument → NSAttributedString(화면) → 고침 → RichDocument 되돌리기 → 원래 형식으로 저장
@Suite(.serialized)
struct RichDocumentEditingTests {
    // MARK: 도구

    private func png(width: Int = 60, height: Int = 30) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private let pageSize = CGSize(width: 595, height: 842)

    private func sample() -> RichDocument {
        RichDocument(title: "시험", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("큰 제목")], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("중간 제목")], headingLevel: 2),
            DocumentParagraph(runs: [DocumentRun("작은 제목")], headingLevel: 3),
            DocumentParagraph(runs: [
                DocumentRun("앞 글 "), DocumentRun("굵게", bold: true), DocumentRun(" 사이 "),
                DocumentRun("기울임", italic: true), DocumentRun(" 뒤 "), DocumentRun("둘 다", bold: true, italic: true), DocumentRun(" 끝"),
            ]),
            DocumentParagraph(runs: [DocumentRun("• 목록 항목")]),
            DocumentParagraph(runs: [], table: [["구분", "값"], ["가", "10"], ["나", "20"]]),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(), size: CGSize(width: 120, height: 60))),
            DocumentParagraph(runs: [DocumentRun("둘째 쪽 글")], pageBreakBefore: true),
            DocumentParagraph(runs: [DocumentRun("둘째 쪽 소제목")], headingLevel: 2),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(width: 3000, height: 1500), size: CGSize(width: 3000, height: 1500))),
            DocumentParagraph(runs: [DocumentRun("셋째 쪽 글")], pageBreakBefore: true),
        ], pageSize: pageSize)
    }

    /// 화면이 보여 주는 글: 쪽 나눔은 화면 쪽이 하듯 `.hanlabongPageBreak` 문단을 끼운다
    private func screen(_ doc: RichDocument) -> NSMutableAttributedString {
        let content = RichDocumentWriter.metrics(doc).content
        let out = NSMutableAttributedString()
        var group: [DocumentParagraph] = []
        func flush() {
            guard !group.isEmpty else { return }
            out.append(RichDocumentWriter.attributedString(paragraphs: group, content: content, target: .pdf).0)
            group = []
        }
        for (index, paragraph) in doc.paragraphs.enumerated() {
            if paragraph.pageBreakBefore, index > 0 {
                flush()
                out.append(NSAttributedString(string: "── 쪽 나눔 ──\n", attributes: [.hanlabongPageBreak: true]))
            }
            var plain = paragraph
            plain.pageBreakBefore = false
            group.append(plain)
        }
        flush()
        return out
    }

    private func back(_ text: NSAttributedString, _ doc: RichDocument) -> RichDocument {
        RichDocumentEditing.document(from: text, title: doc.title, pageSize: doc.pageSize)
    }

    /// writer가 그림을 본문 폭에 맞춰 줄이므로 기대값도 같이 줄인다
    private func expected(_ doc: RichDocument) -> [DocumentParagraph] {
        let content = RichDocumentWriter.metrics(doc).content
        return doc.paragraphs.map { p in
            var q = p
            if var image = q.image { image.size = RichDocumentWriter.fitted(image.size, in: content); q.image = image }
            return q
        }
    }

    private func kinds(_ paragraphs: [DocumentParagraph]) -> [String] {
        paragraphs.map { $0.table != nil ? "표" : $0.image != nil ? "그림" : "글\($0.headingLevel.map { "H\($0)" } ?? "")\($0.pageBreakBefore ? "|쪽" : "")" }
    }

    private func tempURL(_ ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("t.\(ext)")
    }

    private func reread(_ doc: RichDocument, as format: DocumentFormat) throws -> RichDocument {
        let url = tempURL(format.fileExtension)
        try RichDocumentWriter.write(doc, as: format).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try RichDocumentReader.read(url)
    }

    private func replace(_ text: NSMutableAttributedString, _ old: String, _ new: String) {
        let r = (text.string as NSString).range(of: old)
        #expect(r.location != NSNotFound, "\(old) 없음")
        if r.location != NSNotFound { text.replaceCharacters(in: r, with: new) }
    }

    // MARK: 왕복

    @Test func headingFontMatchesWriterSizes() {
        #expect(RichDocumentEditing.headingFont(level: 1, bold: false, italic: false).pointSize == 22)
        #expect(RichDocumentEditing.headingFont(level: 2, bold: false, italic: false).pointSize == 17)
        #expect(RichDocumentEditing.headingFont(level: 3, bold: false, italic: false).pointSize == 13)
        #expect(RichDocumentEditing.headingFont(level: nil, bold: false, italic: false).pointSize == 11)
        #expect(RichDocumentEditing.headingFont(level: 2, bold: false, italic: false).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!RichDocumentEditing.headingFont(level: nil, bold: false, italic: false).fontDescriptor.symbolicTraits.contains(.bold))
        let both = RichDocumentEditing.headingFont(level: nil, bold: true, italic: true).fontDescriptor.symbolicTraits
        #expect(both.contains(.bold) && both.contains(.italic))
    }

    @Test func writerMarksHeadingsOnScreenText() {
        let text = screen(sample())
        let r = (text.string as NSString).range(of: "중간 제목")
        #expect(text.attribute(.hanlabongHeading, at: r.location, effectiveRange: nil) as? Int == 2)
        let body = (text.string as NSString).range(of: "앞 글")
        #expect(text.attribute(.hanlabongHeading, at: body.location, effectiveRange: nil) == nil)
    }

    @Test func roundTripKeepsEverything() throws {
        let doc = sample()
        let result = back(screen(doc), doc)
        #expect(result.title == "시험")
        #expect(result.pageSize == pageSize)
        let want = expected(doc)
        #expect(kinds(result.paragraphs) == kinds(want))
        #expect(result.paragraphs.count == want.count)
        for (got, exp) in zip(result.paragraphs, want) {
            #expect(got.headingLevel == exp.headingLevel)
            #expect(got.pageBreakBefore == exp.pageBreakBefore)
            #expect(got.table == exp.table)
            #expect(got.runs == exp.runs)
            if let gi = got.image, let ei = exp.image {
                #expect(gi.size == ei.size)
                #expect(gi.png == ei.png)       // 원본 PNG 그대로
            } else {
                #expect(got.image == nil && exp.image == nil)
            }
        }
        // 굵게·기울임 조각이 따로 남았는지
        let styled = result.paragraphs[3].runs
        #expect(styled.map(\.bold) == [false, true, false, false, false, true, false])
        #expect(styled.map(\.italic) == [false, false, false, true, false, true, false])
    }

    @Test func roundTripThroughFormatsKeepsTableImageHeading() throws {
        let doc = sample()
        let result = back(screen(doc), doc)
        for format in [DocumentFormat.docx, .hwpx, .md] {
            let again = try reread(result, as: format)
            let name = format.rawValue
            #expect(again.paragraphs.filter { $0.table != nil }.first?.table == [["구분", "값"], ["가", "10"], ["나", "20"]], "\(name) 표")
            #expect(again.paragraphs.filter { $0.image != nil }.count == 2, "\(name) 그림 수")
            let levels = again.paragraphs.compactMap(\.headingLevel)
            #expect(levels == [1, 2, 3, 2], "\(name) 제목 \(levels)")
            #expect(again.paragraphs.contains { $0.text.contains("둘째 쪽 글") }, "\(name) 글")
            #expect(again.paragraphs.filter(\.pageBreakBefore).count == 2, "\(name) 쪽 나눔")
        }
    }

    // MARK: 고친 경우

    @Test func editedTextBoldAndTableCellSurviveFormats() throws {
        let doc = sample()
        let text = screen(doc)
        replace(text, "앞 글 ", "새로 쓴 글 ")                                    // 문단 하나 글 바꾸기
        replace(text, "20", "25")                                              // 표 칸 글 바꾸기
        let word = (text.string as NSString).range(of: "목록 항목")
        text.addAttribute(.font, value: RichDocumentEditing.headingFont(level: nil, bold: true, italic: false), range: word)   // 굵게 추가
        let result = back(text, doc)

        #expect(result.paragraphs[3].runs.first?.text == "새로 쓴 글 ")
        #expect(result.paragraphs[3].runs.first?.bold == false)
        #expect(result.paragraphs[5].table == [["구분", "값"], ["가", "10"], ["나", "25"]])
        #expect(result.paragraphs[4].runs == [DocumentRun("• ", bold: false), DocumentRun("목록 항목", bold: true)])
        #expect(result.paragraphs.compactMap(\.headingLevel) == [1, 2, 3, 2])

        for format in [DocumentFormat.docx, .hwpx, .md] {
            let again = try reread(result, as: format)
            #expect(again.paragraphs.contains { $0.text.contains("새로 쓴 글") }, "\(format.rawValue) 고친 글")
            #expect(again.paragraphs.compactMap(\.table).first == [["구분", "값"], ["가", "10"], ["나", "25"]], "\(format.rawValue) 고친 표")
            #expect(again.paragraphs.compactMap(\.headingLevel) == [1, 2, 3, 2], "\(format.rawValue) 제목")
            #expect(again.paragraphs.filter { $0.image != nil }.count == 2, "\(format.rawValue) 그림")
        }
        // 굵게는 docx에서 글자 모양으로 남는다
        let docx = try reread(result, as: .docx)
        let bolded = docx.paragraphs.first { $0.text.contains("목록 항목") }
        #expect(bolded?.runs.contains { $0.bold && $0.text.contains("목록 항목") } == true)
    }

    @Test func changingHeadingLevelFromScreen() {
        let doc = RichDocument(title: "t", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("본문이던 글")]),
            DocumentParagraph(runs: [DocumentRun("제목이던 글")], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("그대로인 글")]),
        ])
        let text = screen(doc)
        // 본문 → 제목 2 (화면의 제목 바꾸기 단추가 하는 일)
        let a = (text.string as NSString).range(of: "본문이던 글")
        text.addAttributes([.font: RichDocumentEditing.headingFont(level: 2, bold: false, italic: false), .hanlabongHeading: 2], range: a)
        // 제목 → 본문
        let b = (text.string as NSString).range(of: "제목이던 글")
        text.removeAttribute(.hanlabongHeading, range: b)
        text.addAttribute(.font, value: RichDocumentEditing.headingFont(level: nil, bold: false, italic: false), range: b)
        let result = back(text, doc)
        #expect(result.paragraphs.map(\.headingLevel) == [2, nil, nil])
    }

    @Test func headingGuessedFromFontSizeWhenNoMark() {
        let text = NSMutableAttributedString()
        func add(_ s: String, size: CGFloat, bold: Bool = false) {
            text.append(NSAttributedString(string: s + "\n", attributes: [.font: RichDocumentWriter.font(size: size, bold: bold, italic: false)]))
        }
        add("본문 하나는 이렇게 조금 긴 문장으로 쓴다", size: 11)
        add("본문 둘도 이렇게 조금 긴 문장으로 쓴다", size: 11)
        add("크다", size: 22, bold: true)
        add("중간", size: 17, bold: true)
        add("작다", size: 13, bold: true)
        add("살짝 큰 본문", size: 11.5)
        let result = RichDocumentEditing.document(from: text, title: "t", pageSize: nil)
        #expect(result.paragraphs.map(\.headingLevel) == [nil, nil, 1, 2, 3, nil])
        #expect(result.paragraphs[2].runs == [DocumentRun("크다")])      // 제목 안 굵게는 따로 두지 않는다
    }

    // MARK: 사용자가 새로 만든 것

    @Test func userMadeTableMultiParagraphCellsAndEmptyTable() {
        let text = NSMutableAttributedString(string: "앞 글\n")
        func table(_ cells: [[String]]) {
            let t = NSTextTable()
            t.numberOfColumns = cells.first?.count ?? 1
            for (r, row) in cells.enumerated() {
                for (c, value) in row.enumerated() {
                    let block = NSTextTableBlock(table: t, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [block]
                    text.append(NSAttributedString(string: value + "\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 12)]))
                }
            }
        }
        table([["이름", "나이"], ["철수", "7\n8"], ["영희", ""]])        // 둘째 줄 둘째 칸: 문단 두 개
        text.append(NSAttributedString(string: "사이 글\n"))
        table([["", ""], ["", ""]])                                      // 막 만든 빈 표 (바로 앞 표와는 다른 표)
        let result = RichDocumentEditing.document(from: text, title: "t", pageSize: nil)
        #expect(kinds(result.paragraphs) == ["글", "표", "글", "표"])
        #expect(result.paragraphs[1].table == [["이름", "나이"], ["철수", "7\n8"], ["영희", ""]])
        #expect(result.paragraphs[3].table == [["", ""], ["", ""]])
    }

    @Test func adjacentTablesStaySeparate() {
        let text = NSMutableAttributedString()
        for label in ["첫째", "둘째"] {
            let t = NSTextTable(); t.numberOfColumns = 1
            let block = NSTextTableBlock(table: t, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            let style = NSMutableParagraphStyle(); style.textBlocks = [block]
            text.append(NSAttributedString(string: label + "\n", attributes: [.paragraphStyle: style]))
        }
        let result = RichDocumentEditing.document(from: text, title: "t", pageSize: nil)
        #expect(result.paragraphs.map(\.table) == [[["첫째"]], [["둘째"]]])
    }

    @Test func pictureMixedWithTextSplitsAndPageBreaks() {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(data: png(width: 40, height: 20))
        attachment.bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
        let text = NSMutableAttributedString(string: "앞 ")
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " 뒤\n\n   \n첫 쪽 끝\u{0C}다음 쪽 시작\n"))
        text.append(NSAttributedString(string: "\n", attributes: [.hanlabongPageBreak: true]))      // 글자 없이 줄바꿈에만 표시
        text.append(NSAttributedString(string: "마지막\n"))
        let result = RichDocumentEditing.document(from: text, title: "t", pageSize: nil)
        #expect(kinds(result.paragraphs) == ["글", "그림", "글", "글", "글|쪽", "글|쪽"])
        #expect(result.paragraphs[1].image?.size == CGSize(width: 80, height: 40))
        #expect(result.paragraphs.map(\.text) == ["앞 ", "", " 뒤", "첫 쪽 끝", "다음 쪽 시작", "마지막"])
    }

    @Test func leadingPageBreakAndConsecutiveBreaksAreHarmless() {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "── 쪽 나눔 ──\n", attributes: [.hanlabongPageBreak: true]))
        text.append(NSAttributedString(string: "처음\n"))
        text.append(NSAttributedString(string: "── 쪽 나눔 ──\n", attributes: [.hanlabongPageBreak: true]))
        text.append(NSAttributedString(string: "── 쪽 나눔 ──\n", attributes: [.hanlabongPageBreak: true]))
        text.append(NSAttributedString(string: "끝\n"))
        let result = RichDocumentEditing.document(from: text, title: "t", pageSize: nil)
        #expect(result.paragraphs.map(\.pageBreakBefore) == [false, true])
        #expect(result.paragraphs.map(\.text) == ["처음", "끝"])
    }

    @Test func emptyInputGivesEmptyDocument() {
        #expect(RichDocumentEditing.document(from: NSAttributedString(string: ""), title: "t", pageSize: nil).paragraphs.isEmpty)
        #expect(RichDocumentEditing.document(from: NSAttributedString(string: "\n\n  \n"), title: "t", pageSize: nil).paragraphs.isEmpty)
    }
}
