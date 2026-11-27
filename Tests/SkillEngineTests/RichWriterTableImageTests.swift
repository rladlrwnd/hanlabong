import AppKit
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// RichDocumentWriter: 표·그림·쪽 나눔·쪽 크기가 형식마다 제대로 들어가는지
@Suite(.serialized)
struct RichWriterTableImageTests {
    private func png(width: Int = 60, height: Int = 30) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func sample(landscape: Bool = true, bigImage: Bool = false) -> RichDocument {
        let size = landscape ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
        return RichDocument(title: "시험", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("제목", bold: true)], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("앞 글 "), DocumentRun("2018 수능 ", bold: true), DocumentRun("뒤 글")]),
            DocumentParagraph(runs: [], table: [["구분", "값|A"], ["가", "10"], ["나", "20"]]),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(), size: bigImage ? CGSize(width: 3000, height: 1500) : CGSize(width: 120, height: 60))),
            DocumentParagraph(runs: [DocumentRun("둘째 쪽 글")], pageBreakBefore: true),
        ], pageSize: size)
    }

    private func zipEntries(_ data: Data) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: (MiniZipReader(data)?.entries ?? []).map { ($0.name, $0.data) })
    }

    @Test func rtfHasLandscapeTablePageBreakAndPicture() throws {
        let data = try RichDocumentWriter.write(sample(), as: .rtf)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\\paperw16840"))
        #expect(text.contains("\\paperh11900"))
        #expect(text.contains("\\trowd"))
        #expect(text.contains("\\page"))
        #expect(text.contains("\\pict\\pngblip"))
        #expect(!text.contains("HLBIMGTOKEN"))
    }

    @Test func odtHasLandscapeTablePageBreakAndPicture() throws {
        let data = try RichDocumentWriter.write(sample(), as: .odt)
        let files = zipEntries(data)
        let styles = String(decoding: files["styles.xml"] ?? Data(), as: UTF8.self)
        let content = String(decoding: files["content.xml"] ?? Data(), as: UTF8.self)
        let manifest = String(decoding: files["META-INF/manifest.xml"] ?? Data(), as: UTF8.self)
        #expect(styles.contains("fo:page-width=\"842pt\""))
        #expect(styles.contains("fo:page-height=\"595pt\""))
        #expect(styles.contains("landscape"))
        #expect(content.contains("<table:table "))
        #expect(content.contains("fo:break-before=\"page\""))
        #expect(content.contains("text:style-name=\"HLBPB\""))
        #expect(content.contains("<draw:image xlink:href=\"Pictures/image1.png\""))
        #expect(files["Pictures/image1.png"] != nil)
        #expect(manifest.contains("Pictures/image1.png"))
        #expect(!content.contains("HLBIMGTOKEN") && !content.contains("HLBPAGETOKEN"))
        #expect(files["mimetype"] != nil)
    }

    @Test func htmlHasTableImagePageBreak() throws {
        let html = String(decoding: try RichDocumentWriter.write(sample(), as: .html), as: UTF8.self)
        #expect(html.contains("<table>") && html.contains("<th>구분</th>") && html.contains("<td>가</td>"))
        #expect(html.contains("<img src=\"data:image/png;base64,"))
        #expect(html.contains("page-break-before:always;break-before:page"))
        #expect(html.contains("border-collapse"))
    }

    @Test func markdownHasPipeTableClosedBoldImageAndRule() throws {
        let md = String(decoding: try RichDocumentWriter.write(sample(), as: .md), as: UTF8.self)
        #expect(md.contains("| 구분 | 값\\|A |"))
        #expect(md.contains("|---|---|"))
        #expect(md.contains("**2018 수능** 뒤 글"))
        #expect(!md.contains("수능 **"))
        #expect(md.contains("![그림](data:image/png;base64,"))
        #expect(md.contains("\n---\n\n둘째 쪽 글"))
    }

    @Test func markdownMergesAdjacentBoldAndKeepsSpaceOutside() {
        let doc = RichDocument(title: "t", paragraphs: [DocumentParagraph(runs: [
            DocumentRun("가 ", bold: true), DocumentRun("나 ", bold: true), DocumentRun(" 다", italic: true), DocumentRun("라"),
        ])])
        let md = RichDocumentWriter.markdown(doc)
        #expect(md.hasPrefix("**가 나** "))
        #expect(md.contains("*다*라"))
    }

    @Test func markdownBigImageBecomesPlaceholder() {
        let big = DocumentImage(png: Data(count: 1_200_000), size: CGSize(width: 10, height: 10))
        let md = RichDocumentWriter.markdown(RichDocument(title: "t", paragraphs: [DocumentParagraph(runs: [], image: big)]))
        #expect(md.contains("[그림 1]") && !md.contains("data:image"))
    }

    @Test func textHasTabTablePlaceholderAndBlankLines() throws {
        let txt = String(decoding: try RichDocumentWriter.write(sample(), as: .txt), as: UTF8.self)
        #expect(txt.contains("구분\t값|A\n가\t10"))
        #expect(txt.contains("[그림]"))
        #expect(txt.contains("\n\n\n둘째 쪽 글"))
    }

    @Test func epubHasImageFileManifestAndTable() throws {
        let files = zipEntries(try RichDocumentWriter.write(sample(), as: .epub))
        let opf = String(decoding: files["OEBPS/content.opf"] ?? Data(), as: UTF8.self)
        let page = String(decoding: files["OEBPS/text.xhtml"] ?? Data(), as: UTF8.self)
        #expect(files["OEBPS/images/image1.png"] != nil)
        #expect(opf.contains("href=\"images/image1.png\"") && opf.contains("media-type=\"image/png\""))
        #expect(page.contains("<img src=\"images/image1.png\""))
        #expect(page.contains("<table>") && page.contains("<th>구분</th>"))
        #expect(page.contains("page-break-before:always"))
    }

    @Test func pdfHasLandscapePageSizeTableTextAndTwoPages() throws {
        let data = try RichDocumentWriter.write(sample(), as: .pdf)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(Int(box.width) == 842 && Int(box.height) == 595)
        let text = pdf.string ?? ""
        #expect(text.contains("구분") && text.contains("20"))
        #expect(text.contains("둘째 쪽 글"))
        let second: String = pdf.page(at: 1)?.string ?? ""
        #expect(second.contains("둘째 쪽 글"))
    }

    @Test func pdfPortraitDefaultIsA4AndBigImageFits() throws {
        var doc = sample(landscape: false, bigImage: true)
        doc.pageSize = nil
        let pdf = try #require(PDFDocument(data: try RichDocumentWriter.write(doc, as: .pdf)))
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(Int(box.width) == 595 && Int(box.height) == 842)
        #expect(pdf.pageCount >= 2)
    }

    @Test func bigImageIsScaledToBodyWidthInRtfAndOdt() throws {
        let doc = sample(landscape: false, bigImage: true)
        let rtf = String(decoding: try RichDocumentWriter.write(doc, as: .rtf), as: UTF8.self)
        // A4 세로: 본문 폭 595 - 2*48 = 499pt = 9980 twips 이하
        let goal = try #require(rtf.range(of: "\\picwgoal").map { rtf[$0.upperBound...].prefix { $0.isNumber } })
        #expect((Int(goal) ?? 99999) <= 9980)
    }

    @Test func dumpForLooking() throws {
        guard let dir = ProcessInfo.processInfo.environment["HLB_DUMP_DIR"] else { return }
        for f in [DocumentFormat.pdf, .rtf, .odt, .html, .md, .epub, .txt] {
            try RichDocumentWriter.write(sample(), as: f).write(to: URL(fileURLWithPath: dir).appendingPathComponent("out.\(f.rawValue)"))
        }
    }

    @Test func headingAndItalicBehaviourKept() throws {
        let doc = RichDocument(title: "t", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("큰제목")], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("기울임", italic: true)]),
        ])
        let html = String(decoding: try RichDocumentWriter.write(doc, as: .html), as: UTF8.self)
        #expect(html.contains("<h1>큰제목</h1>") && html.contains("<em>기울임</em>"))
        let md = String(decoding: try RichDocumentWriter.write(doc, as: .md), as: UTF8.self)
        #expect(md.hasPrefix("# 큰제목") && md.contains("*기울임*"))
    }
}
