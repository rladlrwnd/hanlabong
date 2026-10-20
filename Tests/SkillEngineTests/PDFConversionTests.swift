import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

// MARK: - 문단 다시 짜기 (PDF 없이, 줄만 흉내)

struct ParagraphAssemblyTests {
    /// 쪽 높이 800, 본문 11pt, 줄 간격 14pt인 줄 하나. 행을 하나 건너뛰면 문단 사이 빈 줄이다.
    private func line(_ text: String, page: Int = 0, row: Int, size: CGFloat = 11, x: CGFloat = 72,
                      width: CGFloat = 450, bold: Bool = false) -> PDFLine {
        let top = 80 + CGFloat(row) * 14
        return PDFLine(page: page, runs: [DocumentRun(text, bold: bold)], minX: x, top: top, bottom: top + size,
                       width: width, fontSize: size, pageHeight: 800)
    }

    @Test func wrappedLinesJoinAndBlankRowsSplit() {
        let paragraphs = PDFTextExtractor.assemble([
            line("첫 문단의 첫 줄인데 문장이", row: 0),
            line("다음 줄로 이어집니다.", row: 1, width: 200),
            line("Second paragraph starts after", row: 3),
            line("a blank gap.", row: 4, width: 120),
        ])
        #expect(paragraphs.map(\.text) == ["첫 문단의 첫 줄인데 문장이 다음 줄로 이어집니다.", "Second paragraph starts after a blank gap."])
    }

    @Test func shortLineEndingASentenceEndsTheParagraph() {
        let paragraphs = PDFTextExtractor.assemble([
            line("This line fills the whole width of the column and", row: 0),
            line("ends here.", row: 1, width: 80),
            line("Next paragraph with no extra gap.", row: 2),
        ])
        #expect(paragraphs.count == 2)
    }

    @Test func biggerTextBecomesHeadings() {
        let paragraphs = PDFTextExtractor.assemble([
            line("보고서 제목", row: 0, size: 22),
            line("1장 시작", row: 3, size: 15),
            line("본문 첫 줄입니다.", row: 5),
            line("본문 둘째 줄입니다.", row: 6),
            line("본문 셋째 줄입니다.", row: 7),
        ])
        #expect(paragraphs.map(\.headingLevel) == [1, 2, nil])
    }

    @Test func boldOneLinerBecomesSmallHeadingButBoldWordsStayInline() {
        let paragraphs = PDFTextExtractor.assemble([
            line("요약", row: 0, width: 40, bold: true),
            PDFLine(page: 0, runs: [DocumentRun("이건 "), DocumentRun("중요한", bold: true), DocumentRun(" 문장이다.")],
                    minX: 72, top: 94, bottom: 105, width: 450, fontSize: 11, pageHeight: 800),
            line("그리고 이어지는 줄이다.", row: 2, width: 150),
        ])
        #expect(paragraphs.count == 2)
        #expect(paragraphs.first?.headingLevel == 3)
        #expect(paragraphs.last?.runs.map(\.bold) == [false, true, false])
        #expect(paragraphs.last?.headingLevel == nil)
    }

    @Test func englishHyphenationIsRejoined() {
        let paragraphs = PDFTextExtractor.assemble([
            line("This is an inter-", row: 0),
            line("national standard.", row: 1, width: 100),
        ])
        #expect(paragraphs.map(\.text) == ["This is an international standard."])
    }

    @Test func chineseAndJapaneseJoinWithoutSpaces() {
        let cjk = PDFTextExtractor.assemble([line("这是一个很长的句子在这里", row: 0), line("继续。", row: 1, width: 40)])
        #expect(cjk.map(\.text) == ["这是一个很长的句子在这里继续。"])
    }

    @Test func koreanWordSplitAcrossLinesIsGluedBackByParticleOrEnding() {
        // 맥 기본 조판·한글 "글자 단위" 줄 나눔: 단어 중간에서 줄이 바뀐다
        let paragraphs = PDFTextExtractor.assemble([
            line("이번 촬영은 저조도로 진행했다. 셔터 속도", row: 0),
            line("는 1/5초였고 결과는 인화지별로 테스트했", row: 1),
            line("다.", row: 2, width: 20),
        ])
        #expect(paragraphs.map(\.text) == ["이번 촬영은 저조도로 진행했다. 셔터 속도는 1/5초였고 결과는 인화지별로 테스트했다."])
    }

    @Test func koreanUsesWordsSeenElsewhereInTheDocument() {
        let paragraphs = PDFTextExtractor.assemble([
            line("오늘 카메라를 들고 나가서 카메라를 닦고 다시", row: 0),         // 줄 가운데에 "카메라를"이 나온다
            line("들어와서 사진을 정리했다 그리고 다시 카메", row: 1),
            line("라를 꺼내서 사진을 찍었다 그래서 결국 사진을", row: 2),     // 카메 + 라를 → 카메라를
            line("찍었다 라는 기록을 남긴다.", row: 3, width: 160),           // 사진을 + 찍었다 → 둘 다 따로 나온 낱말이라 띄움
        ])
        let text = paragraphs.map(\.text).joined()
        #expect(text.contains("다시 카메라를 꺼내서"))
        #expect(text.contains("결국 사진을 찍었다"))
    }

