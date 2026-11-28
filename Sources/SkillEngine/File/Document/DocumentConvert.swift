import AppKit
import Compression
import CoreText
import Foundation

/// 문서끼리 바꾸기(양방향): Word·RTF·OpenDocument·HTML·Markdown·텍스트·EPUB·PDF 중 아무거나 → 아무거나.
/// 가운데 모양은 "문단 목록"(제목 단계·굵게·기울임)이라, 어느 형식에서 읽든 같은 방법으로 쓴다.
/// 글·제목·강조에 더해 표·그림·쪽 나눔·쪽 크기도 옮긴다(각주 같은 건 옮기지 않는다).
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

public struct DocumentMargins: Equatable, Sendable {
    public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

public struct RichDocument: Sendable {
    public var title: String
    public var paragraphs: [DocumentParagraph]
    /// 쪽 크기(포인트). PDF에서 온 문서는 원래 쪽 크기라 비율을 지킨다. 모르면 nil(A4 세로)
    public var pageSize: CGSize?
    /// 쪽 여백 pt(nil = 쓰는 쪽이 정함)
    public var margins: DocumentMargins?
    /// 머리글·꼬리글 문단, 꼬리글에 쪽 번호를 넣을지
    public var header: [DocumentParagraph] = []
    public var footer: [DocumentParagraph] = []
    public var showPageNumber = false
    /// 본문 글자 크기·글꼴(nil = 기본 11pt)
    public var bodyFontSize: CGFloat?
    public var bodyFontName: String?

    public init(title: String, paragraphs: [DocumentParagraph], pageSize: CGSize? = nil) {
        self.title = title
        self.paragraphs = paragraphs
        self.pageSize = pageSize
    }

