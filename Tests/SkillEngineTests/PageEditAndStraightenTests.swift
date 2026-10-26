import AppKit
import CoreImage
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import SkillEngine

/// PDF 쪽 편집(순서·돌리기·끼워 넣기)과 사진 수평 맞추기
struct PageEditAndStraightenTests {
    /// 쪽마다 "PAGE n" 글자가 박힌 PDF
    private func makePDF(pages: Int, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for n in 1...pages {
            context.beginPDFPage(nil)
            let line = NSAttributedString(string: "PAGE \(n)", attributes: [.font: NSFont.systemFont(ofSize: 30)])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            line.draw(at: CGPoint(x: 40, y: 300))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func texts(_ data: Data) -> [String] {
        let document = PDFDocument(data: data)!
        return (0..<document.pageCount).map { document.page(at: $0)!.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    @Test func reordersRotatesAndKeepsText() throws {
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("a.pdf")
        makePDF(pages: 3, at: url)
        let edit = PDFPageEdit(pages: [.init(index: 2), .init(index: 0, rotation: 90)])   // 3쪽, 1쪽(돌림). 2쪽은 뺌
        let skill = FileSkill(id: "pdf-edit", name: "PDF", input: [.pdf], steps: [.pdfPages(edit)], output: FileOutput(suffix: "_edit"))
        let result = try FileSkillExecutor().run(skill, input: url)
        #expect(result.fileExtension == "pdf")
        #expect(texts(result.data) == ["PAGE 3", "PAGE 1"])
        #expect(PDFDocument(data: result.data)!.page(at: 1)!.rotation == 90)
    }

    @Test func insertsAnotherPDFAndAPhoto() throws {
        let dir = try Fixtures.makeTempDir()
        let main = dir.appendingPathComponent("main.pdf"), extra = dir.appendingPathComponent("extra.pdf")
        makePDF(pages: 2, at: main)
        makePDF(pages: 1, at: extra)
        let photo = try Fixtures.write(Fixtures.rgb(width: 60, height: 40) { _, _ in (200, 80, 10, 255) }, to: dir.appendingPathComponent("p.png"), type: .png)
        let edit = PDFPageEdit(pages: [.init(index: 0), .init(file: 1, index: 0), .init(file: 2, index: 0), .init(index: 1)],
                               extraFiles: [extra.path, photo.path])
        let data = try PDFPageEditor.make(PDFDocument(url: main)!, edit: edit)
        #expect(texts(data) == ["PAGE 1", "PAGE 1", "", "PAGE 2"])
        #expect(PDFDocument(data: data)!.pageCount == 4)
    }

    @Test func photosMergeIntoOnePDF() throws {
        let dir = try Fixtures.makeTempDir()
        let first = try Fixtures.write(Fixtures.rgb(width: 80, height: 60) { _, _ in (10, 120, 200, 255) }, to: dir.appendingPathComponent("a.jpg"), type: .jpeg)
        let second = try Fixtures.write(Fixtures.rgb(width: 60, height: 80) { _, _ in (200, 80, 10, 255) }, to: dir.appendingPathComponent("b.png"), type: .png)
        let edit = PDFPageEdit(pages: [.init(index: 0), .init(file: 1, index: 0)], extraFiles: [second.path])
        let skill = FileSkill(id: "pdf-edit", name: "PDF", input: [.pdf, .image], steps: [.pdfPages(edit)], output: FileOutput(suffix: "_merged"))
        let result = try FileSkillExecutor().run(skill, input: first)
        #expect(result.fileExtension == "pdf")
        #expect(PDFDocument(data: result.data)?.pageCount == 2)
    }

    @Test func emptyOrMissingPagesAreRejected() throws {
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("a.pdf")
        makePDF(pages: 1, at: url)
        #expect(throws: (any Error).self) { try PDFPageEditor.make(PDFDocument(url: url)!, edit: PDFPageEdit(pages: [])) }
        #expect(throws: (any Error).self) { try PDFPageEditor.make(PDFDocument(url: url)!, edit: PDFPageEdit(pages: [.init(index: 5)])) }
    }

    @Test func newStepsSurviveJSON() throws {
        let steps: [FileStep] = [.straighten(degrees: -3.5), .pdfPages(PDFPageEdit(pages: [.init(file: 1, index: 2, rotation: 270)], extraFiles: ["/tmp/x.pdf"]))]
        let back = try JSONDecoder().decode([FileStep].self, from: JSONEncoder().encode(steps))
        #expect(back == steps)
    }

    @Test func straightenKeepsAspectAndHidesCorners() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let out = FileSkillExecutor.straightened(image, degrees: 10)
        let ratio = out.extent.width / out.extent.height
        #expect(abs(ratio - 1.5) < 0.01)
        #expect(out.extent.width < 600 && out.extent.origin == .zero)
        // 모서리까지 빨강(빈 투명 모서리가 없어야 한다)
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(pixel[3] == 255 && pixel[0] > 200)
        #expect(FileSkillExecutor.straightened(image, degrees: 0).extent == image.extent)
    }
}

/// 진짜 파일로 눈 확인용(선택형). 결과와 쪽 모음 그림을 DRAGEDIT_EDIT_OUT에 남긴다.
///   DRAGEDIT_EDIT_PDF=a.pdf DRAGEDIT_EDIT_INSERT=b.jpg DRAGEDIT_EDIT_PHOTO=c.jpg DRAGEDIT_EDIT_OUT=/폴더 swift test --filter RealEditSmoke
struct RealEditSmokeTests {
    private static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["DRAGEDIT_EDIT_OUT"] != nil && env["DRAGEDIT_EDIT_PDF"] != nil))
    func pdfPagesOnRealFile() throws {
        let out = URL(fileURLWithPath: Self.env["DRAGEDIT_EDIT_OUT"]!)
        let source = PDFDocument(url: URL(fileURLWithPath: Self.env["DRAGEDIT_EDIT_PDF"]!))!
        var pages = (0..<source.pageCount).reversed().map { PDFPageEdit.Page(index: $0) }
        pages[0].rotation = 90
        var extras: [String] = []
        if let insert = Self.env["DRAGEDIT_EDIT_INSERT"] { extras = [insert]; pages.insert(.init(file: 1, index: 0), at: 1) }
        let data = try PDFPageEditor.make(source, edit: PDFPageEdit(pages: pages, extraFiles: extras))
        try data.write(to: out.appendingPathComponent("pdf_edit.pdf"))
        // 쪽 모음 그림
        let result = PDFDocument(data: data)!
        let thumb = 220, n = result.pageCount
        let sheet = NSImage(size: NSSize(width: thumb * n, height: thumb), flipped: false) { _ in
            NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: thumb * n, height: thumb).fill()
            for i in 0..<n { result.page(at: i)!.thumbnail(of: CGSize(width: thumb - 10, height: thumb - 10), for: .cropBox).draw(in: NSRect(x: i * thumb + 5, y: 5, width: thumb - 10, height: thumb - 10)) }
            return true
        }
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("pdf_edit_pages.png"))
        print("▶︎ \(source.pageCount)쪽 → \(n)쪽, 글자 \(result.string?.count ?? 0)자 (원본 \(source.string?.count ?? 0)자)")
    }

    @Test(.enabled(if: env["DRAGEDIT_EDIT_OUT"] != nil && env["DRAGEDIT_EDIT_PHOTO"] != nil))
    func straightenOnRealPhoto() throws {
        let out = URL(fileURLWithPath: Self.env["DRAGEDIT_EDIT_OUT"]!)
        let skill = FileSkill(id: "image-edit", name: "edit", input: [.image, .raw],
                              steps: [.decode, .straighten(degrees: 8), .resize(.longEdge(1080)), .colorspace(.keep), .metadata(MetadataSpec(mode: .keepAll)), .encode(EncodeSpec(format: .jpg, quality: 0.9))],
                              output: FileOutput(suffix: "_edit"))
        let result = try FileSkillExecutor().run(skill, input: URL(fileURLWithPath: Self.env["DRAGEDIT_EDIT_PHOTO"]!))
        try result.data.write(to: out.appendingPathComponent("photo_edit.jpg"))
        print("▶︎ 사진 \(result.width)×\(result.height)")
    }
}
