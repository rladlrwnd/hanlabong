import AppKit
import Foundation

/// 워드·RTF·ODT → PDF를 "모양 그대로" 만든다.
/// 맥의 문서 읽기(NSAttributedString)가 글꼴·크기·굵기·정렬·문단 간격·용지 크기·여백은 살려 주지만 "단 나누기"는 버린다.
/// 그래서 워드 파일(.docx)의 구역 설정(w:sectPr)에서 단 수·단 너비·단 사이를 직접 읽어, 쪽마다 단 개수만큼 글 상자를 이어 붙여 흘린다.
/// (예전 방식은 글만 뽑아 우리 틀에 다시 앉혀서 가로 용지·2단·글꼴이 전부 사라졌다)
public enum LayoutPDF {
    /// 단 하나: 너비와 오른쪽 단 사이(포인트)
    public struct Column: Equatable, Sendable {
        public var width: CGFloat
        public var gap: CGFloat
        public init(width: CGFloat, gap: CGFloat) { self.width = width; self.gap = gap }
    }

    public struct Page: Equatable, Sendable {
        public var size: CGSize
        public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
        public var columns: [Column]

        public static let a4 = Page(size: CGSize(width: 595.3, height: 841.9), top: 72, left: 72, bottom: 72, right: 72, columns: [])

        /// 글이 들어갈 너비(여백을 뺀)
        var bodyWidth: CGFloat { size.width - left - right }
        /// 단이 없으면 한 단
        var resolvedColumns: [Column] { columns.isEmpty ? [Column(width: bodyWidth, gap: 0)] : columns }
    }

