import CoreGraphics
import Foundation

/// 한글(.hwpx, OWPML)을 직접 뜯어 읽는다(XML 글자만 줄 단위로 뽑으면 표가 칸마다 한 줄씩 나오므로).
/// - 문단(hp:p): 제목은 문단 스타일("개요 1" 등)·문단 모양의 개요 수준, 없으면 글자 크기·굵기로. 굵게·기울임은 header.xml의 글자 모양(charPr)
/// - 표(hp:tbl): 칸 주소(cellAddr)로 줄 × 칸을 만들고, 병합된 칸은 빈 칸으로 둔다. 표 안 문단은 바깥 문단으로 나오지 않는다
/// - 그림(hp:pic): hc:img의 binaryItemIDRef → content.hpf 목록 → BinData 파일을 PNG로. 크기는 hwpunit ÷ 100 = pt
/// - 쪽 나눔: pageBreak="1"·문단 모양의 pageBreakBefore / 쪽 크기: hp:pagePr(hwpunit ÷ 100 = pt)
/// - 문단 모양(정렬·들여쓰기·간격·줄 간격)·글자 모양(밑줄·취소선·첨자·색·크기·글꼴)·쪽 여백·머리글/꼬리글/쪽 번호·표 칸 너비/합친 칸/머리줄/테두리 없음·수식·글상자 글을 같이 읽는다
enum HwpxReader {
    typealias Result = HangulDocument

