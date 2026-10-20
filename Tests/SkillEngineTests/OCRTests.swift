import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import SkillEngine

/// 글자 인식(OCR): 그림 속 글자는 코드로 그린다(흰 바탕에 검은 글자, 한국어·영어)
/// 하나씩 돌린다: 테스트는 Swift 동시성 공용 스레드에서 바로 Vision을 부르는데, 수십 개를 한꺼번에 돌리면
/// 공용 스레드가 바닥나서 Vision이 멈춘다(앱은 전용 큐에서 돌려서 괜찮다).
@Suite(.serialized)
struct OCRTests {
    private let executor = FileSkillExecutor()
    private static let lines = ["DragEdit OCR Test 2026", "사진 작업 보고서", "인화지별 테스트 결과"]

    /// 문서처럼 보이는 그림
    private func textImage(width: Int = 1600, height: Int = 720) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Fixtures.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, text) in Self.lines.enumerated() {
            let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, 72, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 80, y: CGFloat(height) - 160 - CGFloat(index) * 180)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    /// 90도 반시계로 돌린 픽셀 + EXIF 6(시계로 90도 돌려서 보기) = 똑바로 보이는 세로 사진
    private func rotatedForOrientation6(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        let context = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Fixtures.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.translateBy(x: CGFloat(h), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()!
    }

    private func expectReadsTheLines(_ text: String, _ where_: String = "") {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for word in ["DragEdit", "OCR", "사진", "보고서", "인화지별"] {
            #expect(flat.contains(word), "\(where_) “\(word)”를 못 읽었어요: \(flat.prefix(200))")
        }
    }

    // MARK: 사진 → 텍스트

    @Test func photoToTextReadsKoreanAndEnglish() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(textImage(), to: dir.appendingPathComponent("문서.png"), type: .png)
        let output = try FileJob.run(DefaultFileSkills.imageToText, input: url, executor: executor)
        #expect(output.lastPathComponent == "문서.txt")
        expectReadsTheLines(try String(contentsOf: output, encoding: .utf8))
    }

    @Test func portraitPhotoWithExifRotationIsReadUpright() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(rotatedForOrientation6(textImage()), to: dir.appendingPathComponent("세로.jpg"), type: .jpeg,
                                     properties: [kCGImagePropertyOrientation as String: 6])
        let result = try executor.run(DefaultFileSkills.imageToText, input: url)
        expectReadsTheLines(String(decoding: result.data, as: UTF8.self), "세로 사진:")
    }

    @Test func blankPhotoSaysItFoundNoText() throws {
        let dir = try Fixtures.makeTempDir()
        let blank = Fixtures.rgb(width: 400, height: 300) { _, _ in (255, 255, 255, 255) }
        let url = try Fixtures.write(blank, to: dir.appendingPathComponent("빈.png"), type: .png)
        #expect(throws: FileSkillError.noTextFound("빈.png")) { try executor.run(DefaultFileSkills.imageToText, input: url) }
    }

    // MARK: 사진 → PDF

    /// PDF 쪽을 다시 그림으로 그려서 OCR → 사진이 똑바로 들어갔는지 확인
    private func readPageAsImage(_ page: PDFPage) throws -> String {
        let rendered = try #require(OCRSource.render(page))
        return try TextRecognizer.recognize(rendered.image).lines.map(\.text).joined(separator: " ")
    }

    @Test func searchablePDFLetsYouFindAndCopyTheText() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(textImage(), to: dir.appendingPathComponent("스캔.jpg"), type: .jpeg)
        let output = try FileJob.run(DefaultFileSkills.imageToSearchablePDF, input: url, executor: executor)
        #expect(output.lastPathComponent == "스캔.pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        expectReadsTheLines(page.string ?? "", "보이지 않는 글자 층:")                 // 복사하면 나오는 글자
        #expect(!document.findString("보고서", withOptions: []).isEmpty)             // 검색이 된다
        expectReadsTheLines(try readPageAsImage(page), "PDF 속 그림:")               // 보이는 모양은 원본 사진
    }

    @Test func portraitPhotoBecomesAPortraitPage() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(rotatedForOrientation6(textImage()), to: dir.appendingPathComponent("세로.jpg"), type: .jpeg,
                                     properties: [kCGImagePropertyOrientation as String: 6])
        let data = try executor.run(DefaultFileSkills.imageToSearchablePDF, input: url).data
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        #expect(box.height > box.width)                                             // 세로 쪽
        expectReadsTheLines(try readPageAsImage(page), "세로 PDF 속 그림:")           // 옆으로 눕지 않았다
        expectReadsTheLines(page.string ?? "", "세로 PDF 글자 층:")
    }

    @Test func plainPDFKeepsTheJPEGAsIsAndHasNoText() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.noise(width: 1200, height: 900), to: dir.appendingPathComponent("사진.jpg"), type: .jpeg)
        let jpegSize = try Data(contentsOf: url).count
        let data = try executor.run(DefaultFileSkills.imageToPlainPDF, input: url).data
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        #expect(PDFTextExtractor.letterCount(document.page(at: 0)?.string ?? "") == 0)
        // JPEG를 다시 압축하지 않고 그대로 넣었으면 용량이 거의 같다(압축을 풀어 넣으면 몇 배가 된다)
        #expect(data.count < jpegSize + jpegSize / 5 + 20_000, "PDF \(data.count)바이트 vs JPEG \(jpegSize)바이트")
    }

    // MARK: 스캔 PDF

    /// 그림만 들어 있는(글자 층이 없는) 스캔 PDF. `textPage`면 앞에 진짜 글자 쪽을 하나 넣는다.
    private func scannedPDF(at url: URL, textPage: Bool = false) {
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &media, nil)!
        if textPage {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("HelveticaNeue" as CFString, 14, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "첫 쪽은 진짜 글자로 된 쪽이다.",
                                                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 72, y: 760)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.beginPDFPage(nil)
        context.draw(textImage(), in: CGRect(x: 40, y: 400, width: 515, height: 232))
        context.endPDFPage()
        context.closePDF()
    }

    @Test func scannedPDFBecomesTextThroughOCR() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("스캔.pdf")
        scannedPDF(at: pdf)
        let text = String(decoding: try executor.run(DefaultFileSkills.pdfToPlainText, input: pdf).data, as: UTF8.self)
        expectReadsTheLines(text, "스캔 PDF → 텍스트:")
    }

    @Test func scannedPDFBecomesAWordFileThatOpens() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("스캔.pdf")
        scannedPDF(at: pdf)
        let output = try FileJob.run(DefaultFileSkills.pdfToWord, input: pdf, executor: executor)
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
        expectReadsTheLines(read, "스캔 PDF → Word:")
    }

    @Test func mixedPDFUsesRealTextWhereItExistsAndOCRElsewhere() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("섞임.pdf")
        scannedPDF(at: pdf, textPage: true)
        let text = String(decoding: try executor.run(DefaultFileSkills.pdfToPlainText, input: pdf).data, as: UTF8.self)
        #expect(text.contains("첫 쪽은 진짜 글자로 된 쪽이다."))
        expectReadsTheLines(text, "섞인 PDF 둘째 쪽:")
    }

    @Test func scannedPDFGetsAnInvisibleTextLayerAndKeepsItsLook() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("스캔.pdf")
        scannedPDF(at: pdf, textPage: true)
        let output = try FileJob.run(DefaultFileSkills.pdfAddText, input: pdf, executor: executor)
        #expect(output.lastPathComponent == "스캔_ocr.pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("첫 쪽은 진짜 글자로 된 쪽이다.") == true)   // 글자 쪽은 그대로
        expectReadsTheLines(document.page(at: 1)?.string ?? "", "스캔 쪽 글자 층:")
        #expect(!document.findString("인화지별", withOptions: []).isEmpty)
    }

    @Test func blankScannedPDFIsExplained() throws {
        let dir = try Fixtures.makeTempDir()
        let pdf = dir.appendingPathComponent("빈스캔.pdf")
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(pdf as CFURL, mediaBox: &media, nil)!
        context.beginPDFPage(nil)
        context.draw(Fixtures.rgb(width: 300, height: 400) { _, _ in (240, 240, 240, 255) }, in: CGRect(x: 50, y: 50, width: 495, height: 742))
        context.endPDFPage()
        context.closePDF()
        #expect(throws: FileSkillError.noTextInPDF("빈스캔.pdf")) { try executor.run(DefaultFileSkills.pdfToPlainText, input: pdf) }
    }

    @Test func ocrBlocksRoundTripThroughJSONAndRefusePhotoBlocks() throws {
        for skill in [DefaultFileSkills.imageToText, DefaultFileSkills.imageToSearchablePDF, DefaultFileSkills.imageToPlainPDF, DefaultFileSkills.pdfAddText] {
            try skill.validate()
            #expect(try JSONDecoder().decode(FileSkill.self, from: JSONEncoder().encode(skill)) == skill)
        }
        let mixed = FileSkill(id: "x", name: "x", input: [.image], steps: [.resize(.longEdge(100)), .ocrText], output: FileOutput(suffix: ""))
        #expect(throws: FileSkillError.self) { try mixed.validate() }
    }
}