    @Test func koreanWordWrappedDocumentsKeepTheirSpaces() {
        // 어절(단어) 단위로 줄을 바꾸는 문서: 줄 끝이 들쭉날쭉하고, 근거가 없으면 띄어 쓴다
        let paragraphs = PDFTextExtractor.assemble([
            line("단어 단위로 줄을 바꾸는 문서는", row: 0, width: 300),
            line("오른쪽 끝이 들쭉날쭉하게 남고", row: 1, width: 330),
            line("낱말이 줄 끝에서 잘리지 않는다", row: 2, width: 280),
            line("마지막 줄이다.", row: 3, width: 120),
        ])
        #expect(paragraphs.map(\.text) == ["단어 단위로 줄을 바꾸는 문서는 오른쪽 끝이 들쭉날쭉하게 남고 낱말이 줄 끝에서 잘리지 않는다 마지막 줄이다."])
    }

    @Test func listItemsStartTheirOwnParagraphs() {
        let paragraphs = PDFTextExtractor.assemble([
            line("준비물은 다음과 같다", row: 0, width: 150),
            line("• 카메라", row: 1, width: 60),
            line("• 삼각대", row: 2, width: 60),
            line("1. 첫째 항목", row: 3, width: 80),
            line("2) 둘째 항목", row: 4, width: 80),
        ])
        #expect(paragraphs.map(\.text) == ["준비물은 다음과 같다", "• 카메라", "• 삼각대", "1. 첫째 항목", "2) 둘째 항목"])
    }

    @Test func pageNumbersAreDroppedAndUnfinishedSentencesContinueOnTheNextPage() {
        let paragraphs = PDFTextExtractor.assemble([
            line("이 문장은 쪽 끝에서 끊겼지만", page: 0, row: 0),
            PDFLine(page: 0, runs: [DocumentRun("- 1 -")], minX: 290, top: 770, bottom: 780, width: 20, fontSize: 9, pageHeight: 800),
            line("다음 쪽에서 이어진다.", page: 1, row: 0, width: 150),
            line("새 문단.", page: 1, row: 2, width: 60),
        ])
        #expect(paragraphs.map(\.text) == ["이 문장은 쪽 끝에서 끊겼지만 다음 쪽에서 이어진다.", "새 문단."])
    }
}

// MARK: - 진짜 PDF로 Word·텍스트 만들기

struct PDFConversionTests {
    private let executor = FileSkillExecutor()

    private struct Block {
        let text: String
        let size: CGFloat
        var bold = false
    }

