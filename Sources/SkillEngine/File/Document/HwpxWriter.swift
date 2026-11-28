import CoreText
import CoreGraphics
import Foundation

/// 한글(.hwpx, OWPML) 쓰기: 문단(정렬·들여쓰기·간격·줄 간격)·제목(크게·굵게)·글자 모양(굵게·기울임·밑줄·취소선·첨자·색·크기·글꼴)·탭·표(칸 너비·합친 칸·머리줄·테두리 없음)·그림·쪽 나눔·
/// 쪽 크기·여백·머리글·꼬리글·쪽 번호. 쪽 크기는 문서가 정한 대로(없으면 A4), 본문은 문서가 정한 대로(없으면 10pt 함초롬바탕).
/// 한글 2014 이후 버전과 한컴독스에서 열린다(공개 규격 KS X 6101).
enum HwpxWriter {
    private static let ns = """
    xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" \
    xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" \
    xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf"
    """

    // MARK: 모양 목록(글자 모양·문단 모양은 쓰는 대로 번호를 매긴다)

    private struct CharKey: Hashable {
        var bold = false, italic = false, underline = false, strike = false
        var script = 0
        var color: String?
        var height = 1000
        var font = 0
        /// 한글·한자·일본 글자에 쓸 글꼴(라틴 전용 글꼴이면 같은 계열의 한글 글꼴)
        var hangul = 0
    }

    /// 문단 위·아래 선
    private struct BorderKey: Hashable {
        var top: Line?
        var bottom: Line?
        struct Line: Hashable { var color: String; var width: String }
    }

    private struct ParaKey: Hashable {
        var align = "JUSTIFY"
        var intent = 0, left = 0, right = 0, prev = 0, next = 800
        var line = 160
        /// 문단 테두리(borderFill 번호, 1 = 없음)와 글자와의 거리
        var border = 1
        var borderTop = 0, borderBottom = 0
        var ignoreMargin = false
    }

    private final class Styles {
        var fonts: [String]
        let bodyHeight: Int
        private(set) var chars: [CharKey] = []
        private(set) var paras: [ParaKey] = []
        private(set) var borders: [BorderKey] = []
        private var charIndex: [CharKey: Int] = [:]
        private var paraIndex: [ParaKey: Int] = [:]
        private var borderIndex: [BorderKey: Int] = [:]
        private(set) var bodyHangul = 0
        /// 문단 테두리 borderFill 번호는 표 칸용(1~4) 다음부터
        static let firstBorderID = 5

        init(bodyFont: String, bodyHeight: Int) {
            fonts = [bodyFont]
            self.bodyHeight = bodyHeight
            bodyHangul = hangulPartner(bodyFont).map(font) ?? 0
            _ = char(base(height: bodyHeight))                                         // 0: 본문
            _ = para(ParaKey())                                                         // 0: 본문 문단
            _ = para(ParaKey(align: "LEFT", next: 0, line: 130))                        // 1: 표 칸 안 문단
        }

        func font(_ name: String?) -> Int {
            guard let name, !name.isEmpty else { return 0 }
            if let index = fonts.firstIndex(of: name) { return index }
            fonts.append(name)
            return fonts.count - 1
        }

        /// 본문 글꼴로 쓰는 기본 글자 모양
        func base(height: Int, bold: Bool = false) -> CharKey {
            CharKey(bold: bold, height: height, font: 0, hangul: bodyHangul)
        }

        /// 라틴 글자 글꼴과 한글 글꼴 번호
        func fontPair(_ name: String?) -> (latin: Int, hangul: Int) {
            guard let name, !name.isEmpty else { return (0, bodyHangul) }
            let latin = font(name)
            return (latin, hangulPartner(name).map(font) ?? latin)
        }

        func border(_ key: BorderKey) -> Int {
            if let id = borderIndex[key] { return id }
            borders.append(key)
            borderIndex[key] = Self.firstBorderID + borders.count - 1
            return Self.firstBorderID + borders.count - 1
        }

        func char(_ key: CharKey) -> Int {
            if let id = charIndex[key] { return id }
            chars.append(key)
            charIndex[key] = chars.count - 1
            return chars.count - 1
        }

        func para(_ key: ParaKey) -> Int {
            if let id = paraIndex[key] { return id }
            paras.append(key)
            paraIndex[key] = paras.count - 1
            return paras.count - 1
        }

        /// 글 조각의 글자 모양 번호. 제목이면 굵게·제목 크기(조각에 크기가 있으면 그것)
        func char(_ run: DocumentRun, heading: Int?) -> Int {
            let fonts = fontPair(run.fontName)
            var key = CharKey(bold: run.bold, italic: run.italic, underline: run.underline, strike: run.strike, script: run.script,
                              color: run.colorHex?.uppercased(), height: bodyHeight, font: fonts.latin, hangul: fonts.hangul)
            if let heading {
                key.bold = true
                key.height = [1800, 1400, 1100][min(max(heading, 1), 3) - 1]
            }
            if let size = run.fontSize, size > 0 { key.height = Int((size * 100).rounded()) }
            return char(key)
        }

