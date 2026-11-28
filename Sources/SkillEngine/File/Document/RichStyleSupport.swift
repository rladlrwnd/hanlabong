import AppKit
import Foundation

// 문서 틀의 새 필드(문단 모양·글자 모양·표 모양·쪽 여백·머리글/꼬리글)를 화면 글(NSAttributedString)과
// html·md·rtf·pdf 쓰기에 옮기는 공용 도구. RichDocumentWriter(쓰기)와 RichDocumentEditing(되돌리기)이 같이 쓴다.

public extension NSAttributedString.Key {
    /// 사용자가 정한 글꼴 이름(그 글꼴이 이 맥에 없어 다른 글꼴로 그려져도 되돌릴 때 이름을 잃지 않게)
    static let hanlabongFontName = NSAttributedString.Key("HanlabongFontName")
    /// "이 문단은 본문이다" 표시: 크기가 커도 제목으로 짐작하지 않게(writer가 본문 글에 단다)
    static let hanlabongPlainBody = NSAttributedString.Key("HanlabongPlainBody")
    /// 문단 위·아래 구분선(DocumentRule). PDF로 그릴 때 선을 긋는다
    static let hanlabongRuleAbove = NSAttributedString.Key("HanlabongRuleAbove")
    static let hanlabongRuleBelow = NSAttributedString.Key("HanlabongRuleBelow")
}

enum RichStyle {
    /// 첨자 글자는 원래 크기의 이 비율
    static let scriptScale: CGFloat = 0.7
    static let defaultBodySize: CGFloat = 11

    // MARK: 크기 · 글꼴

    /// 제목 크기: 본문 11pt일 때 22 / 17 / 13, 본문이 다르면 같은 비율로
    static func headingSize(level: Int?, body: CGFloat) -> CGFloat {
        switch level {
        case 1?: return body * 22 / 11
        case 2?: return body * 17 / 11
        case 3?: return body * 13 / 11
        default: return body
        }
    }

    static func sanitizedBodySize(_ size: CGFloat?) -> CGFloat {
        guard let size, size.isFinite, size >= 4, size <= 200 else { return defaultBodySize }
        return size
    }

    /// 글꼴 이름(가족 이름 우선, 없으면 PostScript 이름)으로 글꼴을 만든다. 없으면 시스템 글꼴
    static func font(name: String?, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        if let name, !name.isEmpty {
            let manager = NSFontManager.shared
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            if let found = manager.font(withFamily: name, traits: traits, weight: bold ? 9 : 5, size: size) { return found }
            if var found = NSFont(name: name, size: size) {
                if bold { found = manager.convert(found, toHaveTrait: .boldFontMask) }
                if italic { found = manager.convert(found, toHaveTrait: .italicFontMask) }
                return found
            }
            // 이 맥에 없는 글꼴: 같은 계열의 맥 글꼴로(바탕·명조 → 애플명조, 돋움·고딕 → 애플 SD 산돌고딕, 라틴 세리프 → Times New Roman)
            if let stand = standIn(for: name), stand != name { return font(name: stand, size: size, bold: bold, italic: italic) }
        }
        return RichDocumentWriter.font(size: size, bold: bold, italic: italic)
    }

    /// 없는 글꼴 대신 쓸 맥 글꼴(대신할 게 없으면 nil = 시스템 글꼴)
    static func standIn(for name: String) -> String? {
        let lower = name.lowercased()
        let korean = name.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        switch PDFContentScan.kind(of: name) {
        case .serif: return korean || lower.contains("batang") || lower.contains("myungjo") || lower.contains("myeongjo") ? "AppleMyungjo" : "Times New Roman"
        case .mono: return "Menlo"
        case .sans: return korean || ["gothic", "dotum", "gulim", "malgun"].contains(where: lower.contains) ? "Apple SD Gothic Neo" : nil
        }
    }

    // MARK: 색

