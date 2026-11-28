import AppKit
import Foundation

// 문서 편집(Hanlabong WordPro 2단계): 화면에서 사용자가 고친 NSAttributedString을 다시 RichDocument로 되돌린다.
// 보여 줄 때는 RichDocumentWriter.attributedString(target: .pdf)가 만든 글을 쓰고,
// 저장할 때는 아래 document(from:)로 되돌린 뒤 RichDocumentWriter.write로 원래 형식에 쓴다.

public extension NSAttributedString.Key {
    /// 쪽 나눔 표시 문단: 이 속성이 붙은 글(문단 전체)은 내용이 아니라 쪽 경계. 다음 문단이 pageBreakBefore가 된다
    static let hanlabongPageBreak = NSAttributedString.Key("HanlabongPageBreak")
    /// 제목 단계(Int 1~3). 이 속성이 붙은 문단은 그 단계의 제목
    static let hanlabongHeading = NSAttributedString.Key("HanlabongHeading")
}

public enum RichDocumentEditing {
    // MARK: 제목 글꼴

    /// writer가 제목·본문에 쓰는 글자 크기: 제목 1 = 22, 2 = 17, 3 = 13, 본문(nil) = 11
    public static func headingPointSize(level: Int?) -> CGFloat {
        RichStyle.headingSize(level: level, body: RichStyle.defaultBodySize)
    }

    /// 본문 크기가 11pt가 아닌 문서의 제목 크기(같은 비율)
    public static func headingPointSize(level: Int?, body: CGFloat) -> CGFloat {
        RichStyle.headingSize(level: level, body: RichStyle.sanitizedBodySize(body))
    }

    /// 제목 단계에 맞는 글꼴(화면의 제목 바꾸기 단추가 쓴다): level nil = 본문.
    /// writer와 똑같이 제목은 항상 굵게 쓴다(`bold`는 본문에서만 뜻이 있다)
    public static func headingFont(level: Int?, bold: Bool, italic: Bool, body: CGFloat = 11, name: String? = nil) -> NSFont {
        let clamped = level.map { min(max($0, 1), 3) }
        return RichStyle.font(name: name, size: headingPointSize(level: clamped, body: body), bold: bold || clamped != nil, italic: italic)
    }

    // MARK: 되돌리기

    /// 화면에서 고친 글 → 문서. pageSize는 그대로 넘긴다.
    ///
    /// 규칙
    /// - 문단은 줄바꿈(\n, \r, U+2029) 기준. 글자가 없는(공백뿐인) 문단은 버린다
    /// - 굵게·기울임은 글꼴 모양(symbolic traits, 굵기)으로. 같은 모양이 이어지면 한 조각
    /// - 제목: `.hanlabongHeading`이 문단 글자의 절반 이상에 붙어 있으면 그 단계. 없으면 글꼴 크기(본문의 1.12배 이상일 때만,
    ///   writer 제목 크기 비율과 가장 가까운 단계). 제목 안의 굵게는 제목이 이미 굵으니 따로 두지 않는다
    /// - 표: 같은 NSTextTable의 칸(NSTextTableBlock)을 startingRow·startingColumn으로 모아 [[String]]. 칸 안 여러 문단은 줄바꿈으로
    /// - 그림: NSTextAttachment → PNG + 크기(attachment.bounds, 없으면 그림 크기). 글과 섞인 문단은 글/그림/글로 나눈다
    /// - 쪽 나눔: `.hanlabongPageBreak`가 붙은 글과 폼피드(U+000C)는 버리고 다음 덩어리에 pageBreakBefore. 문서 맨 앞의 쪽 나눔은 무시
    /// - 문단 모양: 정렬·들여쓰기(왼쪽·첫 줄)·문단 앞뒤 간격·줄 간격 배수. 기본값(writer가 쓰는 8/6pt 간격, 3pt 줄 틈)과 같으면 nil
    /// - 글자 모양: 밑줄·취소선·첨자(baselineOffset)·색(검정은 nil)·링크, 글자 크기·글꼴은 본문(또는 그 제목 단계 기본)과 다를 때만
    /// - 표: 칸 너비 비율·합친 칸·머리줄 수(배경이 있는 맨 위 줄들)·테두리 유무. 모양이 옛 기본(머리줄 1·테두리 있음·같은 너비)이면 tableLayout은 nil
    /// - `original`: 이 글이 나온 문서. 화면 글에 없는 값(쪽 여백·머리글·꼬리글·쪽 번호·본문 크기·본문 글꼴)을 그대로 이어받는다.
    ///   본문 크기는 original에 없으면 화면 글에서 재서(11pt가 아닐 때만) 채운다
    public static func document(from text: NSAttributedString, title: String, pageSize: CGSize?, basedOn original: RichDocument? = nil) -> RichDocument {
        let converter = Converter(text, bodySize: original?.bodyFontSize, bodyName: original?.bodyFontName)
        var document = RichDocument(title: title, paragraphs: converter.run(), pageSize: pageSize)
        if let original {
            document.margins = original.margins
            document.header = original.header
            document.footer = original.footer
            document.showPageNumber = original.showPageNumber
            document.bodyFontName = original.bodyFontName
        }
        document.bodyFontSize = original?.bodyFontSize ?? (abs(converter.bodySize - RichStyle.defaultBodySize) > 0.01 ? converter.bodySize : nil)
        return document
    }

