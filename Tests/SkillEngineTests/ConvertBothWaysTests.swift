import AppKit
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// 문서끼리 양방향 변환, PDF → 사진·PowerPoint·Excel, 영상 형식들
@Suite(.serialized)
struct DocumentConversionTests {
    private let executor = FileSkillExecutor()
    private let markdown = """
    # 인화 실험 보고서

    이 보고서는 **바리타지**와 *반광지*를 비교한다. 결론은 아래에 있다.

    ## 결과

    - 바리타지는 암부 계조가 부드럽다
    - 광택지는 대비가 높다

    마지막 문단이다.
    """

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = try Fixtures.makeTempDir().appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func convert(_ url: URL, to format: DocumentFormat) throws -> URL {
        try FileJob.run(DefaultFileSkills.toDocument(format), input: url, executor: executor)
    }

    @Test func markdownGoesToEveryFormatAndBack() throws {
        let md = try write(markdown, "보고서.md")
        for format in DocumentFormat.allCases where format != .md {
            let out = try convert(md, to: format)
            #expect(out.lastPathComponent == "보고서.\(format.fileExtension)", "\(format)")
            // 다시 Markdown으로 돌아오면 제목·굵게·목록이 남아 있다
            let back = try String(contentsOf: try convert(out, to: .md), encoding: .utf8)
            #expect(back.contains("바리타지") && back.contains("마지막 문단"), "\(format) → md")
            if [.docx, .html, .epub, .rtf, .odt].contains(format) {
                #expect(back.contains("# 인화 실험 보고서") || back.contains("## 인화 실험 보고서"), "\(format) 제목")
                #expect(back.contains("**바리타지**"), "\(format) 굵게")
            }
        }
    }

    @Test func wordBecomesASearchablePDF() throws {
        let dir = try Fixtures.makeTempDir()
        let attributed = NSAttributedString(string: "워드 문서 제목\n\n본문에 있는 글자는 PDF에서도 찾을 수 있어야 한다. " + String(repeating: "긴 문단 ", count: 600))
        let docx = dir.appendingPathComponent("문서.docx")
        try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        #expect(FileKindDetector.kind(of: docx) == .document)
        let pdf = try convert(docx, to: .pdf)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount >= 2)                                         // 길면 여러 쪽
        #expect(document.string?.contains("찾을 수 있어야") == true)
    }

    @Test func htmlDropsScriptsAndKeepsStructure() throws {
        let html = try write("<html><head><title>t</title><script>var x=1</script></head><body><h1>제목</h1><p>첫 <b>굵은</b> 문단</p><ul><li>하나</li><li>둘</li></ul></body></html>", "페이지.html")
        let md = try String(contentsOf: try convert(html, to: .md), encoding: .utf8)
        #expect(md.contains("# 제목") && md.contains("**굵은**") && md.contains("- 하나") && !md.contains("var x"))
    }

    @Test func epubIsAValidPackage() throws {
        let epub = try convert(try write(markdown, "책.md"), to: .epub)
        let data = try Data(contentsOf: epub)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")      // mimetype이 맨 앞
        #expect(String(decoding: data[38..<58], as: UTF8.self) == "application/epub+zip")  // 압축 없이
    }

    @Test func pdfBecomesMarkdownToo() throws {
        let pdf = try convert(try write(markdown, "a.md"), to: .pdf)
        let back = try String(contentsOf: try FileJob.run(DefaultFileSkills.toDocument(.md), input: pdf, executor: executor), encoding: .utf8)
        #expect(back.contains("바리타지"))
    }

    private func samplePDF(pages: Int) throws -> URL {
        var lines = "# 표가 있는 문서\n\n"
        for page in 0..<pages { lines += "항목\t수량\t가격\n" + (1...3).map { "필름 \($0 + page)\t\($0)\t\($0 * 12000)" }.joined(separator: "\n") + "\n\n" }
        return try convert(try write(lines, "표.txt"), to: .pdf)
    }

    @Test func pdfPagesBecomeImages() throws {
        let one = try samplePDF(pages: 1)
        let png = try FileJob.run(DefaultFileSkills.pdfToPNG, input: one, executor: executor)
        #expect(png.pathExtension == "png")
        let image = Fixtures.cgImage(of: try Data(contentsOf: png))
        #expect(image.width == Int((595.0 * 300 / 72).rounded()))                // 300DPI
        // 여러 쪽 → 폴더 하나에 쪽마다
        let long = try convert(try write(String(repeating: "아주 긴 글이에요. ", count: 3000), "긴.txt"), to: .pdf)
        let pageCount = try #require(PDFDocument(url: long)).pageCount
        #expect(pageCount > 1)
        let folder = try FileJob.run(DefaultFileSkills.pdfToJPG, input: long, executor: executor)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(folder.lastPathComponent == "긴" && files.count == pageCount && files.first == "긴-001.jpg")
    }

    @Test func pdfBecomesSlidesAndSheets() throws {
        let pdf = try samplePDF(pages: 1)
        let pptx = try FileJob.run(DefaultFileSkills.pdfToPPTX, input: pdf, executor: executor)
        let entries = try #require(RichDocumentReader.unzip(["-Z1", pptx.path]))
        #expect(entries.contains("ppt/slides/slide1.xml") && entries.contains("ppt/media/image1.jpeg") && entries.contains("ppt/theme/theme1.xml"))
        let xlsx = try FileJob.run(DefaultFileSkills.pdfToXLSX, input: pdf, executor: executor)
        let sheet = try #require(RichDocumentReader.unzip(["-p", xlsx.path, "xl/worksheets/sheet1.xml"]))
        #expect(sheet.contains(">필름 1<") && sheet.contains("<v>12000</v>"))       // 칸이 나뉘고 숫자는 숫자로
    }
}