    /// 읽을 수 없는 파일(zip이 아니거나 구역 파일이 없음)이면 nil
    static func read(_ url: URL) -> Result? {
        guard let package = ZipPackage(url) else { return nil }
        let sections = package.names
            .filter { $0.range(of: "^Contents/section[0-9]+\\.xml$", options: .regularExpression) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !sections.isEmpty else { return nil }
        let reader = Reader(package: package)
        for path in sections {
            guard let root = package.xml(path) else { continue }
            reader.walkSection(root)
        }
        reader.finishHeadings()
        reader.blocks.paragraphs += reader.footnotes
        guard !reader.blocks.paragraphs.isEmpty else { return nil }
        var result = HangulDocument(paragraphs: reader.blocks.paragraphs, pageSize: reader.pageSize)
        result.margins = reader.margins
        result.header = reader.headerParagraphs
        result.footer = reader.footerParagraphs
        result.showPageNumber = reader.showPageNumber
        if let body = readerBodySize(reader.heightHistogram) { result.bodyFontSize = CGFloat(body) / 100 }
        result.bodyFontName = reader.fontHistogram.max { $0.value < $1.value }?.key
        result.normalizeBodyFont()
        return result
    }

    private struct CharShape {
        var height = 1000
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var script = 0
        var colorHex: String?
        var fontName: String?
    }
    private struct ParaShape {
        var headingType = "NONE"
        var headingLevel = 0
        var headingID = "0"
        var pageBreakBefore = false
        var known = false
        var alignment: DocumentAlignment?
        var intent: CGFloat?
        var left: CGFloat?
        var prev: CGFloat?
        var next: CGFloat?
        var lineType = "PERCENT"
        var lineValue: CGFloat?
    }
    private enum Piece {
        case runs([DocumentRun])
        case image(DocumentImage)
        case table([[String]], DocumentTableLayout)
        case pageBreak
    }
    private struct ParaStyle { var name = ""; var paraPr: String?; var charPr: String? }

    private final class Reader {
        let package: ZipPackage
        var charShapes: [String: CharShape] = [:]
        var paraShapes: [String: ParaShape] = [:]
        var styles: [String: ParaStyle] = [:]
        var faces: [String: [String: String]] = [:]       // 언어 → 글꼴 번호 → 이름
        var borderFills: [String: Bool] = [:]             // 테두리·배경 번호 → 선이 하나라도 있는가
        var binaryItems: [String: String] = [:]          // 그림 번호 → 패키지 안 경로
        var blocks = ReaderBlocks()
        var pageSize: CGSize?
        var margins: DocumentMargins?
        var headerParagraphs: [DocumentParagraph] = []
        var footerParagraphs: [DocumentParagraph] = []
        var showPageNumber = false
        var footnotes: [DocumentParagraph] = []
        var heightHistogram: [Int: Int] = [:]
        var fontHistogram: [String: Int] = [:]
        var imageCache: [String: DocumentImage?] = [:]
        var cellImages: [DocumentImage] = []
        var counters: [String: Int] = [:]
        var sizeInfo: [Int: (height: Int, bold: Bool, chars: Int)] = [:]
        var levelFixed: Set<Int> = []
        var depth = 0

        init(package: ZipPackage) {
            self.package = package
            let headerPath = package.contains("Contents/header.xml") ? "Contents/header.xml" : package.names.first { $0.hasSuffix("header.xml") }
            if let headerPath, let head = package.xml(headerPath) { loadHeader(head) }
            let manifestPath = package.contains("Contents/content.hpf") ? "Contents/content.hpf" : package.names.first { $0.hasSuffix(".hpf") }
            if let manifestPath, let manifest = package.xml(manifestPath) {
                var items: [OXNode] = []
                manifest.descendants("item", into: &items)
                for item in items {
                    if let id = item.attr("id"), let href = item.attr("href") { binaryItems[id] = ZipPackage.resolve(href, relativeTo: "x") }
                }
            }
        }

        /// 문단 모양 안의 항목: 바로 아래 → switch/case(HWPUNIT) → switch/default(옛 단위, 2배 값). 두 번째 값은 "2배 값인가"
        static func shapeNode(_ node: OXNode, _ name: String) -> (OXNode, Bool)? {
            if let direct = node.child(name) { return (direct, false) }
            if let sw = node.child("switch") {
                if let found = sw.child("case")?.child(name) { return (found, false) }
                if let found = sw.child("default")?.child(name) { return (found, true) }
            }
            return nil
        }

        func loadHeader(_ head: OXNode) {
            var chars: [OXNode] = [], paras: [OXNode] = [], styleNodes: [OXNode] = []
            var faceNodes: [OXNode] = [], fills: [OXNode] = []
            head.descendants("charPr", into: &chars)
            head.descendants("paraPr", into: &paras)
            head.descendants("style", into: &styleNodes)
            head.descendants("fontface", into: &faceNodes)
            head.descendants("borderFill", into: &fills)
            for face in faceNodes {
                let lang = (face.attr("lang") ?? "").uppercased()
                for font in face.children("font") {
                    if let id = font.attr("id"), let name = font.attr("face") { faces[lang, default: [:]][id] = name }
                }
            }
            for node in fills {
                guard let id = node.attr("id") else { continue }
                let sides = ["leftBorder", "rightBorder", "topBorder", "bottomBorder"]
                borderFills[id] = sides.contains { side in
                    guard let type = node.child(side)?.attr("type")?.uppercased() else { return false }
                    return type != "NONE"
                }
            }
            for node in chars {
                guard let id = node.attr("id") else { continue }
                var shape = CharShape(height: node.attr("height").flatMap(Int.init) ?? 1000,
                                      bold: node.child("bold") != nil, italic: node.child("italic") != nil)
                if let type = node.child("underline")?.attr("type")?.uppercased() { shape.underline = type == "BOTTOM" }
                if let strike = node.child("strikeout")?.attr("shape")?.uppercased() { shape.strike = strike != "NONE" }
                if node.child("supscript") != nil { shape.script = 1 } else if node.child("subscript") != nil { shape.script = -1 }
                if let color = node.attr("textColor"), color.hasPrefix("#"), color.count == 7 {
                    let hex = String(color.dropFirst()).uppercased()
                    shape.colorHex = hex == "000000" ? nil : hex
                }
                if let ref = node.child("fontRef") {
                    for (lang, key) in [("HANGUL", "hangul"), ("LATIN", "latin")] {
                        if let fid = ref.attr(key), let name = faces[lang]?[fid], !name.isEmpty { shape.fontName = name; break }
                    }
                }
                charShapes[id] = shape
            }
            for node in paras {
                guard let id = node.attr("id") else { continue }
                var shape = ParaShape()
                if let heading = node.child("heading") {
                    shape.headingType = heading.attr("type") ?? "NONE"
                    shape.headingLevel = min(max(heading.attr("level").flatMap(Int.init) ?? 0, 0), 9)
                    shape.headingID = heading.attr("idRef") ?? "0"
                }
                shape.pageBreakBefore = node.child("breakSetting")?.attr("pageBreakBefore") == "1"
                if let align = node.child("align")?.attr("horizontal")?.uppercased() {
                    shape.known = true
                    switch align {
                    case "LEFT": shape.alignment = .left
                    case "RIGHT": shape.alignment = .right
                    case "CENTER": shape.alignment = .center
                    default: shape.alignment = .justify
                    }
                }
                if let (margin, doubled) = Self.shapeNode(node, "margin") {
                    shape.known = true
                    func value(_ name: String) -> CGFloat? {
                        guard let v = margin.child(name)?.attr("value").flatMap(Double.init) else { return nil }
                        return CGFloat(v) / (doubled ? 200 : 100)
                    }
                    shape.intent = value("intent")
                    shape.left = value("left")
                    shape.prev = value("prev")
                    shape.next = value("next")
                }
                if let (line, doubled) = Self.shapeNode(node, "lineSpacing"), let v = line.attr("value").flatMap(Double.init) {
                    shape.known = true
                    shape.lineType = (line.attr("type") ?? "PERCENT").uppercased()
                    shape.lineValue = shape.lineType == "PERCENT" ? CGFloat(v) : CGFloat(v) / (doubled ? 200 : 100)
                }
                paraShapes[id] = shape
            }
            for node in styleNodes {
                guard let id = node.attr("id") else { continue }
                styles[id] = ParaStyle(name: node.attr("name") ?? node.attr("engName") ?? "",
                                       paraPr: node.attr("paraPrIDRef"), charPr: node.attr("charPrIDRef"))
            }
        }

        // MARK: 구역 훑기

        func walkSection(_ root: OXNode) {
            for p in root.children("p") { paragraph(p, top: true) }
        }

        static func headingLevel(fromStyleName name: String) -> Int? {
            let n = name.lowercased().replacingOccurrences(of: " ", with: "")
            if n == "title" || n == "제목" { return 1 }
            for prefix in ["개요", "outline", "제목", "heading"] where n.hasPrefix(prefix) {
                if let value = Int(n.dropFirst(prefix.count)), value >= 1 { return min(value, 3) }
            }
            return nil
        }

        // MARK: 문단

        final class State {
            var pieces: [Piece] = []
            var height = 0
            var chars = 0
            var allBold = true
            var plain = false
            var pagePr: OXNode?
            var link: String?
            /// 글상자(떠 있는 상자) 안의 글: 본문 문단 뒤에 따로 문단으로 놓는다
            var boxes: [String] = []

            func add(_ text: String, shape: CharShape) {
                guard !text.isEmpty else { return }
                var run = DocumentRun(text, bold: shape.bold, italic: shape.italic)
                run.underline = shape.underline
                run.strike = shape.strike
                run.script = shape.script
                run.colorHex = shape.colorHex
                run.fontSize = CGFloat(shape.height) / 100
                run.fontName = shape.fontName
                run.linkURL = link
                if case .runs(var runs)? = pieces.last {
                    pieces.removeLast()
                    if let last = runs.last, last.sameStyle(as: run) { runs[runs.count - 1].text += text } else { runs.append(run) }
                    pieces.append(.runs(runs))
                } else {
                    pieces.append(.runs([run]))
                }
                if !text.allSatisfy({ $0.isWhitespace }) {
                    height = max(height, shape.height)
                    chars += text.count
                    if !shape.bold { allBold = false }
                }
            }
        }

        /// 문단 모양을 문단에 입힌다
        func applyShape(_ shape: ParaShape, to paragraph: inout DocumentParagraph, fontPoints: CGFloat) {
            guard shape.known else { return }
            paragraph.alignment = shape.alignment
            paragraph.leftIndent = shape.left ?? 0
            paragraph.firstLineIndent = shape.intent ?? 0
            paragraph.spaceBefore = shape.prev
            paragraph.spaceAfter = shape.next
            if let value = shape.lineValue {
                if shape.lineType == "PERCENT" { paragraph.lineSpacing = value / 100 }
                else if shape.lineType == "FIXED" || shape.lineType == "AT_LEAST" {
                    paragraph.lineSpacing = HangulRuns.multiple(fixedPoints: value, fontPoints: fontPoints)
                }
            }
        }

        func paragraph(_ p: OXNode, top: Bool) {
            let paraID = p.attr("paraPrIDRef")
            let shape = paraID.flatMap { paraShapes[$0] } ?? ParaShape()
            let style = p.attr("styleIDRef").flatMap { styles[$0] }

            if p.attr("pageBreak") == "1" || shape.pageBreakBefore { blocks.pendingBreak = true }

            // 제목 단계: 문단 스타일 이름 → 문단 모양의 개요 수준
            var level: Int?
            if let name = style?.name, let found = Self.headingLevel(fromStyleName: name) { level = found }
            else if let styleShape = style?.paraPr.flatMap({ paraShapes[$0] }), styleShape.headingType == "OUTLINE" { level = min(styleShape.headingLevel + 1, 3) }
            if level == nil, shape.headingType == "OUTLINE" { level = min(shape.headingLevel + 1, 3) }

            let state = State()
            collect(p, state)
            if let pagePr = state.pagePr { notePage(pagePr) }

            // 목록 표시
            var marker = ""
            if level == nil {
                switch shape.headingType {
                case "BULLET": marker = "• "
                case "NUMBER":
                    let key = shape.headingID + ":" + String(shape.headingLevel)
                    counters[key, default: 0] += 1
                    marker = "\(counters[key]!). "
                default: break
                }
            }
            if marker.isEmpty { counters.removeAll() }

            var markerPending = !marker.isEmpty
            for piece in state.pieces {
                switch piece {
                case .runs(var runs):
                    if markerPending, runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        runs.insert(DocumentRun(marker), at: 0)
                        markerPending = false
                    }
                    let index = blocks.paragraphs.count
                    if addText(runs, level: level, shape: shape, fontPoints: CGFloat(state.height) / 100) {
                        if level == nil { sizeInfo[index] = (state.height, state.allBold && state.chars > 0, state.chars) }
                        else { levelFixed.insert(index) }
                    }
                case .image(let image): blocks.image(image)
                case .table(let rows, let layout): addTable(rows, layout: layout)
                case .pageBreak: blocks.pendingBreak = true
                }
            }
            for box in state.boxes where !box.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for line in box.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    addText([DocumentRun(line)], level: nil, shape: ParaShape(), fontPoints: 10)
                }
            }
        }

        @discardableResult
        func addText(_ runs: [DocumentRun], level: Int?, shape: ParaShape, fontPoints: CGFloat) -> Bool {
            let merged = HangulRuns.merge(runs)
            guard HangulRuns.hasVisibleText(merged) else { return false }
            var paragraph = DocumentParagraph(runs: merged, headingLevel: level)
            applyShape(shape, to: &paragraph, fontPoints: fontPoints)
            blocks.addKeepingStyle(paragraph)
            return true
        }

        /// 표는 글이 하나도 없어도 버리지 않는다(빈 양식 칸)
        func addTable(_ rows: [[String]], layout: DocumentTableLayout) {
            let cleaned = ReaderBlocks.normalizeTable(rows)
            guard !cleaned.isEmpty else { return }
            var paragraph = DocumentParagraph(runs: [], table: cleaned)
            paragraph.tableLayout = layout
            blocks.addKeepingStyle(paragraph)
        }

        /// hp:p 안의 run들을 차례로 읽어 글·표·그림 조각으로
        func collect(_ p: OXNode, _ state: State) {
            for run in p.children("run") {
                let shape = run.attr("charPrIDRef").flatMap { charShapes[$0] } ?? CharShape()
                for item in run.children {
                    switch item.name {
                    case "t":
                        let text = text(of: item)
                        state.add(text, shape: shape)
                        if !state.plain, !text.allSatisfy({ $0.isWhitespace }) {
                            heightHistogram[shape.height, default: 0] += text.count
                            if let name = shape.fontName { fontHistogram[name, default: 0] += text.count }
                        }
                    case "tbl":
                        guard depth < 40 else { continue }
                        depth += 1
                        let (rows, layout, images) = table(item)
                        depth -= 1
                        if state.plain {
                            state.pieces.append(.runs([DocumentRun(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))]))
                            cellImages += images
                        } else {
                            state.pieces.append(.table(rows, layout))
                            for image in images { state.pieces.append(.image(image)) }
                        }
                    case "pic":
                        if let image = picture(item) { if state.plain { cellImages.append(image) } else { state.pieces.append(.image(image)) } }
                    case "container":
                        // 묶음 안의 그림·글상자. 가장 바깥 것만 모은다(글상자 안 그림·글상자는 addBox가 다시 찾는다).
                        // descendants로 모으면 겹친 글상자를 깊이마다 또 훑어서 이상한 파일에서 멈췄다
                        var parts: [OXNode] = []
                        item.outermostDescendants(["pic", "drawText"], into: &parts)
                        for part in parts {
                            if part.name == "drawText" { addBox(part, state); continue }
                            if let image = picture(part) { if state.plain { cellImages.append(image) } else { state.pieces.append(.image(image)) } }
                        }
                    case "rect", "ellipse", "arc", "polygon", "curve", "connectLine", "textart":
                        if let box = item.firstDescendant("drawText") { addBox(box, state) }
                        var parts: [OXNode] = []
                        item.outermostDescendants(["pic", "drawText"], into: &parts)     // 글상자 안 그림은 addBox가 이미 챙김
                        for pic in parts where pic.name == "pic" { if let image = picture(pic) { if state.plain { cellImages.append(image) } else { state.pieces.append(.image(image)) } } }
                    case "equation":
                        // 수식 스크립트 글을 그대로
                        if let script = item.firstDescendant("script")?.allText.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
                            state.add(script, shape: shape)
                        }
                    case "ctrl":
                        control(item, state, shape: shape)
                    case "secPr":
                        if state.pagePr == nil { state.pagePr = item.child("pagePr") }
                    default: break
                    }
                }
            }
        }

        /// 글상자(drawText) 안 글
        func addBox(_ drawText: OXNode, _ state: State) {
            guard let list = drawText.child("subList") ?? drawText.firstDescendant("subList") else { return }
            let saved = cellImages
            cellImages = []
            let lines = plainLines(list)
            let images = cellImages
            cellImages = saved
            let text = lines.joined(separator: "\n")
            if state.plain {
                if !text.isEmpty { state.pieces.append(.runs([DocumentRun("\n" + text)])) }
                cellImages += images
            } else {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.boxes.append(text) }
                for image in images { state.pieces.append(.image(image)) }
            }
        }

        /// hp:ctrl 안: 머리글·꼬리글·쪽 번호·각주·하이퍼링크
        func control(_ ctrl: OXNode, _ state: State, shape: CharShape) {
            for item in ctrl.children {
                switch item.name {
                case "header", "footer":
                    guard let list = item.child("subList") ?? item.firstDescendant("subList") else { continue }
                    let isHeader = item.name == "header"
                    if isHeader ? !headerParagraphs.isEmpty : !footerParagraphs.isEmpty { continue }   // 첫 것만(홀·짝 따로여도)
                    var out: [DocumentParagraph] = []
                    for p in list.children("p") {
                        if let simple = simpleParagraph(p) { out.append(simple) }
                    }
                    if isHeader { headerParagraphs = out } else { footerParagraphs = out }
                case "pageNum":
                    showPageNumber = true
                case "autoNum":
                    if (item.attr("numType") ?? "").uppercased() == "PAGE" { showPageNumber = true }
                case "footNote", "endNote":
                    guard let list = item.child("subList") ?? item.firstDescendant("subList") else { continue }
                    let number = footnoteNumber + 1
                    footnoteNumber = number
                    var reference = DocumentRun("\(number)", bold: shape.bold, italic: shape.italic)
                    reference.script = 1
                    state.pieces.append(.runs([reference]))
                    var first = true
                    for p in list.children("p") {
                        guard var simple = simpleParagraph(p) else { continue }
                        if first { simple.runs.insert(DocumentRun("각주 \(number). "), at: 0); first = false }
                        footnotes.append(simple)
                    }
                case "fieldBegin":
                    if (item.attr("type") ?? "").uppercased() == "HYPERLINK" {
                        var params: [OXNode] = []
                        item.descendants("stringParam", into: &params)
                        if let command = params.first(where: { $0.attr("name") == "Command" })?.allText {
                            let unescaped = command.replacingOccurrences(of: "\\:", with: ":").replacingOccurrences(of: "\\;", with: "\u{1}")
                            let url = unescaped.components(separatedBy: ";").first?.replacingOccurrences(of: "\u{1}", with: ";") ?? ""
                            state.link = url.isEmpty ? nil : url
                        }
                    }
                case "fieldEnd":
                    state.link = nil
                default: break
                }
            }
        }

        var footnoteNumber = 0

        /// 머리글·꼬리글·각주 안 문단: 글 조각과 정렬만(쪽 번호 자리는 빼고 showPageNumber로)
        func simpleParagraph(_ p: OXNode) -> DocumentParagraph? {
            let shape = p.attr("paraPrIDRef").flatMap { paraShapes[$0] } ?? ParaShape()
            var runs: [DocumentRun] = []
            for run in p.children("run") {
                let char = run.attr("charPrIDRef").flatMap { charShapes[$0] } ?? CharShape()
                for item in run.children {
                    switch item.name {
                    case "t":
                        let state = State()
                        state.add(text(of: item), shape: char)
                        for piece in state.pieces { if case .runs(let r) = piece { runs += r } }
                    case "ctrl":
                        for c in item.children {
                            if c.name == "autoNum" && (c.attr("numType") ?? "").uppercased() == "PAGE" { showPageNumber = true }
                            if c.name == "pageNum" { showPageNumber = true }
                        }
                    default: break
                    }
                }
            }
            runs = HangulRuns.merge(runs)
            guard HangulRuns.hasVisibleText(runs) else { return nil }
            var paragraph = DocumentParagraph(runs: runs)
            applyShape(shape, to: &paragraph, fontPoints: 10)
            return paragraph
        }

        /// hp:t 안: 글 조각 + 줄바꿈·탭·고정폭 공백
        func text(of t: OXNode) -> String {
            var out = ""
            for c in t.children {
                if c.isText { out += c.text; continue }
                switch c.name {
                case "lineBreak": out += "\n"
                case "tab": out += "\t"
                case "nbSpace", "fwSpace": out += " "
                case "hyphen": out += "-"
                default: break
                }
            }
            return out
        }

        func notePage(_ pagePr: OXNode) {
            guard pageSize == nil, let w = pagePr.attr("width").flatMap(Double.init), let h = pagePr.attr("height").flatMap(Double.init), w > 0, h > 0 else { return }
            var size = CGSize(width: w / 100, height: h / 100)
            if pagePr.attr("landscape") == "NARROWLY", size.width < size.height { size = CGSize(width: size.height, height: size.width) }
            pageSize = size
            if let m = pagePr.child("margin") {
                func pt(_ key: String) -> CGFloat? { m.attr(key).flatMap(Double.init).map { CGFloat($0) / 100 } }
                if let top = pt("top"), let left = pt("left"), let bottom = pt("bottom"), let right = pt("right") {
                    margins = DocumentMargins(top: top, left: left, bottom: bottom, right: right)
                }
            }
        }

        // MARK: 그림

        func picture(_ pic: OXNode) -> DocumentImage? {
            guard let img = pic.firstDescendant("img"), let id = img.attr("binaryItemIDRef") else { return nil }
            var size: CGSize?
            for name in ["sz", "curSz", "orgSz"] {
                if let node = pic.child(name), let w = node.attr("width").flatMap(Double.init), let h = node.attr("height").flatMap(Double.init), w > 0, h > 0 {
                    size = CGSize(width: w / 100, height: h / 100)
                    break
                }
            }
            if imageCache[id] == nil {
                var found: DocumentImage?
                if let data = binaryData(id: id) { found = ReaderImage.image(from: data, size: nil) }
                imageCache[id] = .some(found)
            }
            guard var image = imageCache[id] ?? nil else { return nil }
            if let size { image.size = size }
            return image
        }

        /// content.hpf 목록에서 찾고, 없으면 BinData 폴더에서 이름이 같은 파일을 찾는다
        func binaryData(id: String) -> Data? {
            if let path = binaryItems[id] {
                if let data = package.data(path) ?? package.data("Contents/" + path) ?? package.dataIgnoringCase(path) { return data }
            }
            let base = id.lowercased()
            if let name = package.names.first(where: {
                let n = $0.lowercased()
                return n.hasPrefix("bindata/") && ((n as NSString).deletingPathExtension as NSString).lastPathComponent == base
            }) { return package.data(name) }
            return nil
        }

        // MARK: 표

        func table(_ tbl: OXNode) -> (rows: [[String]], layout: DocumentTableLayout, images: [DocumentImage]) {
            struct Cell { var row: Int, col: Int, rowSpan: Int, colSpan: Int, width: Double?, text: String, header: Bool, border: Bool? }
            var cells: [Cell] = []
            var images: [DocumentImage] = []
            var rowIndex = 0
            var maxRow = 0, maxCol = 0
            let tableBorder: Bool? = tbl.attr("borderFillIDRef").flatMap { borderFills[$0] }
            for tr in tbl.children("tr") {
                var runningCol = 0
                for tc in tr.children("tc") {
                    let addr = tc.child("cellAddr")
                    let col = addr?.attr("colAddr").flatMap(Int.init) ?? runningCol
                    let row = addr?.attr("rowAddr").flatMap(Int.init) ?? rowIndex
                    let span = tc.child("cellSpan")
                    let colSpan = min(max(span?.attr("colSpan").flatMap(Int.init) ?? 1, 1), 1_000)
                    let rowSpan = min(max(span?.attr("rowSpan").flatMap(Int.init) ?? 1, 1), 20_000)
                    runningCol = min(max(col, 0), 1_000) + colSpan     // 범위 확인 전에 더하므로 먼저 줄인다(Int.max면 넘쳐서 죽음)
                    guard row >= 0, col >= 0, row < 20_000, col < 1_000 else { continue }
                    cellImages = []
                    let text = cellText(tc)
                    images += cellImages
                    let width = tc.child("cellSz")?.attr("width").flatMap(Double.init)
                    cells.append(Cell(row: row, col: col, rowSpan: min(rowSpan, 20_000), colSpan: min(colSpan, 1_000), width: width, text: text,
                                      header: tc.attr("header") == "1", border: tc.attr("borderFillIDRef").flatMap { borderFills[$0] }))
                    maxRow = max(maxRow, row + 1)
                    maxCol = max(maxCol, col + 1)
                }
                rowIndex += 1
            }
            let colCount = max(maxCol, min(tbl.attr("colCnt").flatMap(Int.init) ?? 0, 1_000))
            // 줄 수는 속성값만 믿지 않는다(속성만으로 표 하나에 2천만 칸을 만들 수 있었다). 칸 합계 상한 안에서
            let rowCount = min(max(maxRow, min(tbl.attr("rowCnt").flatMap(Int.init) ?? 0, 20_000)), max(1, ReaderBlocks.maxTableCells / max(colCount, 1)))
            var grid = Array(repeating: Array(repeating: "", count: colCount), count: rowCount)
            for cell in cells where cell.row < rowCount && cell.col < colCount {
                grid[cell.row][cell.col] = cell.text
            }

            var layout = DocumentTableLayout()
            // 합친 칸
            for cell in cells where (cell.colSpan > 1 || cell.rowSpan > 1) && cell.row < rowCount && cell.col < colCount {
                layout.spans.append(DocumentCellSpan(row: cell.row, column: cell.col,
                                                     columns: min(cell.colSpan, colCount - cell.col), rows: min(cell.rowSpan, rowCount - cell.row)))
            }
            // 칸(열) 너비: 칸을 안 합친 칸의 너비 → 합친 칸은 남는 너비를 모르는 열에 나눈다
            var widths = [Double?](repeating: nil, count: colCount)
            for cell in cells where cell.colSpan == 1 && cell.col < colCount {
                if let w = cell.width, w > 0 { widths[cell.col] = max(widths[cell.col] ?? 0, w) }
            }
            for cell in cells.sorted(by: { $0.colSpan < $1.colSpan }) where cell.colSpan > 1 && cell.col < colCount {
                guard let total = cell.width, total > 0 else { continue }
                let range = cell.col..<min(cell.col + cell.colSpan, colCount)
                let known = range.compactMap { widths[$0] }.reduce(0, +)
                let unknown = range.filter { widths[$0] == nil }
                if !unknown.isEmpty, total > known {
                    for index in unknown { widths[index] = (total - known) / Double(unknown.count) }
                }
            }
            if colCount > 0, widths.contains(where: { $0 != nil }) {
                let known = widths.compactMap { $0 }
                let fallback = known.reduce(0, +) / Double(known.count)
                layout.columnWidths = widths.map { CGFloat($0 ?? fallback) }
            }
            // 머리줄: 맨 위부터 모든 칸이 제목 칸(header="1")인 줄. 전부 머리줄이면 표시가 의미 없으니 0
            var headerRows = 0
            for row in 0..<rowCount {
                let inRow = cells.filter { $0.row == row }
                guard !inRow.isEmpty, inRow.allSatisfy(\.header) else { break }
                headerRows += 1
            }
            layout.headerRows = headerRows >= rowCount ? 0 : headerRows
            // 테두리: 표와 모든 칸의 테두리·배경 모양에 선이 하나도 없으면 테두리 없는 표(모양 정보를 못 읽으면 있는 걸로)
            if !borderFills.isEmpty {
                let known = ([tableBorder] + cells.map(\.border))
                let anyLine = known.contains { $0 ?? true }
                layout.borders = anyLine
            }
            return (grid, layout, images)
        }

        func cellText(_ tc: OXNode) -> String {
            guard let list = tc.child("subList") ?? tc.firstDescendant("subList") else { return "" }
            return plainLines(list).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func plainLines(_ list: OXNode) -> [String] {
            var lines: [String] = []
            for p in list.children("p") {
                let state = State()
                state.plain = true
                collect(p, state)
                var text = ""
                for piece in state.pieces { if case .runs(let runs) = piece { text += runs.map(\.text).joined() } }
                lines.append(text)
            }
            return lines
        }

        // MARK: 마무리: 스타일로 제목을 못 정한 문단은 글자 크기·굵기로 짐작

        func finishHeadings() {
            var histogram: [Int: Int] = [:]
            for (index, info) in sizeInfo where !levelFixed.contains(index) { histogram[info.height, default: 0] += info.chars }
            guard let body = readerBodySize(histogram) else { return }
            for (index, info) in sizeInfo where info.chars <= 200 && info.height > 0 {
                if let level = readerSizeLevel(size: Double(info.height), body: Double(body)) {
                    blocks.paragraphs[index].headingLevel = level
                } else if info.bold, Double(info.height) >= Double(body) * 1.05 {
                    blocks.paragraphs[index].headingLevel = 3
                }
            }
        }
    }
}