    // MARK: - 내부

    /// 문서 덩어리 모으기. 쪽 나눔은 다음 덩어리에 붙인다(문서 맨 앞이면 무시)
    private struct Collector {
        var paragraphs: [DocumentParagraph] = []
        var pendingBreak = false

        mutating func add(_ paragraph: DocumentParagraph) {
            var p = paragraph
            if pendingBreak {
                p.pageBreakBefore = !paragraphs.isEmpty
                pendingBreak = false
            }
            paragraphs.append(p)
        }
    }

    /// 글 조각의 모양(크기는 첨자 축소를 되돌린 본래 크기)
    private struct RunStyle {
        var bold = false, italic = false, underline = false, strike = false
        var script = 0
        var colorHex: String?
        var size: CGFloat = 11
        var fontName: String?
        var link: String?
    }

    private enum Piece {
        case text(String, style: RunStyle, heading: Int?, plain: Bool)
        case image(DocumentImage)
        case pageBreak
    }

    private struct TableCell {
        var row: Int, col: Int, rowSpan: Int, colSpan: Int
        var text: String
        var width: CGFloat?
        var widthType: NSTextBlock.ValueType?
        var header: Bool
        var bordered: Bool
    }

    private struct TableInProgress {
        var table: NSTextTable
        var cells: [TableCell] = []
    }

    private final class Converter {
        let attributed: NSAttributedString
        let string: NSString
        var out = Collector()
        var table: TableInProgress?
        var bodySize: CGFloat = 11
        let givenBodySize: CGFloat?
        let bodyName: String?
        /// 본문 글꼴의 가족 이름(이 글꼴로 그려진 글은 글꼴을 따로 두지 않는다)
        let baseFamily: String

        init(_ attributed: NSAttributedString, bodySize: CGFloat?, bodyName: String?) {
            self.attributed = attributed
            self.string = attributed.string as NSString
            self.givenBodySize = bodySize.map { RichStyle.sanitizedBodySize($0) }
            self.bodyName = (bodyName?.isEmpty == false) ? bodyName : nil
            self.baseFamily = (RichStyle.font(name: self.bodyName, size: 11, bold: false, italic: false).familyName ?? "").lowercased()
        }

        private static let ignorable = CharacterSet(charactersIn: "\u{FFFC}\u{0C}")

        private func tableBlock(at location: Int) -> NSTextTableBlock? {
            guard location >= 0, location < string.length,
                  let style = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
            return style.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
        }

        /// 본문 글자 크기: 표 밖 글자 중 가장 많은 크기(제목이 더 길어도 제목을 본문으로 잡지 않는 규칙은 readerBodySize가 맡는다)
        private func measureBodySize() -> CGFloat {
            var histogram: [Int: Int] = [:]
            let full = NSRange(location: 0, length: string.length)
            string.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
                guard range.length > 0, self.tableBlock(at: range.location) == nil else { return }
                self.attributed.enumerateAttribute(.font, in: range) { value, sub, _ in
                    guard let font = value as? NSFont else { return }
                    let visible = self.string.substring(with: sub).unicodeScalars.filter {
                        !CharacterSet.whitespacesAndNewlines.contains($0) && !Self.ignorable.contains($0)
                    }.count
                    if visible > 0 { histogram[Int((font.pointSize * 2).rounded()), default: 0] += visible }
                }
            }
            if let best = readerBodySize(histogram) { return CGFloat(best) / 2 }
            return 11
        }

