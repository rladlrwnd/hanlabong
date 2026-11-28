import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// PDF에서 뽑아 다시 짠 글. Word·텍스트로 쓸 때 같은 모양을 쓴다.
public struct DocumentRun: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    /// 1 = 위첨자, -1 = 아래첨자, 0 = 보통
    public var script = 0
    /// 글자색 "RRGGBB"(nil = 기본 검정)
    public var colorHex: String?
    /// 글자 크기 pt(nil = 본문 크기)
    public var fontSize: CGFloat?
    /// 글꼴 이름(nil = 본문 글꼴)
    public var fontName: String?
    /// 링크 주소
    public var linkURL: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
    }

    /// 글자 외 모양이 같은가(이어진 조각을 합칠 때)
    public func sameStyle(as other: DocumentRun) -> Bool {
        var a = self, b = other
        a.text = ""; b.text = ""
        return a == b
    }
}

/// 문단 정렬
public enum DocumentAlignment: String, Equatable, Sendable { case left, center, right, justify }

/// 문단 위·아래에 긋는 가로 구분선(PDF의 가로줄을 살린다)
public struct DocumentRule: Equatable, Sendable {
    /// 선 색 "RRGGBB"
    public var colorHex: String
    /// 선 굵기 pt
    public var width: CGFloat
    /// 글자와 선 사이 거리 pt
    public var gap: CGFloat
    /// true = 문단 들여쓰기와 상관없이 본문 폭 전체에 긋는다
    public var fullWidth: Bool

    public init(colorHex: String = "808080", width: CGFloat = 0.5, gap: CGFloat = 4, fullWidth: Bool = true) {
        self.colorHex = colorHex; self.width = width; self.gap = gap; self.fullWidth = fullWidth
    }
}

/// 표 모양: 칸 너비·합친 칸·머리줄·테두리. `DocumentParagraph.table`의 글과 같은 줄×칸 격자 기준
public struct DocumentTableLayout: Equatable, Sendable {
    /// 칸(열) 너비 비율(합이 1이 아니어도 됨, 비율로 쓴다). 비어 있으면 같은 너비
    public var columnWidths: [CGFloat] = []
    /// 합친 칸: (줄, 칸) → (가로 칸 수, 세로 줄 수). 합쳐져 가려진 칸은 글이 비어 있고 여기 없음
    public var spans: [DocumentCellSpan] = []
    /// 맨 위에서 머리줄로 볼 줄 수(0이면 머리줄 없음)
    public var headerRows = 0
    /// 테두리를 그리는가
    public var borders = true

    public init(columnWidths: [CGFloat] = [], spans: [DocumentCellSpan] = [], headerRows: Int = 0, borders: Bool = true) {
        self.columnWidths = columnWidths
        self.spans = spans
        self.headerRows = headerRows
        self.borders = borders
    }
}

public struct DocumentCellSpan: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var columns: Int
    public var rows: Int
    public init(row: Int, column: Int, columns: Int, rows: Int) {
        self.row = row; self.column = column; self.columns = columns; self.rows = rows
    }
}

/// 문서 안의 그림(PDF의 그래프·도표 등을 잘라 낸 것). 크기는 포인트(쪽에서 차지하던 크기)
public struct DocumentImage: Equatable, Sendable {
    public var png: Data
    public var size: CGSize

    public init(png: Data, size: CGSize) {
        self.png = png
        self.size = size
    }
}

/// 문서의 한 덩어리. 보통은 글 문단이고, `table`이나 `image`가 있으면 그 덩어리는 표·그림이다.
public struct DocumentParagraph: Equatable, Sendable {
    public var runs: [DocumentRun]
    /// 1 = 큰 제목, 2 = 중간 제목, 3 = 굵은 한 줄 제목. 본문은 nil.
    public var headingLevel: Int?
    /// 표: 줄 × 칸의 글자. 첫 줄은 머리줄로 본다. 있으면 `runs`는 비워 둔다
    public var table: [[String]]?
    /// 그림: 있으면 `runs`는 비우거나 그림 설명(캡션 아님)만 둔다
    public var image: DocumentImage?
    /// 이 덩어리 앞에서 쪽을 넘긴다(PDF의 쪽 경계를 살린다)
    public var pageBreakBefore = false
    /// 문단 모양(nil·0 = 기본)
    public var alignment: DocumentAlignment?
    public var leftIndent: CGFloat = 0
    /// 오른쪽 들여쓰기 pt
    public var rightIndent: CGFloat = 0
    /// 문단 위·아래 구분선
    public var ruleAbove: DocumentRule?
    public var ruleBelow: DocumentRule?
    /// 첫 줄 들여쓰기(음수 = 내어쓰기)
    public var firstLineIndent: CGFloat = 0
    public var spaceBefore: CGFloat?
    public var spaceAfter: CGFloat?
    /// 줄 간격 배수(1.0 = 한 줄)
    public var lineSpacing: CGFloat?
    /// 표 모양(table이 있을 때)
    public var tableLayout: DocumentTableLayout?

    public init(runs: [DocumentRun], headingLevel: Int? = nil, table: [[String]]? = nil,
                image: DocumentImage? = nil, pageBreakBefore: Bool = false) {
        self.runs = runs
        self.headingLevel = headingLevel
        self.table = table
        self.image = image
        self.pageBreakBefore = pageBreakBefore
    }

