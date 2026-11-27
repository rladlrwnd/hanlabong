import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Word(.docx)를 직접 뜯어 읽는다(macOS 문서 읽기는 제목을 글자 크기로 짐작하고 표를 칸마다 문단으로 쪼개서).
/// - 문단: 스타일(제목 1~3·Title)·개요 수준(outlineLvl)으로 제목 단계, 정렬·들여쓰기·간격·줄 간격(스타일·기본값 포함)
/// - 글자: 굵게·기울임·밑줄·취소선·위/아래 첨자·색·크기·글꼴·링크, 탭·줄바꿈, 체크박스 기호(w:sym), 수식 글, 글상자
/// - 표: 줄 × 칸 + 칸 너비·합친 칸(gridSpan·vMerge)·머리줄·테두리 유무. 글이 없는 표도 남김
/// - 그림: word/media 파일을 PNG로(자르기 반영), 크기는 wp:extent. 못 읽는 그림(EMF 등)은 "[그림]" 글로
/// - 쪽: 나눔·크기(w:pgSz 그대로)·여백(w:pgMar)·머리글·꼬리글·쪽 번호(PAGE 필드)
/// - 목록: 번호 매기기 정의(numbering.xml)의 lvlText 틀("%1.%2", "제%1조")과 numFmt(가나다·①·로마자 …)로 표시를 앞에 붙인다
/// - 각주·미주: 본문 자리엔 위첨자 번호, 본문 끝에 "각주 1. …" 문단
enum DocxReader {
    struct Result {
        var paragraphs: [DocumentParagraph]
        var pageSize: CGSize?
        var margins: DocumentMargins?
        var header: [DocumentParagraph] = []
        var footer: [DocumentParagraph] = []
        var showPageNumber = false
        var bodyFontSize: CGFloat?
        var bodyFontName: String?
    }

    /// 읽을 수 없는 파일(zip이 아니거나 본문이 없음)이면 nil
    static func read(_ url: URL) -> Result? {
        guard let package = ZipPackage(url),
              let documentPath = mainDocumentPath(package),
              let document = package.xml(documentPath),
              let body = document.child("body") else { return nil }
        let reader = Reader(package: package, documentPath: documentPath)
        reader.walkBlocks(body)
        reader.appendNotes()
        // 한라봉이 쓴 docx는 제목을 스타일로 적어 두니, 글자 크기로 제목을 짐작하지 않는다(큰 글자 한 줄이 제목으로 바뀌지 않게)
        if package.xml("docProps/app.xml")?.child("Application")?.allText != "Hanlabong" { reader.finishHeadings() }
        guard !reader.blocks.paragraphs.isEmpty else { return nil }
        var result = Result(paragraphs: reader.blocks.paragraphs, pageSize: reader.pageSize)
        result.margins = reader.margins
        let header = reader.readHeaderFooter(reader.headerPath)
        let footer = reader.readHeaderFooter(reader.footerPath)
        result.header = header.paragraphs
        result.footer = footer.paragraphs
        result.showPageNumber = header.hasPage || footer.hasPage
        reader.normalizeBody(&result)
        return result
    }

    /// _rels/.rels의 officeDocument 관계, 없으면 word/document.xml
    private static func mainDocumentPath(_ package: ZipPackage) -> String? {
        if let rels = package.xml("_rels/.rels") {
            for rel in rels.children("Relationship") where (rel.attr("Type") ?? "").hasSuffix("/officeDocument") {
                if let target = rel.attr("Target") {
                    let path = ZipPackage.resolve(target, relativeTo: "x")      // 패키지 맨 위 기준
                    if package.contains(path) { return path }
                }
            }
        }
        return package.contains("word/document.xml") ? "word/document.xml" : nil
    }

    // MARK: 스타일·번호 정의

    /// 문단 모양(트윕은 pt로 바꿔 둔다). 값이 없으면 nil
    struct ParaProps {
        var jc: String?
        var left: Double?
        /// 첫 줄 들여쓰기(음수 = 내어쓰기)
        var first: Double?
        var before: Double?
        var after: Double?
        var line: Double?
        var lineRule: String?

        init(_ pPr: OXNode?) {
            guard let pPr else { return }
            jc = pPr.child("jc")?.attr("val")
            if let ind = pPr.child("ind") {
                left = (ind.attr("left") ?? ind.attr("start")).flatMap(Double.init).map { $0 / 20 }
                if let h = ind.attr("hanging").flatMap(Double.init) { first = -h / 20 }
                else if let f = ind.attr("firstLine").flatMap(Double.init) { first = f / 20 }
            }
            if let spacing = pPr.child("spacing") {
                before = spacing.attr("before").flatMap(Double.init).map { $0 / 20 }
                after = spacing.attr("after").flatMap(Double.init).map { $0 / 20 }
                line = spacing.attr("line").flatMap(Double.init)
                lineRule = spacing.attr("lineRule")
            }
        }

        /// 비어 있는 값만 `other`에서 채운다(앞쪽이 이긴다)
        mutating func fill(_ other: ParaProps) {
            jc = jc ?? other.jc
            left = left ?? other.left
            first = first ?? other.first
            before = before ?? other.before
            after = after ?? other.after
            if line == nil { line = other.line; lineRule = other.lineRule }
        }

        /// 번호 수준의 들여쓰기만
        var indentOnly: ParaProps {
            var copy = self
            copy.jc = nil; copy.before = nil; copy.after = nil; copy.line = nil; copy.lineRule = nil
            return copy
        }
    }

    /// 글자 모양
    struct CharProps {
        var bold: Bool?
        var italic: Bool?
        var half: Int?
        var color: String?
        var underline: Bool?
        var strike: Bool?
        var script: Int?
        var ascii: String?
        var hAnsi: String?
        var eastAsia: String?

        init(_ rPr: OXNode?) {
            guard let rPr else { return }
            bold = DocxReader.toggle(rPr, "b")
            italic = DocxReader.toggle(rPr, "i")
            half = rPr.child("sz")?.attr("val").flatMap(Int.init)
            color = rPr.child("color")?.attr("val")
            if let u = rPr.child("u") { underline = (u.attr("val") ?? "single") != "none" }
            let single = DocxReader.toggle(rPr, "strike"), double = DocxReader.toggle(rPr, "dstrike")
            if single != nil || double != nil { strike = (single ?? false) || (double ?? false) }
            switch rPr.child("vertAlign")?.attr("val") {
            case "superscript": script = 1
            case "subscript": script = -1
            case "baseline": script = 0
            default: break
            }
            if let fonts = rPr.child("rFonts") {
                ascii = fonts.attr("ascii"); hAnsi = fonts.attr("hAnsi"); eastAsia = fonts.attr("eastAsia")
            }
        }

        mutating func fill(_ other: CharProps) {
            bold = bold ?? other.bold
            italic = italic ?? other.italic
            half = half ?? other.half
            color = color ?? other.color
            underline = underline ?? other.underline
            strike = strike ?? other.strike
            script = script ?? other.script
            ascii = ascii ?? other.ascii
            hAnsi = hAnsi ?? other.hAnsi
            eastAsia = eastAsia ?? other.eastAsia
        }

