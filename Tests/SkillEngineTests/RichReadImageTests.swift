import AppKit
import Foundation
import Testing
@testable import SkillEngine

/// RTF·RTFD·ODT를 읽을 때 그림이 문단으로 살아남는지
@Suite(.serialized)
struct RichReadImageTests {
    private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func sample() -> RichDocument {
        RichDocument(title: "그림", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("앞 글")]),
            DocumentParagraph(runs: [], image: DocumentImage(png: png(), size: CGSize(width: 120, height: 60))),
            DocumentParagraph(runs: [DocumentRun("뒤 글")]),
        ])
    }

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rri-\(UUID().uuidString)-\(name)")
    }

    @Test func rtfdKeepsImage() throws {
        let attr = NSMutableAttributedString(string: "앞 글\n")
        let wrapper = FileWrapper(regularFileWithContents: png())
        wrapper.preferredFilename = "a.png"
        attr.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        attr.append(NSAttributedString(string: "\n뒤 글"))
        let dir = tmp("t.rtfd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fw = try #require(attr.rtfd(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]) == nil ? nil : attr.fileWrapper(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]))
        try fw.write(to: dir, options: .atomic, originalContentsURL: nil)
        let doc = try RichDocumentReader.read(dir)
        #expect(doc.paragraphs.contains { $0.image != nil })
    }

    @Test func rtfWrittenByUsKeepsImage() throws {
        let url = tmp("t.rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        try RichDocumentWriter.write(sample(), as: .rtf).write(to: url)
        let doc = try RichDocumentReader.read(url)
        #expect(doc.paragraphs.contains { $0.image != nil })
    }

    @Test func odtWrittenByUsKeepsImage() throws {
        let url = tmp("t.odt")
        defer { try? FileManager.default.removeItem(at: url) }
        try RichDocumentWriter.write(sample(), as: .odt).write(to: url)
        let doc = try RichDocumentReader.read(url)
        #expect(doc.paragraphs.contains { $0.image != nil })
        #expect(doc.paragraphs.contains { $0.text.contains("뒤 글") })
    }

    /// 다른 프로그램이 만든 것처럼 cm 단위 프레임을 손으로 짠 ODT
    @Test func handmadeOdtWithCmFrameKeepsImage() throws {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.text".utf8), store: true)
        zip.add("META-INF/manifest.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"Pictures/p.png\" manifest:media-type=\"image/png\"/></manifest:manifest>")
        zip.add("content.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" office:version=\"1.2\"><office:body><office:text><text:p>앞 글</text:p><text:p><draw:frame draw:name=\"g\" text:anchor-type=\"as-char\" svg:width=\"5.08cm\" svg:height=\"2.54cm\"><draw:image xlink:href=\"Pictures/p.png\" xlink:type=\"simple\"/></draw:frame></text:p><text:p>뒤 글</text:p></office:text></office:body></office:document-content>")
        zip.add("Pictures/p.png", png(), store: true)
        let url = tmp("h.odt")
        defer { try? FileManager.default.removeItem(at: url) }
        try zip.finish().write(to: url)
        let doc = try RichDocumentReader.read(url)
        let image = try #require(doc.paragraphs.compactMap(\.image).first)
        #expect(abs(image.size.width - 144) < 1 && abs(image.size.height - 72) < 1)
        #expect(doc.paragraphs.contains { $0.text.contains("뒤 글") })
    }
}
