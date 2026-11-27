import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SkillEngine

/// Word(.docx)·한글(.hwpx)에 표·그림·쪽 나눔·쪽 크기가 진짜 구조로 들어가는지
struct WriterStructureTests {
    private func png(width: Int = 40, height: Int = 20) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func sample(pageSize: CGSize?, imageSize: CGSize = CGSize(width: 200, height: 100)) -> RichDocument {
        RichDocument(title: "구조 확인", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("큰 제목")], headingLevel: 1),
            DocumentParagraph(runs: [DocumentRun("본문 "), DocumentRun("굵게", bold: true), DocumentRun("기울임", italic: true)]),
            DocumentParagraph(runs: [], table: [["이름", "점수", "비고"], ["가나다", "90", "첫째\n둘째 줄"], ["abc", "85"]]),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(), size: imageSize)),
            DocumentParagraph(runs: [DocumentRun("둘째 쪽 글")], pageBreakBefore: true),
            DocumentParagraph(runs: [], table: [["A", "B"], ["1", "2"]], pageBreakBefore: true),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(), size: imageSize), pageBreakBefore: true),
        ], pageSize: pageSize)
    }

    private func unpack(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("a.zip")
        try data.write(to: zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zip.path, "-d", dir.appendingPathComponent("x").path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return dir.appendingPathComponent("x")
    }

    private func text(_ dir: URL, _ path: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    private func assertWellFormed(_ xml: String) {
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "XML 오류: \(parser.parserError?.localizedDescription ?? "") 줄 \(parser.lineNumber)")
    }

    @Test func docxHasTableImagePageBreakAndLandscape() throws {
        let data = try RichDocumentWriter.write(sample(pageSize: CGSize(width: 842, height: 595)), as: .docx)
        let dir = try unpack(data)
        let document = try text(dir, "word/document.xml")
        assertWellFormed(document)
        for part in ["[Content_Types].xml", "word/_rels/document.xml.rels", "word/styles.xml"] { assertWellFormed(try text(dir, part)) }
        #expect(document.contains("<w:tbl>") && document.contains("<w:tblHeader/>") && document.contains(#"w:fill="EDEDED""#))
        #expect(document.components(separatedBy: "<w:tbl>").count == 3)            // 표 두 개
        #expect(document.components(separatedBy: "<w:drawing>").count == 3)        // 그림 두 개
        #expect(document.contains("<w:pageBreakBefore/>"))
        #expect(document.contains(#"w:orient="landscape""#) && document.contains(#"w:w="16840" w:h="11900""#))
        #expect(document.contains(#"<w:pStyle w:val="Heading1"/>"#) && document.contains("<w:b/>") && document.contains("<w:i/>"))
        // 표 칸 너비 합 = 본문 폭, 그림 크기 = 200×100pt
        #expect(document.contains(#"cx="2540000" cy="1270000""#))
        let rels = try text(dir, "word/_rels/document.xml.rels")
        #expect(rels.contains("media/image1.png") && rels.contains("media/image2.png") && rels.contains(#"Id="rId11""#))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("word/media/image2.png").path))
        #expect(try text(dir, "[Content_Types].xml").contains(#"Extension="png""#))
    }

    @Test func docxShrinksOversizedImageAndKeepsPortraitDefault() throws {
        let data = try RichDocumentWriter.write(sample(pageSize: nil, imageSize: CGSize(width: 2000, height: 1000)), as: .docx)
        let document = try text(try unpack(data), "word/document.xml")
        #expect(!document.contains("orient="))
        let widths = document.components(separatedBy: #"<wp:extent cx=""#).dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        let textWidthEMU = DocxWriter.textWidth(for: CGSize(width: 595, height: 842)) * 635
        #expect(widths.count == 2 && widths.allSatisfy { $0 <= textWidthEMU })
        #expect(DocxWriter.margin(for: CGSize(width: 595, height: 842)) == 952)    // 짧은 변의 8%
    }

    @Test func docxTableTextIsReadableByTextutil() throws {
        let data = try RichDocumentWriter.write(sample(pageSize: nil), as: .docx)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.docx")
        try data.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", file.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.contains("가나다") && output.contains("점수") && output.contains("둘째 줄") && output.contains("둘째 쪽 글"))
    }

    @Test func hwpxHasTableImagePageBreakAndPageSize() throws {
        let data = try RichDocumentWriter.write(sample(pageSize: CGSize(width: 842, height: 595)), as: .hwpx)
        let dir = try unpack(data)
        let section = try text(dir, "Contents/section0.xml")
        for part in ["Contents/section0.xml", "Contents/header.xml", "Contents/content.hpf"] { assertWellFormed(try text(dir, part)) }
        #expect(section.contains(#"rowCnt="3" colCnt="3""#) && section.contains("<hp:cellAddr") && section.contains("<hp:cellSpan") && section.contains("<hp:cellSz"))
        #expect(section.components(separatedBy: "<hp:tbl ").count == 3 && section.components(separatedBy: "<hp:pic ").count == 3)
        #expect(section.contains(#"pageBreak="1""#))
        #expect(section.contains(#"landscape="NARROWLY" width="84200" height="59500""#))
        #expect(section.contains(#"<hp:curSz width="20000" height="10000"/>"#))
        let hpf = try text(dir, "Contents/content.hpf")
        #expect(hpf.contains(#"href="BinData/image1.png""#) && hpf.contains(#"href="BinData/image2.png""#))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("BinData/image1.png").path))
        // 표 칸 수 = 줄마다 cellAddr 수, 머리줄 borderFill 3이 header.xml에 있음
        let header = try text(dir, "Contents/header.xml")
        #expect(header.contains(#"<hh:borderFill id="3""#) && header.contains(#"<hh:paraPr id="1""#) && header.contains(#"height="900""#))   // 글자 모양 번호는 쓰는 대로 매긴다
        #expect(section.components(separatedBy: "<hp:tc ").count - 1 == 9 + 4)
    }

    @Test func hwpxDefaultsToA4PortraitAndShrinksImage() throws {
        let data = try RichDocumentWriter.write(sample(pageSize: nil, imageSize: CGSize(width: 2000, height: 1000)), as: .hwpx)
        let section = try text(try unpack(data), "Contents/section0.xml")
        #expect(section.contains(#"landscape="WIDELY" width="59500" height="84200""#))
        #expect(!section.contains(#"<hp:curSz width="200000""#))
    }
}