    static func color(hex: String?) -> NSColor? {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// 글자색 → "RRGGBB". 검정(기본)과 시스템이 알아서 바꾸는 색(라벨 색 등)은 nil
    static func hex(of color: NSColor?) -> String? {
        guard let color, color.type == .componentBased, let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.01 else { return nil }
        func byte(_ x: CGFloat) -> Int { min(255, max(0, Int((x * 255).rounded()))) }
        let r = byte(rgb.redComponent), g = byte(rgb.greenComponent), b = byte(rgb.blueComponent)
        if r == 0, g == 0, b == 0 { return nil }
        return String(format: "%02X%02X%02X", r, g, b)
    }

    // MARK: 문단 모양

    static func tabStops() -> [NSTextTab] { (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 72) } }

    static func defaultSpaceAfter(heading: Bool) -> CGFloat { heading ? 6 : 8 }
    static func defaultSpaceBefore(heading: Bool) -> CGFloat { heading ? 10 : 0 }
    static let defaultLineGap: CGFloat = 3

    static func paragraphStyle(for p: DocumentParagraph, heading: Bool) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        // 탭으로 나눈 글이 칸처럼 보이게 넓은 탭 간격(1인치)
        style.tabStops = tabStops()
        style.defaultTabInterval = 72
        switch p.alignment {
        case .left?: style.alignment = .left
        case .center?: style.alignment = .center
        case .right?: style.alignment = .right
        case .justify?: style.alignment = .justified
        case nil: break
        }
        let left = max(0, p.leftIndent.isFinite ? p.leftIndent : 0)
        style.headIndent = left
        style.firstLineHeadIndent = max(0, left + (p.firstLineIndent.isFinite ? p.firstLineIndent : 0))
        if p.rightIndent.isFinite, p.rightIndent > 0 { style.tailIndent = -p.rightIndent }
        if let multiple = p.lineSpacing, multiple.isFinite, multiple > 0 {
            style.lineHeightMultiple = multiple
            style.lineSpacing = 0
        } else {
            style.lineSpacing = defaultLineGap
        }
        style.paragraphSpacing = max(0, p.spaceAfter ?? defaultSpaceAfter(heading: heading))
        style.paragraphSpacingBefore = max(0, p.spaceBefore ?? defaultSpaceBefore(heading: heading))
        // 구분선이 차지하는 자리(한글에서도 문단 선은 그만큼 자리를 차지한다)
        if let rule = p.ruleBelow { style.paragraphSpacing += rule.gap + rule.width }
        if let rule = p.ruleAbove { style.paragraphSpacingBefore += rule.gap + rule.width }
        return style
    }

    // MARK: 글자 모양

    static func attributes(for run: DocumentRun, heading: Int?, bodySize: CGFloat, bodyName: String?,
                           style: NSParagraphStyle, marks: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let base = heading != nil ? headingSize(level: heading, body: bodySize) : bodySize
        var size = run.fontSize ?? base
        if !size.isFinite || size < 1 { size = base }
        size = min(size, 400)
        let drawn = run.script != 0 ? size * scriptScale : size
        let name = (run.fontName?.isEmpty == false ? run.fontName : nil) ?? bodyName
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(name: name, size: drawn, bold: run.bold || heading != nil, italic: run.italic),
            .paragraphStyle: style,
            .foregroundColor: color(hex: run.colorHex) ?? NSColor.black,
        ]
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if run.script > 0 { attrs[.baselineOffset] = size * 0.35 }
        else if run.script < 0 { attrs[.baselineOffset] = -size * 0.15 }
        if let name = run.fontName, !name.isEmpty { attrs[.hanlabongFontName] = name }
        if let link = run.linkURL, let url = URL(string: link) { attrs[.link] = url }
        for (key, value) in marks { attrs[key] = value }
        return attrs
    }

    // MARK: 표 모양

    /// 표 칸 하나가 합쳐진 칸에 가려졌는가 + 합친 칸 목록
    struct TableGrid {
        var rows: Int
        var columns: Int
        var spanAt: [Int: DocumentCellSpan] = [:]     // row * 1000 + column
        var covered = Set<Int>()

        init(rows: Int, columns: Int, layout: DocumentTableLayout?) {
            self.rows = rows
            self.columns = columns
            for span in layout?.spans ?? [] {
                guard span.row >= 0, span.column >= 0, span.row < rows, span.column < columns,
                      span.columns >= 1, span.rows >= 1, span.columns > 1 || span.rows > 1 else { continue }
                let cs = min(span.columns, columns - span.column), rs = min(span.rows, rows - span.row)
                // 이미 다른 합친 칸에 가려진 자리는 건너뛴다
                var clash = false
                for r in span.row..<(span.row + rs) { for c in span.column..<(span.column + cs) where covered.contains(r * 1000 + c) || (spanAt[r * 1000 + c] != nil) { clash = true } }
                if clash { continue }
                spanAt[span.row * 1000 + span.column] = DocumentCellSpan(row: span.row, column: span.column, columns: cs, rows: rs)
                for r in span.row..<(span.row + rs) { for c in span.column..<(span.column + cs) where !(r == span.row && c == span.column) { covered.insert(r * 1000 + c) } }
            }
        }

        func span(_ r: Int, _ c: Int) -> DocumentCellSpan? { spanAt[r * 1000 + c] }
        func isCovered(_ r: Int, _ c: Int) -> Bool { covered.contains(r * 1000 + c) }
    }

    /// 칸 너비 비율(%). 열 수와 맞지 않거나 쓸 수 없으면 nil(같은 너비)
    static func columnPercents(_ layout: DocumentTableLayout?, columns: Int) -> [CGFloat]? {
        guard let widths = layout?.columnWidths, widths.count == columns, columns > 0,
              widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let sum = widths.reduce(0, +)
        guard sum > 0 else { return nil }
        return widths.map { $0 / sum * 100 }
    }

    static func headerRows(_ layout: DocumentTableLayout?, rows: Int) -> Int {
        guard let layout else { return min(1, rows) }          // 틀 없는 표는 옛 약속대로 첫 줄이 머리줄
        return min(max(0, layout.headerRows), rows)
    }

    // MARK: 머리글 · 꼬리글 (PDF·RTF)

    static func paragraphsPlainText(_ paragraphs: [DocumentParagraph]) -> [(text: String, alignment: DocumentAlignment?, bold: Bool)] {
        paragraphs.compactMap { p in
            let text = p.runs.map(\.text).joined().replacingOccurrences(of: "\n", with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (text, p.alignment, p.runs.contains(where: \.bold))
        }
    }

    // MARK: HTML · Markdown 조각

    static func css(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
    }

    static func cssIdentifier(_ text: String) -> String {
        let banned = Set("'\"\\<>;{}&".unicodeScalars)
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !banned.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar) { out.append(scalar) }
        return String(out)
    }

    static func safeLink(_ link: String?) -> String? {
        guard let link = link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty else { return nil }
        let lower = link.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("file:") { return nil }
        return link
    }

    /// 문단 모양 → CSS 선언(없으면 빈 글)
    static func paragraphCSS(_ p: DocumentParagraph) -> String {
        var parts: [String] = []
        switch p.alignment {
        case .center?: parts.append("text-align:center")
        case .right?: parts.append("text-align:right")
        case .justify?: parts.append("text-align:justify")
        case .left?: parts.append("text-align:left")
        case nil: break
        }
        if p.leftIndent > 0 { parts.append("margin-left:\(css(p.leftIndent))pt") }
        if p.firstLineIndent != 0 { parts.append("text-indent:\(css(p.firstLineIndent))pt") }
        if let v = p.spaceBefore { parts.append("margin-top:\(css(max(0, v)))pt") }
        if let v = p.spaceAfter { parts.append("margin-bottom:\(css(max(0, v)))pt") }
        if let v = p.lineSpacing, v > 0 { parts.append("line-height:\(css(v))") }
        return parts.joined(separator: ";")
    }

    /// 글자 모양을 입힌 HTML 조각. 제목(`heading`)은 이미 굵으니 `<strong>`을 빼고 크기는 제목 크기 그대로 둔다
    static func htmlRun(_ run: DocumentRun, heading: Bool) -> String {
        var t = RichDocumentWriter.escape(run.text).replacingOccurrences(of: "\n", with: "<br/>")
        var css: [String] = []
        if let hex = run.colorHex, hex.count == 6, UInt32(hex, radix: 16) != nil, hex != "000000" { css.append("color:#\(hex)") }
        if let size = run.fontSize, size > 0 { css.append("font-size:\(RichStyle.css(size))pt") }
        if let name = run.fontName, !cssIdentifier(name).isEmpty { css.append("font-family:'\(cssIdentifier(name))'") }
        if !css.isEmpty { t = "<span style=\"\(css.joined(separator: ";"))\">\(t)</span>" }
        if run.script > 0 { t = "<sup>\(t)</sup>" } else if run.script < 0 { t = "<sub>\(t)</sub>" }
        if run.underline { t = "<u>\(t)</u>" }
        if run.strike { t = "<s>\(t)</s>" }
        if let link = safeLink(run.linkURL) { t = "<a href=\"\(RichDocumentWriter.escape(link))\">\(t)</a>" }
        if run.italic { t = "<em>\(t)</em>" }
        if run.bold, !heading { t = "<strong>\(t)</strong>" }
        return t
    }

    /// 표 → HTML. 틀(layout)이 없으면 옛 모양(첫 줄 머리줄·테두리 있음) 그대로
    static func htmlTable(_ rows: [[String]], layout: DocumentTableLayout?, attributes: String) -> String {
        let columns = rows.map(\.count).max() ?? 1
        let grid = TableGrid(rows: rows.count, columns: columns, layout: layout)
        let header = headerRows(layout, rows: rows.count)
        func row(_ r: Int) -> String {
            let tag = r < header ? "th" : "td"
            var cells = ""
            for c in 0..<columns where !grid.isCovered(r, c) {
                var attrs = ""
                if let span = grid.span(r, c) {
                    if span.columns > 1 { attrs += " colspan=\"\(span.columns)\"" }
                    if span.rows > 1 { attrs += " rowspan=\"\(span.rows)\"" }
                }
                let text = RichDocumentWriter.escape(c < rows[r].count ? rows[r][c] : "").replacingOccurrences(of: "\n", with: "<br/>")
                cells += "<\(tag)\(attrs)>\(text)</\(tag)>"
            }
            return "<tr>\(cells)</tr>"
        }
        var cls = ""
        if layout?.borders == false { cls = " class=\"nb\"" }
        var colgroup = ""
        if let percents = columnPercents(layout, columns: columns) {
            colgroup = "<colgroup>" + percents.map { "<col style=\"width:\(css($0))%\"/>" }.joined() + "</colgroup>"
        }
        let head = header > 0 ? "<thead>" + (0..<header).map(row).joined() + "</thead>" : ""
        let bodyRows = header < rows.count ? "<tbody>" + (header..<rows.count).map(row).joined() + "</tbody>" : ""
        return "<table\(cls)\(attributes)>\(colgroup)\(head)\(bodyRows)</table>"
    }

    /// 마크다운 한 조각: 굵게·기울임은 `**` `*`, 나머지는 html 태그(`<u>` `<sup>` `<sub>`)·`~~`·링크
    static func markdownRun(_ run: DocumentRun, styled: Bool) -> String {
        let chars = Array(run.text)
        guard let first = chars.firstIndex(where: { !$0.isWhitespace }), let last = chars.lastIndex(where: { !$0.isWhitespace }) else { return run.text }
        let lead = String(chars[..<first]), trail = String(chars[(last + 1)...])
        var core = String(chars[first...last])
        if run.script > 0 { core = "<sup>\(core)</sup>" } else if run.script < 0 { core = "<sub>\(core)</sub>" }
        if run.underline { core = "<u>\(core)</u>" }
        if run.strike { core = "~~\(core)~~" }
        if let link = safeLink(run.linkURL) { core = "[\(core)](\(link.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")))" }
        if styled, run.bold || run.italic {
            let mark = run.bold && run.italic ? "***" : run.bold ? "**" : "*"
            core = mark + core + mark
        }
        return lead + core + trail
    }
}