struct VectorAndHangulTests {
    private let executor = FileSkillExecutor()

    /// 실제 사진으로 확인: VEC_IN=사진 VEC_OUT=폴더 swift test --filter realScan
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEC_IN"] != nil)) func realScan() throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: env["VEC_IN"]!)
        let out = URL(fileURLWithPath: env["VEC_OUT"]!)
        for skill in [DefaultFileSkills.vectorPDF, DefaultFileSkills.vectorSVG] {
            let result = try executor.run(skill, input: input)
            try result.data.write(to: out.appendingPathComponent("vector.\(result.fileExtension)"))
        }
    }

    @Test func documentScanKeepsTextAsRealText() throws {
        // 흰 종이에 글자 몇 줄 + 상자 하나를 그린 "스캔"
        let w = 1200, h = 900
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        NSAttributedString(string: "RAW파일을 이미지파일로 변환하는 과정.", attributes: attrs).draw(at: NSPoint(x: 80, y: 760))
        NSAttributedString(string: "JPEG = 8 bit (채널당 256색)", attributes: attrs).draw(at: NSPoint(x: 80, y: 680))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(6); ctx.stroke(CGRect(x: 120, y: 200, width: 400, height: 220))
        let png = try Fixtures.write(ctx.makeImage()!, to: try Fixtures.makeTempDir().appendingPathComponent("스캔.png"), type: .png)
        let pdf = try FileJob.run(DefaultFileSkills.vectorPDF, input: png, executor: executor)
        let text = try #require(PDFDocument(url: pdf)?.string)
        #expect(text.contains("변환하는 과정."))                                      // 마침표까지 진짜 글자로
        #expect(text.contains("256"))
        let svg = try String(contentsOf: try FileJob.run(DefaultFileSkills.vectorSVG, input: png, executor: executor), encoding: .utf8)
        #expect(svg.contains("<text") && svg.contains("Z"))                          // 글자는 text, 상자는 path
    }

    /// 흰 바탕에 검은 고리(가운데가 뚫린 원)와 네모
    private func drawing() throws -> URL {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addEllipse(in: CGRect(x: 30, y: 50, width: 200, height: 200)); ctx.addEllipse(in: CGRect(x: 90, y: 110, width: 80, height: 80))
        ctx.fillPath(using: .evenOdd)
        ctx.fill(CGRect(x: 280, y: 100, width: 80, height: 80))
        return try Fixtures.write(ctx.makeImage()!, to: try Fixtures.makeTempDir().appendingPathComponent("로고.png"), type: .png)
    }

    @Test func scansBecomeVectorShapesWithHoles() throws {
        let png = try drawing()
        let svgURL = try FileJob.run(DefaultFileSkills.vectorSVG, input: png, executor: executor)
        let svg = try String(contentsOf: svgURL, encoding: .utf8)
        #expect(svgURL.lastPathComponent == "로고_vector.svg")
        #expect(svg.contains("viewBox=\"0 0 400 300\"") && svg.contains("fill-rule=\"evenodd\""))
        #expect(svg.components(separatedBy: "Z").count - 1 >= 3)                    // 고리 바깥·안쪽 + 네모
        let pdf = try FileJob.run(DefaultFileSkills.vectorPDF, input: png, executor: executor)
        let page = try #require(PDFDocument(url: pdf)?.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        #expect(abs(size.width - 595) < 1 && abs(size.width / size.height - 4.0 / 3) < 0.01)       // A4 폭, 비율 그대로
        // 하얀 그림은 거절
        let blank = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        blank.setFillColor(CGColor(gray: 1, alpha: 1)); blank.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        let white = try Fixtures.write(blank.makeImage()!, to: try Fixtures.makeTempDir().appendingPathComponent("w.png"), type: .png)
        #expect(throws: FileSkillError.self) { try executor.run(DefaultFileSkills.vectorSVG, input: white) }
    }

    @Test func documentsBecomeHangulAndComeBack() throws {
        let md = try Fixtures.makeTempDir().appendingPathComponent("보고서.md")
        try "# 제목이다\n\n본문에 **굵은 글자**와 & 기호가 있다.\n\n둘째 문단".write(to: md, atomically: true, encoding: .utf8)
        let hwpx = try FileJob.run(DefaultFileSkills.toDocument(.hwpx), input: md, executor: executor)
        let data = try Data(contentsOf: hwpx)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: data[38..<57], as: UTF8.self) == "application/hwp+zip")
        let section = try #require(RichDocumentReader.unzip(["-p", hwpx.path, "Contents/section0.xml"]))
        #expect(section.contains("<hp:t>제목이다</hp:t>") && section.contains("&amp; 기호") && section.contains("charPrIDRef=\"1\""))
        #expect(FileKindDetector.kind(of: hwpx) == .document)
        let back = try String(contentsOf: try FileJob.run(DefaultFileSkills.toDocument(.txt), input: hwpx, executor: executor), encoding: .utf8)
        #expect(back.contains("제목이다") && back.contains("둘째 문단"))
    }
}