        func para(_ paragraph: DocumentParagraph) -> Int {
            var key = ParaKey()
            switch paragraph.alignment {
            case .left?: key.align = "LEFT"
            case .right?: key.align = "RIGHT"
            case .center?: key.align = "CENTER"
            default: key.align = "JUSTIFY"
            }
            key.intent = Int((paragraph.firstLineIndent * 100).rounded())
            key.left = Int((paragraph.leftIndent * 100).rounded())
            key.right = Int((max(0, paragraph.rightIndent) * 100).rounded())
            if paragraph.ruleAbove != nil || paragraph.ruleBelow != nil {
                func line(_ rule: DocumentRule?) -> BorderKey.Line? {
                    rule.map { BorderKey.Line(color: "#" + $0.colorHex.uppercased(), width: HwpxWriter.borderWidth($0.width)) }
                }
                key.border = border(BorderKey(top: line(paragraph.ruleAbove), bottom: line(paragraph.ruleBelow)))
                key.borderTop = Int(((paragraph.ruleAbove?.gap ?? 0) * 100).rounded())
                key.borderBottom = Int(((paragraph.ruleBelow?.gap ?? 0) * 100).rounded())
                key.ignoreMargin = (paragraph.ruleAbove ?? paragraph.ruleBelow)?.fullWidth ?? false
            }
            key.prev = Int(((paragraph.spaceBefore ?? 0) * 100).rounded())
            key.next = Int(((paragraph.spaceAfter ?? 8) * 100).rounded())
            key.line = min(max(Int(((paragraph.lineSpacing ?? 1.6) * 100).rounded()), 50), 500)
            return para(key)
        }
    }