        func run() -> [DocumentParagraph] {
            guard string.length > 0 else { return [] }
            bodySize = givenBodySize ?? measureBodySize()
            let full = NSRange(location: 0, length: string.length)
            let nsString = string
            nsString.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
                self.handle(range: range, enclosing: enclosing)
            }
            flushTable()
            return out.paragraphs
        }

        // MARK: 표

        private func flushTable() {
            guard let t = table else { return }
            table = nil
            var rowCount = 0
            var colCount = max(t.table.numberOfColumns, 0)
            for cell in t.cells {
                rowCount = max(rowCount, cell.row + cell.rowSpan)
                colCount = max(colCount, cell.col + cell.colSpan)
            }
            guard rowCount > 0, colCount > 0, rowCount <= 20_000, colCount <= 1_000 else { return }
            var grid = Array(repeating: Array(repeating: "", count: colCount), count: rowCount)
            for cell in t.cells where cell.row >= 0 && cell.col >= 0 { grid[cell.row][cell.col] = cell.text }
            var paragraph = DocumentParagraph(runs: [], table: ReaderBlocks.normalizeTable(grid))
            paragraph.tableLayout = Self.layout(of: t.cells, rows: rowCount, columns: colCount)
            // 사용자가 막 만든 빈 표도 표로 남긴다(칸 글이 모두 비어도 버리지 않는다)
            out.add(paragraph)
        }

        /// 칸들의 모양 → 표 모양. 옛 기본(머리줄 1·테두리 있음·같은 너비·합친 칸 없음)이면 nil
        private static func layout(of cells: [TableCell], rows: Int, columns: Int) -> DocumentTableLayout? {
            var layout = DocumentTableLayout()
            layout.spans = cells.filter { $0.rowSpan > 1 || $0.colSpan > 1 }
                .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
                .map { DocumentCellSpan(row: $0.row, column: $0.col, columns: $0.colSpan, rows: $0.rowSpan) }
            // 칸 너비: 한 칸짜리 셀에서 열마다 너비를 모으고 비율로
            var widths: [CGFloat?] = Array(repeating: nil, count: columns)
            var kind: NSTextBlock.ValueType?
            var consistent = true
            for cell in cells where cell.colSpan == 1 && cell.col >= 0 && cell.col < columns {
                guard let w = cell.width, w > 0, let type = cell.widthType else { continue }
                if let kind, kind != type { consistent = false }
                kind = type
                if widths[cell.col] == nil { widths[cell.col] = w }
            }
            let known = widths.compactMap { $0 }
            if consistent, !known.isEmpty {
                let fill = known.reduce(0, +) / CGFloat(known.count)
                let all = widths.map { $0 ?? fill }
                let sum = all.reduce(0, +)
                if sum > 0 { layout.columnWidths = all.map { $0 / sum } }
            }
            // 머리줄: 맨 위에서부터 칸이 모두 배경색인 줄
            var header = 0
            while header < rows {
                let line = cells.filter { $0.row == header }
                guard !line.isEmpty, line.allSatisfy(\.header) else { break }
                header += 1
            }
            layout.headerRows = header
            layout.borders = cells.isEmpty || cells.contains { $0.bordered }
            return layout == DocumentTableLayout(headerRows: 1) ? nil : layout
        }

        private func addTableCell(_ block: NSTextTableBlock, range: NSRange) {
            if let existing = table, existing.table !== block.table { flushTable() }
            if table == nil { table = TableInProgress(table: block.table) }
            let raw = range.length > 0 ? string.substring(with: range) : ""
            let text = Self.cleanedCellText(raw)
            if let i = table!.cells.firstIndex(where: { $0.row == block.startingRow && $0.col == block.startingColumn }) {
                if !text.isEmpty { table!.cells[i].text += (table!.cells[i].text.isEmpty ? "" : "\n") + text }
            } else {
                let value = block.value(for: .width)
                table!.cells.append(TableCell(
                    row: block.startingRow, col: block.startingColumn, rowSpan: max(1, block.rowSpan), colSpan: max(1, block.columnSpan),
                    text: text, width: value > 0 ? value : nil, widthType: value > 0 ? block.valueType(for: .width) : nil,
                    header: block.backgroundColor != nil, bordered: block.width(for: .border, edge: .minX) > 0))
            }
        }

        private static func cleanedCellText(_ raw: String) -> String {
            raw.replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{0C}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
        }

        // MARK: 문단

        private func handle(range: NSRange, enclosing: NSRange) {
            let probe = range.length > 0 ? range.location : enclosing.location
            if let block = tableBlock(at: probe) {
                addTableCell(block, range: range)
                return
            }
            flushTable()
            guard range.length > 0 else {
                // 글자 없이 줄바꿈에만 쪽 나눔 표시가 붙은 문단
                if enclosing.length > 0, let value = attributed.attribute(.hanlabongPageBreak, at: enclosing.location, effectiveRange: nil),
                   (value as? Bool) != false, (value as? NSNumber)?.intValue != 0 {
                    out.pendingBreak = true
                }
                return
            }

            // 1) 문단 안 조각: 글 · 그림 · 쪽 나눔
            var pieces: [Piece] = []
            attributed.enumerateAttributes(in: range, options: []) { attrs, sub, _ in
                if let value = attrs[.hanlabongPageBreak], (value as? Bool) != false, (value as? NSNumber)?.intValue != 0 {
                    if case .pageBreak? = pieces.last {} else { pieces.append(.pageBreak) }
                    return
                }
                let raw = string.substring(with: sub)
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    let count = max(raw.filter { $0 == "\u{FFFC}" }.count, 1)
                    if let picture = Self.documentImage(attachment) {
                        for _ in 0..<count { pieces.append(.image(picture)) }
                    }
                    // 그림 말고 같이 붙어 온 글자(드문 경우)는 아래에서 이어서 다룬다
                    let rest = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
                    if rest.isEmpty { return }
                    appendText(rest, attrs: attrs, to: &pieces)
                    return
                }
                appendText(raw, attrs: attrs, to: &pieces)
            }

            // 2) 문단 모양: 제목 단계 + 정렬·들여쓰기·간격
            let level = headingLevel(of: pieces)
            let paragraphStyle = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let baseSize = RichStyle.headingSize(level: level, body: bodySize)

            // 3) 조각을 덩어리로
            var runs: [DocumentRun] = []
            func flush() {
                let merged = ReaderBlocks.merge(runs)
                runs = []
                guard merged.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
                var paragraph = DocumentParagraph(runs: merged, headingLevel: level)
                Self.applyShape(of: paragraphStyle, heading: level != nil, to: &paragraph)
                out.add(paragraph)
            }
            for piece in pieces {
                switch piece {
                case .text(let text, let style, _, _):
                    var run = DocumentRun(text, bold: level == nil && style.bold, italic: style.italic)   // 제목은 이미 굵으니 굵게는 따로 두지 않는다
                    run.underline = style.underline
                    run.strike = style.strike
                    run.script = style.script
                    run.colorHex = style.colorHex
                    run.linkURL = style.link
                    if abs(style.size - baseSize) > 0.05 { run.fontSize = (style.size * 100).rounded() / 100 }
                    run.fontName = style.fontName
                    runs.append(run)
                case .image(let picture):
                    flush()
                    out.add(DocumentParagraph(runs: [], image: picture))
                case .pageBreak:
                    flush()
                    out.pendingBreak = true
                }
            }
            flush()
        }

        /// 글 조각을 모양과 함께 담는다(폼피드에서는 쪽 나눔으로 나눈다)
        private func appendText(_ raw: String, attrs: [NSAttributedString.Key: Any], to pieces: inout [Piece]) {
            let font = attrs[.font] as? NSFont
            var style = RunStyle()
            style.bold = Self.isBold(font)
            style.italic = Self.isItalic(font)
            style.underline = ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
            style.strike = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
            let offset = (attrs[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
            let legacy = (attrs[.superscript] as? NSNumber)?.intValue ?? 0
            style.script = offset > 0.01 ? 1 : offset < -0.01 ? -1 : legacy > 0 ? 1 : legacy < 0 ? -1 : 0
            style.colorHex = RichStyle.hex(of: attrs[.foregroundColor] as? NSColor)
            let pointSize = font?.pointSize ?? bodySize
            style.size = (offset != 0 && style.script != 0) ? pointSize / RichStyle.scriptScale : pointSize
            style.fontName = fontName(of: font, requested: attrs[.hanlabongFontName] as? String)
            if let url = attrs[.link] as? URL { style.link = url.absoluteString }
            else if let text = attrs[.link] as? String, !text.isEmpty { style.link = text }
            var heading: Int?
            if let value = attrs[.hanlabongHeading] {
                if let n = value as? Int { heading = min(max(n, 1), 3) }
                else if let n = (value as? NSNumber)?.intValue { heading = min(max(n, 1), 3) }
            }
            let plain = attrs[.hanlabongPlainBody] != nil
            let parts = raw.components(separatedBy: "\u{0C}")
            for (n, part) in parts.enumerated() {
                if n > 0, case .pageBreak? = pieces.last {} else if n > 0 { pieces.append(.pageBreak) }
                let text = part.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
                guard !text.isEmpty else { continue }
                pieces.append(.text(text, style: style, heading: heading, plain: plain))
            }
        }

        /// 글꼴: 본문 글꼴과 가족이 다를 때만 이름을 둔다. 시스템 글꼴(이름이 "."로 시작)로 그려졌으면 writer가 적어 둔 이름을 쓴다
        private func fontName(of font: NSFont?, requested: String?) -> String? {
            let family = font?.familyName ?? ""
            if !family.isEmpty, !family.hasPrefix(".") {
                if family.lowercased() == baseFamily { return nil }
                if let requested, !requested.isEmpty, requested.lowercased() == family.lowercased() { return requested }
                return family
            }
            guard let requested, !requested.isEmpty else { return nil }
            if let bodyName, requested.lowercased() == bodyName.lowercased() { return nil }
            return requested
        }

        /// 문단 모양(정렬·들여쓰기·간격·줄 간격). writer 기본값과 같으면 비워 둔다
        private static func applyShape(of style: NSParagraphStyle?, heading: Bool, to paragraph: inout DocumentParagraph) {
            guard let style else { return }
            switch style.alignment {
            case .center: paragraph.alignment = .center
            case .right: paragraph.alignment = .right
            case .justified: paragraph.alignment = .justify
            case .left: paragraph.alignment = .left
            default: paragraph.alignment = nil
            }
            paragraph.leftIndent = style.headIndent
            paragraph.firstLineIndent = style.firstLineHeadIndent - style.headIndent
            if style.tailIndent < 0 { paragraph.rightIndent = -style.tailIndent }
            if style.paragraphSpacingBefore != RichStyle.defaultSpaceBefore(heading: heading) { paragraph.spaceBefore = style.paragraphSpacingBefore }
            if style.paragraphSpacing != RichStyle.defaultSpaceAfter(heading: heading) { paragraph.spaceAfter = style.paragraphSpacing }
            if style.lineHeightMultiple > 0 { paragraph.lineSpacing = style.lineHeightMultiple }
        }

        /// 제목 단계: 속성이 문단 글자의 절반 이상에 있으면 그 단계, 없으면 글자 크기로 짐작(본문 표시가 있으면 짐작하지 않는다)
        private func headingLevel(of pieces: [Piece]) -> Int? {
            var visibleTotal = 0
            var plainVisible = 0
            var perLevel: [Int: Int] = [:]
            var largest: CGFloat = 0
            for piece in pieces {
                guard case .text(let text, let style, let heading, let plain) = piece else { continue }
                let visible = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
                guard visible > 0 else { continue }
                visibleTotal += visible
                largest = max(largest, style.size)
                if let heading { perLevel[heading, default: 0] += visible } else if plain { plainVisible += visible }
            }
            guard visibleTotal > 0 else { return nil }
            if let best = perLevel.max(by: { $0.value < $1.value }), best.value * 2 >= visibleTotal { return best.key }
            guard perLevel.isEmpty, plainVisible * 2 < visibleTotal, bodySize > 0 else { return nil }
            // 글꼴 크기로: writer의 제목 크기 비율(22:17:13 ÷ 11)에 가장 가까운 단계. 본문보다 확실히(1.12배) 클 때만
            let ratio = largest / bodySize
            guard ratio >= 1.12 else { return nil }
            let candidates: [(level: Int, ratio: CGFloat)] = [(1, 22.0 / 11), (2, 17.0 / 11), (3, 13.0 / 11)]
            return candidates.min(by: { abs($0.ratio - ratio) < abs($1.ratio - ratio) })?.level
        }

        // MARK: 글꼴 · 그림

        static func isBold(_ font: NSFont?) -> Bool {
            guard let font else { return false }
            if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
            if let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
               let weight = (traits[.weight] as? NSNumber)?.doubleValue, weight >= 0.3 { return true }
            return false
        }

        static func isItalic(_ font: NSFont?) -> Bool {
            font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
        }

        /// 첨부 → 문서 그림. 원본 PNG(contents)가 있으면 그대로, 없으면 fileWrapper·화면 그림에서 PNG로
        static func documentImage(_ attachment: NSTextAttachment) -> DocumentImage? {
            let bounds = attachment.bounds.size
            let imageSize = attachment.image?.size
            var size: CGSize? = bounds.width > 0 && bounds.height > 0 ? bounds : nil
            if size == nil, let s = imageSize, s.width > 0, s.height > 0 { size = s }

            var candidates: [Data] = []
            if let data = attachment.contents { candidates.append(data) }
            if let data = attachment.fileWrapper?.regularFileContents { candidates.append(data) }
            for data in candidates {
                if let picture = ReaderImage.image(from: data, size: size) { return picture }
            }
            if let image = attachment.image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return ReaderImage.image(from: png, size: size)
            }
            return nil
        }
    }
}