        /// 글에 맞는 글꼴 이름: 한글·한자가 있으면 동아시아 글꼴, 아니면 영문 글꼴
        func fontName(for text: String) -> String? {
            let cjk = text.unicodeScalars.contains { $0.value >= 0x1100 && !(0x2000...0x2BFF).contains($0.value) }
            let name = cjk ? (eastAsia ?? ascii ?? hAnsi) : (ascii ?? hAnsi ?? eastAsia)
            return name?.isEmpty == false ? name : nil
        }

        /// 기본 글꼴 이름(글을 가리지 않고 동아시아 글꼴 먼저)
        var defaultName: String? {
            let name = eastAsia ?? ascii ?? hAnsi
            return name?.isEmpty == false ? name : nil
        }
    }

    struct Style {
        var type = "paragraph"
        var name = ""
        var basedOn: String?
        var outline: Int?
        var numId: String?
        var ilvl: Int?
        var pageBreakBefore: Bool?
        var para = ParaProps(nil)
        var char = CharProps(nil)
        /// 표 스타일: 테두리가 있는가, 첫 줄을 굵게 하는가
        var tableBorders: Bool?
        var firstRowBold: Bool?
    }

    /// 번호 수준 하나: 형식·틀·시작값·들여쓰기
    struct NumLevel {
        var fmt = "decimal"
        var text = "%1."
        var start = 1
        var suff = "tab"
        var para = ParaProps(nil)
    }

    /// w:b 같은 켬/끔 요소: 요소가 없으면 nil, 있으면 val이 0·false·off가 아닌지
    static func toggle(_ node: OXNode?, _ name: String) -> Bool? {
        guard let element = node?.child(name) else { return nil }
        guard let v = element.attr("val")?.lowercased() else { return true }
        return !(v == "0" || v == "false" || v == "off")
    }

    /// 테두리 요소(tblBorders 등)에 실제로 그리는 변이 있는가. 요소가 없으면 nil
    static func hasBorders(_ node: OXNode?) -> Bool? {
        guard let node else { return nil }
        let sides = ["top", "left", "bottom", "right", "start", "end", "insideH", "insideV"]
        var any = false
        for side in sides {
            guard let b = node.child(side) else { continue }
            let v = (b.attr("val") ?? "single").lowercased()
            if v != "none" && v != "nil" { any = true }
        }
        return any
    }

    /// 쓰기 쉬운 글자색 "RRGGBB"("auto"·잘못된 값은 nil)
    static func colorHex(_ value: String?) -> String? {
        guard let value, value.count == 6, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value.uppercased()
    }

    /// Wingdings·Symbol 기호 글자 → 보통 글자(체크박스 등). 모르면 nil
    static func symbol(font: String?, char: String?) -> String? {
        guard let char, var code = UInt32(char, radix: 16) else { return nil }
        if code >= 0xF000 { code -= 0xF000 }
        let wingdings: [UInt32: String] = [0xA8: "☐", 0x6F: "☐", 0x71: "☐", 0xA3: "☐", 0xFE: "☑", 0xFD: "☒", 0x78: "☒", 0x52: "☑", 0xFC: "✓", 0xFB: "✗", 0x76: "❖", 0xA7: "▪", 0x6C: "●", 0xD8: "➢", 0xB7: "•"]
        if let s = wingdings[code] { return s }
        if let scalar = Unicode.Scalar(code), code >= 0x20, code != 0x7F, !(font ?? "").lowercased().contains("wingdings") { return String(Character(scalar)) }
        return nil
    }