    /// 쓸 쪽 크기: 모르면 A4 세로
    public var resolvedPageSize: CGSize { pageSize ?? CGSize(width: 595, height: 842) }
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
        let rich = ["docx", "doc", "rtf", "rtfd", "odt", "wordml", "epub", "hwpx", "hwp"].contains(ext)
        guard size <= (rich ? maxDocumentBytes : maxTextBytes) else { throw FileSkillError.tooLarge(name) }
        var paragraphs: [DocumentParagraph]
        var pageSize: CGSize?
        var hangul: HangulDocument?     // 한글 파일(.hwp·.hwpx)에서 읽은 여백·머리글·꼬리글·본문 글꼴
        switch ext {
        case "docx", "doc", "rtf", "rtfd", "odt", "wordml":
            // .docx는 직접 뜯어 읽는다(제목 스타일·표·그림·쪽 나눔·쪽 크기). 못 읽으면(.doc 옛 형식 등) macOS 문서 읽기로
            if ext == "docx" || (ext == "doc" && DocumentReaders.hasZipSignature(url)), let docx = DocxReader.read(url) {
                paragraphs = docx.paragraphs
                pageSize = docx.pageSize
                // 여백·머리글·꼬리글·쪽 번호·본문 글꼴도 넘긴다(한글과 같은 그릇을 쓴다)
                var extra = HangulDocument()
                extra.margins = docx.margins
                extra.header = docx.header
                extra.footer = docx.footer
                extra.showPageNumber = docx.showPageNumber
                extra.bodyFontSize = docx.bodyFontSize
                extra.bodyFontName = docx.bodyFontName
                hangul = extra
            } else {
                // RTF·ODT는 AppKit이 그림을 버리므로 그림을 자리표로 바꿔 읽고 나중에 되돌린다(RTFD는 첨부로 그대로 읽힌다)
                var prepared: RichReadImages.Prepared?
                var type: NSAttributedString.DocumentType?
                if ext == "rtf", let raw = try? Data(contentsOf: url) {
                    prepared = RichReadImages.prepareRTF(raw); type = .rtf
                } else if ext == "odt", let raw = try? Data(contentsOf: url) {
                    prepared = RichReadImages.prepareODT(raw); type = .openDocument
                }
                if let prepared, let type,
                   let attributed = try? NSAttributedString(data: prepared.data, options: [.documentType: type], documentAttributes: nil) {
                    paragraphs = RichReadImages.restore(fromAttributed(attributed), images: prepared.images)
                } else {
                    guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                        throw FileSkillError.unreadable(name)
                    }
                    paragraphs = fromAttributed(attributed)
                }
            }
        case "epub":
            paragraphs = try epub(url)
        case "hwp":
            do {
                let old = try HwpReader.document(url)
                paragraphs = old.paragraphs
                pageSize = old.pageSize
                hangul = old
            } catch HwpReader.Failure.locked, HwpReader.Failure.distribution {
                throw FileSkillError.lockedHangul(name)
            } catch {
                throw FileSkillError.unreadable(name)
            }
        case "hwpx":
            if let hwpx = HwpxReader.read(url) {
                paragraphs = hwpx.paragraphs
                pageSize = hwpx.pageSize
                hangul = hwpx
            } else {
                guard let text = DocumentReaders.zipXMLText(url, ext: "hwpx") else { throw FileSkillError.unreadable(name) }
                paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { DocumentParagraph(runs: [DocumentRun($0)]) }
            }
        default:
            guard let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0), let text = WhatIsText.decode(data) else {
                throw FileSkillError.notText(name)
            }
            let folder = url.deletingLastPathComponent()
            if ["html", "htm", "xhtml"].contains(ext) || DocumentReaders.looksLikeHTML(text) {
                paragraphs = fromHTML(text, baseURL: folder)
            } else if ["md", "markdown"].contains(ext) {
                paragraphs = fromMarkdown(text, baseURL: folder)
            } else {
                paragraphs = fromPlain(text)
            }
        }
        // 글자가 있거나, 표·그림이라도 있어야 읽은 것으로 본다
        guard paragraphs.contains(where: { $0.image != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw FileSkillError.notText(name)
        }
        var result = RichDocument(title: title, paragraphs: paragraphs, pageSize: pageSize)
        hangul?.apply(to: &result)
        return result
    }

    static func fromPlain(_ text: String) -> [DocumentParagraph] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { DocumentParagraph(runs: [DocumentRun($0)]) }
    }

    /// RTF·ODT·옛 .doc 등(macOS 문서 읽기): 글자 크기로 제목 단계를, 글꼴 모양으로 굵게·기울임을 알아낸다.
    /// 표(NSTextTableBlock)는 행·열을 복원해 table로 만들고, 표 안 글자는 본문 크기·제목 짐작에서 뺀다. 그림(첨부)·쪽 나눔(폼 피드)도 옮긴다.
    static func fromAttributed(_ attributed: NSAttributedString) -> [DocumentParagraph] {
        let string = attributed.string as NSString
        let full = NSRange(location: 0, length: string.length)

        func tableBlock(at location: Int) -> NSTextTableBlock? {
            guard location < string.length,
                  let style = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
            return style.textBlocks.first as? NSTextTableBlock
        }

        // 1) 본문 글자 크기: 표 밖 글자만 센다
        var histogram: [Int: Int] = [:]
        string.enumerateSubstrings(in: full, options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0, tableBlock(at: range.location) == nil else { return }
            attributed.enumerateAttribute(.font, in: range) { value, sub, _ in
                guard let font = value as? NSFont else { return }
                let visible = string.substring(with: sub).filter { !$0.isWhitespace && $0 != "\u{FFFC}" }.count
                if visible > 0 { histogram[Int((font.pointSize * 2).rounded()), default: 0] += visible }
            }
        }
        let body = CGFloat(readerBodySize(histogram) ?? 24) / 2

        // 2) 문단을 훑으면서 표는 모아 두었다가 끝나면 한 덩어리로
        var blocks = ReaderBlocks()
        struct TableInProgress {
            var table: NSTextTable
            var cells: [(row: Int, col: Int, rowSpan: Int, colSpan: Int, text: String)] = []
        }
        var current: TableInProgress?
        func flushTable() {
            guard let t = current else { return }
            current = nil
            var rowCount = 0, colCount = max(t.table.numberOfColumns, 0)
            for cell in t.cells {
                rowCount = max(rowCount, cell.row + 1)
                colCount = max(colCount, cell.col + 1)
            }
            guard rowCount > 0, colCount > 0, rowCount <= 20_000, colCount <= 1_000 else { return }
            var grid = Array(repeating: Array(repeating: "", count: colCount), count: rowCount)
            for cell in t.cells where cell.row >= 0 && cell.col >= 0 { grid[cell.row][cell.col] = cell.text }
            blocks.table(grid)
        }

        string.enumerateSubstrings(in: full, options: .byParagraphs) { _, range, _, _ in
            if let block = tableBlock(at: range.location) {
                if let existing = current, existing.table !== block.table { flushTable() }
                if current == nil { current = TableInProgress(table: block.table) }
                let text = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{0C}", with: "")
                if let i = current!.cells.firstIndex(where: { $0.row == block.startingRow && $0.col == block.startingColumn }) {
                    if !text.isEmpty { current!.cells[i].text += (current!.cells[i].text.isEmpty ? "" : "\n") + text }
                } else {
                    current!.cells.append((block.startingRow, block.startingColumn, block.rowSpan, block.columnSpan, text))
                }
                return
            }
            flushTable()
            guard range.length > 0 else { return }

            // 문단 안: 글 조각 · 그림 · 쪽 나눔
            var pieces: [ReaderPiece] = []
            var largest: CGFloat = 0
            var allBold = true
            func addText(_ text: String, bold: Bool, italic: Bool) {
                guard !text.isEmpty else { return }
                if case .runs(var runs)? = pieces.last {
                    pieces.removeLast()
                    if let last = runs.last, last.bold == bold, last.italic == italic { runs[runs.count - 1].text += text }
                    else { runs.append(DocumentRun(text, bold: bold, italic: italic)) }
                    pieces.append(.runs(runs))
                } else {
                    pieces.append(.runs([DocumentRun(text, bold: bold, italic: italic)]))
                }
            }
            attributed.enumerateAttributes(in: range) { attrs, sub, _ in
                let font = attrs[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let bold = traits.contains(.bold), italic = traits.contains(.italic)
                let raw = string.substring(with: sub)
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    var data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
                    if data == nil, let image = attachment.image { data = image.tiffRepresentation }
                    if let data {
                        let bounds = attachment.bounds.size
                        let size = bounds.width > 0 && bounds.height > 0 ? bounds : attachment.image?.size
                        if let picture = ReaderImage.image(from: data, size: size) { pieces.append(.image(picture)) }
                    }
                    return
                }
                // 쪽 나눔(폼 피드)에서 글을 나눈다
                let parts = raw.components(separatedBy: "\u{0C}")
                for (n, part) in parts.enumerated() {
                    if n > 0 { pieces.append(.pageBreak) }
                    let text = part.replacingOccurrences(of: "\u{FFFC}", with: "")
                    guard !text.isEmpty else { continue }
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        largest = max(largest, font?.pointSize ?? body)
                        if !bold { allBold = false }
                    }
                    addText(text, bold: bold, italic: italic)
                }
            }

            var marker = ""
            if let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
               let list = style.textLists.last {
                marker = list.markerFormat.rawValue.contains("decimal") ? "" : "• "
            }
            var markerPending = !marker.isEmpty
            for piece in pieces {
                switch piece {
                case .runs(var runs):
                    let text = runs.map(\.text).joined()
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    var level: Int?
                    if largest >= body * 1.6 { level = 1 } else if largest >= body * 1.25 { level = 2 } else if allBold, text.count < 80 { level = 3 }
                    if markerPending, !text.hasPrefix("•") { runs.insert(DocumentRun(marker), at: 0) }
                    markerPending = false
                    blocks.text(runs, level: level)
                case .image(let image): blocks.image(image)
                case .table(let rows): blocks.table(rows)
                case .pageBreak: blocks.pendingBreak = true
                }
            }
        }
        flushTable()
        return blocks.paragraphs
    }

    // MARK: HTML

    /// 간단한 HTML 읽기(자세한 건 HTMLReader): 제목·문단·목록·굵게·기울임·표·그림·쪽 나눔
    static func fromHTML(_ html: String, baseURL: URL? = nil, resolver: ((String) -> Data?)? = nil) -> [DocumentParagraph] {
        HTMLReader.parse(html, baseURL: baseURL, resolver: resolver)
    }

    // MARK: Markdown

    /// Markdown 읽기(자세한 건 MarkdownReader): 제목·목록·표·그림·쪽 나눔(`---`)
    static func fromMarkdown(_ markdown: String, baseURL: URL? = nil) -> [DocumentParagraph] {
        MarkdownReader.parse(markdown, baseURL: baseURL)
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
        for page in pages {
            guard let html = unzip(["-p", url.path, page]) else { continue }
            // 그림은 쪽 파일 기준 상대 경로로 zip 안에서 꺼낸다
            result += fromHTML(html, resolver: { src in
                let path = ZipPackage.resolve(src.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? src, relativeTo: page)
                return BoundedProcess.run("/usr/bin/unzip", ["-p", url.path, ZipPackage.escaped(path)])
            })
        }
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
            return DocxWriter.make(document)
        case .rtf: return try rtf(document)
        case .odt: return try odt(document)
        case .html: return Data(html(document, standalone: true).utf8)
        case .md: return Data(markdown(document).utf8)
        case .txt: return Data(plainText(document).utf8)
        case .epub: return epub(document)
        case .hwpx: return HwpxWriter.make(document)
        case .pdf: return pdf(document)
        }
    }

    // MARK: 쪽 크기

    struct PageMetrics {
        var page: CGSize
        var margins: DocumentMargins
        /// 왼쪽 여백(네 쪽이 같을 때 쓰던 값)
        var margin: CGFloat { margins.left }
        var content: CGSize {
            CGSize(width: max(72, page.width - margins.left - margins.right), height: max(72, page.height - margins.top - margins.bottom))
        }
    }

    /// 쪽 크기와 여백: 문서에 여백(margins)이 있으면 그것(쪽의 40%까지만), 없으면 짧은 변의 약 8%
    static func metrics(_ document: RichDocument) -> PageMetrics {
        var size = document.resolvedPageSize
        if size.width < 100 || size.height < 100 || !size.width.isFinite || !size.height.isFinite { size = CGSize(width: 595, height: 842) }
        if let m = document.margins {
            func clamp(_ v: CGFloat, _ limit: CGFloat) -> CGFloat { v.isFinite ? min(max(0, v), limit * 0.4) : 0 }
            return PageMetrics(page: size, margins: DocumentMargins(
                top: clamp(m.top, size.height), left: clamp(m.left, size.width),
                bottom: clamp(m.bottom, size.height), right: clamp(m.right, size.width)))
        }
        let margin = (min(size.width, size.height) * 0.08).rounded()
        return PageMetrics(page: size, margins: DocumentMargins(top: margin, left: margin, bottom: margin, right: margin))
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// 본문 폭(과 높이)에 맞춰 비율을 지키며 줄인 그림 크기(키우지는 않는다)
    static func fitted(_ size: CGSize, in content: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(1, content.width / size.width, content.height / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    // MARK: 서식 있는 글(RTF·ODT·PDF 공통)

    public enum RichTarget { case rtf, odt, pdf }

    static func imageToken(_ index: Int) -> String { "HLBIMGTOKEN\(index)END" }
    static let pageToken = "HLBPAGETOKENEND"

    /// 문단 목록 → NSAttributedString. RTF·ODT는 AppKit이 그림·ODT 쪽 나눔을 못 쓰므로 자리표(토큰)를 넣고 나중에 바꿔 끼운다.
    /// 돌려주는 그림 목록은 본문 폭에 맞춰 줄인 크기다(토큰 번호 순서).
    /// `bodyFontSize`·`bodyFontName`: 문서의 본문 글자 크기·글꼴(nil = 11pt·시스템 글꼴). 글자 크기·글꼴을 따로 정한 조각은 그 값이 먼저다.
    public static func attributedString(paragraphs: [DocumentParagraph], content: CGSize, target: RichTarget,
                                        bodyFontSize: CGFloat? = nil, bodyFontName: String? = nil) -> (NSAttributedString, [DocumentImage]) {
        let out = NSMutableAttributedString()
        var images: [DocumentImage] = []
        let bodySize = RichStyle.sanitizedBodySize(bodyFontSize)
        let bodyName = (bodyFontName?.isEmpty == false) ? bodyFontName : nil

        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.pageBreakBefore, index > 0, out.length > 0 {
                switch target {
                case .rtf: out.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font(size: 11, bold: false, italic: false)]))
                case .odt:
                    let tiny = NSMutableParagraphStyle(); tiny.paragraphSpacing = 0
                    out.append(NSAttributedString(string: pageToken + "\n", attributes: [.font: font(size: 1, bold: false, italic: false), .paragraphStyle: tiny]))
                case .pdf: break      // PDF는 호출하는 쪽에서 쪽마다 나눠서 부른다
                }
            }

            if let rows = paragraph.table, !rows.isEmpty, (rows.map(\.count).max() ?? 0) > 0 {
                appendTable(rows, layout: paragraph.tableLayout, bodyName: bodyName, to: out)
                continue
            }

            if let image = paragraph.image {
                let size = fitted(image.size, in: content)
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                switch target {
                case .pdf:
                    let attachment = NSTextAttachment()
                    attachment.image = NSImage(data: image.png)
                    // 편집 화면이 되돌릴 때 원본 PNG를 그대로 쓰게 같이 담아 둔다(화면에는 image가 쓰인다)
                    attachment.contents = image.png
                    attachment.fileType = "public.png"
                    attachment.bounds = CGRect(origin: .zero, size: size)
                    let piece = NSMutableAttributedString(attachment: attachment)
                    piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
                    out.append(piece)
                    out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: font(size: 11, bold: false, italic: false)]))
                case .rtf, .odt:
                    out.append(NSAttributedString(string: imageToken(images.count) + "\n", attributes: [.paragraphStyle: style, .font: font(size: 11, bold: false, italic: false)]))
                }
                images.append(DocumentImage(png: image.png, size: size))
                continue
            }

            // 편집 화면이 되돌릴 때 제목을 알아보도록 제목 글에 표시(.hanlabongHeading)를 단다. 본문 글에는 본문 표시
            var marks: [NSAttributedString.Key: Any] = [:]
            let level = paragraph.headingLevel.map { min(max($0, 1), 3) }
            if let level { marks[.hanlabongHeading] = level } else { marks[.hanlabongPlainBody] = true }
            if let rule = paragraph.ruleAbove { marks[.hanlabongRuleAbove] = rule }
            if let rule = paragraph.ruleBelow { marks[.hanlabongRuleBelow] = rule }
            let style = RichStyle.paragraphStyle(for: paragraph, heading: level != nil)
            for run in paragraph.runs {
                out.append(NSAttributedString(string: run.text, attributes: RichStyle.attributes(
                    for: run, heading: level, bodySize: bodySize, bodyName: bodyName, style: style, marks: marks)))
            }
            let endSize = RichStyle.headingSize(level: level, body: bodySize)
            out.append(NSAttributedString(string: "\n", attributes: [
                .paragraphStyle: style, .font: RichStyle.font(name: bodyName, size: endSize, bold: level != nil, italic: false),
            ].merging(marks) { $1 }))
        }
        return (out, images)
    }

    /// 진짜 표(NSTextTable): 얇은 테두리, 머리줄은 굵게·옅은 배경, 글자 9.5pt.
    /// 틀(layout)이 있으면 칸 너비(비율)·합친 칸·머리줄 수·테두리 유무를 따른다. 없으면 첫 줄이 머리줄.
    private static func appendTable(_ rows: [[String]], layout: DocumentTableLayout?, bodyName: String?, to out: NSMutableAttributedString) {
        let columns = rows.map(\.count).max() ?? 1
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let grid = RichStyle.TableGrid(rows: rows.count, columns: columns, layout: layout)
        let percents = RichStyle.columnPercents(layout, columns: columns)
        let header = RichStyle.headerRows(layout, rows: rows.count)
        let borders = layout?.borders ?? true
        for (r, row) in rows.enumerated() {
            for c in 0..<columns where !grid.isCovered(r, c) {
                let span = grid.span(r, c)
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: span?.rows ?? 1, startingColumn: c, columnSpan: span?.columns ?? 1)
                block.setWidth(borders ? 0.5 : 0, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(white: 0.55, alpha: 1))
                block.setWidth(3, type: .absoluteValueType, for: .padding)
                if let percents {
                    let covered = c..<(c + (span?.columns ?? 1))
                    block.setValue(percents[covered].reduce(0, +), type: .percentageValueType, for: .width)
                }
                if r < header { block.backgroundColor = NSColor(white: 0.92, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineSpacing = 1
                style.paragraphSpacing = 0
                let cell = (c < row.count ? row[c] : "").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                out.append(NSAttributedString(string: cell + "\n", attributes: [
                    .font: RichStyle.font(name: bodyName, size: 9.5, bold: r < header, italic: false), .paragraphStyle: style, .foregroundColor: NSColor.black,
                ]))
            }
        }
        // 표 뒤에 숨 쉴 틈
        let gap = NSMutableParagraphStyle(); gap.paragraphSpacing = 0
        out.append(NSAttributedString(string: "\n", attributes: [.font: font(size: 5, bold: false, italic: false), .paragraphStyle: gap]))
    }

    // MARK: RTF

    static func rtf(_ document: RichDocument) throws -> Data {
        let m = metrics(document)
        let (attributed, images) = attributedString(paragraphs: document.paragraphs, content: m.content, target: .rtf,
                                                    bodyFontSize: document.bodyFontSize, bodyFontName: document.bodyFontName)
        let raw = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: pageAttributes(document, type: .rtf, metrics: m))
        let headerFooter = rtfHeaderFooter(document)
        guard !images.isEmpty || !headerFooter.isEmpty else { return raw }
        // AppKit의 RTF는 그림을 버린다 → 자리표를 \pict(PNG)로 바꿔 끼운다
        var text = String(decoding: raw, as: UTF8.self)
        if !headerFooter.isEmpty, let at = text.range(of: "\\pard") { text.insert(contentsOf: headerFooter, at: at.lowerBound) }
        for (i, image) in images.enumerated() {
            let pixels = pixelSize(of: image)
            let hex = image.png.map { String(format: "%02x", $0) }.joined()
            let pict = "{\\pict\\pngblip\\picw\(Int(pixels.width))\\pich\(Int(pixels.height))\\picwgoal\(Int(image.size.width * 20))\\pichgoal\(Int(image.size.height * 20)) \(hex)}"
            text = text.replacingOccurrences(of: imageToken(i), with: pict)
        }
        return Data(text.utf8)
    }

    /// RTF 머리글·꼬리글 그룹(`{\header ...}` `{\footer ...}`). 쪽 번호는 PAGE 필드
    private static func rtfHeaderFooter(_ document: RichDocument) -> String {
        func escape(_ text: String) -> String {
            var out = ""
            for unit in text.utf16 {
                switch unit {
                case 0x5C: out += "\\\\"
                case 0x7B: out += "\\{"
                case 0x7D: out += "\\}"
                case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
                default: out += "\\u\(Int16(bitPattern: unit))?"
                }
            }
            return out
        }
        func group(_ name: String, _ paragraphs: [DocumentParagraph], pageNumber: Bool) -> String {
            var lines = RichStyle.paragraphsPlainText(paragraphs).map { item -> String in
                let align: String
                switch item.alignment { case .center?: align = "\\qc"; case .right?: align = "\\qr"; case .justify?: align = "\\qj"; default: align = "\\ql" }
                return "\\pard\(align)\\fs18 " + (item.bold ? "\\b " : "") + escape(item.text) + (item.bold ? "\\b0" : "") + "\\par"
            }
            if pageNumber { lines.append("\\pard\\qc\\fs18 {\\field{\\*\\fldinst PAGE}{\\fldrslt 1}}\\par") }
            return lines.isEmpty ? "" : "{\\\(name) " + lines.joined(separator: "\n") + "}\n"
        }
        return group("header", document.header, pageNumber: false) + group("footer", document.footer, pageNumber: document.showPageNumber)
    }

    private static func pixelSize(of image: DocumentImage) -> CGSize {
        if let rep = NSBitmapImageRep(data: image.png), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private static func pageAttributes(_ document: RichDocument, type: NSAttributedString.DocumentType, metrics m: PageMetrics) -> [NSAttributedString.DocumentAttributeKey: Any] {
        [.documentType: type, .title: document.title, .paperSize: NSSize(width: m.page.width, height: m.page.height),
         .leftMargin: m.margins.left, .rightMargin: m.margins.right, .topMargin: m.margins.top, .bottomMargin: m.margins.bottom]
    }

    // MARK: ODT

    static func odt(_ document: RichDocument) throws -> Data {
        let m = metrics(document)
        let (attributed, images) = attributedString(paragraphs: document.paragraphs, content: m.content, target: .odt,
                                                    bodyFontSize: document.bodyFontSize, bodyFontName: document.bodyFontName)
        let raw = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: pageAttributes(document, type: .openDocument, metrics: m))
        // AppKit의 ODT는 쪽 크기·여백·그림·쪽 나눔을 무시한다 → 압축을 풀어 고쳐 다시 묶는다
        guard let source = MiniZipReader(raw) else { return raw }
        var out = ZipWriter()
        if let mime = source.entries.first(where: { $0.name == "mimetype" }) { out.add("mimetype", mime.data, store: true) }
        for entry in source.entries where entry.name != "mimetype" {
            switch entry.name {
            case "content.xml":
                out.add(entry.name, patchODTContent(String(decoding: entry.data, as: UTF8.self), images: images))
            case "styles.xml":
                out.add(entry.name, patchODTPageLayout(String(decoding: entry.data, as: UTF8.self), metrics: m))
            case "META-INF/manifest.xml" where !images.isEmpty:
                var xml = String(decoding: entry.data, as: UTF8.self)
                let items = images.indices.map { " <manifest:file-entry manifest:media-type=\"image/png\" manifest:full-path=\"Pictures/image\($0 + 1).png\"/>\n" }.joined()
                if let range = xml.range(of: "</manifest:manifest>") { xml.replaceSubrange(range, with: items + "</manifest:manifest>") }
                out.add(entry.name, xml)
            default:
                out.add(entry.name, entry.data)
            }
        }
        for (i, image) in images.enumerated() { out.add("Pictures/image\(i + 1).png", image.png, store: true) }
        return out.finish()
    }

    private static func patchODTPageLayout(_ xml: String, metrics m: PageMetrics) -> String {
        let landscape = m.page.width > m.page.height
        let properties = "<style:page-layout-properties fo:page-width=\"\(Int(m.page.width))pt\" fo:page-height=\"\(Int(m.page.height))pt\" style:print-orientation=\"\(landscape ? "landscape" : "portrait")\" fo:margin-top=\"\(Int(m.margins.top))pt\" fo:margin-bottom=\"\(Int(m.margins.bottom))pt\" fo:margin-left=\"\(Int(m.margins.left))pt\" fo:margin-right=\"\(Int(m.margins.right))pt\"/>"
        guard let regex = try? NSRegularExpression(pattern: "<style:page-layout-properties[^>]*/>") else { return xml }
        return regex.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..., in: xml), withTemplate: NSRegularExpression.escapedTemplate(for: properties))
    }

    private static func patchODTContent(_ source: String, images: [DocumentImage]) -> String {
        var xml = source
        // 쪽 나눔: 자리표 문단을 "앞에서 쪽을 넘기는" 아주 작은 빈 문단으로
        if xml.contains(pageToken) {
            let style = "<style:style style:name=\"HLBPB\" style:family=\"paragraph\"><style:paragraph-properties fo:break-before=\"page\" fo:margin-top=\"0pt\" fo:margin-bottom=\"0pt\"/><style:text-properties fo:font-size=\"1pt\"/></style:style>"
            if let regex = try? NSRegularExpression(pattern: "<text:p[^>]*>(?:<text:span[^>]*>)?\(pageToken)(?:</text:span>)?</text:p>") {
                xml = regex.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..., in: xml), withTemplate: "<text:p text:style-name=\"HLBPB\"/>")
            }
            if let range = xml.range(of: "<office:automatic-styles>") {
                xml.replaceSubrange(range, with: "<office:automatic-styles>" + style)
            } else if let range = xml.range(of: "<office:automatic-styles/>") {
                xml.replaceSubrange(range, with: "<office:automatic-styles>" + style + "</office:automatic-styles>")
            }
        }
        for (i, image) in images.enumerated() {
            let frame = "<draw:frame draw:name=\"image\(i + 1)\" text:anchor-type=\"as-char\" svg:width=\"\(Int(image.size.width))pt\" svg:height=\"\(Int(image.size.height))pt\"><draw:image xlink:href=\"Pictures/image\(i + 1).png\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame>"
            xml = xml.replacingOccurrences(of: imageToken(i), with: frame)
        }
        return xml
    }

    // MARK: 글자 · 마크다운

    static func plainText(_ document: RichDocument) -> String {
        var out = ""
        for (index, paragraph) in document.paragraphs.enumerated() {
            if index > 0 { out += paragraph.pageBreakBefore ? "\n\n\n" : "\n\n" }
            out += paragraph.image != nil ? "[그림]" : paragraph.text
        }
        return out + "\n"
    }

    /// 굵게·기울임 표시는 글자 앞뒤 빈칸을 바깥으로 빼서 쓴다(`**글 **`은 굵게가 안 된다 → `**글** `).
    /// 밑줄·첨자는 html 태그(`<u>` `<sup>` `<sub>`), 취소선은 `~~`, 링크는 `[글](주소)`. 색·크기·글꼴은 마크다운에 없어 뺀다.
    static func markdownInline(_ runs: [DocumentRun], styled: Bool) -> String {
        var merged: [DocumentRun] = []
        func shown(_ run: DocumentRun) -> DocumentRun {      // 마크다운에 안 나타나는 모양은 같은 것으로 본다
            var r = run; r.colorHex = nil; r.fontSize = nil; r.fontName = nil; return r
        }
        for run in runs where !run.text.isEmpty {
            if var last = merged.last, shown(last).sameStyle(as: shown(run)) {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged.map { RichStyle.markdownRun($0, styled: styled) }.joined()
    }

    static func markdown(_ document: RichDocument) -> String {
        var imageNumber = 0
        let blocks = document.paragraphs.enumerated().map { index, paragraph -> String in
            var block: String
            if let rows = paragraph.table, !rows.isEmpty, (rows.map(\.count).max() ?? 0) > 0 {
                let columns = rows.map(\.count).max() ?? 1
                func line(_ row: [String]) -> String {
                    let cells = (0..<columns).map { c -> String in
                        (c < row.count ? row[c] : "").replacingOccurrences(of: "|", with: "\\|")
                            .replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
                    }
                    return "| " + cells.joined(separator: " | ") + " |"
                }
                var lines = [line(rows[0]), "|" + String(repeating: "---|", count: columns)]
                lines += rows.dropFirst().map(line)
                block = lines.joined(separator: "\n")
            } else if let image = paragraph.image {
                imageNumber += 1
                block = image.png.count > 1_000_000 ? "[그림 \(imageNumber)]" : "![그림](data:image/png;base64,\(image.png.base64EncodedString()))"
            } else {
                let inner = markdownInline(paragraph.runs, styled: paragraph.headingLevel == nil)
                if let level = paragraph.headingLevel { block = String(repeating: "#", count: level) + " " + inner }
                else { block = inner.hasPrefix("• ") ? "- " + inner.dropFirst(2) : inner }
            }
            return paragraph.pageBreakBefore && index > 0 ? "---\n\n" + block : block
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: HTML · EPUB

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let tableCSS = "table{border-collapse:collapse;margin:1em 0}th,td{border:1px solid #aaa;padding:4px 8px;vertical-align:top;font-size:.92em}th{background:#eee;font-weight:bold}.nb th,.nb td{border:none}.nb th{background:none}img{max-width:100%;height:auto}"

    /// 본문 조각. `ids`: 제목에 id(p번호)를 붙인다(EPUB 목차용). `image`: (그림 번호, 그림) → img의 src
    static func htmlBlocks(_ document: RichDocument, ids: Bool, image: (Int, DocumentImage) -> String) -> String {
        htmlBlocks(paragraphs: document.paragraphs, ids: ids, image: image)
    }

    static func htmlBlocks(paragraphs: [DocumentParagraph], ids: Bool, image: (Int, DocumentImage) -> String) -> String {
        var imageNumber = 0
        return paragraphs.enumerated().map { index, paragraph -> String in
            var styles: [String] = []
            let shape = RichStyle.paragraphCSS(paragraph)
            if !shape.isEmpty { styles.append(shape) }
            if paragraph.pageBreakBefore && index > 0 { styles.append("page-break-before:always;break-before:page") }
            let breakAttr = styles.isEmpty ? "" : " style=\"\(styles.joined(separator: ";"))\""
            if let rows = paragraph.table, !rows.isEmpty, (rows.map(\.count).max() ?? 0) > 0 {
                var tableStyles: [String] = []
                if paragraph.pageBreakBefore && index > 0 { tableStyles.append("page-break-before:always;break-before:page") }
                let attr = tableStyles.isEmpty ? "" : " style=\"\(tableStyles.joined(separator: ";"))\""
                return RichStyle.htmlTable(rows, layout: paragraph.tableLayout, attributes: attr)
            }
            if let picture = paragraph.image {
                let src = image(imageNumber, picture)
                imageNumber += 1
                return "<p\(breakAttr)><img src=\"\(src)\" width=\"\(Int(picture.size.width.rounded()))\" height=\"\(Int(picture.size.height.rounded()))\" alt=\"그림\"/></p>"
            }
            let heading = paragraph.headingLevel != nil
            let inner = paragraph.runs.map { RichStyle.htmlRun($0, heading: heading) }.joined()
            if let level = paragraph.headingLevel { return "<h\(level)\(ids ? " id=\"p\(index)\"" : "")\(breakAttr)>\(inner)</h\(level)>" }
            return "<p\(breakAttr)>\(inner)</p>"
        }.joined(separator: "\n")
    }

    static func html(_ document: RichDocument, standalone: Bool) -> String {
        let image: (Int, DocumentImage) -> String = { _, picture in "data:image/png;base64," + picture.png.base64EncodedString() }
        let body = htmlBlocks(document, ids: false, image: image)
        var bodyCSS = "font:16px/1.7 -apple-system,\"Apple SD Gothic Neo\",sans-serif;max-width:46em;margin:3em auto;padding:0 1em;color:#222"
        if let name = document.bodyFontName, !RichStyle.cssIdentifier(name).isEmpty {
            bodyCSS = "font:16px/1.7 '\(RichStyle.cssIdentifier(name))',-apple-system,\"Apple SD Gothic Neo\",sans-serif;max-width:46em;margin:3em auto;padding:0 1em;color:#222"
        }
        if let size = document.bodyFontSize, size.isFinite, size >= 4, size <= 200 { bodyCSS += ";font-size:\(RichStyle.css(size))pt" }
        let header = document.header.isEmpty ? "" : "<header style=\"color:#666;font-size:.85em;border-bottom:1px solid #ddd;margin-bottom:1.5em\">\n\(htmlBlocks(paragraphs: document.header, ids: false, image: image))\n</header>\n"
        let footer = document.footer.isEmpty ? "" : "\n<footer style=\"color:#666;font-size:.85em;border-top:1px solid #ddd;margin-top:1.5em\">\n\(htmlBlocks(paragraphs: document.footer, ids: false, image: image))\n</footer>"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(document.title))</title>
        <style>body{\(bodyCSS)}h1,h2,h3{line-height:1.3}\(tableCSS)</style>
        </head><body>
        \(header)\(body)\(footer)
        </body></html>

        """
    }

    /// EPUB 3: mimetype(압축 없이 맨 앞) + container + 목차(nav) + 본문 한 장 + 그림 파일
    static func epub(_ document: RichDocument) -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8), store: true)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        var pictures: [Data] = []
        let body = htmlBlocks(document, ids: true) { number, picture in
            pictures.append(picture.png)
            return "images/image\(number + 1).png"
        }
        let id = UUID().uuidString
        let lang = document.paragraphs.contains { $0.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } } ? "ko" : "en"
        let imageItems = pictures.indices.map { "<item id=\"img\($0 + 1)\" href=\"images/image\($0 + 1).png\" media-type=\"image/png\"/>" }.joined()
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:\(id)</dc:identifier><dc:title>\(escape(document.title))</dc:title><dc:language>\(lang)</dc:language><meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()).prefix(19))Z</meta></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>\(imageItems)</manifest>
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
        zip.add("OEBPS/text.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)"><head><title>\(escape(document.title))</title><style>\(tableCSS)</style></head>
        <body>
        \(body)
        </body></html>
        """)
        for (i, png) in pictures.enumerated() { zip.add("OEBPS/images/image\(i + 1).png", png, store: true) }
        return zip.finish()
    }

    // MARK: PDF

    /// 머리글(위 여백 안쪽)·꼬리글(아래 여백 안쪽)·쪽 번호(꼬리글 맨 아래, 가운데)를 그린다
    private static func drawHeaderFooter(_ document: RichDocument, metrics m: PageMetrics, pageNumber: Int, in context: CGContext) {
        var footerParagraphs = document.footer
        if document.showPageNumber {
            var number = DocumentParagraph(runs: [DocumentRun(String(pageNumber))])
            number.alignment = .center
            footerParagraphs.append(number)
        }
        guard !document.header.isEmpty || !footerParagraphs.isEmpty else { return }
        func text(_ paragraphs: [DocumentParagraph]) -> NSAttributedString {
            let trimmed = paragraphs.map { p -> DocumentParagraph in
                var q = p; q.spaceAfter = q.spaceAfter ?? 0; q.spaceBefore = q.spaceBefore ?? 0; q.pageBreakBefore = false; return q
            }
            return attributedString(paragraphs: trimmed, content: m.content, target: .pdf, bodyFontSize: 9, bodyFontName: document.bodyFontName).0
        }
        context.saveGState()
        context.translateBy(x: 0, y: m.page.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let width = m.content.width
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if !document.header.isEmpty {
            let header = text(document.header)
            let h = ceil(header.boundingRect(with: CGSize(width: width, height: 10_000), options: options).height)
            header.draw(with: CGRect(x: m.margins.left, y: max(6, m.margins.top - 8 - h), width: width, height: h + 2), options: options)
        }
        if !footerParagraphs.isEmpty {
            let footer = text(footerParagraphs)
            let h = ceil(footer.boundingRect(with: CGSize(width: width, height: 10_000), options: options).height)
            let y = min(m.page.height - h - 6, m.page.height - m.margins.bottom + 8)
            footer.draw(with: CGRect(x: m.margins.left, y: y, width: width, height: h + 2), options: options)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// 문단 위·아래 구분선을 긋는다(뒤집힌 좌표, 본문 왼쪽 위가 0)
    private static func drawRules(storage: NSTextStorage, layout: NSLayoutManager, glyphs: NSRange, width: CGFloat) {
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = storage.string as NSString
        var location = characters.location
        while location < NSMaxRange(characters) {
            let paragraphRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraphRange) }
            let attrs = storage.attributes(at: paragraphRange.location, effectiveRange: nil)
            let above = attrs[.hanlabongRuleAbove] as? DocumentRule, below = attrs[.hanlabongRuleBelow] as? DocumentRule
            guard above != nil || below != nil else { continue }
            let glyphRange = layout.glyphRange(forCharacterRange: paragraphRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            func line(_ rule: DocumentRule, y: CGFloat) {
                let left = rule.fullWidth ? 0 : (style?.headIndent ?? 0)
                let right = rule.fullWidth ? width : width + min(0, style?.tailIndent ?? 0)
                let path = NSBezierPath()
                path.move(to: CGPoint(x: left, y: y)); path.line(to: CGPoint(x: right, y: y))
                path.lineWidth = max(rule.width, 0.25)
                (RichStyle.color(hex: rule.colorHex) ?? .gray).setStroke()
                path.stroke()
            }
            if let above, NSLocationInRange(glyphRange.location, glyphs) {
                let first = layout.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                line(above, y: first.minY - above.gap - above.width / 2)
            }
            if let below, NSLocationInRange(NSMaxRange(glyphRange) - 1, glyphs) {
                let last = layout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphRange) - 1, effectiveRange: nil)
                line(below, y: last.maxY + below.gap + below.width / 2)
            }
        }
    }

    /// 문서 쪽 크기 PDF(여백은 문서 여백, 없으면 짧은 변의 약 8%). 머리글은 위, 꼬리글(과 쪽 번호)은 아래. 글자는 진짜 글자라 검색·복사가 된다. 표·그림도 그린다.
    static func pdf(_ document: RichDocument) -> Data {
        let m = metrics(document)
        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: m.page)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: document.title] as CFDictionary) else { return Data() }

        // 쪽 나눔이 있는 곳에서 묶음을 끊는다
        var groups: [[DocumentParagraph]] = [[]]
        for paragraph in document.paragraphs {
            if paragraph.pageBreakBefore, !groups[groups.count - 1].isEmpty { groups.append([]) }
            groups[groups.count - 1].append(paragraph)
        }

        var pages = 0
        for group in groups where !group.isEmpty {
            let (attributed, _) = attributedString(paragraphs: group, content: m.content, target: .pdf,
                                                   bodyFontSize: document.bodyFontSize, bodyFontName: document.bodyFontName)
            let storage = NSTextStorage(attributedString: attributed)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            while pages < 5000 {
                let container = NSTextContainer(size: m.content)
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                let range = layout.glyphRange(for: container)
                if range.length == 0 { layout.removeTextContainer(at: layout.textContainers.count - 1); break }
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: m.margins.left, y: m.page.height - m.margins.top)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                layout.drawBackground(forGlyphRange: range, at: .zero)
                layout.drawGlyphs(forGlyphRange: range, at: .zero)
                drawRules(storage: storage, layout: layout, glyphs: range, width: m.content.width)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                drawHeaderFooter(document, metrics: m, pageNumber: pages + 1, in: context)
                context.endPDFPage()
                pages += 1
                if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            }
        }
        if pages == 0 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return output as Data
    }
}

// MARK: - 작은 zip 읽기(ODT 고치기용)

/// AppKit이 만든 .odt 같은 작은 zip을 메모리에서 푼다(그대로/DEFLATE만).
struct MiniZipReader {
    struct Entry { var name: String; var data: Data }
    private(set) var entries: [Entry] = []

    init?(_ data: Data) {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? u16(o) | u16(o + 2) << 16 : 0 }
        guard b.count > 22 else { return nil }
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x0201_4b50 else { return nil }
            let method = u16(p + 10), compressed = u32(p + 20), size = u32(p + 24)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), commentLength = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLength <= b.count else { return nil }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength
            guard local + 30 <= b.count else { return nil }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count else { return nil }
            if name.hasSuffix("/") { continue }
            let body = Data(b[start..<(start + compressed)])
            if method == 0 {
                entries.append(Entry(name: name, data: body))
            } else if method == 8 {
                guard let inflated = Self.inflate(body, size: size) else { return nil }
                entries.append(Entry(name: name, data: inflated))
            } else {
                return nil
            }
        }
    }

    private static func inflate(_ data: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        guard size < 256_000_000 else { return nil }
        var out = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&out, size, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return written == size ? Data(out) : nil
    }
}