    /// 글자만(표는 칸을 탭, 줄을 줄바꿈으로)
    public var text: String {
        if let table { return table.map { $0.joined(separator: "\t") }.joined(separator: "\n") }
        return runs.map(\.text).joined()
    }
}

public struct ExtractedDocument: Sendable {
    public var paragraphs: [DocumentParagraph]
    /// 줄바꿈을 그대로 둔 페이지별 글자(“줄 유지” 옵션용)
    public var rawPages: [String]
    public var title: String?
    /// 첫 페이지 크기(포인트)
    public var pageSize: CGSize
    public var pageCount: Int
    /// 본문 글자 크기(포인트)
    public var bodyFontSize: CGFloat
    /// 본문 글꼴(가장 많은 글자에 쓰인 글꼴, 모르면 nil)
    public var bodyFontName: String?
    /// 쪽 여백(본문 글이 놓인 자리에서 잰 값, 모르면 nil)
    public var margins: DocumentMargins?

    /// 서식 있는 문서로(한글·워드 등으로 쓸 때): 쪽 크기·여백·본문 글꼴과 크기를 함께 넘긴다
    public func richDocument(title fallback: String) -> RichDocument {
        var document = RichDocument(title: title ?? fallback, paragraphs: paragraphs, pageSize: pageSize)
        document.margins = margins
        document.bodyFontSize = bodyFontSize
        document.bodyFontName = bodyFontName
        return document
    }
}

/// PDF 한 줄. 좌표는 페이지 위쪽이 0인 값으로 바꿔 둔다.
struct PDFLine: Equatable {
    var page: Int
    var runs: [DocumentRun]
    var minX: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var width: CGFloat
    var fontSize: CGFloat
    var pageHeight: CGFloat
    /// 줄 안에서 넓게 벌어진 곳으로 나눈 조각(표 칸 찾기용). 비어 있으면 줄 전체가 한 조각.
    var segments: [Segment] = []

    var text: String { runs.map(\.text).joined() }

    struct Segment: Equatable {
        var runs: [DocumentRun]
        var minX: CGFloat
        var maxX: CGFloat
        var text: String { runs.map(\.text).joined() }
    }
}

enum PDFTextExtractor {
    static func letterCount(_ text: String) -> Int { text.filter { !$0.isWhitespace }.count }

