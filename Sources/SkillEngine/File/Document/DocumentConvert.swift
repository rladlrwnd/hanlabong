import AppKit
import CoreText
import Foundation

/// 문서끼리 바꾸기(양방향): Word·RTF·OpenDocument·HTML·Markdown·텍스트·EPUB·PDF 중 아무거나 → 아무거나.
/// 가운데 모양은 "문단 목록"(제목 단계·굵게·기울임)이라, 어느 형식에서 읽든 같은 방법으로 쓴다.
/// 그림·표·각주 같은 건 옮기지 않는다(글과 제목·강조만).
public enum DocumentFormat: String, Codable, CaseIterable, Sendable {
    case pdf, docx, rtf, odt, html, md, txt, epub, hwpx

    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "Word"
        case .rtf: return "RTF"
        case .odt: return "ODT"
        case .html: return "HTML"
        case .md: return "Markdown"
        case .txt: return L("텍스트", "Text")
        case .epub: return "EPUB"
        case .hwpx: return L("한글", "Hangul")
        }
    }

    /// 이 확장자의 파일이 이 형식인지(같은 형식으로는 바꾸지 않게)
    public func matches(extension ext: String) -> Bool {
        let e = ext.lowercased()
        switch self {
        case .docx: return e == "docx" || e == "doc"
        case .html: return e == "html" || e == "htm" || e == "xhtml"
        case .md: return e == "md" || e == "markdown"
        case .rtf: return e == "rtf" || e == "rtfd"
        default: return e == rawValue
        }
    }
}

public struct RichDocument: Sendable {
    public var title: String
    public var paragraphs: [DocumentParagraph]

    public init(title: String, paragraphs: [DocumentParagraph]) {
        self.title = title
        self.paragraphs = paragraphs
    }
}

// MARK: - 읽기

public enum RichDocumentReader {
    /// PDF가 아닌 문서를 문단으로 읽는다(PDF는 PDFTextExtractor가 읽는다)
    /// 읽을 수 있는 크기 한도: 서식 있는 문서·EPUB 200MB, 글 파일 50MB(넘으면 멈추지 않고 거절)
    public static let maxDocumentBytes = 200_000_000
    public static let maxTextBytes = 50_000_000

