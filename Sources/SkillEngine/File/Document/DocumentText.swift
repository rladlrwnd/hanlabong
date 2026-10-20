import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// PDF에서 뽑아 다시 짠 글. Word·텍스트로 쓸 때 같은 모양을 쓴다.
public struct DocumentRun: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false

    public init(_ text: String, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
    }
}

public struct DocumentParagraph: Equatable, Sendable {
    public var runs: [DocumentRun]
    /// 1 = 큰 제목, 2 = 중간 제목, 3 = 굵은 한 줄 제목. 본문은 nil.
    public var headingLevel: Int?

    public init(runs: [DocumentRun], headingLevel: Int? = nil) {
        self.runs = runs
        self.headingLevel = headingLevel
    }

    public var text: String { runs.map(\.text).joined() }
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

    var text: String { runs.map(\.text).joined() }
}

enum PDFTextExtractor {
    static func letterCount(_ text: String) -> Int { text.filter { !$0.isWhitespace }.count }

    /// PDFKit으로 줄 단위 글자·위치·글꼴을 읽고 문단으로 다시 짠다.
    /// `ocr`을 주면 글자가 없는 쪽(스캔한 쪽)은 그 쪽을 그림으로 그려서 글자 인식한 줄을 대신 쓴다.
    static func extract(_ document: PDFDocument, ocr: ((PDFPage, Int) throws -> [PDFLine])? = nil) throws -> ExtractedDocument {
        var lines: [PDFLine] = []
        var rawPages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            if let ocr, letterCount(page.string ?? "") < 3 {
                let recognized = try ocr(page, index)
                lines += recognized
                rawPages.append(recognized.map(\.text).joined(separator: "\n"))
                continue
            }
            rawPages.append(page.string ?? "")
            guard let selection = page.selection(for: bounds) else { continue }
            for line in selection.selectionsByLine() {
                let rect = line.bounds(for: page)
                let runs = Self.runs(of: line)
                let text = runs.map(\.text).joined()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                lines.append(PDFLine(
                    page: index, runs: runs,
                    minX: rect.minX - bounds.minX, top: bounds.maxY - rect.maxY, bottom: bounds.maxY - rect.minY,
                    width: rect.width, fontSize: Self.dominantSize(of: line) ?? rect.height * 0.8,
                    pageHeight: bounds.height
                ))
            }
        }
        let first = document.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractedDocument(
            paragraphs: assemble(lines), rawPages: rawPages, title: title?.isEmpty == false ? title : nil,
            pageSize: first, pageCount: document.pageCount, bodyFontSize: bodySize(of: lines)
        )
    }

    // MARK: 글꼴

    private static let fontKey = NSAttributedString.Key("NSFont")

    private static func font(_ value: Any?) -> CTFont? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return nil }
        return (value as! CTFont)
    }

    /// 한 줄을 굵게·기울임이 같은 조각들로 나눈다
    private static func runs(of line: PDFSelection) -> [DocumentRun] {
        guard let attributed = line.attributedString, attributed.length > 0 else {
            return [DocumentRun(Self.clean(line.string ?? ""))]
        }
        var runs: [DocumentRun] = []
        attributed.enumerateAttribute(fontKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let text = Self.clean(attributed.attributedSubstring(from: range).string)
            guard !text.isEmpty else { return }
            var bold = false, italic = false
            if let font = font(value) {
                let traits = CTFontGetSymbolicTraits(font)
                let name = (CTFontCopyPostScriptName(font) as String).lowercased()
                bold = traits.contains(.traitBold) || name.contains("bold") || name.contains("heavy") || name.contains("black")
                italic = traits.contains(.traitItalic) || name.contains("italic") || name.contains("oblique")
            }
            if let last = runs.last, last.bold == bold, last.italic == italic {
                runs[runs.count - 1].text += text
            } else {
                runs.append(DocumentRun(text, bold: bold, italic: italic))
            }
        }
        return runs
    }

    /// 가장 많은 글자에 쓰인 글자 크기
    private static func dominantSize(of line: PDFSelection) -> CGFloat? {
        guard let attributed = line.attributedString, attributed.length > 0 else { return nil }
        var counts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(fontKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let font = font(value) { counts[(CTFontGetSize(font) * 2).rounded() / 2, default: 0] += range.length }
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

    static func bodySize(of lines: [PDFLine]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[(line.fontSize * 2).rounded() / 2, default: 0] += line.text.count }
        return weights.max { $0.value < $1.value }?.key ?? 11
    }

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！", "…", ":", "："]
    private static let listMarker = try! NSRegularExpression(
        pattern: #"^\s*([•·▪‣◦●○■□\-–—*]|\d{1,3}[.)]|\(\d{1,3}\)|[①-⑳]|[가-하][.)]|[a-zA-Z][.)])\s+"#
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
    static func join(_ previous: inout [DocumentRun], with next: [DocumentRun], spacing: KoreanSpacing = KoreanSpacing()) {
        guard let lastRun = previous.last, var nextFirst = next.first else { previous += next; return }
        let prevText = lastRun.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        previous[previous.count - 1].text = prevText
        nextFirst.text = nextFirst.text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        var rest = next
        rest[0] = nextFirst

        let a = prevText.last, b = nextFirst.text.first
        if let a, let b, a == "-", prevText.dropLast().last?.isLetter == true, b.isLowercase {
            previous[previous.count - 1].text.removeLast()            // inter-\nnational → international
        } else if let a, let b, isCJK(a), isCJK(b) {
            // 붙여 쓴다
        } else if let head = trailingHangul(prevText), let tail = leadingHangul(nextFirst.text),
                  !spacing.needsSpace(head: head, tail: tail) {
            // 단어 중간에서 바뀐 줄: 붙여 쓴다 (속도 + 는 → 속도는)
        } else {
            previous[previous.count - 1].text += " "
        }
        for run in rest {
            if let last = previous.last, last.bold == run.bold, last.italic == run.italic {
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

    static func assemble(_ input: [PDFLine]) -> [DocumentParagraph] {
        let lines = input.filter { !isPageNumber($0) }
        guard !lines.isEmpty else { return [] }
        let body = bodySize(of: lines)

        // 같은 크기 본문 줄 사이의 보통 간격(아래쪽 30% 값). 줄이 몇 개 없으면 글자 크기로 어림한다.
        var gaps: [CGFloat] = []
        for (a, b) in zip(lines, lines.dropFirst()) where a.page == b.page && abs(a.fontSize - body) < 0.6 && abs(b.fontSize - body) < 0.6 {
            let gap = b.top - a.bottom
            if gap > -body * 0.2 { gaps.append(gap) }
        }
        gaps.sort()
        let typicalGap = gaps.count >= 3 ? gaps[gaps.count * 3 / 10] : body * 0.35
        let bigGap = max(typicalGap * 1.8, typicalGap + body * 0.45)

        // 단 너비: 본문 줄 너비의 90% 지점(“짧은 줄”을 판단하는 기준)
        let widths = lines.filter { abs($0.fontSize - body) < 0.6 }.map(\.width).sorted()
        let columnWidth = widths.isEmpty ? (lines.map(\.width).max() ?? 0) : widths[Int(Double(widths.count - 1) * 0.9)]
        let spacing = koreanSpacing(for: lines, body: body, columnWidth: columnWidth)

        var paragraphs: [DocumentParagraph] = []
        var current: [DocumentRun] = []
        var currentSize: CGFloat = 0
        var currentLeft: CGFloat = 0
        var lineCount = 0
        var previous: PDFLine?

        func flush() {
            guard !current.isEmpty else { return }
            var runs = current
            runs[0].text = runs[0].text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
            runs[runs.count - 1].text = runs[runs.count - 1].text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            runs.removeAll { $0.text.isEmpty }
            guard !runs.isEmpty else { current = []; return }
            let text = runs.map(\.text).joined()
            var level: Int?
            if currentSize >= body * 1.6, text.count <= 120 { level = 1 }
            else if currentSize >= body * 1.2, text.count <= 120 { level = 2 }
            else if lineCount == 1, runs.allSatisfy(\.bold), text.count <= 60, !endsSentence(text), !isListItem(text) { level = 3 }
            paragraphs.append(DocumentParagraph(runs: runs, headingLevel: level))
            current = []
            lineCount = 0
        }

        for line in lines {
            var startNew = previous == nil
            if let prev = previous {
                let prevEnds = endsSentence(prev.text)
                let sizeChanged = abs(line.fontSize - prev.fontSize) > 0.75
                // 굵은 짧은 한 줄 다음에 보통 글이 오면 그 줄은 소제목이다
                let boldLabel = prev.runs.allSatisfy(\.bold) && !line.runs.allSatisfy(\.bold)
                    && prev.text.count <= 60 && !prevEnds && prev.width < columnWidth * 0.7
                if line.page != prev.page {
                    startNew = prevEnds || sizeChanged || boldLabel || isListItem(line.text)
                } else {
                    let gap = line.top - prev.bottom
                    let shortPrev = prev.width < columnWidth * 0.7
                    let indented = line.minX - currentLeft > body * 1.2
                    startNew = sizeChanged
                        || gap > bigGap
                        || boldLabel
                        || isListItem(line.text)
                        || (prevEnds && (shortPrev || indented))
                }
            }
            if startNew {
                flush()
                current = line.runs
                currentSize = line.fontSize
                currentLeft = line.minX
            } else {
                join(&current, with: line.runs, spacing: spacing)
            }
            lineCount += 1
            previous = line
        }
        flush()
        return paragraphs
    }
}