    /// CoreText로 실제 PDF를 만든다(A4, 좁은 단이라 문단이 여러 줄로 감긴다). 넘치면 다음 쪽으로.
    private func makePDF(_ blocks: [Block], at url: URL, columnWidth: CGFloat = 300) {
        let attributed = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let name = block.bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
            let font = CTFontCreateWithName(name as CFString, block.size, nil)
            var spacing: CGFloat = block.size * 0.9
            let style = withUnsafeBytes(of: &spacing) { pointer in
                var setting = CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: pointer.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }
            attributed.append(NSAttributedString(string: block.text + (index < blocks.count - 1 ? "\n" : ""), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ]))
        }
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &media, [kCGPDFContextTitle as String: "테스트 보고서"] as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var start = 0
        while start < attributed.length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0),
                                                 CGPath(rect: CGRect(x: 72, y: 72, width: columnWidth, height: 360), transform: nil), nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            start += max(visible.length, 1)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private let sample: [Block] = [
        Block(text: "사진 작업 보고서", size: 24, bold: true),
        Block(text: "이번 촬영은 올림픽공원에서 저조도 핸드헬드로 진행했다. 셔터 속도는 1/5초였고 삼각대 없이 촬영했다. 결과물은 인화지별로 테스트했다.", size: 11),
        Block(text: "The second paragraph is written in English so that we can check how wrapped lines are joined back together into one paragraph without breaking words.", size: 11),
        Block(text: "결과 정리", size: 16, bold: true),
        Block(text: "• 바리타지는 계조가 가장 부드러웠다", size: 11),
        Block(text: "• 반광지는 디테일이 선명했다", size: 11),
        Block(text: String(repeating: "다음 쪽까지 이어지는 긴 문단을 만들기 위해 같은 문장을 여러 번 적는다. ", count: 14), size: 11),
    ]

    private func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    @Test func pdfBecomesTextWithTheSameParagraphs() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("보고서.pdf")
        makePDF(sample, at: pdf)
        #expect(PDFDocument(url: pdf)!.pageCount >= 2)                       // 마지막 문단이 다음 쪽으로 넘어간다

        let result = try executor.run(DefaultFileSkills.pdfToPlainText, input: pdf)
        #expect(result.fileExtension == "txt")
        let paragraphs = String(decoding: result.data, as: UTF8.self)
            .components(separatedBy: "\n\n").map(normalize).filter { !$0.isEmpty }
        #expect(paragraphs == sample.map { normalize($0.text) })
    }

    @Test func pdfBecomesAWordFileThatOpensWithHeadingsAndParagraphs() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("보고서.pdf")
        makePDF(sample, at: pdf)
        let output = try FileJob.run(DefaultFileSkills.pdfToWord, input: pdf, executor: executor)
        #expect(output.lastPathComponent == "보고서.docx")

        // 1) zip으로 온전한가
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tq", output.path]
        test.standardOutput = Pipe()
        try test.run(); test.waitUntilExit()
        #expect(test.terminationStatus == 0)

        // 2) macOS가 Word 문서로 읽을 수 있고 문단이 그대로인가 (textutil = 텍스트 편집기와 같은 엔진)
        let textutil = Process()
        textutil.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        textutil.arguments = ["-convert", "txt", "-stdout", output.path]
        let pipe = Pipe()
        textutil.standardOutput = pipe
        textutil.standardError = Pipe()
        try textutil.run()
        let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        textutil.waitUntilExit()
        #expect(textutil.terminationStatus == 0)
        #expect(read.components(separatedBy: "\n").map(normalize).filter { !$0.isEmpty } == sample.map { normalize($0.text) })

        // 3) 제목 스타일·쪽 크기
        let documentXML = DocxWriter.body(try PDFTextExtractor.extract(PDFDocument(url: pdf)!))
        #expect(documentXML.contains(#"<w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">사진 작업 보고서"#))
        #expect(documentXML.contains(#"<w:pStyle w:val="Heading2"/>"#))
        #expect(documentXML.contains(#"<w:pgSz w:w="11900" w:h="16840"/>"#))
    }

    @Test func keepLineBreaksKeepsThePDFLines() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("a.pdf")
        makePDF(sample, at: pdf)
        let skill = FileSkill(id: "t", name: "t", input: [.pdf], steps: [.pdfToText(keepLineBreaks: true)], output: FileOutput(suffix: "_lines"))
        let text = String(decoding: try executor.run(skill, input: pdf).data, as: UTF8.self)
        #expect(text.components(separatedBy: "\n").count > sample.count + 4)    // 감긴 줄마다 줄바꿈이 남는다
    }

    @Test func scannedPDFWithoutTextIsExplained() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("scan.pdf")
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(pdf as CFURL, mediaBox: &media, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.3, alpha: 1)
        context.fill(CGRect(x: 50, y: 50, width: 400, height: 600))   // 글자 없이 그림만
        context.endPDFPage()
        context.closePDF()
        #expect(throws: FileSkillError.noTextInPDF("scan.pdf")) {
            try executor.run(DefaultFileSkills.pdfToWord, input: pdf)
        }
    }

    @Test func passwordProtectedPDFIsExplained() throws {
        let dir = try Fixtures.makeTempDir()
        let plain = dir.appendingPathComponent("plain.pdf")
        makePDF(Array(sample.prefix(2)), at: plain)
        let locked = dir.appendingPathComponent("locked.pdf")
        #expect(PDFDocument(url: plain)!.write(to: locked, withOptions: [.userPasswordOption: "1234", .ownerPasswordOption: "1234"]))
        #expect(throws: FileSkillError.encryptedPDF("locked.pdf")) {
            try executor.run(DefaultFileSkills.pdfToPlainText, input: locked)
        }
    }

    @Test func photoSkillsRefusePDFsAndPDFSkillsRefusePhotos() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("a.pdf")
        makePDF(Array(sample.prefix(2)), at: pdf)
        #expect(throws: FileSkillError.wrongKind(file: "a.pdf")) { try executor.run(DefaultFileSkills.web, input: pdf) }
        let photo = try Fixtures.write(Fixtures.noise(width: 20, height: 20), to: dir.appendingPathComponent("p.png"), type: .png)
        #expect(throws: FileSkillError.wrongKind(file: "p.png")) { try executor.run(DefaultFileSkills.pdfToWord, input: photo) }
    }

    @Test func pdfSkillsCannotMixInPhotoBlocks() {
        let mixed = FileSkill(id: "x", name: "x", input: [.pdf], steps: [.resize(.longEdge(100)), .pdfToDocx], output: FileOutput(suffix: ""))
        #expect(throws: FileSkillError.self) { try mixed.validate() }
        #expect(throws: Never.self) { try DefaultFileSkills.pdfToWord.validate() }
    }

    @Test func pdfBlocksRoundTripThroughJSON() throws {
        for skill in [DefaultFileSkills.pdfToWord, DefaultFileSkills.pdfToPlainText,
                      FileSkill(id: "x", name: "x", input: [.pdf], steps: [.pdfToText(keepLineBreaks: true)], output: FileOutput(suffix: "_l"))] {
            #expect(try JSONDecoder().decode(FileSkill.self, from: JSONEncoder().encode(skill)) == skill)
        }
    }
}