@Suite(.serialized, .enabled(if: FFmpeg.executable != nil))
struct VideoFormatTests {
    private let executor = FileSkillExecutor()

    private func clip(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("클립.mp4")
        let p = Process()
        p.executableURL = FFmpeg.executable
        p.arguments = ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=15:duration=2",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return url
    }

    @Test func everyContainerComesOutPlayable() throws {
        let source = try clip(try Fixtures.makeTempDir())
        for skill in DefaultFileSkills.videoFormats + [DefaultFileSkills.videoToMP3] {
            let out = try FileJob.run(skill, input: source, executor: executor)
            guard case .video(let spec)? = skill.steps.last, let format = spec.format else { continue }
            #expect(out.pathExtension == format.fileExtension)
            let info = try FFmpeg.probe(out)
            #expect(abs(info.duration - 2) < 0.6, "\(format) \(info.duration)")
            if format == .mp3 { #expect(info.hasAudio && !info.hasVideo) }
            else if format == .gif { #expect(info.hasVideo && !info.hasAudio) }
            else { #expect(info.hasVideo && info.hasAudio, "\(format)") }
        }
    }

    @Test func gifTurnsBackIntoMP4() throws {
        let dir = try Fixtures.makeTempDir()
        let gif = try FileJob.run(DefaultFileSkills.toVideo(.gif), input: try clip(dir), executor: executor)
        #expect(FileKindDetector.kind(of: gif) == .image)
        let mp4 = try FileJob.run(DefaultFileSkills.gifToMP4, input: gif, executor: executor)
        let info = try FFmpeg.probe(mp4)
        #expect(mp4.pathExtension == "mp4" && info.hasVideo)
    }
}
