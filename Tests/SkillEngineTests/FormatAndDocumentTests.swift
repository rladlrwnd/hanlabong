import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SkillEngine

/// 사진 형식 바꾸기(PNG·HEIC·AVIF·TIFF·PSD·GIF·BMP·JPG)
struct FormatConversionTests {
    private let executor = FileSkillExecutor()

    @Test func everyFormatWritesAFileThatReadsBackAtTheSameSize() throws {
        let dir = try Fixtures.makeTempDir()
        let source = try Fixtures.write(Fixtures.noise(width: 120, height: 80), to: dir.appendingPathComponent("사진.png"), type: .png)
        for skill in DefaultFileSkills.allFormatConversions {
            try skill.validate()
            let result = try executor.run(skill, input: source)
            guard case .encode(let spec) = skill.steps.last else { Issue.record("encode 없음"); continue }
            #expect(result.fileExtension == spec.format.fileExtension)
            let image = try #require(CGImageSourceCreateWithData(result.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "\(spec.format)")
            #expect(image.width == 120 && image.height == 80, "\(spec.format)")
        }
    }

    @Test func transparencySurvivesWhereTheFormatAllowsIt() throws {
        let dir = try Fixtures.makeTempDir()
        let clear = Fixtures.rgb(width: 10, height: 10, alpha: true) { _, _ in (255, 0, 0, 0) }
        let source = try Fixtures.write(clear, to: dir.appendingPathComponent("투명.png"), type: .png)
        func corner(_ skill: FileSkill) throws -> (r: Int, g: Int, b: Int, a: Int) {
            let data = try executor.run(skill, input: source).data
            return Fixtures.pixel(Fixtures.rgba(Fixtures.cgImage(of: data), in: Fixtures.sRGB), width: 10, x: 0, y: 0)
        }
        #expect(try corner(DefaultFileSkills.toPSD).a < 10)           // PSD는 투명 유지
        #expect(try corner(DefaultFileSkills.toAVIF).a < 10)
        let bmp = try corner(DefaultFileSkills.toBMP)                  // BMP·JPG는 흰 배경
        #expect(bmp.a == 255 && bmp.r > 240 && bmp.g > 240)
    }

    @Test func sameNameGetsANumberInsteadOfOverwriting() throws {
        let dir = try Fixtures.makeTempDir()
        let source = try Fixtures.write(Fixtures.noise(width: 20, height: 20), to: dir.appendingPathComponent("a.png"), type: .png)
        let hash = try Fixtures.sha256(source)
        let output = try FileJob.run(DefaultFileSkills.toPNG, input: source, executor: executor)
        #expect(output.lastPathComponent == "a (1).png")
        #expect(try Fixtures.sha256(source) == hash)
        #expect(try FileJob.run(DefaultFileSkills.toAVIF, input: source, executor: executor).lastPathComponent == "a.avif")
    }
}

/// What is it?이 읽는 여러 문서
struct DocumentReaderTests {
    private let body = "이 문서는 사진 인화지 비교 실험 보고서다. 바리타지는 암부 계조가 부드럽고 광택지는 대비가 높다."

