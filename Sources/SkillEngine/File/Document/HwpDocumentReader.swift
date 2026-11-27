import CoreGraphics
import Foundation

/// 옛 한글(.hwp, HWP 5.0 공개 규격)을 레코드 level 나무로 읽어 문단 모양·글자 모양·표·그림·머리글/꼬리글/각주·쪽 크기를 살린다.
/// - 레코드 머리: 종류 10비트, level 10비트, 길이 12비트. level로 부모-자식을 짠다(문단 → 글·글자모양·컨트롤, 컨트롤 → 표 정보·칸 목록·칸 안 문단 …)
/// - DocInfo: FACE_NAME(19)·BORDER_FILL(20)·CHAR_SHAPE(21)·PARA_SHAPE(25)·BIN_DATA(18)
/// - 컨트롤 id: tbl(표)·gso(그림·글상자)·head/foot(머리글·꼬리글)·fn/en(각주·미주)·secd(PAGE_DEF 쪽 크기·여백)·pgnp/atno(쪽 번호)·eqed(수식)
extension HwpReader {
    static func document(_ url: URL) throws -> HangulDocument {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.broken }
        let box = try CompoundFile(data)
        guard let header = box.stream("FileHeader"), header.count >= 40,
              header.starts(with: Array("HWP Document File".utf8)) else { throw Failure.notHwp }
        let flags = header.uint32(at: 36)
        if flags & 0b10 != 0 { throw Failure.locked }
        if flags & 0b100 != 0 { throw Failure.distribution }
        let compressed = flags & 0b1 != 0
        var inflatedTotal = 0
        func load(_ path: String) throws -> Data? {
            guard let raw = box.stream(path) else { return nil }
            let out = compressed ? try inflate(raw, limit: maxInflatedBytes - inflatedTotal) : raw
            inflatedTotal += out.count
            return out
        }
        let docInfo = try load("DocInfo")
        var sections: [Data] = []
        for index in 0..<1000 {
            guard let section = try load("BodyText/Section\(index)") else { break }
            sections.append(section)
        }
        let names = Dictionary(box.streamNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var document = structured(docInfo: docInfo, sections: sections) { name in
            guard let real = names[name.lowercased()], let raw = box.stream(real) else { return nil }
            return raw
        }
        if document.paragraphs.isEmpty {
            // 구조로 못 읽으면 예전처럼 글만
            let found = sections.flatMap { HwpReader.texts(inRecords: $0) }
            guard !found.isEmpty else { throw Failure.broken }
            document.paragraphs = found.map { DocumentParagraph(runs: [DocumentRun($0)]) }
        }
        return document
    }

    // MARK: 레코드 나무

    final class Node {
        let tag: UInt32
        let level: Int
        let payload: Data
        var children: [Node] = []
        init(tag: UInt32, level: Int, payload: Data) { self.tag = tag; self.level = level; self.payload = payload }
        func first(_ tag: UInt32) -> Node? { children.first { $0.tag == tag } }
        func find(_ tag: UInt32) -> Node? {
            for c in children { if c.tag == tag { return c }; if let f = c.find(tag) { return f } }
            return nil
        }
    }

    static func tree(_ data: Data) -> [Node] {
        var roots: [Node] = []
        var stack: [Node] = []
        var offset = 0
        var count = 0
        while offset + 4 <= data.count, count < 4_000_000 {
            let head = data.uint32(at: offset)
            offset += 4
            var size = Int(head >> 20)
            if size == 0xFFF {
                guard offset + 4 <= data.count else { break }
                size = Int(data.uint32(at: offset))
                offset += 4
            }
            guard size >= 0, offset + size <= data.count else { break }
            let node = Node(tag: head & 0x3FF, level: Int((head >> 10) & 0x3FF),
                            payload: data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + size))
            offset += size
            count += 1
            while let last = stack.last, last.level >= node.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        return roots
    }

    // 레코드 종류(HWPTAG_BEGIN = 0x10)
    private enum Tag {
        static let binData: UInt32 = 18, faceName: UInt32 = 19, borderFill: UInt32 = 20, charShape: UInt32 = 21, paraShape: UInt32 = 25
        static let paraHeader: UInt32 = 66, paraText: UInt32 = 67, paraCharShape: UInt32 = 68, ctrlHeader: UInt32 = 71
        static let listHeader: UInt32 = 72, pageDef: UInt32 = 73, table: UInt32 = 77, picture: UInt32 = 85, eqEdit: UInt32 = 88
    }