    public static let rich: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "wordml"]

    /// 파일 → 모양을 살린 PDF. 못 읽으면 nil(부르는 쪽이 예전 방식으로 간다)
    public static func make(from url: URL) -> Data? {
        var attributes: NSDictionary?
        guard rich.contains(url.pathExtension.lowercased()),
              let text = try? NSAttributedString(url: url, options: [:], documentAttributes: &attributes), text.length > 0 else { return nil }
        let info = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        var page = Page.a4
        if let paper = info[.paperSize] as? NSSize, paper.width > 50, paper.height > 50 { page.size = paper }
        if let v = info[.topMargin] as? CGFloat { page.top = v }
        if let v = info[.leftMargin] as? CGFloat { page.left = v }
        if let v = info[.bottomMargin] as? CGFloat { page.bottom = v }
        if let v = info[.rightMargin] as? CGFloat { page.right = v }
        var body = text
        if url.pathExtension.lowercased() == "docx" {
            page.columns = docxColumns(url, bodyWidth: page.bodyWidth)
            body = applyingDocxLineSpacing(text, url: url)
        }
        return render(body, page: page)
    }

    /// 워드 구역 설정의 단: <w:cols w:num="2" w:space="720" w:equalWidth="0"><w:col w:w="9672" w:space="720"/>…
    /// 단위는 1/20 포인트(twip). 마지막 구역(문서 끝)의 설정을 쓴다.
    static func docxColumns(_ url: URL, bodyWidth: CGFloat) -> [Column] {
        guard let xml = DocumentReaders.zipEntry(url, path: "word/document.xml"),
              let sect = xml.range(of: "<w:sectPr", options: .backwards).map({ String(xml[$0.lowerBound...]) }),
              let colsRange = sect.range(of: #"<w:cols\b[^>]*?(/>|>.*?</w:cols>)"#, options: .regularExpression) else { return [] }
        let cols = String(sect[colsRange])
        func number(_ name: String, in s: String) -> Double? {
            guard let r = s.range(of: "w:\(name)=\"([0-9.]+)\"", options: .regularExpression) else { return nil }
            return Double(s[r].split(separator: "\"")[1])
        }
        let count = Int(number("num", in: cols) ?? 1)
        guard count > 1 else { return [] }
        let space = CGFloat((number("space", in: cols) ?? 720) / 20)
        let each = cols.matches(of: /<w:col\b[^>]*\/>/).map { String($0.output) }
        if !cols.contains("w:equalWidth=\"1\""), each.count == count {
            let list = each.map { Column(width: CGFloat((number("w", in: $0) ?? 0) / 20), gap: CGFloat((number("space", in: $0) ?? 0) / 20)) }
            if list.allSatisfy({ $0.width > 20 }) { return list }
        }
        let width = (bodyWidth - space * CGFloat(count - 1)) / CGFloat(count)
        guard width > 20 else { return [] }
        return (0..<count).map { Column(width: width, gap: $0 == count - 1 ? 0 : space) }
    }

    /// 줄 간격: 맥의 워드 읽기가 "1.5줄" 같은 줄 간격(w:spacing w:line)을 버려서, 문단마다 직접 읽어 다시 입힌다.
    /// auto = 240분의 몇 배, exact = 딱 그 높이, atLeast = 최소 그 높이(단위 1/20pt). 문단에 없으면 문서 기본값.
    /// 워드 문단 수와 읽어 온 문단 수가 다르면(표·글상자 등) 엉뚱한 문단에 입히지 않게 그대로 둔다.
    static func applyingDocxLineSpacing(_ text: NSAttributedString, url: URL) -> NSAttributedString {
        guard let xml = DocumentReaders.zipEntry(url, path: "word/document.xml") else { return text }
        let styles = DocumentReaders.zipEntry(url, path: "word/styles.xml") ?? ""
        func spacing(_ s: Substring) -> (line: Double, rule: String)? {
            guard let tag = s.range(of: #"<w:spacing\b[^>]*\bw:line="[0-9]+"[^>]*/>"#, options: .regularExpression).map({ s[$0] }),
                  let v = tag.range(of: #"w:line="([0-9]+)""#, options: .regularExpression),
                  let line = Double(tag[v].split(separator: "\"")[1]) else { return nil }
            let rule = tag.range(of: #"w:lineRule="([a-zA-Z]+)""#, options: .regularExpression).map { String(tag[$0].split(separator: "\"")[1]) } ?? "auto"
            return (line, rule)
        }
        let defaults = styles.range(of: #"<w:pPrDefault>.*?</w:pPrDefault>"#, options: .regularExpression).flatMap { spacing(styles[$0]) }
        let paragraphs = xml.matches(of: /<w:p\b[^>]*>.*?<\/w:p>|<w:p\b[^>]*\/>/.dotMatchesNewlines()).map { m -> (line: Double, rule: String)? in
            let p = xml[m.range]
            let props = p.range(of: #"<w:pPr>.*?</w:pPr>"#, options: .regularExpression).map { p[$0] } ?? ""
            return spacing(props) ?? defaults
        }
        let string = text.string as NSString
        var ranges: [NSRange] = []
        var at = 0
        while at < string.length {
            let r = string.paragraphRange(for: NSRange(location: at, length: 0))
            ranges.append(r)
            at = NSMaxRange(r)
        }
        guard !paragraphs.isEmpty, ranges.count == paragraphs.count || ranges.count + 1 == paragraphs.count else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        for (range, spec) in zip(ranges, paragraphs) {
            guard let spec, range.length > 0 else { continue }
            let current = (out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
            let style = current.mutableCopy() as! NSMutableParagraphStyle
            switch spec.rule {
            case "exact": style.minimumLineHeight = spec.line / 20; style.maximumLineHeight = spec.line / 20
            case "atLeast": style.minimumLineHeight = spec.line / 20
            default: style.lineHeightMultiple = spec.line / 240
            }
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return out
    }

    /// 글을 쪽 → 단 순서로 흘려서 PDF로. 쪽마다 단 개수만큼 글 상자를 만들어 이어 붙인다.
    public static func render(_ text: NSAttributedString, page: Page) -> Data? {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let columns = page.resolvedColumns
        let height = max(page.size.height - page.top - page.bottom, 50)
        var containers: [NSTextContainer] = []
        // 끝까지 다 담길 때까지 쪽을 늘린다(망가진 문서에서 끝없이 돌지 않게 1000쪽까지)
        while containers.count < 1000 * columns.count {
            for column in columns {
                let box = NSTextContainer(size: CGSize(width: max(column.width, 20), height: height))
                box.lineFragmentPadding = 0
                layout.addTextContainer(box)
                containers.append(box)
            }
            let last = layout.glyphRange(for: containers[containers.count - 1])
            if NSMaxRange(last) >= layout.numberOfGlyphs { break }
        }
        // 뒤쪽의 빈 쪽은 버린다
        var pages = containers.count / columns.count
        while pages > 1 {
            let first = (pages - 1) * columns.count
            if (first..<(first + columns.count)).allSatisfy({ layout.glyphRange(for: containers[$0]).length == 0 }) { pages -= 1 } else { break }
        }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for p in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // 글 배치는 위가 0인 좌표라 뒤집어서 그린다
            ctx.translateBy(x: 0, y: page.size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            var x = page.left
            for (i, column) in columns.enumerated() {
                let container = containers[p * columns.count + i]
                let range = layout.glyphRange(for: container)
                if range.length > 0 {
                    let origin = CGPoint(x: x, y: page.top)
                    layout.drawBackground(forGlyphRange: range, at: origin)
                    layout.drawGlyphs(forGlyphRange: range, at: origin)
                }
                x += column.width + column.gap
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