    /// 번호 값 → 글자(numFmt별)
    static func formatNumber(_ n: Int, _ fmt: String) -> String {
        let value = max(n, 0)
        func repeated(_ chars: [Character]) -> String {
            guard value > 0, !chars.isEmpty else { return "\(value)" }
            let k = (value - 1) / chars.count + 1
            return String(repeating: String(chars[(value - 1) % chars.count]), count: min(k, 6))
        }
        func roman(_ number: Int) -> String {
            guard number > 0, number < 4000 else { return "\(number)" }
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var rest = number, out = ""
            for (v, s) in table { while rest >= v { out += s; rest -= v } }
            return out
        }
        func digits(_ map: [Character]) -> String { String(String(value).compactMap { $0.wholeNumberValue.map { map[$0] } }) }
        /// 만 단위 아래 한자·한글 수 읽기(일·이·삼 / 十 …)
        func counting(_ number: Int, _ d: [String], _ unit: [String]) -> String {
            guard number > 0, number < 10000 else { return number == 0 ? d[0] : "\(number)" }
            var out = ""
            let places = [1000, 100, 10, 1]
            for (i, p) in places.enumerated() {
                let digit = (number / p) % 10
                if digit == 0 { continue }
                if digit == 1 && p != 1 { out += unit[i] } else { out += d[digit] + unit[i] }
            }
            return out
        }
        switch fmt {
        case "decimal": return "\(value)"
        case "decimalZero": return value < 10 ? "0\(value)" : "\(value)"
        case "upperRoman": return roman(value)
        case "lowerRoman": return roman(value).lowercased()
        case "upperLetter": return repeated(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        case "lowerLetter": return repeated(Array("abcdefghijklmnopqrstuvwxyz"))
        case "ganada": return repeated(Array("가나다라마바사아자차카타파하"))
        case "chosung": return repeated(Array("ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ"))
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese", "ideographEnclosedCircle":
            if (1...20).contains(value) { return String(UnicodeScalar(0x2460 + UInt32(value) - 1)!) }
            if (21...35).contains(value) { return String(UnicodeScalar(0x3251 + UInt32(value) - 21)!) }
            if (36...50).contains(value) { return String(UnicodeScalar(0x32B1 + UInt32(value) - 36)!) }
            return "(\(value))"
        case "decimalEnclosedParen": return "(\(value))"
        case "decimalEnclosedFullstop": return "\(value)."
        case "decimalFullWidth", "decimalFullWidth2": return digits(Array("０１２３４５６７８９"))
        case "koreanDigital", "koreanDigital2": return digits(Array("영일이삼사오육칠팔구"))
        case "koreanCounting", "koreanLegal": return counting(value, ["영", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구"], ["천", "백", "십", ""])
        case "ideographDigital", "japaneseDigitalTenThousand": return digits(Array("〇一二三四五六七八九"))
        case "chineseCounting", "chineseCountingThousand", "japaneseCounting", "ideographTraditional":
            return counting(value, ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"], ["千", "百", "十", ""])
        case "ordinal":
            let tens = value % 100
            let suffix = (11...13).contains(tens) ? "th" : (value % 10 == 1 ? "st" : value % 10 == 2 ? "nd" : value % 10 == 3 ? "rd" : "th")
            return "\(value)\(suffix)"
        case "none": return ""
        default: return "\(value)"
        }
    }

    /// 글머리 기호(Symbol·Wingdings의 사설 영역 글자는 보통 기호로)
    static func bulletMark(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "•" }
        switch scalar.value {
        case 0xF0B7, 0xB7: return "•"
        case 0xF0A7: return "▪"
        case 0xF0D8: return "➢"
        case 0xF0FC: return "✓"
        case 0xF076: return "❖"
        case 0xF0A8: return "☐"
        case 0xF0FE: return "☑"
        case 0xF0FD: return "☒"
        case 0xF06F: return "○"
        case 0xF0E0...0xF0FF, 0xE000...0xF8FF: return "•"
        default: return String(text.prefix(1))
        }
    }

    private final class Reader {
        let package: ZipPackage
        let documentPath: String
        let folderPrefix: String
        var styles: [String: Style] = [:]
        var defaultParagraphStyle: String?
        var defaultTableStyle: String?
        var defaultHalfPoints = 22
        var defaultChar = CharProps(nil)
        var defaultPara = ParaProps(nil)
        var relationships: [String: String] = [:]
        var externalLinks: [String: String] = [:]
        /// 번호 정의: numId → abstractNumId, abstractNumId → (ilvl → 수준)
        var numToAbstract: [String: String] = [:]
        var abstractLevels: [String: [Int: NumLevel]] = [:]
        var startOverrides: [String: [Int: Int]] = [:]
        var levelOverrides: [String: [Int: NumLevel]] = [:]
        var counters: [String: [Int: Int]] = [:]
        var blocks = ReaderBlocks()
        var pageSize: CGSize?
        var margins: DocumentMargins?
        var headerPath: String?
        var footerPath: String?
        var imageCache: [String: DocumentImage?] = [:]
        var cellImages: [DocumentImage] = []
        /// 글 문단마다: 가장 큰 글자(포인트)·글자 수 — 제목 단계를 스타일로 못 정했을 때 크기로 짐작하려고
        var sizeInfo: [Int: (points: Double, chars: Int)] = [:]
        var styleLevel: Set<Int> = []
        var depth = 0
        /// 본문 글자 크기·글꼴 최빈값을 위한 글자 수(반 포인트 / 이름)
        var sizeHistogram: [Int: Int] = [:]
        var nameHistogram: [String: Int] = [:]
        /// 머리글·꼬리글을 읽는 중이면 쪽 번호 필드를 표시 글자로 바꿔 둔다
        var headerMode = false
        static let pageMark = "\u{E000}"
        /// 각주·미주 번호: 참조 id → 번호(나온 순서)
        var footnoteNumbers: [String: Int] = [:]
        var endnoteNumbers: [String: Int] = [:]
        var footnoteOrder: [String] = []
        var endnoteOrder: [String] = []

        init(package: ZipPackage, documentPath: String) {
            self.package = package
            self.documentPath = documentPath
            let folder = (documentPath as NSString).deletingLastPathComponent
            let prefix = folder.isEmpty ? "" : folder + "/"
            folderPrefix = prefix
            loadStyles(prefix + "styles.xml")
            loadNumbering(prefix + "numbering.xml")
            loadRelationships(prefix + "_rels/" + (documentPath as NSString).lastPathComponent + ".rels")
        }

        // MARK: 불러오기

        func loadStyles(_ path: String) {
            guard let root = package.xml(path) else { return }
            if let defaults = root.child("docDefaults") {
                defaultChar = CharProps(defaults.child("rPrDefault")?.child("rPr"))
                defaultPara = ParaProps(defaults.child("pPrDefault")?.child("pPr"))
                if let sz = defaultChar.half { defaultHalfPoints = sz }
            }
            for node in root.children("style") {
                guard let id = node.attr("styleId") else { continue }
                var style = Style()
                style.type = node.attr("type") ?? "paragraph"
                style.name = node.child("name")?.attr("val") ?? ""
                style.basedOn = node.child("basedOn")?.attr("val")
                let pPr = node.child("pPr"), rPr = node.child("rPr")
                style.outline = pPr?.child("outlineLvl")?.attr("val").flatMap(Int.init)
                style.pageBreakBefore = DocxReader.toggle(pPr, "pageBreakBefore")
                if let numPr = pPr?.child("numPr") {
                    style.numId = numPr.child("numId")?.attr("val")
                    style.ilvl = numPr.child("ilvl")?.attr("val").flatMap(Int.init)
                }
                style.para = ParaProps(pPr)
                style.char = CharProps(rPr)
                if style.type == "table" {
                    style.tableBorders = DocxReader.hasBorders(node.child("tblPr")?.child("tblBorders"))
                    for conditional in node.children("tblStylePr") where conditional.attr("type") == "firstRow" {
                        style.firstRowBold = DocxReader.toggle(conditional.child("rPr"), "b")
                    }
                }
                styles[id] = style
                if style.type == "paragraph", node.attr("default") == "1" { defaultParagraphStyle = id }
                if style.type == "table", node.attr("default") == "1" { defaultTableStyle = id }
            }
        }

        func parseLevel(_ lvl: OXNode) -> NumLevel {
            var level = NumLevel()
            level.fmt = lvl.child("numFmt")?.attr("val") ?? "decimal"
            if let text = lvl.child("lvlText")?.attr("val") { level.text = text } else if level.fmt == "bullet" { level.text = "•" }
            level.start = lvl.child("start")?.attr("val").flatMap(Int.init) ?? 1
            level.suff = lvl.child("suff")?.attr("val") ?? "tab"
            level.para = ParaProps(lvl.child("pPr")).indentOnly
            return level
        }

        func loadNumbering(_ path: String) {
            guard let root = package.xml(path) else { return }
            for abstract in root.children("abstractNum") {
                guard let id = abstract.attr("abstractNumId") else { continue }
                var levels: [Int: NumLevel] = [:]
                for lvl in abstract.children("lvl") {
                    if let index = lvl.attr("ilvl").flatMap(Int.init) { levels[index] = parseLevel(lvl) }
                }
                abstractLevels[id] = levels
            }
            for num in root.children("num") {
                guard let id = num.attr("numId") else { continue }
                if let abstract = num.child("abstractNumId")?.attr("val") { numToAbstract[id] = abstract }
                for override in num.children("lvlOverride") {
                    guard let index = override.attr("ilvl").flatMap(Int.init) else { continue }
                    if let start = override.child("startOverride")?.attr("val").flatMap(Int.init) { startOverrides[id, default: [:]][index] = start }
                    if let lvl = override.child("lvl") { levelOverrides[id, default: [:]][index] = parseLevel(lvl) }
                }
            }
        }

        func loadRelationships(_ path: String) {
            guard let root = package.xml(path) else { return }
            for rel in root.children("Relationship") {
                guard let id = rel.attr("Id"), let target = rel.attr("Target") else { continue }
                if rel.attr("TargetMode") == "External" { externalLinks[id] = target }
                else { relationships[id] = ZipPackage.resolve(target, relativeTo: documentPath) }
            }
        }

        // MARK: 스타일 풀이(basedOn 사슬을 따라 올라간다)

        func chain(_ styleId: String?) -> [Style] {
            var out: [Style] = []
            var current = styleId
            var seen = Set<String>()
            while let id = current, !seen.contains(id), let style = styles[id], out.count < 12 {
                seen.insert(id)
                out.append(style)
                current = style.basedOn
            }
            return out
        }

        static func headingLevel(fromName name: String) -> Int? {
            let n = name.lowercased().replacingOccurrences(of: " ", with: "")
            if n == "title" || n == "제목" { return 1 }
            for prefix in ["heading", "제목", "개요"] where n.hasPrefix(prefix) {
                if let value = Int(n.dropFirst(prefix.count)), value >= 1 { return min(value, 3) }
            }
            return nil
        }

        /// 문단 스타일 사슬로 본 제목 단계
        func headingLevel(styleChain: [Style]) -> Int? {
            for style in styleChain {
                if let level = Self.headingLevel(fromName: style.name) { return level }
                if let outline = style.outline { return outline < 9 ? min(outline + 1, 3) : nil }
            }
            return nil
        }

        // MARK: 본문 훑기

        func walkBlocks(_ container: OXNode) {
            guard depth < 40 else { return }
            depth += 1
            defer { depth -= 1 }
            for node in container.children {
                switch node.name {
                case "p": paragraph(node)
                case "tbl":
                    let info = table(node)
                    blocks.docxTable(info.rows, layout: info.layout)
                    for image in info.images { blocks.docxAdd(DocumentParagraph(runs: [], image: image)) }
                case "sdt": if let content = node.child("sdtContent") { walkBlocks(content) }
                case "sdtContent", "customXml", "ins", "moveTo", "smartTag": walkBlocks(node)
                case "AlternateContent": if let choice = node.child("Choice") ?? node.child("Fallback") { walkBlocks(choice) }
                case "sectPr": noteSection(node)
                default: break
                }
            }
        }

        /// 첫 구역의 쪽 크기(w/h를 그대로, 가로세로를 맞바꾸지 않는다)·여백·머리글·꼬리글 연결
        func noteSection(_ sectPr: OXNode) {
            guard pageSize == nil, let pgSz = sectPr.child("pgSz"),
                  let w = pgSz.attr("w").flatMap(Double.init), let h = pgSz.attr("h").flatMap(Double.init), w > 0, h > 0 else { return }
            pageSize = CGSize(width: w / 20, height: h / 20)
            if let mar = sectPr.child("pgMar") {
                func pt(_ key: String) -> CGFloat? { mar.attr(key).flatMap(Double.init).map { CGFloat(abs($0) / 20) } }
                if let top = pt("top"), let bottom = pt("bottom"), let left = pt("left") ?? pt("start"), let right = pt("right") ?? pt("end") {
                    margins = DocumentMargins(top: top, left: left + (pt("gutter") ?? 0), bottom: bottom, right: right)
                }
            }
            for ref in sectPr.children("headerReference") where (ref.attr("type") ?? "default") == "default" {
                if let id = ref.attr("id") { headerPath = relationships[id] }
            }
            for ref in sectPr.children("footerReference") where (ref.attr("type") ?? "default") == "default" {
                if let id = ref.attr("id") { footerPath = relationships[id] }
            }
        }

        // MARK: 문단

        /// 필드(w:fldChar … instrText … separate … 결과 … end) 하나를 읽는 동안의 상태
        struct Field {
            var instr = ""
            var inResult = false
            var suppress = false
            var savedLink: String?
        }

        /// 문단 하나를 읽는 동안의 상태
        final class ParaState {
            var pieces: [ReaderPiece] = []
            var paragraphStyle: [Style] = []
            var points: Double = 0
            var chars = 0
            var textBoxes: [OXNode] = []
            var plain = false
            var link: String?
            var fields: [Field] = []
            /// 문단 아래에 따로 놓을 수식(oMathPara)
            var blockEquations: [String] = []

            var suppress: Bool { fields.contains { $0.suppress } }

            func add(_ run: DocumentRun, points size: Double) {
                guard !run.text.isEmpty, !suppress else { return }
                if case .runs(var runs)? = pieces.last {
                    pieces.removeLast()
                    runs.append(run)
                    pieces.append(.runs(runs))
                } else {
                    pieces.append(.runs([run]))
                }
                if !run.text.allSatisfy({ $0.isWhitespace }) {
                    points = max(points, size)
                    chars += run.text.count
                }
            }
        }

        func paragraph(_ p: OXNode) {
            let pPr = p.child("pPr")
            let styleId = pPr?.child("pStyle")?.attr("val") ?? defaultParagraphStyle
            let styleChain = chain(styleId)

            // 쪽 나눔(문단 앞)
            if let explicit = DocxReader.toggle(pPr, "pageBreakBefore") {
                if explicit { blocks.pendingBreak = true }
            } else if styleChain.contains(where: { $0.pageBreakBefore == true }) {
                blocks.pendingBreak = true
            }

            // 제목 단계: 문단의 개요 수준 → 스타일 이름·개요 수준
            var level: Int?
            if let outline = pPr?.child("outlineLvl")?.attr("val").flatMap(Int.init) {
                level = outline < 9 ? min(outline + 1, 3) : nil
            } else {
                level = headingLevel(styleChain: styleChain)
            }

            let state = ParaState()
            state.paragraphStyle = styleChain
            walkInline(p, state)

            // 번호 표시(제목에도 붙인다)
            var marker = ""
            var numLevel: NumLevel?
            var numFromDirect = false
            if let (numId, ilvl, direct) = numbering(pPr: pPr, styleChain: styleChain) {
                (marker, numLevel) = listMarker(numId: numId, ilvl: ilvl)
                numFromDirect = direct
            }

            // 문단 모양: 문단 자신 → (번호 수준) → 스타일 사슬 → (번호 수준) → 문서 기본값
            var props = ParaProps(pPr)
            if numFromDirect, let numLevel { props.fill(numLevel.para) }
            for style in styleChain { props.fill(style.para) }
            if let numLevel { props.fill(numLevel.para) }
            props.fill(defaultPara)
            let maxPoints = state.points > 0 ? state.points : Double(defaultHalfPoints) / 2

            func shaped(_ paragraph: DocumentParagraph) -> DocumentParagraph {
                var out = paragraph
                switch props.jc {
                case "center": out.alignment = .center
                case "right", "end": out.alignment = .right
                case "both", "distribute", "thaiDistribute": out.alignment = .justify
                case "left", "start": out.alignment = .left
                default: break
                }
                if let left = props.left, left != 0 { out.leftIndent = CGFloat(left) }
                if let first = props.first, first != 0 { out.firstLineIndent = CGFloat(first) }
                out.spaceBefore = props.before.map { CGFloat($0) }
                out.spaceAfter = props.after.map { CGFloat($0) }
                if let line = props.line, line > 0 {
                    let multiple: Double
                    if props.lineRule == nil || props.lineRule == "auto" { multiple = line / 240 }
                    else { multiple = (line / 20) / (maxPoints * 1.2) }     // 고정·최소 간격은 글자 크기의 배수로 근사
                    out.lineSpacing = CGFloat(min(max((multiple * 100).rounded() / 100, 0.5), 5))
                }
                return out
            }

            // 조각을 모아 문단으로: 그림은 그 문단의 앞(글보다 먼저 나온 것)·뒤로 옮겨 문단을 쪼개지 않는다
            var segmentRuns: [DocumentRun] = []
            var leading: [DocumentImage] = []
            var trailing: [DocumentImage] = []
            var markerPending = !marker.isEmpty
            func flush() {
                for image in leading { blocks.docxAdd(shaped(DocumentParagraph(runs: [], image: image))) }
                if !segmentRuns.isEmpty {
                    var runs = segmentRuns
                    if markerPending, let index = runs.firstIndex(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        var mark = runs[index]
                        mark.text = marker
                        mark.linkURL = nil
                        runs.insert(mark, at: index)
                        markerPending = false
                    }
                    let merged = Self.mergeRuns(runs)
                    if merged.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        let index = blocks.paragraphs.count
                        blocks.docxAdd(shaped(DocumentParagraph(runs: merged, headingLevel: level)))
                        if level == nil { sizeInfo[index] = (maxPoints, state.chars) } else { styleLevel.insert(index) }
                    }
                }
                for image in trailing { blocks.docxAdd(shaped(DocumentParagraph(runs: [], image: image))) }
                segmentRuns = []; leading = []; trailing = []
            }
            for piece in state.pieces {
                switch piece {
                case .runs(let runs): segmentRuns += runs
                case .image(let image): if segmentRuns.isEmpty { leading.append(image) } else { trailing.append(image) }
                case .table(let rows):
                    flush()
                    blocks.docxTable(rows, layout: nil)
                case .pageBreak:
                    flush()
                    blocks.pendingBreak = true
                }
            }
            flush()
            for text in state.blockEquations where !text.isEmpty {
                var run = DocumentRun("(수식) " + text)
                run.fontSize = nil
                blocks.docxAdd(shaped(DocumentParagraph(runs: [run])))
            }
            for box in state.textBoxes { walkBlocks(box) }

            // 구역 나눔(다음 쪽에서 시작)
            if let sect = pPr?.child("sectPr") {
                noteSection(sect)
                let type = sect.child("type")?.attr("val") ?? "nextPage"
                if type != "continuous" { blocks.pendingBreak = true }
            }
        }

        /// 같은 모양끼리 이어 붙이고 빈 조각은 뺀다
        static func mergeRuns(_ runs: [DocumentRun]) -> [DocumentRun] {
            var out: [DocumentRun] = []
            for run in runs where !run.text.isEmpty {
                if let last = out.last, last.sameStyle(as: run) { out[out.count - 1].text += run.text }
                else { out.append(run) }
            }
            return out
        }

        /// 번호 정의: (numId, 수준, 문단이 직접 달았는가)
        func numbering(pPr: OXNode?, styleChain: [Style]) -> (String, Int, Bool)? {
            var numId = pPr?.child("numPr")?.child("numId")?.attr("val")
            let direct = numId != nil
            var ilvl = pPr?.child("numPr")?.child("ilvl")?.attr("val").flatMap(Int.init)
            if numId == nil { numId = styleChain.compactMap(\.numId).first }
            if ilvl == nil { ilvl = styleChain.compactMap(\.ilvl).first }
            guard let id = numId, id != "0" else { return nil }
            return (id, ilvl ?? 0, direct)
        }

        /// 번호 표시 글자와 그 수준 정의. lvlText 틀의 %1~%9를 각 수준 값으로 바꾼다
        func listMarker(numId: String, ilvl: Int) -> (String, NumLevel?) {
            guard let abstractId = numToAbstract[numId] else { return ("• ", nil) }
            func level(_ index: Int) -> NumLevel? { levelOverrides[numId]?[index] ?? abstractLevels[abstractId]?[index] }
            func start(_ index: Int) -> Int { startOverrides[numId]?[index] ?? level(index)?.start ?? 1 }
            guard let current = level(ilvl) else { return ("• ", nil) }
            if current.fmt == "bullet" {
                return (DocxReader.bulletMark(current.text) + (current.suff == "nothing" ? "" : " "), current)
            }
            // 덮어쓰기가 있는 번호는 자기 번호끼리, 아니면 같은 목록 정의끼리 센다
            let key = (startOverrides[numId] != nil || levelOverrides[numId] != nil) ? "n" + numId : "a" + abstractId
            var values = counters[key] ?? [:]
            values[ilvl] = values[ilvl].map { $0 + 1 } ?? start(ilvl)
            for deeper in values.keys where deeper > ilvl { values[deeper] = nil }
            counters[key] = values
            if current.fmt == "none" && !current.text.contains("%") { return (current.text.isEmpty ? "" : current.text + " ", current) }
            var text = current.text
            for index in stride(from: 8, through: 0, by: -1) {
                let token = "%\(index + 1)"
                guard text.contains(token) else { continue }
                let shown = level(index).map { DocxReader.formatNumber(values[index] ?? start(index), $0.fmt) } ?? ""
                text = text.replacingOccurrences(of: token, with: shown)
            }
            if text.isEmpty { return ("", current) }
            return (text + (current.suff == "nothing" ? "" : " "), current)
        }

        // MARK: 문단 안

        func hyperlinkTarget(_ node: OXNode) -> String? {
            if let id = node.attr("id"), let target = externalLinks[id] { return target }
            return nil
        }

        /// 수식(m:oMath) 안 글: m:t만 이어 붙인다
        func equationText(_ node: OXNode) -> String {
            var out = ""
            func collect(_ n: OXNode) {
                for c in n.children {
                    if c.prefix == "m" && c.name == "t" { out += c.allText }
                    else if !c.isText { collect(c) }
                }
            }
            collect(node)
            return out
        }

        func walkInline(_ node: OXNode, _ state: ParaState) {
            for child in node.children {
                switch child.name {
                case "r": run(child, state)
                case "hyperlink":
                    let saved = state.link
                    if let target = hyperlinkTarget(child) { state.link = target }
                    walkInline(child, state)
                    state.link = saved
                case "fldSimple":
                    let instr = (child.attr("instr") ?? "").trimmingCharacters(in: .whitespaces)
                    if headerMode, instr.uppercased().hasPrefix("PAGE") {
                        state.add(DocumentRun(Self.pageMark), points: 0)
                    } else if let url = Self.hyperlinkURL(in: instr) {
                        let saved = state.link
                        state.link = url
                        walkInline(child, state)
                        state.link = saved
                    } else {
                        walkInline(child, state)
                    }
                case "ins", "smartTag", "sdtContent", "customXml", "moveTo", "bdo", "dir": walkInline(child, state)
                case "sdt": if let content = child.child("sdtContent") { walkInline(content, state) }
                case "ruby": if let base = child.child("rubyBase") { walkInline(base, state) }       // 본문 글만(읽는 법은 뺀다)
                case "oMathPara":
                    var parts: [String] = []
                    for math in child.children("oMath") { parts.append(equationText(math)) }
                    state.blockEquations.append(parts.joined(separator: " "))
                case "oMath":
                    let text = equationText(child)
                    if !text.isEmpty { state.add(DocumentRun(text), points: Double(defaultHalfPoints) / 2) }
                case "AlternateContent":
                    if let choice = child.child("Choice") ?? child.child("Fallback") { walkInline(choice, state) }
                default: break
                }
            }
        }

        /// HYPERLINK "주소" 필드 명령에서 주소
        static func hyperlinkURL(in instr: String) -> String? {
            guard instr.uppercased().hasPrefix("HYPERLINK"), let open = instr.firstIndex(of: "\"") else { return nil }
            let rest = instr[instr.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            let url = String(rest[..<close])
            return url.isEmpty ? nil : url
        }

        func run(_ r: OXNode, _ state: ParaState) {
            let rPr = r.child("rPr")
            if DocxReader.toggle(rPr, "vanish") == true { return }
            var cp = CharProps(rPr)
            for style in chain(rPr?.child("rStyle")?.attr("val")) { cp.fill(style.char) }
            for style in state.paragraphStyle { cp.fill(style.char) }
            let explicit = cp
            cp.fill(defaultChar)
            let half = cp.half ?? defaultHalfPoints
            let points = Double(half) / 2

            func emit(_ text: String) {
                guard !text.isEmpty else { return }
                var run = DocumentRun(text, bold: cp.bold ?? false, italic: cp.italic ?? false)
                run.underline = cp.underline ?? false
                run.strike = cp.strike ?? false
                run.script = cp.script ?? 0
                run.colorHex = DocxReader.colorHex(cp.color)
                run.fontSize = CGFloat(points)
                run.fontName = explicit.fontName(for: text) ?? defaultChar.defaultName
                run.linkURL = state.link
                state.add(run, points: points)
                if !state.plain, !state.suppress, !text.allSatisfy({ $0.isWhitespace }) {
                    sizeHistogram[half, default: 0] += text.count
                    if let name = run.fontName { nameHistogram[name, default: 0] += text.count }
                }
            }

            for item in r.children {
                switch item.name {
                case "t": emit(item.allText)
                case "tab", "ptab": emit("\t")
                case "br":
                    switch item.attr("type") {
                    case "page": if !state.plain { state.pieces.append(.pageBreak) }
                    case "column": break
                    default: emit("\n")
                    }
                case "cr": emit("\n")
                case "noBreakHyphen": emit("-")
                case "sym": if let s = DocxReader.symbol(font: item.attr("font"), char: item.attr("char")) { emit(s) }
                case "footnoteReference":
                    if let id = item.attr("id") { emitNote(id: id, endnote: false, state: state, emit: emit, cp: cp) }
                case "endnoteReference":
                    if let id = item.attr("id") { emitNote(id: id, endnote: true, state: state, emit: emit, cp: cp) }
                case "fldChar":
                    switch item.attr("fldCharType") {
                    case "begin": state.fields.append(Field())
                    case "separate":
                        guard var field = state.fields.popLast() else { break }
                        field.inResult = true
                        let instr = field.instr.trimmingCharacters(in: .whitespaces)
                        field.savedLink = state.link
                        if let url = Self.hyperlinkURL(in: instr) { state.link = url }
                        let word = instr.uppercased().split(separator: " ").first.map(String.init) ?? ""
                        let isPage = headerMode && word == "PAGE"
                        if isPage { state.add(DocumentRun(Self.pageMark), points: 0) }
                        field.suppress = isPage
                        state.fields.append(field)
                    case "end":
                        if let field = state.fields.popLast(), field.inResult { state.link = field.savedLink }
                    default: break
                    }
                case "instrText":
                    if var field = state.fields.popLast() {
                        if !field.inResult { field.instr += item.allText }
                        state.fields.append(field)
                    }
                case "drawing": drawing(item, state)
                case "pict": picture(item, state)
                case "AlternateContent":
                    if let choice = item.child("Choice") ?? item.child("Fallback") {
                        for inner in choice.children {
                            if inner.name == "drawing" { drawing(inner, state) } else if inner.name == "pict" { picture(inner, state) }
                        }
                    }
                default: break
                }
            }
        }

        /// 각주·미주 참조: 본문 자리에는 위첨자 번호
        func emitNote(id: String, endnote: Bool, state: ParaState, emit: (String) -> Void, cp: CharProps) {
            var number: Int
            if endnote {
                if let known = endnoteNumbers[id] { number = known } else { endnoteOrder.append(id); number = endnoteOrder.count; endnoteNumbers[id] = number }
            } else {
                if let known = footnoteNumbers[id] { number = known } else { footnoteOrder.append(id); number = footnoteOrder.count; footnoteNumbers[id] = number }
            }
            var run = DocumentRun("\(number)", bold: cp.bold ?? false, italic: cp.italic ?? false)
            run.script = 1
            run.fontSize = CGFloat(Double(cp.half ?? defaultHalfPoints) / 2)
            run.linkURL = state.link
            state.add(run, points: Double(cp.half ?? defaultHalfPoints) / 2)
        }

        /// 본문 끝에 "각주 1. …" "미주 1. …" 문단
        func appendNotes() {
            func notes(file: String, element: String, ids: [String], label: String) {
                guard !ids.isEmpty, let root = package.xml(folderPrefix + file) else { return }
                var byId: [String: OXNode] = [:]
                for node in root.children(element) {
                    if let id = node.attr("id"), node.attr("type") == nil || node.attr("type") == "normal" { byId[id] = node }
                }
                for (index, id) in ids.enumerated() {
                    guard let node = byId[id] else { continue }
                    let text = cellText(node).replacingOccurrences(of: "\n", with: " ")
                    guard !text.isEmpty else { continue }
                    blocks.docxAdd(DocumentParagraph(runs: [DocumentRun("\(label) \(index + 1). \(text)")]))
                }
            }
            notes(file: "footnotes.xml", element: "footnote", ids: footnoteOrder, label: "각주")
            notes(file: "endnotes.xml", element: "endnote", ids: endnoteOrder, label: "미주")
        }

        // MARK: 그림

        func imageData(relationship id: String, size: CGSize?) -> DocumentImage? {
            if let cached = imageCache[id] { return cached.map { image in
                var copy = image
                if let size, size.width > 0, size.height > 0 { copy.size = size }
                return copy
            } }
            var result: DocumentImage?
            if let path = relationships[id], let data = package.data(path) ?? package.dataIgnoringCase(path) {
                result = ReaderImage.image(from: data, size: nil)
            }
            imageCache[id] = .some(result)
            guard var image = result else { return nil }
            if let size, size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite { image.size = size }
            return image
        }

        /// srcRect(왼쪽·위·오른쪽·아래를 1/1000 퍼센트로)만큼 잘라 낸 그림
        static func cropped(_ image: DocumentImage, rect node: OXNode) -> DocumentImage {
            func fraction(_ key: String) -> Double { (node.attr(key).flatMap(Double.init) ?? 0) / 100_000 }
            let l = fraction("l"), t = fraction("t"), r = fraction("r"), b = fraction("b")
            guard l >= 0, t >= 0, r >= 0, b >= 0, l + r < 0.98, t + b < 0.98, l + t + r + b > 0.0005,
                  let source = CGImageSourceCreateWithData(image.png as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return image }
            let w = Double(cg.width), h = Double(cg.height)
            let box = CGRect(x: w * l, y: h * t, width: w * (1 - l - r), height: h * (1 - t - b)).integral
            guard box.width >= 1, box.height >= 1, let part = cg.cropping(to: box) else { return image }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return image }
            CGImageDestinationAddImage(dest, part, nil)
            guard CGImageDestinationFinalize(dest) else { return image }
            var copy = image
            copy.png = out as Data
            return copy
        }

        func drawing(_ node: OXNode, _ state: ParaState) {
            var boxes: [OXNode] = []
            node.descendants("txbxContent", into: &boxes)
            state.textBoxes += boxes
            guard let blip = node.firstDescendant("blip"), let id = blip.attr("embed") ?? blip.attr("link") else { return }
            var size: CGSize?
            if let extent = node.firstDescendant("extent"), let cx = extent.attr("cx").flatMap(Double.init), let cy = extent.attr("cy").flatMap(Double.init), cx > 0, cy > 0 {
                size = CGSize(width: cx / 12700, height: cy / 12700)
            }
            if var image = imageData(relationship: id, size: size) {
                if let rect = node.firstDescendant("srcRect") { image = Self.cropped(image, rect: rect) }
                state.pieces.append(.image(image))
            } else {
                missingPicture(state)      // EMF·WMF 같은 못 그리는 그림
            }
        }

        func missingPicture(_ state: ParaState) {
            guard !state.plain else { return }
            state.add(DocumentRun("[그림]"), points: Double(defaultHalfPoints) / 2)
        }

        /// 옛 방식 그림(VML): v:imagedata r:id, 크기는 style의 width·height. v:textbox 안 글도 챙긴다
        func picture(_ node: OXNode, _ state: ParaState) {
            var boxes: [OXNode] = []
            node.descendants("txbxContent", into: &boxes)
            state.textBoxes += boxes
            guard let data = node.firstDescendant("imagedata"), let id = data.attr("id") else { return }
            var size: CGSize?
            if let shape = node.firstDescendant("shape"), let style = shape.attr("style") {
                func value(_ key: String) -> Double? {
                    guard let r = style.range(of: key + ":\\s*[0-9.]+(pt|px)?", options: .regularExpression) else { return nil }
                    let piece = style[r].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                    let number = Double(piece.filter { $0.isNumber || $0 == "." }) ?? 0
                    return piece.hasSuffix("px") ? number * 0.75 : number
                }
                if let w = value("width"), let h = value("height"), w > 0, h > 0 { size = CGSize(width: w, height: h) }
            }
            if let image = imageData(relationship: id, size: size) { state.pieces.append(.image(image)) } else { missingPicture(state) }
        }

        // MARK: 표

        struct TableInfo {
            var rows: [[String]]
            var images: [DocumentImage]
            var layout: DocumentTableLayout
        }

        func table(_ tbl: OXNode) -> TableInfo {
            var rows: [[String]] = []
            var images: [DocumentImage] = []
            /// 줄마다 칸 위치·가로 칸 수·세로 합침("restart"/"continue")
            var cells: [[(col: Int, span: Int, merge: String?)]] = []
            var headerFlags: [Bool] = []
            var cellBorders = false
            var cellWidths: [[Double]] = []
            for tr in tbl.children("tr") {
                var row: [String] = []
                var info: [(col: Int, span: Int, merge: String?)] = []
                var widths: [Double] = []
                if let before = tr.child("trPr")?.child("gridBefore")?.attr("val").flatMap(Int.init), before > 0 {
                    row += Array(repeating: "", count: min(before, 200))
                }
                for tc in tr.children("tc") {
                    cellImages = []
                    let col = row.count
                    row.append(cellText(tc))
                    images += cellImages
                    let tcPr = tc.child("tcPr")
                    let span = min(max(tcPr?.child("gridSpan")?.attr("val").flatMap(Int.init) ?? 1, 1), 200)
                    if span > 1 { row += Array(repeating: "", count: span - 1) }
                    var merge: String?
                    if let vMerge = tcPr?.child("vMerge") { merge = vMerge.attr("val") == "restart" ? "restart" : "continue" }
                    info.append((col, span, merge))
                    if DocxReader.hasBorders(tcPr?.child("tcBorders")) == true { cellBorders = true }
                    if let w = tcPr?.child("tcW"), w.attr("type") != "auto", let v = w.attr("w").flatMap(Double.init), v > 0 { widths.append(v) } else { widths.append(0) }
                }
                if let after = tr.child("trPr")?.child("gridAfter")?.attr("val").flatMap(Int.init), after > 0 {
                    row += Array(repeating: "", count: min(after, 200))
                }
                rows.append(row)
                cells.append(info)
                cellWidths.append(widths)
                headerFlags.append(tr.child("trPr")?.child("tblHeader") != nil)
            }
            var layout = DocumentTableLayout(headerRows: 0, borders: true)
            let columns = rows.map(\.count).max() ?? 0

            // 합친 칸
            for (r, info) in cells.enumerated() {
                for cell in info {
                    if cell.merge == "continue" { continue }
                    var down = 1
                    if cell.merge == "restart" {
                        var next = r + 1
                        while next < cells.count, cells[next].contains(where: { $0.col == cell.col && $0.merge == "continue" }) { down += 1; next += 1 }
                    }
                    if cell.span > 1 || down > 1 {
                        layout.spans.append(DocumentCellSpan(row: r, column: cell.col, columns: cell.span, rows: down))
                    }
                }
            }

            // 칸 너비: tblGrid → 없으면 합치지 않은 줄의 tcW
            let grid = (tbl.child("tblGrid")?.children("gridCol") ?? []).compactMap { $0.attr("w").flatMap(Double.init) }
            if grid.count == columns, grid.allSatisfy({ $0 > 0 }) {
                let total = grid.reduce(0, +)
                layout.columnWidths = grid.map { CGFloat($0 / total) }
            } else if let plain = zip(cells, cellWidths).first(where: { $0.0.count == columns && $0.0.allSatisfy { $0.span == 1 } && $0.1.allSatisfy { $0 > 0 } }) {
                let total = plain.1.reduce(0, +)
                layout.columnWidths = plain.1.map { CGFloat($0 / total) }
            }

            // 머리줄: 위에서부터 이어진 tblHeader 줄(10줄 넘으면 머리줄로 안 본다). 없으면 표 스타일의 첫 줄 굵게(tblLook firstRow)
            var header = 0
            while header < headerFlags.count, headerFlags[header] { header += 1 }
            if header > 10 { header = 0 }
            let tblPr = tbl.child("tblPr")
            let styleChain = chain(tblPr?.child("tblStyle")?.attr("val") ?? defaultTableStyle)
            if header == 0, rows.count > 1, let look = tblPr?.child("tblLook") {
                let hex = look.attr("val").flatMap { Int($0, radix: 16) }
                let firstRow = look.attr("firstRow").map { $0 == "1" || $0.lowercased() == "true" } ?? (hex.map { $0 & 0x20 != 0 } ?? false)
                if firstRow, styleChain.compactMap(\.firstRowBold).first == true { header = 1 }
            }
            layout.headerRows = header

            // 테두리: 표(없으면 스타일 사슬)에 그리는 변이 있거나 칸 테두리가 하나라도 있으면
            let drawn = DocxReader.hasBorders(tblPr?.child("tblBorders")) ?? styleChain.compactMap(\.tableBorders).first ?? false
            layout.borders = drawn || cellBorders
            return TableInfo(rows: rows, images: images, layout: layout)
        }

        /// 칸 안 글: 문단은 줄바꿈으로, 안쪽 표는 칸을 탭·줄을 줄바꿈으로 풀어서
        func cellText(_ tc: OXNode) -> String {
            guard depth < 40 else { return "" }
            depth += 1
            defer { depth -= 1 }
            var lines: [String] = []
            for node in tc.children {
                switch node.name {
                case "p":
                    let state = ParaState()
                    state.plain = true
                    state.paragraphStyle = chain(node.child("pPr")?.child("pStyle")?.attr("val") ?? defaultParagraphStyle)
                    walkInline(node, state)
                    var text = ""
                    for piece in state.pieces {
                        switch piece {
                        case .runs(let runs): text += runs.map(\.text).joined()
                        case .image(let image): cellImages.append(image)
                        default: break
                        }
                    }
                    lines.append(text)
                    for equation in state.blockEquations where !equation.isEmpty { lines.append("(수식) " + equation) }
                    for box in state.textBoxes { lines.append(cellText(box)) }          // 칸 안 글상자
                case "tbl":
                    let inner = table(node)
                    let saved = cellImages
                    lines.append(inner.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
                    cellImages = saved + inner.images
                case "sdt":
                    if let content = node.child("sdtContent") { lines.append(cellText(content)) }
                default: break
                }
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: 머리글·꼬리글

        /// 머리글·꼬리글 파일의 글 문단. 쪽 번호 필드가 있으면 hasPage(글자가 남지 않는 문단은 뺀다)
        func readHeaderFooter(_ path: String?) -> (paragraphs: [DocumentParagraph], hasPage: Bool) {
            guard let path, let root = package.xml(path) else { return ([], false) }
            let saved = (blocks, sizeInfo, styleLevel, headerMode, depth)
            blocks = ReaderBlocks()
            sizeInfo = [:]; styleLevel = []
            headerMode = true
            walkBlocks(root)
            var paragraphs = blocks.paragraphs.filter { $0.table == nil && $0.image == nil }
            (blocks, sizeInfo, styleLevel, headerMode, depth) = saved
            var hasPage = false
            paragraphs = paragraphs.compactMap { paragraph in
                var p = paragraph
                guard p.runs.contains(where: { $0.text.contains(Self.pageMark) }) else { return p }
                hasPage = true
                for i in p.runs.indices { p.runs[i].text = p.runs[i].text.replacingOccurrences(of: Self.pageMark, with: "") }
                p.runs = Self.mergeRuns(p.runs)
                // "- 3 -" 같은 틀만 남으면 쪽 번호 표시로 대신한다
                return p.text.contains(where: { $0.isLetter || $0.isNumber }) ? p : nil
            }
            return (paragraphs, hasPage)
        }

        // MARK: 마무리

        /// 스타일로 제목을 못 정한 문단은 글자 크기로 짐작
        func finishHeadings() {
            var histogram: [Int: Int] = [:]
            for (index, info) in sizeInfo where !styleLevel.contains(index) {
                histogram[Int((info.points * 2).rounded()), default: 0] += info.chars
            }
            guard let bodyHalf = readerBodySize(histogram) else { return }
            let body = Double(bodyHalf) / 2
            for (index, info) in sizeInfo where info.chars <= 100 && blocks.paragraphs[index].table == nil {
                if let level = readerSizeLevel(size: info.points, body: body) {
                    blocks.paragraphs[index].headingLevel = level
                }
            }
        }

        /// 본문 글자 크기·글꼴(가장 많은 글자에 쓰인 것)을 정하고, 그와 같은 조각은 "본문 그대로"(nil)로 둔다. 제목은 크기를 비운다
        func normalizeBody(_ result: inout Result) {
            let bodyHalf = sizeHistogram.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
            let bodyName = nameHistogram.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
            result.bodyFontSize = bodyHalf.map { CGFloat($0) / 2 }
            result.bodyFontName = bodyName
            func clean(_ paragraphs: inout [DocumentParagraph]) {
                for i in paragraphs.indices {
                    let heading = paragraphs[i].headingLevel != nil
                    for j in paragraphs[i].runs.indices {
                        if heading { paragraphs[i].runs[j].fontSize = nil }
                        else if let size = paragraphs[i].runs[j].fontSize, let bodyHalf, Int((size * 2).rounded()) == bodyHalf { paragraphs[i].runs[j].fontSize = nil }
                        if let name = paragraphs[i].runs[j].fontName, name == bodyName { paragraphs[i].runs[j].fontName = nil }
                    }
                }
            }
            clean(&result.paragraphs)
            clean(&result.header)
            clean(&result.footer)
        }
    }
}

extension ReaderBlocks {
    /// 쪽 나눔 예약을 붙여서 덩어리를 더한다(문단 모양을 가진 채로)
    mutating func docxAdd(_ paragraph: DocumentParagraph) {
        var p = paragraph
        if pendingBreak {
            p.pageBreakBefore = !paragraphs.isEmpty
            pendingBreak = false
        }
        paragraphs.append(p)
    }

    /// 표: 줄마다 칸 수를 맞추고 글 앞뒤 빈칸을 다듬는다. 글이 없는 표(빈 양식)도 남긴다
    mutating func docxTable(_ rows: [[String]], layout: DocumentTableLayout?) {
        let cleaned = Self.normalizeTable(rows)
        guard !cleaned.isEmpty, cleaned[0].count > 0 else { return }
        var paragraph = DocumentParagraph(runs: [], table: cleaned)
        paragraph.tableLayout = layout
        docxAdd(paragraph)
    }
}