    static func ctrlID(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    // MARK: 문서 정보

    private struct CharInfo {
        var height = 1000
        var bold = false, italic = false, underline = false, strike = false
        var script = 0
        var colorHex: String?
        var fontName: String?
    }
    private struct ParaInfo {
        var alignment: DocumentAlignment = .justify
        var left: CGFloat = 0, indent: CGFloat = 0, prev: CGFloat = 0, next: CGFloat = 0
        var lineType = 0
        var lineValue: CGFloat = 160
    }

    private enum Piece {
        case runs([DocumentRun])
        case image(DocumentImage)
        case table([[String]], DocumentTableLayout)
    }

    /// 레코드 데이터에서 문서를 짠다(파일 없이 시험할 수 있게 나눈 부분). `bin`은 "BinData/BIN0001.png" 같은 칸 이름 → 내용
    static func structured(docInfo: Data?, sections: [Data], bin: @escaping (String) -> Data?) -> HangulDocument {
        let reader = StructuredReader(bin: bin)
        if let docInfo { reader.loadDocInfo(tree(docInfo)) }
        for section in sections { reader.walk(tree(section)) }
        return reader.finish()
    }

    private final class StructuredReader {
        let bin: (String) -> Data?
        var faces: [String] = []
        var chars: [CharInfo] = []
        var paras: [ParaInfo] = []
        var lined: [Bool] = []
        var binItems: [(id: Int, ext: String)] = []
        var blocks = ReaderBlocks()
        var pageSize: CGSize?
        var margins: DocumentMargins?
        var header: [DocumentParagraph] = []
        var footer: [DocumentParagraph] = []
        var footnotes: [DocumentParagraph] = []
        var footnoteCount = 0
        var showPageNumber = false
        var heightHistogram: [Int: Int] = [:]
        var fontHistogram: [String: Int] = [:]
        var sizeInfo: [Int: (height: Int, bold: Bool, chars: Int)] = [:]
        var imageCache: [Int: DocumentImage?] = [:]
        var depth = 0

        init(bin: @escaping (String) -> Data?) { self.bin = bin }

        // MARK: DocInfo

        func loadDocInfo(_ nodes: [Node]) {
            for node in nodes {
                let p = node.payload
                switch node.tag {
                case Tag.faceName:
                    let length = min(Int(p.uint16(at: 1)), max((p.count - 3) / 2, 0))
                    let units = (0..<length).map { p.uint16(at: 3 + $0 * 2) }
                    faces.append(String(decoding: units, as: UTF16.self))
                case Tag.borderFill:
                    // 4방향(왼·오·위·아래) 선: 종류 1바이트·굵기 1바이트·색 4바이트씩. 종류 0 = 선 없음
                    lined.append((0..<4).contains { p.count > 2 + $0 * 6 && p[p.startIndex + 2 + $0 * 6] != 0 })
                case Tag.charShape:
                    guard p.count >= 56 else { chars.append(CharInfo()); continue }
                    var c = CharInfo()
                    c.height = max(Int(p.uint32(at: 42)), 100)
                    let prop = p.uint32(at: 46)
                    c.italic = prop & 1 != 0
                    c.bold = prop & 2 != 0
                    c.underline = (prop >> 2) & 3 == 1
                    c.script = prop & (1 << 15) != 0 ? 1 : (prop & (1 << 16) != 0 ? -1 : 0)
                    c.strike = (prop >> 18) & 7 != 0
                    let color = p.uint32(at: 52)
                    c.colorHex = HangulRuns.hex(Int(color & 255), Int((color >> 8) & 255), Int((color >> 16) & 255))
                    let face = Int(p.uint16(at: 0))
                    if face < faces.count, !faces[face].isEmpty { c.fontName = faces[face] }
                    chars.append(c)
                case Tag.paraShape:
                    guard p.count >= 28 else { paras.append(ParaInfo()); continue }
                    var s = ParaInfo()
                    let prop = p.uint32(at: 0)
                    switch (prop >> 2) & 7 {
                    case 1: s.alignment = .left
                    case 2: s.alignment = .right
                    case 3: s.alignment = .center
                    default: s.alignment = .justify
                    }
                    // 여백·간격은 1/14400 인치(HWPUNIT의 2배) → pt = 값 ÷ 200
                    s.left = CGFloat(p.int32(at: 4)) / 200
                    s.indent = CGFloat(p.int32(at: 12)) / 200
                    s.prev = CGFloat(p.int32(at: 16)) / 200
                    s.next = CGFloat(p.int32(at: 20)) / 200
                    s.lineType = Int(prop & 3)
                    s.lineValue = s.lineType == 0 ? CGFloat(p.int32(at: 24)) : CGFloat(p.int32(at: 24)) / 200
                    paras.append(s)
                case Tag.binData:
                    let type = p.uint16(at: 0) & 0xF
                    if type == 1, p.count >= 6 {
                        let length = min(Int(p.uint16(at: 4)), max((p.count - 6) / 2, 0))
                        let ext = String(decoding: (0..<length).map { p.uint16(at: 6 + $0 * 2) }, as: UTF16.self)
                        binItems.append((Int(p.uint16(at: 2)), ext))
                    } else {
                        binItems.append((-1, ""))
                    }
                default: break
                }
            }
        }

        // MARK: 본문

        func walk(_ roots: [Node]) {
            for node in roots where node.tag == Tag.paraHeader { bodyParagraph(node) }
        }

        func bodyParagraph(_ node: Node) {
            let info = decode(node, plain: false)
            let flags = node.payload.count > 11 ? node.payload[node.payload.startIndex + 11] : 0
            if flags & 0b100 != 0 { blocks.pendingBreak = true }                        // 쪽 나눔
            let shapeID = Int(node.payload.uint16(at: 8))
            let shape = shapeID < paras.count ? paras[shapeID] : nil
            for piece in info.pieces {
                switch piece {
                case .runs(let runs):
                    let merged = HangulRuns.merge(runs)
                    guard HangulRuns.hasVisibleText(merged) else { continue }
                    var paragraph = DocumentParagraph(runs: merged)
                    if let shape { apply(shape, to: &paragraph, fontPoints: CGFloat(info.height) / 100) }
                    sizeInfo[blocks.paragraphs.count] = (info.height, info.allBold && info.chars > 0, info.chars)
                    blocks.addKeepingStyle(paragraph)
                case .image(let image): blocks.image(image)
                case .table(let rows, let layout):
                    let cleaned = ReaderBlocks.normalizeTable(rows)
                    guard !cleaned.isEmpty else { continue }
                    var paragraph = DocumentParagraph(runs: [], table: cleaned)
                    paragraph.tableLayout = layout
                    blocks.addKeepingStyle(paragraph)
                }
            }
        }

        func apply(_ shape: ParaInfo, to paragraph: inout DocumentParagraph, fontPoints: CGFloat) {
            paragraph.alignment = shape.alignment
            paragraph.leftIndent = shape.left
            paragraph.firstLineIndent = shape.indent
            paragraph.spaceBefore = shape.prev
            paragraph.spaceAfter = shape.next
            switch shape.lineType {
            case 0: if shape.lineValue > 0 { paragraph.lineSpacing = shape.lineValue / 100 }
            case 1, 3: if shape.lineValue > 0 { paragraph.lineSpacing = HangulRuns.multiple(fixedPoints: shape.lineValue, fontPoints: fontPoints) }
            default: break
            }
        }

        struct Decoded {
            var pieces: [Piece] = []
            var height = 0
            var chars = 0
            var allBold = true
        }

        /// 문단 하나 → 글·표·그림 조각. 조종 글자는 크기가 달라서(8글자짜리) 위치(글자 모양 구간)를 같이 센다
        private func decode(_ node: Node, plain: Bool) -> Decoded {
            var out = Decoded()
            let ctrls = node.children.filter { $0.tag == Tag.ctrlHeader }
            // 글자 모양 구간: (시작 위치, 번호)
            var spans: [(pos: Int, id: Int)] = []
            if let cs = node.first(Tag.paraCharShape) {
                for i in 0..<(cs.payload.count / 8) { spans.append((Int(cs.payload.uint32(at: i * 8)), Int(cs.payload.uint32(at: i * 8 + 4)))) }
                spans.sort { $0.pos < $1.pos }
            }
            var spanIndex = 0
            func charInfo(at pos: Int) -> CharInfo {
                while spanIndex + 1 < spans.count, spans[spanIndex + 1].pos <= pos { spanIndex += 1 }
                guard spanIndex < spans.count, spans[spanIndex].id < chars.count else { return CharInfo() }
                return chars[spans[spanIndex].id]
            }
            var current: [DocumentRun] = []
            func flushRuns() {
                if !current.isEmpty { out.pieces.append(.runs(current)); current = [] }
            }
            func add(_ text: String, _ info: CharInfo) {
                guard !text.isEmpty else { return }
                var run = DocumentRun(text, bold: info.bold, italic: info.italic)
                run.underline = info.underline; run.strike = info.strike; run.script = info.script
                run.colorHex = info.colorHex
                run.fontSize = CGFloat(info.height) / 100
                run.fontName = info.fontName
                if let last = current.last, last.sameStyle(as: run) { current[current.count - 1].text += text } else { current.append(run) }
                if !text.allSatisfy({ $0.isWhitespace }) {
                    out.height = max(out.height, info.height)
                    out.chars += text.count
                    if !info.bold { out.allBold = false }
                    if !plain {
                        heightHistogram[info.height, default: 0] += text.count
                        if let name = info.fontName { fontHistogram[name, default: 0] += text.count }
                    }
                }
            }

            func emit(_ piece: Piece) {
                flushRuns()
                out.pieces.append(piece)
            }

            if let textNode = node.first(Tag.paraText) {
                let d = textNode.payload
                let count = d.count / 2
                var i = 0
                var ctrlIndex = 0
                var pending: [UInt16] = []
                var pendingInfo = CharInfo()
                func flushPending() {
                    if !pending.isEmpty { add(String(decoding: pending, as: UTF16.self), pendingInfo); pending = [] }
                }
                func push(_ unit: UInt16, at pos: Int) {
                    let info = charInfo(at: pos)
                    if !pending.isEmpty, info.height != pendingInfo.height || info.bold != pendingInfo.bold || info.italic != pendingInfo.italic
                        || info.underline != pendingInfo.underline || info.strike != pendingInfo.strike || info.script != pendingInfo.script
                        || info.colorHex != pendingInfo.colorHex || info.fontName != pendingInfo.fontName { flushPending() }
                    pendingInfo = info
                    pending.append(unit)
                }
                while i < count {
                    let c = d.uint16(at: i * 2)
                    if c >= 32 { push(c, at: i); i += 1; continue }
                    switch c {
                    case 10: push(0x0A, at: i); i += 1
                    case 24: push(0x2D, at: i); i += 1
                    case 30, 31: push(0x20, at: i); i += 1
                    case 0, 13, 25...29: i += 1
                    case 9: push(0x09, at: i); i += 8                                      // 탭(8글자 차지, 앞 2글자는 종류·너비)
                    case 4...8, 19, 20: i += 8
                    default:
                        // 확장 컨트롤(1,2,3,11,12,14~18,21~23): 차례대로 CTRL_HEADER 하나씩
                        let at = i
                        i += 8
                        guard ctrlIndex < ctrls.count else { continue }
                        let ctrl = ctrls[ctrlIndex]
                        ctrlIndex += 1
                        flushPending()
                        control(ctrl, info: charInfo(at: at), plain: plain, emit: emit, add: add)
                    }
                }
                flushPending()
            }
            flushRuns()
            return out
        }

        private func control(_ ctrl: Node, info: CharInfo, plain: Bool,
                             emit: (Piece) -> Void, add: (String, CharInfo) -> Void) {
            let id = ctrl.payload.uint32(at: 0)
            switch id {
            case HwpReader.ctrlID("tbl "):
                guard depth < 20 else { return }
                depth += 1
                let (rows, layout) = table(ctrl)
                depth -= 1
                if plain {
                    add(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"), info)
                } else {
                    emit(.table(rows, layout))
                }
            case HwpReader.ctrlID("gso "):
                if let picture = picture(ctrl), !plain {
                    emit(.image(picture))
                }
                // 글상자 글(떠 있는 상자): 안의 문단 글
                let text = listParagraphs(ctrl).map { plainText($0) }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(text, info) }
            case HwpReader.ctrlID("head"), HwpReader.ctrlID("foot"):
                let isHeader = id == HwpReader.ctrlID("head")
                if isHeader ? !header.isEmpty : !footer.isEmpty { return }
                var list: [DocumentParagraph] = []
                for p in listParagraphs(ctrl) {
                    if let simple = simpleParagraph(p) { list.append(simple) }
                }
                if isHeader { header = list } else { footer = list }
            case HwpReader.ctrlID("fn  "), HwpReader.ctrlID("en  "):
                footnoteCount += 1
                let number = footnoteCount
                var reference = DocumentRun("\(number)", bold: info.bold, italic: info.italic)
                reference.script = 1
                emit(.runs([reference]))
                var first = true
                for p in listParagraphs(ctrl) {
                    guard var simple = simpleParagraph(p) else { continue }
                    if first { simple.runs.insert(DocumentRun("각주 \(number). "), at: 0); first = false }
                    footnotes.append(simple)
                }
            case HwpReader.ctrlID("secd"):
                if let def = ctrl.first(Tag.pageDef) { pageDefinition(def.payload) }
            case HwpReader.ctrlID("pgnp"):
                showPageNumber = true
            case HwpReader.ctrlID("atno"):
                if ctrl.payload.uint32(at: 4) & 0xF == 0 { showPageNumber = true }
            case HwpReader.ctrlID("eqed"):
                if let eq = ctrl.find(Tag.eqEdit) {
                    let p = eq.payload
                    let length = min(Int(p.uint16(at: 4)), max((p.count - 6) / 2, 0))
                    let script = String(decoding: (0..<length).map { p.uint16(at: 6 + $0 * 2) }, as: UTF16.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !script.isEmpty { add(script, info) }
                }
            default: break    // 단 나누기(cold)·숨은 설명(tcmt)·책갈피·필드 등: 글이 아니라 버린다
            }
        }

        func pageDefinition(_ p: Data) {
            guard p.count >= 36, pageSize == nil else { return }
            var w = CGFloat(p.uint32(at: 0)) / 100, h = CGFloat(p.uint32(at: 4)) / 100
            guard w > 0, h > 0 else { return }
            if p.uint32(at: 36) & 1 != 0, w < h { swap(&w, &h) }
            pageSize = CGSize(width: w, height: h)
            func pt(_ o: Int) -> CGFloat { CGFloat(p.uint32(at: o)) / 100 }
            margins = DocumentMargins(top: pt(16), left: pt(8), bottom: pt(20), right: pt(12))
        }

        /// 컨트롤 아래 LIST_HEADER 뒤에 놓인 문단들(머리글·꼬리글·각주·글상자)
        func listParagraphs(_ ctrl: Node) -> [Node] {
            var found: [Node] = []
            func visit(_ node: Node) {
                for c in node.children {
                    if c.tag == Tag.paraHeader { found.append(c) }
                    else if c.tag != Tag.ctrlHeader { visit(c) }
                }
            }
            visit(ctrl)
            return found
        }

        func plainText(_ paragraph: Node) -> String {
            var text = ""
            for piece in decode(paragraph, plain: true).pieces {
                if case .runs(let runs) = piece { text += runs.map(\.text).joined() }
            }
            return text
        }

        /// 머리글·꼬리글·각주 안 문단: 글 조각과 정렬(쪽 번호 자리는 showPageNumber로)
        func simpleParagraph(_ node: Node) -> DocumentParagraph? {
            var runs: [DocumentRun] = []
            for piece in decode(node, plain: true).pieces { if case .runs(let r) = piece { runs += r } }
            runs = HangulRuns.merge(runs)
            guard HangulRuns.hasVisibleText(runs) else { return nil }
            var paragraph = DocumentParagraph(runs: runs)
            let shapeID = Int(node.payload.uint16(at: 8))
            if shapeID < paras.count { apply(paras[shapeID], to: &paragraph, fontPoints: 10) }
            return paragraph
        }

        // MARK: 표

        func table(_ ctrl: Node) -> ([[String]], DocumentTableLayout) {
            guard let info = ctrl.first(Tag.table), info.payload.count >= 8 else { return ([], DocumentTableLayout()) }
            let rowCount = min(Int(info.payload.uint16(at: 4)), 20_000), colCount = min(Int(info.payload.uint16(at: 6)), 1_000)
            struct Cell { var row = 0, col = 0, rowSpan = 1, colSpan = 1, width = 0, border = 0; var text = "" }
            var cells: [Cell] = []
            for node in ctrl.children {
                if node.tag == Tag.listHeader, node.payload.count >= 34 {
                    let p = node.payload
                    cells.append(Cell(row: Int(p.uint16(at: 10)), col: Int(p.uint16(at: 8)), rowSpan: max(Int(p.uint16(at: 14)), 1),
                                      colSpan: max(Int(p.uint16(at: 12)), 1), width: Int(p.uint32(at: 16)), border: Int(p.uint16(at: 32))))
                } else if node.tag == Tag.paraHeader, !cells.isEmpty {
                    let text = plainText(node)
                    cells[cells.count - 1].text += (cells[cells.count - 1].text.isEmpty ? "" : "\n") + text
                }
            }
            let rows = max(rowCount, (cells.map { $0.row + 1 }.max() ?? 0)), cols = max(colCount, (cells.map { $0.col + 1 }.max() ?? 0))
            guard rows > 0, cols > 0, rows <= 20_000, cols <= 1_000 else { return ([], DocumentTableLayout()) }
            var grid = Array(repeating: Array(repeating: "", count: cols), count: rows)
            var layout = DocumentTableLayout()
            var widths = [Double?](repeating: nil, count: cols)
            for cell in cells where cell.row < rows && cell.col < cols {
                grid[cell.row][cell.col] = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cell.colSpan > 1 || cell.rowSpan > 1 {
                    layout.spans.append(DocumentCellSpan(row: cell.row, column: cell.col, columns: min(cell.colSpan, cols - cell.col),
                                                         rows: min(cell.rowSpan, rows - cell.row)))
                } else if cell.width > 0 { widths[cell.col] = max(widths[cell.col] ?? 0, Double(cell.width)) }
            }
            for cell in cells.sorted(by: { $0.colSpan < $1.colSpan }) where cell.colSpan > 1 && cell.col < cols && cell.width > 0 {
                let range = cell.col..<min(cell.col + cell.colSpan, cols)
                let known = range.compactMap { widths[$0] }.reduce(0, +)
                let unknown = range.filter { widths[$0] == nil }
                if !unknown.isEmpty, Double(cell.width) > known {
                    for index in unknown { widths[index] = (Double(cell.width) - known) / Double(unknown.count) }
                }
            }
            if widths.contains(where: { $0 != nil }) {
                let known = widths.compactMap { $0 }
                let fallback = known.reduce(0, +) / Double(known.count)
                layout.columnWidths = widths.map { CGFloat($0 ?? fallback) }
            }
            // 머리줄은 알 수 없다(0). 테두리: 칸들의 테두리 모양에 선이 하나도 없으면 테두리 없는 표
            if !lined.isEmpty {
                let any = cells.contains { cell in cell.border >= 1 && cell.border <= lined.count ? lined[cell.border - 1] : cell.border == 0 ? false : true }
                layout.borders = any || cells.isEmpty
            }
            return (grid, layout)
        }

        // MARK: 그림

        func picture(_ ctrl: Node) -> DocumentImage? {
            guard let pic = ctrl.find(Tag.picture), pic.payload.count >= 73 else { return nil }
            let itemID = Int(pic.payload.uint16(at: 71))
            guard itemID >= 1, itemID <= binItems.count else { return nil }
            if imageCache[itemID] == nil {
                let item = binItems[itemID - 1]
                var found: DocumentImage?
                if item.id >= 0 {
                    let name = String(format: "BinData/BIN%04X.%@", item.id, item.ext)
                    if let raw = bin(name) {
                        found = ReaderImage.image(from: raw, size: nil)
                        if found == nil, let inflated = try? HwpReader.inflate(raw, limit: HwpReader.maxInflatedBytes) {
                            found = ReaderImage.image(from: inflated, size: nil)
                        }
                    }
                }
                imageCache[itemID] = .some(found)
            }
            guard var image = imageCache[itemID] ?? nil else { return nil }
            let w = CGFloat(ctrl.payload.uint32(at: 16)) / 100, h = CGFloat(ctrl.payload.uint32(at: 20)) / 100
            if w > 0, h > 0, w < 20_000, h < 20_000 { image.size = CGSize(width: w, height: h) }
            return image
        }

        // MARK: 마무리

        func finish() -> HangulDocument {
            // 제목 짐작: 글자 크기·굵기(hwpx 읽기와 같은 방식)
            var histogram: [Int: Int] = [:]
            for (_, info) in sizeInfo { histogram[info.height, default: 0] += info.chars }
            if let body = readerBodySize(histogram) {
                for (index, info) in sizeInfo where info.chars <= 200 && info.height > 0 && index < blocks.paragraphs.count {
                    if let level = readerSizeLevel(size: Double(info.height), body: Double(body)) {
                        blocks.paragraphs[index].headingLevel = level
                    } else if info.bold, Double(info.height) >= Double(body) * 1.05 {
                        blocks.paragraphs[index].headingLevel = 3
                    }
                }
            }
            blocks.paragraphs += footnotes
            var result = HangulDocument(paragraphs: blocks.paragraphs, pageSize: pageSize)
            result.margins = margins
            result.header = header
            result.footer = footer
            result.showPageNumber = showPageNumber
            if let body = readerBodySize(heightHistogram) { result.bodyFontSize = CGFloat(body) / 100 }
            result.bodyFontName = fontHistogram.max { $0.value < $1.value }?.key
            result.normalizeBodyFont()
            return result
        }
    }
}
