import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 파일이 무슨 종류인지 **내용으로** 알아낸다(확장자는 믿지 않는다. 이름만 .jpg인 PDF도 있으니까).
public enum FileKindDetector {
    public static func kind(of url: URL) -> FileKind? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            // 사진·PDF가 아니면 글 파일인지(.txt·.md 등, 이름은 힌트일 뿐이고 내용이 글자로 읽혀야 한다)
            if isVideo(url) { return .video }
            if isDocument(url) { return .document }
            return isText(url) ? .text : nil
        }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    /// 이름이 영상이고 앞부분이 MP4·MOV 상자 구조(`ftyp`·`moov`·`mdat`·`wide`)인 것
    private static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard FFmpeg.foreignVideoExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .movie) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        guard head.count >= 8 else { return false }
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)), String(decoding: head[8..<12], as: UTF8.self) == "AVI " { return true }   // AVI
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return true }                       // MKV·WebM
        if head.starts(with: [0x30, 0x26, 0xB2, 0x75]) { return true }                       // WMV(ASF)
        if head.starts(with: Array("FLV".utf8)) { return true }
        if head.starts(with: [0x00, 0x00, 0x01, 0xBA]) || head[0] == 0x47 { return true }   // MPEG-PS·TS
        let tag = String(decoding: head[4..<8], as: UTF8.self)
        return ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(tag)
    }

    /// Word(.docx·.doc)·RTF·OpenDocument·EPUB: 확장자 + 앞부분 표시(zip은 "PK", 옛 Word는 OLE, RTF는 "{\\rtf")
    private static func isDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "rtfd" { return FileManager.default.fileExists(atPath: url.appendingPathComponent("TXT.rtf").path) }
        guard ["docx", "doc", "rtf", "odt", "epub", "wordml", "hwpx"].contains(ext), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        if head.starts(with: [0x50, 0x4B]) { return ["docx", "odt", "epub", "hwpx"].contains(ext) }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return ext == "doc" }
        if head.starts(with: Array("{\\rtf".utf8)) { return ext == "rtf" || ext == "doc" }
        return ext == "wordml" || (ext == "doc" && !head.contains(0))
    }

    private static func isText(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .text),
              !type.conforms(to: .image), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return !head.contains(0) && !head.isEmpty
    }
}