    /// PDFKit으로 줄 단위 글자·위치·글꼴을 읽고 문단으로 다시 짠다.
    /// `ocr`을 주면 글자가 없는 쪽(스캔한 쪽)은 그 쪽을 그림으로 그려서 글자 인식한 줄을 대신 쓴다.
    static func extract(_ document: PDFDocument, ocr: ((PDFPage, Int) throws -> [PDFLine])? = nil) throws -> ExtractedDocument {
        var lines: [PDFLine] = []
        var rawPages: [String] = []
        var ocrPages = Set<Int>()
        var rules: [PDFRule] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            if let ocr, letterCount(page.string ?? "") < 3 {
                let recognized = try ocr(page, index)
                lines += recognized
                rawPages.append(recognized.map(\.text).joined(separator: "\n"))
                ocrPages.insert(index)
                continue
            }
            let pageText = (page.string ?? "") as NSString
            rawPages.append(pageText as String)
            guard let selection = page.selection(for: bounds) else { continue }
            // 내용 흐름을 직접 훑어 실제 글꼴(굵게·세리프)과 가로 구분선을 찾는다
            let scan = PDFContentScan.scan(page, index: index)
            rules += scan.rules
            for line in selection.selectionsByLine() {
                let rect = line.bounds(for: page)
                let top = bounds.maxY - rect.maxY, bottom = bounds.maxY - rect.minY
                let found = PDFContentScan.pieces(for: (top, bottom, rect.minX - bounds.minX, rect.maxX - bounds.minX), in: scan)
                let runs = Self.runs(of: line, pieces: found)
                let text = runs.map(\.text).joined()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let size = Self.dominantSize(of: line) ?? rect.height * 0.8
                lines.append(PDFLine(
                    page: index, runs: runs,
                    minX: rect.minX - bounds.minX, top: top, bottom: bottom,
                    width: rect.width, fontSize: size, pageHeight: bounds.height,
                    segments: segments(of: line, page: page, pageText: pageText, origin: bounds, fontSize: size)
                ))
            }
        }
        // 본문 글꼴·크기(가장 많은 글자에 쓰인 것)는 문서 기본값으로 두고, 조각에는 그와 다른 것만 남긴다
        let body = Self.bodyStyle(of: lines)
        for i in lines.indices {
            for j in lines[i].runs.indices {
                if let size = lines[i].runs[j].fontSize, let bodySize = body.size, abs(size - bodySize) < 0.05 { lines[i].runs[j].fontSize = nil }
                if let name = lines[i].runs[j].fontName, name == body.font { lines[i].runs[j].fontName = nil }
            }
        }
        let first = document.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 그래프를 그림으로 잘라 낼 때만 그 쪽을 그린다(글자 인식한 쪽·돌린 쪽은 좌표가 달라 빼고)
        var margins: DocumentMargins?
        let paragraphs = assemble(lines, rules: rules, margins: &margins) { index in
            guard !ocrPages.contains(index), let page = document.page(at: index), page.rotation % 360 == 0 else { return nil }
            return PageRaster.render(page)
        }
        var extracted = ExtractedDocument(
            paragraphs: paragraphs, rawPages: rawPages, title: title?.isEmpty == false ? title : nil,
            pageSize: first, pageCount: document.pageCount, bodyFontSize: body.size ?? bodySize(of: lines)
        )
        extracted.bodyFontName = body.font
        extracted.margins = margins
        return extracted
    }

    /// 가장 많은 글자에 쓰인 글자 크기·글꼴(조각에 적힌 값 기준, 없으면 nil)
    static func bodyStyle(of lines: [PDFLine]) -> (size: CGFloat?, font: String?) {
        var sizes: [CGFloat: Int] = [:], fonts: [String: Int] = [:]
        for line in lines {
            for run in line.runs {
                let n = letterCount(run.text)
                if let size = run.fontSize { sizes[size, default: 0] += n }
                if let font = run.fontName { fonts[font, default: 0] += n }
            }
        }
        return (sizes.max { $0.value < $1.value }?.key, fonts.max { $0.value < $1.value }?.key)
    }

    // MARK: 글꼴

    private static let fontKey = NSAttributedString.Key("NSFont")

    private static func font(_ value: Any?) -> CTFont? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return nil }
        return (value as! CTFont)
    }

    /// 한 줄을 모양(굵게·기울임·색·크기·글꼴)이 같은 조각들로 나눈다.
    /// `pieces`(내용 흐름에서 찾은 실제 글꼴)가 있으면 굵게·기울임·글꼴은 그것을 믿는다.
    private static func runs(of line: PDFSelection, pieces: [PDFTextPiece] = []) -> [DocumentRun] {
        guard let attributed = line.attributedString, attributed.length > 0 else {
            return [DocumentRun(Self.clean(line.string ?? ""))]
        }
        // PDFKit이 알려 준 글꼴이 실제 글꼴과 같으면 그대로 믿는다(맞지 않을 때만 내용 흐름의 글꼴로 고친다)
        var known = Set<String>()
        attributed.enumerateAttribute(fontKey, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = font(value) { known.insert(CTFontCopyPostScriptName(font) as String) }
        }
        let real = Set(pieces.map { PDFContentScan.strippedName($0.fontName) })
        if real.isEmpty || known.isSubset(of: real) { return runs(of: attributed) }
        return runs(of: attributed, fonts: PDFContentScan.fontRanges(pieces, length: attributed.length))
    }

    private static let colorKey = NSAttributedString.Key("NSColor")

    static func runs(of attributed: NSAttributedString, fonts: [(NSRange, String)] = []) -> [DocumentRun] {
        // 나눌 자리: 글자 속성이 바뀌는 곳 + 실제 글꼴이 바뀌는 곳
        let full = NSRange(location: 0, length: attributed.length)
        var cuts = Set<Int>([0, attributed.length])
        attributed.enumerateAttributes(in: full) { _, range, _ in cuts.insert(range.location) }
        for (range, _) in fonts { cuts.insert(range.location); cuts.insert(min(NSMaxRange(range), attributed.length)) }
        let points = cuts.filter { $0 <= attributed.length }.sorted()
        var runs: [DocumentRun] = []
        for (start, end) in zip(points, points.dropFirst()) where end > start {
            let range = NSRange(location: start, length: end - start)
            let text = Self.clean(attributed.attributedSubstring(from: range).string)
            guard !text.isEmpty else { continue }
            let attrs = attributed.attributes(at: start, effectiveRange: nil)
            var run = DocumentRun(text)
            if let font = font(attrs[fontKey]) {
                let traits = CTFontGetSymbolicTraits(font)
                let name = CTFontCopyPostScriptName(font) as String
                let lower = name.lowercased()
                run.bold = traits.contains(.traitBold) || lower.contains("bold") || lower.contains("heavy") || lower.contains("black")
                run.italic = traits.contains(.traitItalic) || lower.contains("italic") || lower.contains("oblique")
                run.fontSize = (CTFontGetSize(font) * 100).rounded() / 100
                if !name.hasPrefix(".") { run.fontName = PDFContentScan.family(for: name) }
            }
            if let real = fonts.first(where: { NSLocationInRange(start, $0.0) })?.1 {
                let name = PDFContentScan.strippedName(real)
                run.bold = PDFContentScan.isBold(name)
                run.italic = PDFContentScan.isItalic(name)
                run.fontName = PDFContentScan.family(for: name)
            }
            if let color = attrs[colorKey] as? NSColor { run.colorHex = RichStyle.hex(of: color) }
            // 띄어쓰기·문장부호만 다른 글꼴로 나온 조각(한글 사이 공백이 대체 글꼴로 찍힌 것)은 앞 조각에 붙인다
            var looser = run
            looser.fontName = runs.last?.fontName
            if let last = runs.last, last.sameStyle(as: run) || (last.sameStyle(as: looser) && text.allSatisfy({ $0.isWhitespace || $0.isPunctuation })) {
                runs[runs.count - 1].text += text
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    /// 가장 많은 글자에 쓰인 글자 크기
    private static func dominantSize(of line: PDFSelection) -> CGFloat? {
        guard let attributed = line.attributedString, attributed.length > 0 else { return nil }
        var counts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(fontKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            // 0.5pt 단위로 반올림하면 축소한 쪽에서 크기 비율이 달라진다 → 0.01pt까지만
            if let font = font(value) { counts[(CTFontGetSize(font) * 100).rounded() / 100, default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// 줄바꿈·제어 문자 정리(PDF는 줄 끝에 \r\n이나 이상한 문자를 달고 나오기도 한다)
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .control) || scalar == "\t"
        }.map(Character.init)).replacingOccurrences(of: "\t", with: " ")
    }

    // MARK: 문단으로 다시 짜기 (화면·PDF 없이 테스트하는 부분)

    /// 가장 많은 글자에 쓰인 글자 크기. 3% 안쪽으로 비슷한 크기는 한 무리로 본다(절대 단위로 반올림하지 않아서
    /// 같은 내용을 축소해 넣어도 같은 무리가 나온다).
    static func bodySize(of lines: [PDFLine]) -> CGFloat {
        let sized = lines.filter { $0.fontSize > 0 }.map { ($0.fontSize, $0.text.count) }.sorted { $0.0 < $1.0 }
        guard !sized.isEmpty else { return 11 }
        var best: (weight: Int, sum: CGFloat) = (0, 0)
        var group: (start: CGFloat, weight: Int, sum: CGFloat)?
        for (size, count) in sized {
            if let g = group, size <= g.start * 1.03 {
                group = (g.start, g.weight + count, g.sum + size * CGFloat(count))
            } else {
                if let g = group, g.weight > best.weight { best = (g.weight, g.sum) }
                group = (size, count, size * CGFloat(count))
            }
        }
        if let g = group, g.weight > best.weight { best = (g.weight, g.sum) }
        return best.weight > 0 ? best.sum / CGFloat(best.weight) : sized[sized.count / 2].0
    }

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！", "…", ":", "："]
    private static let listMarker = try! NSRegularExpression(
        pattern: #"^\s*([•·▪‣◦●○■□\-–—*]|\d{1,3}[.)]|\(\d{1,3}\)|\[\d{1,3}\]|[①-⑳]|[가-하][.)]|[a-zA-Z][.)])\s+"#
    )
    private static let pageNumber = try! NSRegularExpression(pattern: #"^\s*[-–—]?\s*\d{1,4}\s*[-–—]?\s*$"#)

    static func endsSentence(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while let last = trimmed.last, "\"”’')]」』".contains(last) { trimmed.removeLast() }
        return trimmed.last.map { sentenceEnders.contains($0) } ?? false
    }

    static func isListItem(_ text: String) -> Bool {
        listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 쪽 위·아래 가장자리에 혼자 있는 숫자(쪽 번호)
    static func isPageNumber(_ line: PDFLine) -> Bool {
        let text = line.text
        guard pageNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        return line.top < line.pageHeight * 0.1 || line.bottom > line.pageHeight * 0.9
    }

    // MARK: 한글 줄 잇기

    /// 한글은 단어 중간에서도 줄이 바뀐다(맥 기본 조판, 한글 프로그램의 "글자 단위" 줄 나눔).
    /// 그래서 줄을 이을 때 띄어 쓸지는 이 문서 안의 근거로 정한다.
    struct KoreanSpacing {
        /// 줄 가운데에 나온 낱말(줄 끝·줄 머리 조각은 잘린 말일 수 있어 뺀다)
        var vocabulary: Set<String> = []
        /// 근거가 없을 때: 이 문서는 한글을 글자 단위로 줄바꿈하는가
        var wrapsMidWord = false

        /// 앞말에 붙는 조사·어미. 줄 머리에 이것만 있으면 붙여 쓴다.
        /// 혼자 낱말로도 흔한 것(이, 가, 나, 한, 할, 해, 만, 고…)은 뺐다.
        static let attaching: Set<String> = [
            "은", "는", "을", "를", "의", "에", "에서", "에게", "께", "께서", "로", "으로", "와", "과", "도",
            "까지", "부터", "보다", "처럼", "마다", "조차", "라도", "이나", "이며", "이고", "이다", "이에요", "예요",
            "다", "요", "죠", "니다", "습니다", "입니다", "합니다", "됩니다", "했다", "한다", "된다", "였다", "었다", "았다", "겠다",
            "였고", "었고", "았고", "하고", "하며", "하는", "되는", "됐다", "에요", "이라", "라고", "이라고", "들", "들이", "들은", "들을", "들의",
        ]

        /// true = 띄어 씀, false = 붙여 씀, nil = 근거 없음
        func decide(head: String, tail: String) -> Bool? {
            if vocabulary.contains(head + tail) { return false }
            if Self.attaching.contains(tail) { return false }
            if vocabulary.contains(head) && vocabulary.contains(tail) { return true }
            return nil
        }

        func needsSpace(head: String, tail: String) -> Bool {
            decide(head: head, tail: tail) ?? !wrapsMidWord
        }
    }

    static func isHangul(_ character: Character) -> Bool {
        guard let v = character.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
    }

    /// 줄 끝의 한글 조각(“셔터 속도” → “속도”). 끝이 한글이 아니면 nil.
    static func trailingHangul(_ text: String) -> String? {
        let trimmed = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let piece = String(trimmed.reversed().prefix(while: isHangul).reversed())
        return piece.isEmpty ? nil : piece
    }

    /// 줄 머리의 한글 조각(“다. The…” → “다”). 머리가 한글이 아니면 nil.
    static func leadingHangul(_ text: String) -> String? {
        let trimmed = text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        let piece = String(trimmed.prefix(while: isHangul))
        return piece.isEmpty ? nil : piece
    }

    /// 한글이 들어간 낱말들(문장부호 뗌)
    static func hangulWords(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            .filter { $0.contains(where: isHangul) }
    }

    static func koreanSpacing(for lines: [PDFLine], body: CGFloat, columnWidth: CGFloat) -> KoreanSpacing {
        var spacing = KoreanSpacing()
        for line in lines {
            let words = hangulWords(in: line.text)
            if words.count >= 3 { spacing.vocabulary.formUnion(words.dropFirst().dropLast()) }
        }
        // 근거가 있는 이음새로 이 문서의 줄바꿈 방식을 정한다
        var midWord = 0, atSpace = 0
        for (a, b) in zip(lines, lines.dropFirst()) where a.page == b.page {
            guard let head = trailingHangul(a.text), let tail = leadingHangul(b.text) else { continue }
            switch spacing.decide(head: head, tail: tail) {
            case false?: midWord += 1
            case true?: atSpace += 1
            case nil: break
            }
        }
        if midWord + atSpace > 0 {
            spacing.wrapsMidWord = midWord >= atSpace
        } else {
            // 근거가 하나도 없으면 모양으로: 글자 단위로 줄을 바꾸는 문서는 줄이 거의 늘 꽉 찬다
            let interior = zip(lines, lines.dropFirst()).filter { $0.page == $1.page }.map(\.0)
            let full = interior.filter { $0.width >= columnWidth - body * 1.5 }.count
            spacing.wrapsMidWord = interior.count >= 3 && Double(full) / Double(interior.count) >= 0.9
        }
        return spacing
    }

    /// 앞 줄과 다음 줄을 잇는다: 영어 하이픈 줄넘김은 붙이고, 중국어·일본어 글자끼리는 띄우지 않고,
    /// 한글끼리는 `spacing`의 판단을 따른다.
    /// `beside`: 같은 높이에 나란히 놓인 조각(칸·카드)을 잇는다 → 줄바꿈이 아니니 늘 띄어 쓴다.
    static func join(_ previous: inout [DocumentRun], with next: [DocumentRun], spacing: KoreanSpacing = KoreanSpacing(), beside: Bool = false) {
        guard let lastRun = previous.last, var nextFirst = next.first else { previous += next; return }
        let prevText = lastRun.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        previous[previous.count - 1].text = prevText
        nextFirst.text = nextFirst.text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        var rest = next
        rest[0] = nextFirst

        let a = prevText.last, b = nextFirst.text.first
        if beside {
            previous[previous.count - 1].text += " "
        } else if let a, let b, a == "-", prevText.dropLast().last?.isLetter == true, b.isLowercase {
            previous[previous.count - 1].text.removeLast()            // inter-\nnational → international
        } else if let a, let b, isCJK(a), isCJK(b) {
            // 붙여 쓴다
        } else if let head = trailingHangul(previous.map(\.text).joined()), let tail = leadingHangul(rest.map(\.text).joined()),
                  !spacing.needsSpace(head: head, tail: tail) {
            // 단어 중간에서 바뀐 줄: 붙여 쓴다 (속도 + 는 → 속도는)
        } else {
            previous[previous.count - 1].text += " "
        }
        for run in rest {
            if let last = previous.last, last.sameStyle(as: run) {
                previous[previous.count - 1].text += run.text
            } else {
                previous.append(run)
            }
        }
    }

    /// 한글은 띄어쓰기를 하니 제외. 한자·가나만.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    // MARK: 문단 짜기

    /// "표 5. …", "그림 2. …" 같은 표·그림 제목 줄
    private static let captionPattern = try! NSRegularExpression(
        pattern: #"^\s*(표|그림|도표|도판|사진|Table|Figure|Fig\.|Chart)\s*\d+(\s*[-.]\s*\d+)?\s*[.:)]"#, options: [.caseInsensitive]
    )

    static func isCaption(_ text: String) -> Bool {
        captionPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 줄들을 문단·표·그림 덩어리로 다시 짠다. `raster`를 주면 그 쪽을 그려서 그래프 영역을 그림으로 잘라 낸다.
    static func assemble(_ input: [PDFLine], raster: ((Int) -> PageRaster?)? = nil) -> [DocumentParagraph] {
        var margins: DocumentMargins?
        return assemble(input, rules: [], margins: &margins, raster: raster)
    }

    /// 문단 하나가 PDF에서 놓였던 자리(문단 사이 간격·구분선을 나중에 맞출 때 쓴다)
    private struct Placement {
        var index: Int
        var page: Int
        /// 마지막 줄이 놓인 쪽(쪽을 넘어 이어진 문단이면 page와 다르다)
        var lastPage: Int
        var firstTop: CGFloat
        var lastTop: CGFloat
        var lastBottom: CGFloat
        var size: CGFloat
        var lineSpacing: CGFloat?
        var shaped: Bool
    }

    /// `rules`: 쪽 안의 가로 구분선(문단 위·아래 선으로 붙인다). `margins`: 본문 글이 놓인 자리에서 잰 쪽 여백을 돌려준다.
    /// 정렬(가운데·오른쪽·양쪽)·좌우 들여쓰기·줄 간격·문단 사이 간격도 줄들이 놓인 자리에서 잰다(여러 단으로 짠 쪽은 빼고).
    static func assemble(_ input: [PDFLine], rules: [PDFRule], margins: inout DocumentMargins?,
                         raster: ((Int) -> PageRaster?)? = nil) -> [DocumentParagraph] {
        // 쪽 번호: 쪽 위·아래 가장자리에서 그 높이에 혼자 있는 숫자(나란히 다른 글이 있으면 성적 카드 같은 내용이다)
        let all = input.enumerated().filter { index, line in
            guard isPageNumber(line) else { return true }
            let mid = (line.top + line.bottom) / 2
            return input.enumerated().contains { other, o in
                other != index && o.page == line.page && mid >= o.top && mid <= o.bottom
            }
        }.map(\.element)
        guard !all.isEmpty else { return [] }
        let body = bodySize(of: all)
        let items = PDFLayout.flow(all, body: body, raster: raster)
        let lines = items.compactMap { item -> PDFLine? in if case .line(let line) = item { line } else { nil } }
        // 글자 크기 비교는 본문 크기에 대한 비율로(축소한 쪽에서도 같게)
        func sameSize(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < body * 0.06 }

        // 같은 크기 본문 줄 사이의 보통 간격(아래쪽 30% 값). 줄이 몇 개 없으면 글자 크기로 어림한다.
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where a.page == b.page && sameSize(a.fontSize, body) && sameSize(b.fontSize, body) {
            let gap = b.top - a.bottom
            if gap > -body * 0.2 { gaps.append(gap) }
        }
        gaps.sort()
        let typicalGap = gaps.count >= 3 ? gaps[gaps.count * 3 / 10] : body * 0.35
        let bigGap = max(typicalGap * 1.8, typicalGap + body * 0.45)
        // 문장이 끝난 뒤라면 이 정도만 벌어져도 문단 사이로 본다
        let looseGap = max(typicalGap * 1.5, typicalGap + body * 0.15)

        // 단 너비: 본문 줄 너비의 90% 지점(“짧은 줄”을 판단하는 기준)
        let widths = lines.filter { sameSize($0.fontSize, body) }.map(\.width).sorted()
        let columnWidth = widths.isEmpty ? (lines.map(\.width).max() ?? 0) : widths[Int(Double(widths.count - 1) * 0.9)]
        let spacing = koreanSpacing(for: lines, body: body, columnWidth: columnWidth)

        // 본문 단의 왼쪽·오른쪽 끝: 여러 단으로 짠 쪽은 빼고, 본문 크기의 긴 줄들로 잰다
        var multiColumnPages = Set<Int>()
        for page in Set(all.map(\.page)) {
            let pageLines = all.filter { $0.page == page }
            if PDFLayout.isMultiColumn(Array(pageLines.indices), in: pageLines, body: body) { multiColumnPages.insert(page) }
        }
        let wide = lines.filter { !multiColumnPages.contains($0.page) && sameSize($0.fontSize, body) && $0.width >= columnWidth * 0.5 }
        let columnLeft = wide.map(\.minX).min() ?? 0
        let columnRight = wide.map { $0.minX + $0.width }.max() ?? 0
        let canShape = !wide.isEmpty && columnRight - columnLeft > body * 10
        var placements: [Placement] = []
        var currentLines: [PDFLine] = []

        /// 줄들이 놓인 자리로 정렬·들여쓰기·줄 간격을 잰다
        func shape(_ paragraph: inout DocumentParagraph, lines all: [PDFLine]) -> Bool {
            // 쪽을 넘어간 문단은 첫 쪽에 놓인 줄로 잰다
            guard canShape, let first = all.first, !multiColumnPages.contains(first.page) else { return false }
            let group = all.filter { $0.page == first.page }
            let snap = { (v: CGFloat) -> CGFloat in abs(v) < body * 0.3 ? 0 : (v * 10).rounded() / 10 }
            let lefts = group.map(\.minX), rights = group.map { $0.minX + $0.width }
            // 가운데 정렬: 줄마다 왼쪽·오른쪽 빈 곳이 같다(내어쓴 문단처럼 한쪽만 들어간 줄이 있으면 아니다)
            let centered = group.allSatisfy { abs(($0.minX - columnLeft) - (columnRight - $0.minX - $0.width)) < body * 1.2 }
                && group.contains { $0.minX - columnLeft > body }
            if group.count == 1 {
                let left = lefts[0] - columnLeft, right = columnRight - rights[0]
                if centered && left > body * 2 {
                    paragraph.alignment = .center
                } else if right < body * 0.6 && left > body * 2 {
                    paragraph.alignment = .right
                } else {
                    paragraph.alignment = .left
                    paragraph.leftIndent = max(0, snap(left))
                }
            } else {
                let rest = lefts.dropFirst()
                let leftEdge = rest.min()!
                let maxRight = rights.max()!
                let spread = (lefts.max()! - lefts.min()!)
                if centered {
                    paragraph.alignment = .center
                } else if spread > body * 2 && rights.allSatisfy({ maxRight - $0 < body * 0.6 }) && columnRight - maxRight < body * 0.6 {
                    paragraph.alignment = .right
                } else {
                    let full = rights.dropLast().allSatisfy { maxRight - $0 < body * 0.6 }
                    paragraph.alignment = full ? .justify : .left
                    paragraph.leftIndent = max(0, snap(leftEdge - columnLeft))
                    paragraph.firstLineIndent = snap(lefts[0] - leftEdge)
                    // 꽉 찬 줄이 없으면 오른쪽 끝을 알 수 없다: 왼쪽만큼 들여 썼다고 본다(다음 낱말이 밀려나지 않게 더 좁히지는 않는다)
                    let right = max(0, snap(columnRight - maxRight))
                    paragraph.rightIndent = full ? right : min(right, paragraph.leftIndent)
                }
                let steps = zip(group, group.dropFirst()).map { $1.top - $0.top }
                let average = steps.reduce(0, +) / CGFloat(steps.count)
                paragraph.lineSpacing = min(max((average / max(first.fontSize, 1) * 100).rounded() / 100, 0.8), 3)
            }
            return true
        }

        var paragraphs: [DocumentParagraph] = []
        var current: [DocumentRun] = []
        var currentSize: CGFloat = 0
        var currentLeft: CGFloat = 0
        var currentBreak = false
        var lineCount = 0
        var previous: PDFLine?
        // 쪽이 바뀌었는데 아직 새 덩어리가 시작되지 않았다(문장이 쪽을 넘어 이어진 경우 다음 덩어리에 단다)
        var pendingBreak = false
        var lastPage: Int?

        func flush() {
            guard !current.isEmpty else { return }
            var runs = current
            runs[0].text = runs[0].text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
            runs[runs.count - 1].text = runs[runs.count - 1].text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            runs.removeAll { $0.text.isEmpty }
            current = []
            let group = currentLines
            currentLines = []
            guard !runs.isEmpty else { pendingBreak = pendingBreak || currentBreak; lineCount = 0; return }
            let text = runs.map(\.text).joined()
            var level: Int?
            if currentSize >= body * 1.6, text.count <= 120 { level = 1 }
            else if currentSize >= body * 1.2, text.count <= 120 { level = 2 }
            else if lineCount == 1, runs.allSatisfy(\.bold), text.count <= 60, !endsSentence(text), !isListItem(text),
                    !isCaption(text) { level = 3 }   // 표·그림 제목은 굵은 보통 문단으로 둔다
            if level != nil {
                // 제목도 PDF의 글자 크기 그대로(쓰는 쪽이 제목 크기로 키우지 않게)
                for i in runs.indices where runs[i].fontSize == nil { runs[i].fontSize = (currentSize * 100).rounded() / 100 }
            }
            var paragraph = DocumentParagraph(runs: runs, headingLevel: level, pageBreakBefore: currentBreak)
            let shaped = shape(&paragraph, lines: group)
            if let first = group.first, let last = group.last {
                placements.append(Placement(index: paragraphs.count, page: first.page, lastPage: last.page, firstTop: first.top, lastTop: last.top,
                                            lastBottom: last.bottom, size: first.fontSize, lineSpacing: paragraph.lineSpacing, shaped: shaped))
            }
            paragraphs.append(paragraph)
            lineCount = 0
        }

        for item in items {
            if let lastPage, item.page != lastPage { pendingBreak = true }
            lastPage = item.page
            guard case .line(let line) = item else {
                if case .block(var block, _) = item {
                    flush()
                    block.pageBreakBefore = pendingBreak
                    pendingBreak = false
                    paragraphs.append(block)
                    previous = nil
                }
                continue
            }
            var startNew = previous == nil
            if let prev = previous {
                let prevEnds = endsSentence(prev.text)
                let sizeChanged = abs(line.fontSize - prev.fontSize) > body * 0.07
                // 굵은 짧은 한 줄 다음에 보통 글이 오면 그 줄은 소제목이다
                let boldLabel = prev.runs.allSatisfy(\.bold) && !line.runs.allSatisfy(\.bold)
                    && prev.text.count <= 60 && !prevEnds && prev.width < columnWidth * 0.7
                // 문장이 끝난 뒤 굵은 조각으로 시작하는 줄(줄 전체가 굵은 건 아님) = 굵은 첫 문장으로 여는 새 문단
                let boldOpening = prevEnds && line.runs.count > 1 && line.runs[0].bold
                    && letterCount(line.runs[0].text) >= 2 && !line.runs.allSatisfy(\.bold)
                // 목록 항목으로 시작하는 줄. 숫자 마커("420. …")는 앞 줄이 꽉 찬 문장 중간이면 아니다(줄 머리로 넘어온 숫자일 수 있다)
                let numbered = line.text.trimmingCharacters(in: .whitespaces).first?.isNumber == true
                let listStart = isListItem(line.text) && (!numbered || prevEnds || isListItem(prev.text) || prev.width < columnWidth * 0.7)
                // 줄 전체 글자색이 바뀌었다(색 있는 소제목 다음 검은 본문 같은 것)
                let prevColors = Set(prev.runs.map(\.colorHex)), lineColors = Set(line.runs.map(\.colorHex))
                let colorChanged = prevColors.count == 1 && lineColors.count == 1 && prevColors != lineColors
                if line.page != prev.page {
                    startNew = prevEnds || sizeChanged || boldLabel || boldOpening || colorChanged || listStart
                } else {
                    let gap = line.top - prev.bottom
                    let shortPrev = prev.width < columnWidth * 0.7
                    let indented = line.minX - currentLeft > body * 1.2
                    // 내어쓴 항목(참고문헌 등)이 끝나고 다음 항목이 다시 왼쪽 끝에서 시작한다
                    let outdented = prevEnds && prev.minX - line.minX > body * 0.8
                    startNew = sizeChanged
                        || gap > bigGap
                        || boldLabel
                        || boldOpening
                        || colorChanged
                        || listStart
                        || outdented
                        || (prevEnds && (shortPrev || indented || gap > looseGap))
                }
            }
            if startNew {
                flush()
                currentLines = [line]
                current = line.runs
                currentSize = line.fontSize
                currentLeft = line.minX
                currentBreak = pendingBreak
                pendingBreak = false
            } else {
                let prev = previous!
                let mid = (line.top + line.bottom) / 2
                let beside = line.page == prev.page && mid >= prev.top && mid <= prev.bottom && line.minX >= prev.minX + prev.width
                join(&current, with: line.runs, spacing: spacing, beside: beside)
                currentLines.append(line)
                // 문단이 쪽을 넘어 이어졌다: 쪽은 이 문단 안에서 넘어가니 다음 덩어리 앞에서 또 넘기지 않는다
                if line.page != prev.page { pendingBreak = false }
            }
            lineCount += 1
            previous = line
        }
        flush()
        if canShape { arrange(&paragraphs, placements: placements, rules: rules, body: body, left: columnLeft, right: columnRight,
                              pageWidth: nil, lines: lines, margins: &margins) }
        return paragraphs
    }

    /// 문단 사이 간격·쪽 여백·구분선을 PDF에 놓였던 자리대로 맞춘다.
    /// 간격은 "앞 문단 마지막 줄 위 → 이 문단 첫 줄 위" 거리에서 앞 줄 높이(글자 크기 × 줄 간격)를 뺀 만큼.
    private static func arrange(_ paragraphs: inout [DocumentParagraph], placements: [Placement], rules: [PDFRule], body: CGFloat,
                                left: CGFloat, right: CGFloat, pageWidth: CGFloat?, lines: [PDFLine], margins: inout DocumentMargins?) {
        guard !placements.isEmpty else { return }
        // 한 줄짜리 문단의 줄 간격: 이 문서 본문의 보통 줄 간격
        let spacings = placements.compactMap(\.lineSpacing).sorted()
        let typical = spacings.isEmpty ? 1.6 : spacings[spacings.count / 2]
        var shapedPlacements = placements
        for i in shapedPlacements.indices where shapedPlacements[i].shaped && shapedPlacements[i].lineSpacing == nil {
            shapedPlacements[i].lineSpacing = typical
            paragraphs[shapedPlacements[i].index].lineSpacing = typical
        }
        // 쪽 여백: 본문 단 왼쪽·오른쪽, 쪽마다 첫 줄 위·마지막 줄 아래 중 가장 좁은 곳
        let pageHeight = lines.first?.pageHeight ?? 842
        let tops = Dictionary(grouping: lines, by: \.page).mapValues { $0.map(\.top).min()! }
        let bottoms = Dictionary(grouping: lines, by: \.page).mapValues { $0.map(\.bottom).max()! }
        let marginTop = max(tops.values.min() ?? 56, 14)
        let marginBottom = max(pageHeight - (bottoms.values.max() ?? pageHeight - 56) - 6, 14)
        let pageWidthGuess = pageWidth ?? (left + right)  // 단이 가운데 놓였다고 보고 오른쪽 여백 = 왼쪽 여백
        margins = DocumentMargins(top: marginTop, left: max(left, 14), bottom: marginBottom, right: max(pageWidthGuess - right, 14))

        for (n, place) in shapedPlacements.enumerated() where place.shaped {
            var before: CGFloat
            let previous = n > 0 ? shapedPlacements[n - 1] : nil
            let afterBlock = place.index > 0 && (previous == nil || previous!.index != place.index - 1)
            if afterBlock {
                before = body * 0.6                         // 표·그림 다음
            } else if let previous, previous.lastPage == place.page {
                let height = previous.size * (previous.lineSpacing ?? typical)
                before = place.firstTop - previous.lastTop - height
            } else {
                before = place.firstTop - marginTop        // 쪽 맨 위 문단
            }
            paragraphs[place.index].spaceBefore = max(0, (before * 10).rounded() / 10)
            paragraphs[place.index].spaceAfter = 0
        }

        // 구분선: 글 줄과 겹치지 않는(밑줄이 아닌) 넉넉한 가로줄을 위 문단의 아래 선으로, 위 문단이 없으면 아래 문단의 위 선으로
        let columnWidth = right - left
        for rule in rules where rule.maxX - rule.minX >= columnWidth * 0.4 {
            let crossesText = lines.contains { $0.page == rule.page && rule.y >= $0.top - 1 && rule.y <= $0.bottom + 2
                && rule.maxX > $0.minX && rule.minX < $0.minX + $0.width }
            guard !crossesText else { continue }
            let fullWidth = rule.minX <= left + body && rule.maxX >= right - body
            let above = shapedPlacements.last { $0.shaped && $0.lastPage == rule.page && $0.lastBottom <= rule.y + 1 }
            let below = shapedPlacements.first { $0.shaped && $0.page == rule.page && $0.firstTop >= rule.y - 1 }
            if let above, below == nil || below!.index == above.index + 1 {
                let gap = max(0, rule.y - above.lastBottom)
                paragraphs[above.index].ruleBelow = DocumentRule(colorHex: rule.colorHex, width: rule.width, gap: gap, fullWidth: fullWidth)
                if let below, let space = paragraphs[below.index].spaceBefore {
                    paragraphs[below.index].spaceBefore = max(0, space - gap - rule.width)
                }
            } else if let below {
                let gap = max(0, below.firstTop - rule.y)
                paragraphs[below.index].ruleAbove = DocumentRule(colorHex: rule.colorHex, width: rule.width, gap: gap, fullWidth: fullWidth)
                if let space = paragraphs[below.index].spaceBefore { paragraphs[below.index].spaceBefore = max(0, space - gap - rule.width) }
            }
        }
    }
}