    public static func read(_ url: URL) throws -> RichDocument {
        let name = url.lastPathComponent
        let title = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let rich = ["docx", "doc", "rtf", "rtfd", "odt", "wordml", "epub", "hwpx"].contains(ext)
        guard size <= (rich ? maxDocumentBytes : maxTextBytes) else { throw FileSkillError.tooLarge(name) }
        let paragraphs: [DocumentParagraph]
        switch ext {
        case "docx", "doc", "rtf", "rtfd", "odt", "wordml":
            guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw FileSkillError.unreadable(name)
            }
            paragraphs = fromAttributed(attributed)
        case "epub":
            paragraphs = try epub(url)
        case "hwpx":
            guard let text = DocumentReaders.zipXMLText(url, ext: "hwpx") else { throw FileSkillError.unreadable(name) }
            paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { DocumentParagraph(runs: [DocumentRun($0)]) }
        default:
            guard let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0), let text = WhatIsText.decode(data) else {
                throw FileSkillError.notText(name)
            }
            if ["html", "htm", "xhtml"].contains(ext) || DocumentReaders.looksLikeHTML(text) {
                paragraphs = fromHTML(text)
            } else if ["md", "markdown"].contains(ext) {
                paragraphs = fromMarkdown(text)
            } else {
                paragraphs = fromPlain(text)
            }
        }
        guard paragraphs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw FileSkillError.notText(name)
        }
        return RichDocument(title: title, paragraphs: paragraphs)
    }

    static func fromPlain(_ text: String) -> [DocumentParagraph] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { DocumentParagraph(runs: [DocumentRun($0)]) }
    }

    /// Word·RTF 등: 글자 크기로 제목 단계를, 글꼴 모양으로 굵게·기울임을 알아낸다
    static func fromAttributed(_ attributed: NSAttributedString) -> [DocumentParagraph] {
        let string = attributed.string as NSString
        var sizes: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize, default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        var result: [DocumentParagraph] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { return }
            var runs: [DocumentRun] = []
            var largest: CGFloat = 0
            var allBold = true
            attributed.enumerateAttributes(in: range) { attrs, sub, _ in
                let text = string.substring(with: sub)
                let font = attrs[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let bold = traits.contains(.bold), italic = traits.contains(.italic)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    largest = max(largest, font?.pointSize ?? body)
                    if !bold { allBold = false }
                }
                if let last = runs.last, last.bold == bold, last.italic == italic { runs[runs.count - 1].text += text }
                else { runs.append(DocumentRun(text, bold: bold, italic: italic)) }
            }
            var marker = ""
            if let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
               let list = style.textLists.last {
                marker = list.markerFormat.rawValue.contains("decimal") ? "" : "• "
            }
            let text = runs.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            var level: Int?
            if largest >= body * 1.6 { level = 1 } else if largest >= body * 1.25 { level = 2 } else if allBold, text.count < 80 { level = 3 }
            if !marker.isEmpty, !text.hasPrefix("•") { runs.insert(DocumentRun(marker), at: 0) }
            result.append(DocumentParagraph(runs: runs, headingLevel: level))
        }
        return result
    }

    // MARK: HTML

    /// 간단한 HTML 읽기: 제목(h1~h6)·문단·목록·줄바꿈·굵게·기울임. 스크립트·스타일은 버린다.
    static func fromHTML(_ html: String) -> [DocumentParagraph] {
        var s = html
        for pattern in ["(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?is)<noscript\\b.*?</noscript>", "(?s)<!--.*?-->", "(?is)<head\\b.*?</head>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let token = try! NSRegularExpression(pattern: "<(/?)([a-zA-Z0-9]+)[^>]*>|([^<]+)")
        var result: [DocumentParagraph] = []
        var runs: [DocumentRun] = []
        var level: Int?
        var bold = 0, italic = 0
        var listDepthOrdered: [Bool] = [], counters: [Int] = []
        func flush() {
            let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                var trimmed = runs
                if let first = trimmed.first { trimmed[0].text = String(first.text.drop { $0.isWhitespace }) }
                result.append(DocumentParagraph(runs: trimmed.filter { !$0.text.isEmpty }, headingLevel: level))
            }
            runs = []
            level = nil
        }
        func add(_ text: String) {
            let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !collapsed.isEmpty else { return }
            let b = bold > 0 || (level != nil), i = italic > 0
            if let last = runs.last, last.bold == b, last.italic == i { runs[runs.count - 1].text += collapsed }
            else { runs.append(DocumentRun(collapsed, bold: b, italic: i)) }
        }
        let ns = s as NSString
        for m in token.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 3).location != NSNotFound {
                add(DocumentReaders.decodeEntities(ns.substring(with: m.range(at: 3))))
                continue
            }
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let tag = ns.substring(with: m.range(at: 2)).lowercased()
            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing { level = min(3, Int(String(tag.last!))!) }
            case "p", "div", "section", "article", "blockquote", "pre", "tr", "table", "header", "footer", "figure", "title":
                flush()
            case "br":
                add("\n")
            case "li":
                flush()
                if !closing {
                    if listDepthOrdered.last == true, !counters.isEmpty {
                        counters[counters.count - 1] += 1
                        runs.append(DocumentRun("\(counters.last!). "))
                    } else {
                        runs.append(DocumentRun("• "))
                    }
                }
            case "ul", "ol":
                flush()
                if closing { _ = listDepthOrdered.popLast(); _ = counters.popLast() }
                else { listDepthOrdered.append(tag == "ol"); counters.append(0) }
            case "b", "strong": bold += closing ? -1 : 1
            case "i", "em": italic += closing ? -1 : 1
            case "td", "th": if closing { add("\t") }
            default: break
            }
            bold = max(bold, 0); italic = max(italic, 0)
        }
        flush()
        return result
    }

    // MARK: Markdown

    static func fromMarkdown(_ markdown: String) -> [DocumentParagraph] {
        var result: [DocumentParagraph] = []
        var buffer: [String] = []
        var inCode = false
        var code: [String] = []
        func flushBuffer() {
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(DocumentParagraph(runs: inline(text))) }
            buffer = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    result.append(DocumentParagraph(runs: [DocumentRun(code.joined(separator: "\n"))]))
                    code = []
                } else { flushBuffer() }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushBuffer(); continue }
            if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushBuffer()
                let hashes = line[match].filter { $0 == "#" }.count
                result.append(DocumentParagraph(runs: inline(String(line[match.upperBound...])).map { DocumentRun($0.text, bold: true, italic: $0.italic) },
                                                headingLevel: min(3, hashes)))
                continue
            }
            if line.range(of: "^([-*+]|\\d+[.)])\\s+", options: .regularExpression) != nil {
                flushBuffer()
                let ordered = line.first?.isNumber == true
                let body = line.replacingOccurrences(of: "^([-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
                let marker = ordered ? String(line.prefix { $0.isNumber }) + ". " : "• "
                result.append(DocumentParagraph(runs: [DocumentRun(marker)] + inline(body)))
                continue
            }
            if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil { flushBuffer(); continue }
            if line.hasPrefix(">") { flushBuffer(); result.append(DocumentParagraph(runs: inline(String(line.drop { $0 == ">" || $0 == " " })), headingLevel: nil)); continue }
            if line.hasPrefix("|") {                       // 표: 칸을 탭으로
                flushBuffer()
                if line.range(of: "^\\|?\\s*:?-{2,}", options: .regularExpression) != nil { continue }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                result.append(DocumentParagraph(runs: inline(cells.joined(separator: "\t"))))
                continue
            }
            buffer.append(line)
        }
        if inCode, !code.isEmpty { result.append(DocumentParagraph(runs: [DocumentRun(code.joined(separator: "\n"))])) }
        flushBuffer()
        return result
    }

    /// **굵게**, *기울임*, `코드`, [링크](주소) → 글자와 모양
    static func inline(_ text: String) -> [DocumentRun] {
        var s = text.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        var runs: [DocumentRun] = []
        let regex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|__(.+?)__|\\*(.+?)\\*|_(.+?)_")
        let ns = s as NSString
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { runs.append(DocumentRun(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            if m.range(at: 1).location != NSNotFound { runs.append(DocumentRun(ns.substring(with: m.range(at: 1)), bold: true)) }
            else if m.range(at: 2).location != NSNotFound { runs.append(DocumentRun(ns.substring(with: m.range(at: 2)), bold: true)) }
            else if m.range(at: 3).location != NSNotFound { runs.append(DocumentRun(ns.substring(with: m.range(at: 3)), italic: true)) }
            else { runs.append(DocumentRun(ns.substring(with: m.range(at: 4)), italic: true)) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { runs.append(DocumentRun(ns.substring(from: last))) }
        return runs
    }

    // MARK: EPUB

    static func epub(_ url: URL) throws -> [DocumentParagraph] {
        guard let list = unzip(["-Z1", url.path]) else { throw FileSkillError.unreadable(url.lastPathComponent) }
        var pages: [String] = []
        for line in list.split(separator: "\n").prefix(3000) {          // 항목이 비정상적으로 많은 파일은 앞부분만
            let name = String(line)
            let lower = name.lowercased()
            guard lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") else { continue }
            if lower.contains("nav.") || lower.contains("toc.") { continue }
            pages.append(name)
        }
        pages.sort { (a: String, b: String) -> Bool in a.localizedStandardCompare(b) == .orderedAscending }
        var result: [DocumentParagraph] = []
        for page in pages { if let html = unzip(["-p", url.path, page]) { result += fromHTML(html) } }
        return result
    }

    static func unzip(_ arguments: [String]) -> String? {
        BoundedProcess.unzip(arguments)      // 압축 폭탄 방지: 64MB 넘게 풀리면 멈춘다
    }
}

// MARK: - 쓰기

public enum RichDocumentWriter {
    public static func write(_ document: RichDocument, as format: DocumentFormat) throws -> Data {
        switch format {
        case .docx:
            let extracted = ExtractedDocument(paragraphs: document.paragraphs, rawPages: [], title: document.title,
                                              pageSize: CGSize(width: 595, height: 842), pageCount: 1, bodyFontSize: 11)
            return DocxWriter.make(extracted, title: document.title)
        case .rtf, .odt:
            let attributed = attributedString(document)
            let type: NSAttributedString.DocumentType = format == .rtf ? .rtf : .openDocument
            return try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type, .title: document.title])
        case .html: return Data(html(document, standalone: true).utf8)
        case .md: return Data(markdown(document).utf8)
        case .txt: return Data((document.paragraphs.map(\.text).joined(separator: "\n\n") + "\n").utf8)
        case .epub: return epub(document)
        case .hwpx: return HwpxWriter.make(document)
        case .pdf: return pdf(attributedString(document), title: document.title)
        }
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func attributedString(_ document: RichDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, paragraph) in document.paragraphs.enumerated() {
            let size: CGFloat
            switch paragraph.headingLevel { case 1?: size = 22; case 2?: size = 17; case 3?: size = 13; default: size = 11 }
            let style = NSMutableParagraphStyle()
            // 탭으로 나눈 표가 칸처럼 보이게 넓은 탭 간격(1인치)
            style.tabStops = (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 72) }
            style.defaultTabInterval = 72
            style.lineSpacing = 3
            style.paragraphSpacing = paragraph.headingLevel == nil ? 8 : 6
            style.paragraphSpacingBefore = paragraph.headingLevel == nil ? 0 : 10
            for run in paragraph.runs {
                out.append(NSAttributedString(string: run.text, attributes: [
                    .font: font(size: size, bold: run.bold || paragraph.headingLevel != nil, italic: run.italic),
                    .paragraphStyle: style, .foregroundColor: NSColor.black,
                ]))
            }
            if index < document.paragraphs.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: font(size: size, bold: false, italic: false)])) }
        }
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func htmlBody(_ document: RichDocument) -> String {
        document.paragraphs.map { paragraph -> String in
            let inner = paragraph.runs.map { run -> String in
                var t = escape(run.text).replacingOccurrences(of: "\n", with: "<br/>")
                if run.italic { t = "<em>\(t)</em>" }
                if run.bold, paragraph.headingLevel == nil { t = "<strong>\(t)</strong>" }
                return t
            }.joined()
            if let level = paragraph.headingLevel { return "<h\(level)>\(inner)</h\(level)>" }
            return "<p>\(inner)</p>"
        }.joined(separator: "\n")
    }

    static func html(_ document: RichDocument, standalone: Bool) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(document.title))</title>
        <style>body{font:16px/1.7 -apple-system,"Apple SD Gothic Neo",sans-serif;max-width:46em;margin:3em auto;padding:0 1em;color:#222}h1,h2,h3{line-height:1.3}</style>
        </head><body>
        \(htmlBody(document))
        </body></html>

        """
    }

    static func markdown(_ document: RichDocument) -> String {
        document.paragraphs.map { paragraph in
            let inner = paragraph.runs.map { run -> String in
                let t = run.text
                guard !t.trimmingCharacters(in: .whitespaces).isEmpty, paragraph.headingLevel == nil else { return t }
                if run.bold && run.italic { return "***\(t)***" }
                if run.bold { return "**\(t)**" }
                if run.italic { return "*\(t)*" }
                return t
            }.joined()
            if let level = paragraph.headingLevel { return String(repeating: "#", count: level) + " " + inner }
            return inner.hasPrefix("• ") ? "- " + inner.dropFirst(2) : inner
        }.joined(separator: "\n\n") + "\n"
    }

    /// EPUB 3: mimetype(압축 없이 맨 앞) + container + 목차(nav) + 본문 한 장
    static func epub(_ document: RichDocument) -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8), store: true)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        let id = UUID().uuidString
        let lang = document.paragraphs.contains { $0.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } } ? "ko" : "en"
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:\(id)</dc:identifier><dc:title>\(escape(document.title))</dc:title><dc:language>\(lang)</dc:language><meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()).prefix(19))Z</meta></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="text"/></spine></package>
        """)
        let headings = document.paragraphs.enumerated().filter { $0.element.headingLevel == 1 || $0.element.headingLevel == 2 }
        let toc = headings.isEmpty ? "<li><a href=\"text.xhtml\">\(escape(document.title))</a></li>"
            : headings.map { "<li><a href=\"text.xhtml#p\($0.offset)\">\(escape($0.element.text))</a></li>" }.joined()
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(escape(document.title))</title></head>
        <body><nav epub:type="toc"><ol>\(toc)</ol></nav></body></html>
        """)
        let body = document.paragraphs.enumerated().map { index, paragraph -> String in
            let inner = paragraph.runs.map { run -> String in
                var t = escape(run.text).replacingOccurrences(of: "\n", with: "<br/>")
                if run.italic { t = "<em>\(t)</em>" }
                if run.bold, paragraph.headingLevel == nil { t = "<strong>\(t)</strong>" }
                return t
            }.joined()
            if let level = paragraph.headingLevel { return "<h\(level) id=\"p\(index)\">\(inner)</h\(level)>" }
            return "<p>\(inner)</p>"
        }.joined(separator: "\n")
        zip.add("OEBPS/text.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)"><head><title>\(escape(document.title))</title></head>
        <body>
        \(body)
        </body></html>
        """)
        return zip.finish()
    }

    /// A4 PDF(여백 56pt). 글자는 진짜 글자라 검색·복사가 된다.
    static func pdf(_ attributed: NSAttributedString, title: String) -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary) else { return Data() }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let frameRect = CGRect(x: 56, y: 56, width: 595 - 112, height: 842 - 112)
        var start = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame).length
            context.endPDFPage()
            if visible == 0 { break }
            start += visible
        } while start < attributed.length
        context.closePDF()
        return output as Data
    }
}