    @Test func readsWordRTFAndHTML() throws {
        let dir = try Fixtures.makeTempDir()
        let attributed = NSAttributedString(string: body)
        let docx = dir.appendingPathComponent("보고서.docx")
        try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        #expect(try WhatIsText.read(docx).text.contains("바리타지"))

        let rtf = dir.appendingPathComponent("메모.rtf")
        try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        #expect(try WhatIsText.read(rtf).text.contains("광택지"))

        let html = dir.appendingPathComponent("페이지.html")
        try """
        <!doctype html><html><head><title>인화 실험</title><style>p{color:red}</style><script>var secret = 1;</script></head>
        <body><h1>결과</h1><p>\(body)</p><p>A &amp; B &lt;3 &#54620;&#xAE00;</p></body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let text = try WhatIsText.read(html).text
        #expect(text.hasPrefix("인화 실험"))
        #expect(text.contains("결과") && text.contains("바리타지") && text.contains("A & B <3 한글"))
        #expect(!text.contains("secret") && !text.contains("color:red") && !text.contains("<p>"))
    }

    @Test func readsPowerPointSlidesInOrderAndExcelCells() throws {
        let dir = try Fixtures.makeTempDir()
        var zip = ZipWriter()
        for n in [2, 10, 1] {   // 순서가 섞여 들어가도 1, 2, 10 순서로
            zip.add("ppt/slides/slide\(n).xml", "<p:sld><a:p><a:r><a:t>슬라이드 \(n) 제목이에요</a:t></a:r></a:p><a:p><a:r><a:t>내용 \(n)</a:t></a:r></a:p></p:sld>")
        }
        zip.add("ppt/presentation.xml", "<p:presentation/>")
        let pptx = dir.appendingPathComponent("발표.pptx")
        try zip.finish().write(to: pptx)
        let slides = try WhatIsText.read(pptx).text
        let first = try #require(slides.range(of: "슬라이드 1 제목")), second = try #require(slides.range(of: "슬라이드 2 제목")), tenth = try #require(slides.range(of: "슬라이드 10 제목"))
        #expect(first.lowerBound < second.lowerBound && second.lowerBound < tenth.lowerBound)
        #expect(slides.contains("[슬라이드 1]") && slides.contains("내용 2"))

        var book = ZipWriter()
        book.add("xl/sharedStrings.xml", "<sst><si><t>매출 합계는 1,200만원이다</t></si><si><t xml:space=\"preserve\">지난달보다 12% 늘었다</t></si></sst>")
        let xlsx = dir.appendingPathComponent("표.xlsx")
        try book.finish().write(to: xlsx)
        let cells = try WhatIsText.read(xlsx).text
        #expect(cells.contains("1,200만원") && cells.contains("12% 늘었다"))
    }

    @Test func plainTextWithAnyExtensionWorksButBinaryIsRefused() throws {
        let dir = try Fixtures.makeTempDir()
        let json = dir.appendingPathComponent("설정.json")
        try "{\"설명\": \"\(body)\"}".write(to: json, atomically: true, encoding: .utf8)
        #expect(try WhatIsText.read(json).text.contains("인화지"))
        let odd = dir.appendingPathComponent("이상한확장자.xyz")
        try body.write(to: odd, atomically: true, encoding: .utf8)
        #expect(try WhatIsText.read(odd).text.contains("인화지"))
        let binary = dir.appendingPathComponent("데이터.bin2")
        try Data((0..<4000).map { UInt8($0 % 256) }).write(to: binary)
        #expect(throws: FileSkillError.notText("데이터.bin2")) { try WhatIsText.read(binary) }
    }
}

struct PhotoToolTests {
    @Test func rotateKeepsFormatAndSize() throws {
        let dir = try Fixtures.makeTempDir()
        let png = try Fixtures.write(Fixtures.noise(width: 40, height: 20), to: dir.appendingPathComponent("a.png"), type: .png)
        let out = try FileJob.run(DefaultFileSkills.rotateRight, input: png)
        #expect(out.lastPathComponent == "a_rotated.png")
        let image = Fixtures.cgImage(of: try Data(contentsOf: out))
        #expect(image.width == 20 && image.height == 40)
        let small = try FileJob.run(DefaultFileSkills.shrink500KB, input: png)
        #expect(small.pathExtension == "jpg")
    }
}

/// 압축 폭탄·아주 큰 문서로 앱이 멈추지 않는다
struct OversizeDocumentTests {
    @Test func zipBombIsRefusedQuickly() throws {
        let dir = try Fixtures.makeTempDir()
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8), store: true)
        zip.add("OEBPS/text.xhtml", Data(count: 100_000_000))          // 1억 바이트의 0 → 압축하면 아주 작다
        let bomb = dir.appendingPathComponent("폭탄.epub")
        try zip.finish().write(to: bomb)
        let size = try FileManager.default.attributesOfItem(atPath: bomb.path)[.size] as! Int
        #expect(size < 1_000_000)
        let started = Date()
        #expect(throws: (any Error).self) { try RichDocumentReader.read(bomb) }
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(BoundedProcess.unzip(["-p", bomb.path, "OEBPS/text.xhtml"]) == nil)      // 64MB 넘게 풀리면 버린다
    }

    @Test func hugeTextFileIsRefusedBeforeReading() throws {
        let dir = try Fixtures.makeTempDir()
        let big = dir.appendingPathComponent("큰.txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(RichDocumentReader.maxTextBytes + 1))      // 내용은 비어 있는 큰 파일
        try handle.close()
        #expect(throws: FileSkillError.tooLarge("큰.txt")) { try RichDocumentReader.read(big) }
    }
}
