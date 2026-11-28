import Foundation

/// 간단한 HTML 읽기: 제목(h1~h6)·문단·목록·줄바꿈·굵게·기울임에 더해
/// - `<table>` → 표(첫 줄이 머리줄, colspan은 빈 칸으로, 칸 안 문단·`<br>`은 줄바꿈, 안쪽 표는 글로 풀어서)
/// - `<img>` → 그림: src가 data: 주소면 그 자리에서, 아니면 `resolver`(EPUB 안 파일) 또는 html 파일 옆 상대 경로. 크기는 width·height(우리 쓰기 규칙은 pt)
/// - `page-break-before: always`·`break-before: page` → 쪽 나눔
/// 스크립트·스타일은 버린다.
enum HTMLReader {
    static func parse(_ html: String, baseURL: URL? = nil, resolver: ((String) -> Data?)? = nil) -> [DocumentParagraph] {
        var s = html
        for pattern in ["(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?is)<noscript\\b.*?</noscript>", "(?s)<!--.*?-->", "(?is)<head\\b.*?</head>", "(?is)<![a-z][^>]*>", "(?s)<\\?.*?\\?>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let token = try! NSRegularExpression(pattern: "<(/?)([a-zA-Z0-9]+)([^>]*)>|([^<]+)")
        let breakStyle = try! NSRegularExpression(pattern: "(page-break-before|break-before)\\s*:\\s*(always|page|left|right)", options: .caseInsensitive)

        var blocks = ReaderBlocks()
        var runs: [DocumentRun] = []
        var level: Int?
        var bold = 0, italic = 0
        var listDepthOrdered: [Bool] = [], counters: [Int] = []

        // 표 상태(바깥 표 한 겹만 구조로 읽고, 그 안의 표는 글로 푼다)
        var tableDepth = 0
        var rows: [[String]] = []
        var row: [String] = []
        var cell: String?
        var cellSpan = 1
        var tableImages: [DocumentImage] = []

        func flush() {
            let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                var trimmed = runs
                if let first = trimmed.first { trimmed[0].text = String(first.text.drop { $0.isWhitespace }) }
                blocks.text(trimmed.filter { !$0.text.isEmpty }, level: level)
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
        func closeCell() {
            guard let text = cell else { return }
            cell = nil
            guard row.count < ReaderBlocks.maxTableColumns else { cellSpan = 1; return }     // 칸이 끝없이 늘지 않게
            row.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if cellSpan > 1 { row += Array(repeating: "", count: min(cellSpan - 1, 200)) }
            cellSpan = 1
        }
        func closeRow() {
            closeCell()
            if !row.isEmpty { rows.append(row) }
            row = []
        }
        func cellLineBreak() {
            if let text = cell, !text.isEmpty, !text.hasSuffix("\n") { cell = text + "\n" }
        }
        func attribute(_ name: String, in attrs: String) -> String? {
            guard let range = attrs.range(of: "(?i)(?<![\\w-])\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: .regularExpression) else { return nil }
            var value = String(attrs[range])
            value = String(value[value.index(after: value.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
            if let q = value.first, q == "\"" || q == "'" { value = String(value.dropFirst().dropLast()) }
            return value
        }
        func number(_ text: String?) -> Double? {
            guard let text else { return nil }
            let digits = text.prefix { $0.isNumber || $0 == "." }
            return Double(digits)
        }
        func picture(_ attrs: String) -> DocumentImage? {
            guard let raw = attribute("src", in: attrs) else { return nil }
            let source = DocumentReaders.decodeEntities(raw)
            var image: DocumentImage?
            if source.hasPrefix("data:") { image = MarkdownReader.load(source, baseURL: nil) }
            else if let resolver, let data = resolver(source) { image = ReaderImage.image(from: data, size: nil) }
            else { image = MarkdownReader.loadFile(source, baseURL: baseURL) }
            guard var image else { return nil }
            // 그림 크기: width·height 속성(없으면 픽셀 크기의 3/4). 한쪽만 있으면 비율대로
            let w = number(attribute("width", in: attrs)), h = number(attribute("height", in: attrs))
            let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
            if let w, let h, w > 0, h > 0 { image.size = CGSize(width: w, height: h) }
            else if let w, w > 0 { image.size = CGSize(width: w, height: w / ratio) }
            else if let h, h > 0 { image.size = CGSize(width: h * ratio, height: h) }
            return image
        }

        let ns = s as NSString
        for m in token.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 4).location != NSNotFound {
                let text = DocumentReaders.decodeEntities(ns.substring(with: m.range(at: 4)))
                if tableDepth > 0 {
                    if cell != nil { cell! += text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
                } else { add(text) }
                continue
            }
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let tag = ns.substring(with: m.range(at: 2)).lowercased()
            let attrs = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            let wantsBreak = !closing && attrs.lowercased().contains("break")
                && breakStyle.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) != nil

            // ── 표 안
            if tableDepth > 0 {
                switch tag {
                case "table":
                    if closing {
                        tableDepth -= 1
                        if tableDepth == 0 {
                            closeRow()
                            blocks.table(rows)
                            for image in tableImages { blocks.image(image) }
                            rows = []; tableImages = []
                        } else if cell != nil { cell! += "\n" }
                    } else { tableDepth += 1 }
                case "tr":
                    if tableDepth == 1 { closeRow() } else if cell != nil { cell! += "\n" }
                case "td", "th":
                    if tableDepth == 1 {
                        closeCell()
                        if !closing {
                            cell = ""
                            cellSpan = Int(attribute("colspan", in: attrs) ?? "") ?? 1
                        }
                    } else if closing, cell != nil { cell! += "\t" }
                case "br": if cell != nil { cell! += "\n" }
                case "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol":
                    cellLineBreak()
                    if tag == "li", !closing, cell != nil { cell! += "• " }
                case "img":
                    if !closing, let image = picture(attrs) { tableImages.append(image) }
                default: break
                }
                continue
            }

            // ── 쪽 나눔 표시(br 자체에 붙은 것 포함)
            if wantsBreak {
                flush()
                blocks.pendingBreak = true
                if tag == "br" { continue }
            }

            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing { level = min(3, Int(String(tag.last!))!) }
            case "p", "div", "section", "article", "blockquote", "pre", "tr", "header", "footer", "figure", "figcaption", "title":
                flush()
            case "table":
                flush()
                if !closing { tableDepth = 1; rows = []; row = []; cell = nil; tableImages = [] }
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
            case "img":
                guard !closing, let image = picture(attrs) else { break }
                let savedLevel = level
                flush()
                blocks.image(image)
                level = savedLevel
            default: break
            }
            bold = max(bold, 0); italic = max(italic, 0)
        }
        if tableDepth > 0 { closeRow(); blocks.table(rows); for image in tableImages { blocks.image(image) } }
        flush()
        return blocks.paragraphs
    }
}