    /// 선 굵기 pt → 한글이 아는 굵기 값(mm) 중 가장 가까운 것
    static func borderWidth(_ points: CGFloat) -> String {
        let choices: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]
        let mm = Double(points) * 25.4 / 72
        let best = choices.min { abs($0 - mm) < abs($1 - mm) } ?? 0.12
        return best == best.rounded() ? String(format: "%.1f mm", best) : "\(best) mm"
    }

    /// 라틴 글자만 있는 글꼴이면 한글 글자에 쓸 같은 계열 글꼴(세리프 → 함초롬바탕, 그 밖 → 함초롬돋움). 한글이 있는 글꼴이면 nil
    static func hangulPartner(_ name: String) -> String? {
        let lower = name.lowercased()
        if name.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) || (0x3130...0x318F).contains($0.value) }) { return nil }
        let korean = ["nanum", "malgun", "apple sd", "applegothic", "applemyungjo", "batang", "dotum", "gulim", "gungsuh", "hcr",
                      "noto sans kr", "noto serif kr", "noto sans cjk", "noto serif cjk", "pretendard", "spoqa", "source han", "kopub", "myungjo", "myeongjo"]
        if korean.contains(where: { lower.contains($0) }) { return nil }
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let installed = (CTFontCopyFamilyName(font) as String).lowercased() == lower || (CTFontCopyPostScriptName(font) as String).lowercased() == lower
        if installed {
            var glyph: CGGlyph = 0
            var character: UniChar = 0xAC00
            if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 { return nil }
        }
        return PDFContentScan.kind(of: name) == .serif ? "함초롬바탕" : "함초롬돋움"
    }

    static func make(_ document: RichDocument) -> Data {
        let built = section(document)
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/hwp+zip".utf8), store: true)
        zip.add("version.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><hv:HCFVersion xmlns:hv="http://www.hancom.co.kr/hwpml/2011/version" tagetApplication="WORDPROCESSOR" major="5" minor="1" micro="0" buildNumber="1" os="1" xmlVersion="1.4" application="Hanlabong" appVersion="1.0"/>
        """)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><ocf:container xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf"><ocf:rootfiles><ocf:rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/></ocf:rootfiles></ocf:container>
        """)
        zip.add("META-INF/manifest.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><odf:manifest xmlns:odf="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"/>
        """)
        zip.add("Contents/content.hpf", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><opf:package xmlns:opf="http://www.idpf.org/2007/opf/" \(ns) version="" unique-identifier="" id=""><opf:metadata><opf:title>\(RichDocumentWriter.escape(document.title))</opf:title><opf:language>ko</opf:language></opf:metadata><opf:manifest><opf:item id="header" href="Contents/header.xml" media-type="application/xml"/><opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/><opf:item id="settings" href="settings.xml" media-type="application/xml"/>\(built.images.indices.map { "<opf:item id=\"image\($0 + 1)\" href=\"BinData/image\($0 + 1).png\" media-type=\"image/png\" isEmbeded=\"1\"/>" }.joined())</opf:manifest><opf:spine><opf:itemref idref="header" linear="yes"/><opf:itemref idref="section0" linear="yes"/></opf:spine></opf:package>
        """)
        zip.add("settings.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><ha:HWPApplicationSetting xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app" xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0"><ha:CaretPosition listIDRef="0" paraIDRef="0" pos="0"/></ha:HWPApplicationSetting>
        """)
        zip.add("Contents/header.xml", header(built.styles))
        zip.add("Contents/section0.xml", built.xml)
        for (index, png) in built.images.enumerated() { zip.add("BinData/image\(index + 1).png", png) }
        return zip.finish()
    }

    private static func header(_ styles: Styles) -> String {
        let langs = ["HANGUL", "LATIN", "HANJA", "JAPANESE", "OTHER", "SYMBOL", "USER"]
        let faceList = styles.fonts.enumerated().map { "<hh:font id=\"\($0.offset)\" face=\"\(RichDocumentWriter.escape($0.element))\" type=\"TTF\" isEmbedded=\"0\"/>" }.joined()
        let fonts = langs.map { "<hh:fontface lang=\"\($0)\" fontCnt=\"\(styles.fonts.count)\">\(faceList)</hh:fontface>" }.joined()
        func charPr(_ id: Int, _ key: CharKey) -> String {
            let f = key.font, h = key.hangul
            let ref = "hangul=\"\(h)\" latin=\"\(f)\" hanja=\"\(h)\" japanese=\"\(h)\" other=\"\(f)\" symbol=\"\(f)\" user=\"\(f)\""
            let hundred = "hangul=\"100\" latin=\"100\" hanja=\"100\" japanese=\"100\" other=\"100\" symbol=\"100\" user=\"100\""
            let zero = "hangul=\"0\" latin=\"0\" hanja=\"0\" japanese=\"0\" other=\"0\" symbol=\"0\" user=\"0\""
            let color = key.color.map { "#" + $0 } ?? "#000000"
            return "<hh:charPr id=\"\(id)\" height=\"\(key.height)\" textColor=\"\(color)\" shadeColor=\"none\" useFontSpace=\"0\" useKerning=\"0\" symMark=\"NONE\" borderFillIDRef=\"1\">"
                + "<hh:fontRef \(ref)/><hh:ratio \(hundred)/><hh:spacing \(zero)/><hh:relSz \(hundred)/><hh:offset \(zero)/>"
                + (key.italic ? "<hh:italic/>" : "") + (key.bold ? "<hh:bold/>" : "")
                + "<hh:underline type=\"\(key.underline ? "BOTTOM" : "NONE")\" shape=\"SOLID\" color=\"\(color)\"/>"
                + "<hh:strikeout shape=\"\(key.strike ? "SOLID" : "NONE")\" color=\"\(color)\"/><hh:outline type=\"NONE\"/><hh:shadow type=\"NONE\" color=\"#B2B2B2\" offsetX=\"10\" offsetY=\"10\"/>"
                + (key.script > 0 ? "<hh:supscript/>" : key.script < 0 ? "<hh:subscript/>" : "") + "</hh:charPr>"
        }
        let chars = styles.chars.enumerated().map { charPr($0.offset, $0.element) }.joined()
        func paraPr(_ id: Int, _ key: ParaKey) -> String {
            "<hh:paraPr id=\"\(id)\" tabPrIDRef=\"0\" condense=\"0\" fontLineHeight=\"0\" snapToGrid=\"1\" suppressLineNumbers=\"0\" checked=\"0\"><hh:align horizontal=\"\(key.align)\" vertical=\"BASELINE\"/><hh:heading type=\"NONE\" idRef=\"0\" level=\"0\"/><hh:breakSetting breakLatinWord=\"KEEP_WORD\" breakNonLatinWord=\"KEEP_WORD\" widowOrphan=\"0\" keepWithNext=\"0\" keepLines=\"0\" pageBreakBefore=\"0\" lineWrap=\"BREAK\"/><hh:autoSpacing eAsianEng=\"0\" eAsianNum=\"0\"/><hh:margin><hc:intent value=\"\(key.intent)\" unit=\"HWPUNIT\"/><hc:left value=\"\(key.left)\" unit=\"HWPUNIT\"/><hc:right value=\"\(key.right)\" unit=\"HWPUNIT\"/><hc:prev value=\"\(key.prev)\" unit=\"HWPUNIT\"/><hc:next value=\"\(key.next)\" unit=\"HWPUNIT\"/></hh:margin><hh:lineSpacing type=\"PERCENT\" value=\"\(key.line)\" unit=\"HWPUNIT\"/><hh:border borderFillIDRef=\"\(key.border)\" offsetLeft=\"0\" offsetRight=\"0\" offsetTop=\"\(key.borderTop)\" offsetBottom=\"\(key.borderBottom)\" connect=\"0\" ignoreMargin=\"\(key.ignoreMargin ? 1 : 0)\"/></hh:paraPr>"
        }
        let paras = styles.paras.enumerated().map { paraPr($0.offset, $0.element) }.joined()
        func side(_ name: String, _ type: String) -> String { "<hh:\(name) type=\"\(type)\" width=\"0.12 mm\" color=\"#808080\"/>" }
        /// 표 칸 테두리·배경: 선이 있으면 가는 회색 실선 네 면
        func cellFill(_ id: Int, fill: String, lines: Bool) -> String {
            let type = lines ? "SOLID" : "NONE"
            return "<hh:borderFill id=\"\(id)\" threeD=\"0\" shadow=\"0\" centerLine=\"NONE\" breakCellSeparateLine=\"0\"><hh:slash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/><hh:backSlash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/>"
                + side("leftBorder", type) + side("rightBorder", type) + side("topBorder", type) + side("bottomBorder", type)
                + "<hh:diagonal type=\"SOLID\" width=\"0.1 mm\" color=\"#000000\"/>" + fill + "</hh:borderFill>"
        }
        let gray = "<hc:fillBrush><hc:winBrush faceColor=\"#EDEDED\" hatchColor=\"#999999\" alpha=\"0\"/></hc:fillBrush>"
        let tableBorders = cellFill(2, fill: "", lines: true) + cellFill(3, fill: gray, lines: true) + cellFill(4, fill: gray, lines: false)
        /// 문단 위·아래 선
        func paragraphFill(_ id: Int, _ key: BorderKey) -> String {
            func edge(_ name: String, _ line: BorderKey.Line?) -> String {
                line.map { "<hh:\(name) type=\"SOLID\" width=\"\($0.width)\" color=\"\($0.color)\"/>" } ?? "<hh:\(name) type=\"NONE\" width=\"0.1 mm\" color=\"#000000\"/>"
            }
            return "<hh:borderFill id=\"\(id)\" threeD=\"0\" shadow=\"0\" centerLine=\"NONE\" breakCellSeparateLine=\"0\"><hh:slash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/><hh:backSlash type=\"NONE\" Crooked=\"0\" isCounter=\"0\"/>"
                + edge("leftBorder", nil) + edge("rightBorder", nil) + edge("topBorder", key.top) + edge("bottomBorder", key.bottom)
                + "<hh:diagonal type=\"SOLID\" width=\"0.1 mm\" color=\"#000000\"/></hh:borderFill>"
        }
        let paragraphBorders = styles.borders.enumerated().map { paragraphFill(Styles.firstBorderID + $0.offset, $0.element) }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><hh:head \(ns) version="1.4" secCnt="1"><hh:beginNum page="1" footnote="1" endnote="1" pic="1" tbl="1" equation="1"/><hh:refList><hh:fontfaces itemCnt="7">\(fonts)</hh:fontfaces><hh:borderFills itemCnt="\(4 + styles.borders.count)"><hh:borderFill id="1" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0"><hh:slash type="NONE" Crooked="0" isCounter="0"/><hh:backSlash type="NONE" Crooked="0" isCounter="0"/><hh:leftBorder type="NONE" width="0.1 mm" color="#000000"/><hh:rightBorder type="NONE" width="0.1 mm" color="#000000"/><hh:topBorder type="NONE" width="0.1 mm" color="#000000"/><hh:bottomBorder type="NONE" width="0.1 mm" color="#000000"/><hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/></hh:borderFill>\(tableBorders)\(paragraphBorders)</hh:borderFills><hh:charProperties itemCnt="\(styles.chars.count)">\(chars)</hh:charProperties><hh:tabProperties itemCnt="1"><hh:tabPr id="0" autoTabLeft="0" autoTabRight="0"/></hh:tabProperties><hh:paraProperties itemCnt="\(styles.paras.count)">\(paras)</hh:paraProperties><hh:styles itemCnt="1"><hh:style id="0" type="PARA" name="바탕글" engName="Normal" paraPrIDRef="0" charPrIDRef="0" nextStyleIDRef="0" langID="1042" lockForm="0"/></hh:styles></hh:refList><hh:compatibleDocument targetProgram="HWP201X"><hh:layoutCompatibility/></hh:compatibleDocument><hh:docOption><hh:linkinfo path="" pageInherit="0" footnoteInherit="0"/></hh:docOption><hh:trackchageConfig flags="56"/></hh:head>
        """
    }

    /// 쪽 여백(hwpunit): 쪽 짧은 변의 8%, 다만 20mm~30mm 사이
    private static func margin(_ pageSize: CGSize) -> Int {
        min(max(Int((min(pageSize.width, pageSize.height) * 8).rounded()), 5669), 8504)
    }

    /// 표·그림·문단 번호를 겹치지 않게 매긴다
    private final class IDs { var next = 1_000_000; func make() -> Int { next += 1; return next } }

    /// hp:t 안쪽: 줄바꿈은 같은 문단 안의 줄 나눔, 탭은 탭 글자
    private static func textXML(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\t").map(RichDocumentWriter.escape).joined(separator: "<hp:tab width=\"4000\" leader=\"0\" type=\"1\"/>")
        }.joined(separator: "<hp:lineBreak/>")
    }

    private static func run(_ text: String, charPr: Int) -> String {
        "<hp:run charPrIDRef=\"\(charPr)\"><hp:t>\(textXML(text))</hp:t></hp:run>"
    }

    private static let positionInline = "<hp:pos treatAsChar=\"1\" affectLSpacing=\"0\" flowWithText=\"1\" allowOverlap=\"0\" holdAnchorAndSO=\"0\" vertRelTo=\"PARA\" horzRelTo=\"PARA\" vertAlign=\"TOP\" horzAlign=\"LEFT\" vertOffset=\"0\" horzOffset=\"0\"/>"

    /// 표(hp:tbl). 칸 너비는 모양 정보가 있으면 그 비율, 없으면 글자 길이에 비례.
    /// 합친 칸은 colSpan/rowSpan으로(가려지는 칸은 쓰지 않는다). 모양 정보가 없으면 첫 줄을 머리줄로, 있으면 headerRows만큼만.
    private static func table(_ rows: [[String]], layout: DocumentTableLayout?, width: Int, ids: IDs, styles: Styles) -> String {
        let count = max(rows.map(\.count).max() ?? 1, 1)
        var widths = DocxWriter.columnWidths(rows, count: count, total: width)
        if let given = layout?.columnWidths, given.count == count, given.allSatisfy({ $0 > 0 }) {
            let sum = given.reduce(0, +)
            widths = given.map { max(Int((Double($0 / sum) * Double(width)).rounded()), 300) }
            widths[count - 1] = max(width - widths.dropLast().reduce(0, +), 300)
        }
        let headerRows = layout?.headerRows ?? 1
        let borders = layout?.borders ?? true
        // 합친 칸 지도: 왼쪽 위 칸(시작) → (가로, 세로), 나머지 가려지는 칸
        var origin: [Int: (columns: Int, rows: Int)] = [:]
        var covered = Set<Int>()
        for span in layout?.spans ?? [] where span.row >= 0 && span.column >= 0 && span.row < rows.count && span.column < count {
            let columns = min(max(span.columns, 1), count - span.column), spanRows = min(max(span.rows, 1), rows.count - span.row)
            guard columns > 1 || spanRows > 1, origin[span.row * count + span.column] == nil, !covered.contains(span.row * count + span.column) else { continue }
            origin[span.row * count + span.column] = (columns, spanRows)
            for r in span.row..<(span.row + spanRows) {
                for c in span.column..<(span.column + columns) where !(r == span.row && c == span.column) { covered.insert(r * count + c) }
            }
        }
        let inMargin = "left=\"510\" right=\"510\" top=\"141\" bottom=\"141\""
        // 줄 높이 추정: 9pt 한글 한 글자 ≈ 900, 영문·숫자 ≈ 500 (hwpunit). 한글 프로그램이 열 때 다시 맞춘다
        func lines(_ text: String, columnWidth: Int) -> Int {
            let usable = max(columnWidth - 1020, 500)
            return text.components(separatedBy: "\n").reduce(0) { sum, line in
                let units = line.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 900 : 500) }
                return sum + max(1, (units + usable - 1) / usable)
            }
        }
        func cellWidth(_ row: Int, _ column: Int) -> Int {
            let columns = origin[row * count + column]?.columns ?? 1
            return widths[column..<(column + columns)].reduce(0, +)
        }
        let heights = rows.indices.map { r -> Int in
            (0..<count).compactMap { c -> Int? in
                guard !covered.contains(r * count + c), (origin[r * count + c]?.rows ?? 1) == 1 else { return nil }
                return lines(c < rows[r].count ? rows[r][c] : "", columnWidth: cellWidth(r, c))
            }.max().map { $0 * 1170 + 282 } ?? 1452
        }
        func cellHeight(_ row: Int, _ column: Int) -> Int {
            let span = origin[row * count + column]?.rows ?? 1
            return heights[row..<(row + span)].reduce(0, +)
        }
        var xml = "<hp:tbl id=\"\(ids.make())\" zOrder=\"0\" numberingType=\"TABLE\" textWrap=\"TOP_AND_BOTTOM\" textFlow=\"BOTH_SIDES\" lock=\"0\" dropcapstyle=\"None\" pageBreak=\"CELL\" repeatHeader=\"\(headerRows > 0 ? 1 : 0)\" rowCnt=\"\(rows.count)\" colCnt=\"\(count)\" cellSpacing=\"0\" borderFillIDRef=\"\(borders ? 2 : 1)\" noAdjust=\"0\">"
        xml += "<hp:sz width=\"\(widths.reduce(0, +))\" widthRelTo=\"ABSOLUTE\" height=\"\(heights.reduce(0, +))\" heightRelTo=\"ABSOLUTE\" protect=\"0\"/>" + positionInline
        xml += "<hp:outMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/><hp:inMargin \(inMargin)/>"
        let cellHeightPt = 900
        let normalChar = styles.char(styles.base(height: cellHeightPt)), boldChar = styles.char(styles.base(height: cellHeightPt, bold: true))
        for (rowIndex, row) in rows.enumerated() {
            let header = rowIndex < headerRows
            xml += "<hp:tr>"
            for column in 0..<count where !covered.contains(rowIndex * count + column) {
                let text = column < row.count ? row[column] : ""
                let charPr = header ? boldChar : normalChar
                var cell = ""
                for line in text.components(separatedBy: "\n") {
                    let content = line.isEmpty ? "<hp:t/>" : "<hp:t>\(textXML(line))</hp:t>"
                    cell += "<hp:p id=\"\(ids.make())\" paraPrIDRef=\"1\" styleIDRef=\"0\" pageBreak=\"0\" columnBreak=\"0\" merged=\"0\"><hp:run charPrIDRef=\"\(charPr)\">\(content)</hp:run></hp:p>"
                }
                let fill = borders ? (header ? 3 : 2) : (header ? 4 : 1)
                let span = origin[rowIndex * count + column]
                xml += "<hp:tc name=\"\" header=\"\(header ? 1 : 0)\" hasMargin=\"0\" protect=\"0\" editable=\"0\" dirty=\"0\" borderFillIDRef=\"\(fill)\">"
                xml += "<hp:subList id=\"\" textDirection=\"HORIZONTAL\" lineWrap=\"BREAK\" vertAlign=\"CENTER\" linkListIDRef=\"0\" linkListNextIDRef=\"0\" textWidth=\"0\" textHeight=\"0\" hasTextRef=\"0\" hasNumRef=\"0\">\(cell)</hp:subList>"
                xml += "<hp:cellAddr colAddr=\"\(column)\" rowAddr=\"\(rowIndex)\"/><hp:cellSpan colSpan=\"\(span?.columns ?? 1)\" rowSpan=\"\(span?.rows ?? 1)\"/><hp:cellSz width=\"\(cellWidth(rowIndex, column))\" height=\"\(cellHeight(rowIndex, column))\"/><hp:cellMargin \(inMargin)/></hp:tc>"
            }
            xml += "</hp:tr>"
        }
        return xml + "</hp:tbl><hp:t/>"
    }

    /// 그림(hp:pic): 크기 hwpunit = pt × 100, 본문 폭·높이보다 크면 비율을 지키며 줄인다
    private static func picture(_ image: DocumentImage, index: Int, maxWidth: Int, maxHeight: Int, ids: IDs) -> String {
        var width = Double(image.size.width) * 100, height = Double(image.size.height) * 100
        let scale = min(1, Double(maxWidth) / width, Double(maxHeight) / height)
        width = max((width * scale).rounded(), 1); height = max((height * scale).rounded(), 1)
        let w = Int(width), h = Int(height)
        let identity = "<hc:transMatrix e1=\"1\" e2=\"0\" e3=\"0\" e4=\"0\" e5=\"1\" e6=\"0\"/><hc:scaMatrix e1=\"1\" e2=\"0\" e3=\"0\" e4=\"0\" e5=\"1\" e6=\"0\"/><hc:rotMatrix e1=\"1\" e2=\"0\" e3=\"0\" e4=\"0\" e5=\"1\" e6=\"0\"/>"
        return "<hp:pic id=\"\(ids.make())\" zOrder=\"0\" numberingType=\"PICTURE\" textWrap=\"TOP_AND_BOTTOM\" textFlow=\"BOTH_SIDES\" lock=\"0\" dropcapstyle=\"None\" href=\"\" groupLevel=\"0\" instid=\"\(ids.make())\" reverse=\"0\">"
            + "<hp:offset x=\"0\" y=\"0\"/><hp:orgSz width=\"\(w)\" height=\"\(h)\"/><hp:curSz width=\"\(w)\" height=\"\(h)\"/><hp:flip horizontal=\"0\" vertical=\"0\"/>"
            + "<hp:rotationInfo angle=\"0\" centerX=\"\(w / 2)\" centerY=\"\(h / 2)\" rotateimage=\"1\"/><hp:renderingInfo>\(identity)</hp:renderingInfo>"
            + "<hp:imgRect><hc:pt0 x=\"0\" y=\"0\"/><hc:pt1 x=\"\(w)\" y=\"0\"/><hc:pt2 x=\"\(w)\" y=\"\(h)\"/><hc:pt3 x=\"0\" y=\"\(h)\"/></hp:imgRect>"
            + "<hp:imgClip left=\"0\" right=\"\(w)\" top=\"0\" bottom=\"\(h)\"/><hp:inMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/><hp:imgDim dimwidth=\"\(w)\" dimheight=\"\(h)\"/>"
            + "<hc:img binaryItemIDRef=\"image\(index)\" bright=\"0\" contrast=\"0\" effect=\"REAL_PIC\" alpha=\"0\"/><hp:effects/>"
            + "<hp:sz width=\"\(w)\" widthRelTo=\"ABSOLUTE\" height=\"\(h)\" heightRelTo=\"ABSOLUTE\" protect=\"0\"/>" + positionInline
            + "<hp:outMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/></hp:pic><hp:t/>"
    }

    /// 글 문단 하나(hp:p). `leading`은 첫 run에 끼울 구역 설정·머리글 같은 것
    private static func textParagraph(_ paragraph: DocumentParagraph, ids: IDs, styles: Styles, leading: String = "", pageBreak: Int = 0) -> String {
        var runs = leading.isEmpty ? "" : "<hp:run charPrIDRef=\"0\">\(leading)</hp:run>"
        for piece in paragraph.runs { runs += run(piece.text, charPr: styles.char(piece, heading: paragraph.headingLevel)) }
        return "<hp:p id=\"\(ids.make())\" paraPrIDRef=\"\(styles.para(paragraph))\" styleIDRef=\"0\" pageBreak=\"\(pageBreak)\" columnBreak=\"0\" merged=\"0\">\(runs)</hp:p>"
    }

    /// 머리글·꼬리글 한 개(hp:ctrl)
    private static func headerFooter(_ tag: String, _ paragraphs: [DocumentParagraph], extra: [String], ids: IDs, styles: Styles, textWidth: Int) -> String {
        var inner = paragraphs.map { textParagraph($0, ids: ids, styles: styles) }.joined()
        inner += extra.joined()
        let vertAlign = tag == "header" ? "TOP" : "BOTTOM"
        return "<hp:ctrl><hp:\(tag) id=\"\(ids.make())\" applyPageType=\"BOTH\"><hp:subList id=\"\" textDirection=\"HORIZONTAL\" lineWrap=\"BREAK\" vertAlign=\"\(vertAlign)\" linkListIDRef=\"0\" linkListNextIDRef=\"0\" textWidth=\"\(textWidth)\" textHeight=\"3000\" hasTextRef=\"0\" hasNumRef=\"0\">\(inner)</hp:subList></hp:\(tag)></hp:ctrl>"
    }

    private static func section(_ document: RichDocument) -> (xml: String, images: [Data], styles: Styles) {
        let pageSize = document.resolvedPageSize
        let pageWidth = Int((pageSize.width * 100).rounded()), pageHeight = Int((pageSize.height * 100).rounded())
        // OWPML: 세로 쪽은 WIDELY, 가로 쪽은 NARROWLY
        let landscape = pageWidth > pageHeight ? "NARROWLY" : "WIDELY"
        let defaultMargin = margin(pageSize)
        func unit(_ pt: CGFloat?, _ fallback: Int) -> Int { pt.map { max(Int(($0 * 100).rounded()), 0) } ?? fallback }
        let marginLeft = unit(document.margins?.left, defaultMargin), marginRight = unit(document.margins?.right, defaultMargin)
        let marginTop = unit(document.margins?.top, defaultMargin), marginBottom = unit(document.margins?.bottom, defaultMargin)
        let headerDistance = marginTop / 2, footerDistance = marginBottom / 2
        let textWidth = max(pageWidth - marginLeft - marginRight, 5000), textHeight = max(pageHeight - marginTop - marginBottom, 5000)
        let ids = IDs()
        let styles = Styles(bodyFont: document.bodyFontName ?? "함초롬바탕",
                            bodyHeight: Int(((document.bodyFontSize ?? 10) * 100).rounded()))
        let secPr = "<hp:secPr id=\"\" textDirection=\"HORIZONTAL\" spaceColumns=\"1134\" tabStop=\"8000\" tabStopVal=\"4000\" tabStopUnit=\"HWPUNIT\" outlineShapeIDRef=\"0\" memoShapeIDRef=\"0\" textVerticalWidthHead=\"0\" masterPageCnt=\"0\"><hp:grid lineGrid=\"0\" charGrid=\"0\" wonggojiFormat=\"0\"/><hp:startNum pageStartsOn=\"BOTH\" page=\"0\" pic=\"0\" tbl=\"0\" equation=\"0\"/><hp:visibility hideFirstHeader=\"0\" hideFirstFooter=\"0\" hideFirstMasterPage=\"0\" border=\"SHOW_ALL\" fill=\"SHOW_ALL\" hideFirstPageNum=\"0\" hideFirstEmptyLine=\"0\" showLineNumber=\"0\"/><hp:lineNumberShape restartType=\"0\" countBy=\"0\" distance=\"0\" startNumber=\"0\"/><hp:pagePr landscape=\"\(landscape)\" width=\"\(pageWidth)\" height=\"\(pageHeight)\" gutterType=\"LEFT_ONLY\"><hp:margin header=\"\(headerDistance)\" footer=\"\(footerDistance)\" gutter=\"0\" left=\"\(marginLeft)\" right=\"\(marginRight)\" top=\"\(marginTop)\" bottom=\"\(marginBottom)\"/></hp:pagePr><hp:footNotePr><hp:autoNumFormat type=\"DIGIT\" userChar=\"\" prefixChar=\"\" suffixChar=\")\" supscript=\"0\"/><hp:noteLine length=\"-1\" type=\"SOLID\" width=\"0.12 mm\" color=\"#000000\"/><hp:noteSpacing betweenNotes=\"283\" belowLine=\"567\" aboveLine=\"850\"/><hp:numbering type=\"CONTINUOUS\" newNum=\"1\"/><hp:placement place=\"EACH_COLUMN\" beneathText=\"0\"/></hp:footNotePr><hp:endNotePr><hp:autoNumFormat type=\"DIGIT\" userChar=\"\" prefixChar=\"\" suffixChar=\")\" supscript=\"0\"/><hp:noteLine length=\"14692344\" type=\"SOLID\" width=\"0.12 mm\" color=\"#000000\"/><hp:noteSpacing betweenNotes=\"0\" belowLine=\"567\" aboveLine=\"850\"/><hp:numbering type=\"CONTINUOUS\" newNum=\"1\"/><hp:placement place=\"END_OF_DOCUMENT\" beneathText=\"0\"/></hp:endNotePr><hp:pageBorderFill type=\"BOTH\" borderFillIDRef=\"1\" textBorder=\"PAPER\" headerInside=\"0\" footerInside=\"0\" fillArea=\"PAPER\"><hp:offset left=\"1417\" right=\"1417\" top=\"1417\" bottom=\"1417\"/></hp:pageBorderFill></hp:secPr>"

        // 머리글·꼬리글·쪽 번호는 첫 문단 첫 run에 구역 설정과 함께
        var firstExtras = ""
        if !document.header.isEmpty {
            firstExtras += headerFooter("header", document.header, extra: [], ids: ids, styles: styles, textWidth: textWidth)
        }
        var pageNumberParagraph: [String] = []
        if document.showPageNumber, !document.footer.isEmpty {
            // 꼬리글 글이 있으면 그 아래 가운데에 쪽 번호만 있는 문단을 덧붙인다
            let number = "<hp:run charPrIDRef=\"0\"><hp:ctrl><hp:autoNum num=\"1\" numType=\"PAGE\"><hp:autoNumFormat type=\"DIGIT\" userChar=\"\" prefixChar=\"\" suffixChar=\"\" supscript=\"0\"/></hp:autoNum></hp:ctrl><hp:t/></hp:run>"
            let centered = styles.para(ParaKey(align: "CENTER", next: 0, line: 130))
            pageNumberParagraph = ["<hp:p id=\"\(ids.make())\" paraPrIDRef=\"\(centered)\" styleIDRef=\"0\" pageBreak=\"0\" columnBreak=\"0\" merged=\"0\">\(number)</hp:p>"]
        }
        if !document.footer.isEmpty {
            firstExtras += headerFooter("footer", document.footer, extra: pageNumberParagraph, ids: ids, styles: styles, textWidth: textWidth)
        } else if document.showPageNumber {
            firstExtras += "<hp:ctrl><hp:pageNum pos=\"BOTTOM_CENTER\" formatType=\"DIGIT\" sideChar=\"-\"/></hp:ctrl>"
        }

        var body = ""
        var images: [Data] = []
        let paragraphs = document.paragraphs.isEmpty ? [DocumentParagraph(runs: [DocumentRun("")])] : document.paragraphs
        for (index, paragraph) in paragraphs.enumerated() {
            let leading = index == 0 ? secPr + "<hp:ctrl><hp:colPr id=\"\" type=\"NEWSPAPER\" layout=\"LEFT\" colCount=\"1\" sameSz=\"1\" sameGap=\"0\"/></hp:ctrl>" + firstExtras : ""
            // 첫 문단 앞에서는 쪽을 넘기지 않는다(빈 첫 쪽이 생기므로)
            let pageBreak = paragraph.pageBreakBefore && index > 0 ? 1 : 0
            if let rows = paragraph.table, rows.contains(where: { !$0.isEmpty }) {
                let tableXML = table(rows, layout: paragraph.tableLayout, width: textWidth, ids: ids, styles: styles)
                let runs = (leading.isEmpty ? "" : "<hp:run charPrIDRef=\"0\">\(leading)</hp:run>") + "<hp:run charPrIDRef=\"0\">\(tableXML)</hp:run>"
                body += "<hp:p id=\"\(ids.make())\" paraPrIDRef=\"0\" styleIDRef=\"0\" pageBreak=\"\(pageBreak)\" columnBreak=\"0\" merged=\"0\">\(runs)</hp:p>"
            } else if let image = paragraph.image, image.size.width > 0, image.size.height > 0, !image.png.isEmpty {
                images.append(image.png)
                let runs = (leading.isEmpty ? "" : "<hp:run charPrIDRef=\"0\">\(leading)</hp:run>")
                    + "<hp:run charPrIDRef=\"0\">\(picture(image, index: images.count, maxWidth: textWidth, maxHeight: textHeight, ids: ids))</hp:run>"
                body += "<hp:p id=\"\(ids.make())\" paraPrIDRef=\"0\" styleIDRef=\"0\" pageBreak=\"\(pageBreak)\" columnBreak=\"0\" merged=\"0\">\(runs)</hp:p>"
            } else {
                body += textParagraph(paragraph, ids: ids, styles: styles, leading: leading, pageBreak: pageBreak)
            }
        }
        return ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><hs:sec \(ns)>\(body)</hs:sec>", images, styles)
    }
}
