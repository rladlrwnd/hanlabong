import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

// PDF 쪽의 내용 흐름(content stream)을 직접 훑어서 PDFKit이 알려 주지 않는 것을 찾는다.
// 1. 글 조각마다 실제로 쓰인 글꼴 이름: PDFKit은 끼워 넣은 글꼴(서브셋)을 "Helvetica"로 바꿔 알려 주기도 해서
//    굵은 제목·세리프 글꼴을 놓친다.
// 2. 가로 구분선(가는 선, 납작한 사각형).
// 좌표는 PDFLine과 같게 쪽 위쪽이 0인 포인트로 바꿔 둔다.

/// 글 조각 하나(Tj·TJ 한 번): 어디서 시작했고 어떤 글꼴로 몇 글자를 썼나
struct PDFTextPiece: Equatable {
    var x: CGFloat
    /// 기준선 높이(쪽 위쪽이 0)
    var baseline: CGFloat
    var fontName: String
    var size: CGFloat
    var characters: Int
}

/// 가로 구분선
struct PDFRule: Equatable {
    var page: Int
    /// 선 높이(쪽 위쪽이 0)
    var y: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    var width: CGFloat
    var colorHex: String
}

struct PDFPageScan {
    var pieces: [PDFTextPiece] = []
    var rules: [PDFRule] = []
}

enum PDFContentScan {
    /// 쪽 하나를 훑는다. 돌린 쪽·이상한 쪽은 빈 결과(그러면 예전처럼 PDFKit 정보만 쓴다)
    static func scan(_ page: PDFPage, index: Int) -> PDFPageScan {
        guard let cgPage = page.pageRef, page.rotation % 360 == 0 else { return PDFPageScan() }
        let box = page.bounds(for: .mediaBox)
        let state = ScanState(page: index, box: box)
        let stream = CGPDFContentStreamCreateWithPage(cgPage)
        defer { CGPDFContentStreamRelease(stream) }
        state.stream = stream
        guard let table = CGPDFOperatorTableCreate() else { return PDFPageScan() }
        defer { CGPDFOperatorTableRelease(table) }
        register(table)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
        return PDFPageScan(pieces: state.pieces, rules: state.rules)
    }

    // MARK: 글꼴 이름

    /// "ABCDEF+DejaVuSerif-Bold" → "DejaVuSerif-Bold"
    static func strippedName(_ name: String) -> String {
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            return String(name[name.index(after: plus)...])
        }
        return name
    }

    static func isBold(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["bold", "heavy", "black", "semibold", "demi"].contains { n.contains($0) }
    }

    static func isItalic(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("italic") || n.contains("oblique")
    }

    enum Kind { case serif, sans, mono }

    /// 이름으로 짐작한 글꼴 계열
    static func kind(of name: String) -> Kind {
        let n = name.lowercased()
        if ["mono", "courier", "consol", "menlo", "code"].contains(where: { n.contains($0) }) { return .mono }
        if n.contains("sans") || n.contains("gothic") || n.contains("고딕") || n.contains("돋움") || n.contains("dotum")
            || n.contains("굴림") || n.contains("gulim") { return .sans }
        if ["serif", "times", "roman", "georgia", "garamond", "minion", "cambria", "palatino", "baskerville", "caslon",
            "bodoni", "didot", "charter", "myungjo", "myeongjo", "batang", "mincho", "song", "명조", "바탕"].contains(where: { n.contains($0) }) {
            return .serif
        }
        return .sans
    }

    /// PDF 안의 글꼴 이름 → 문서에 적을 글꼴 가족 이름.
    /// 이 맥에 있는 글꼴이면 그 가족 이름, 없으면 어디서나 있는 같은 계열 글꼴(세리프 → Times New Roman 등)로 바꾼다.
    /// 그래야 한글·워드·한라봉 어디서 열어도 세리프는 세리프로 보인다.
    static func family(for pdfName: String) -> String {
        let name = strippedName(pdfName)
        switch name {
        case "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Arial", "ArialMT": return "Arial"
        case "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic": return "Times New Roman"
        case "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique": return "Courier New"
        default: break
        }
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        if (CTFontCopyPostScriptName(font) as String) == name { return CTFontCopyFamilyName(font) as String }
        // 자주 끼워 넣는 오픈 글꼴은 생김새·글자 폭이 가까운 흔한 글꼴로
        let lower = name.lowercased()
        let lookalikes: [(String, String)] = [
            ("dejavusansmono", "Menlo"), ("dejavuserif", "Georgia"), ("dejavusans", "Verdana"),
            ("bitstreamverasansmono", "Menlo"), ("bitstreamveraserif", "Georgia"), ("bitstreamverasans", "Verdana"),
            ("liberationserif", "Times New Roman"), ("liberationsans", "Arial"), ("liberationmono", "Courier New"),
            ("notoserif", "Georgia"), ("notosans", "Arial"),
        ]
        if let match = lookalikes.first(where: { lower.replacingOccurrences(of: " ", with: "").hasPrefix($0.0) }),
           NSFontManager.shared.availableFontFamilies.contains(match.1) { return match.1 }
        // 가족 이름만 쓰인 경우("DejaVuSerif,Bold" 같은 것)도 한 번 더
        let base = name.components(separatedBy: CharacterSet(charactersIn: "-,")).first ?? name
        if NSFontManager.shared.availableFontFamilies.contains(base) { return base }
        switch kind(of: name) {
        case .serif: return "Times New Roman"
        case .mono: return "Courier New"
        case .sans: return "Arial"
        }
    }

    // MARK: 훑기

    fileprivate final class ScanState {
        let page: Int
        let box: CGRect
        var stream: CGPDFContentStreamRef?
        var pieces: [PDFTextPiece] = []
        var rules: [PDFRule] = []

        // 그래픽 상태
        struct Graphics {
            var ctm = CGAffineTransform.identity
            var lineWidth: CGFloat = 1
            var stroke = "000000"
            var fill = "000000"
        }
        var graphics = Graphics()
        var stack: [Graphics] = []

        // 글 상태
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var leading: CGFloat = 0
        var fontName = ""
        var fontSize: CGFloat = 0
        var twoByte = false
        var fontCache: [String: (name: String, twoByte: Bool)] = [:]

        // 그리는 중인 선
        var path: [(CGPoint, CGPoint)] = []
        var rects: [CGRect] = []
        var start = CGPoint.zero
        var current = CGPoint.zero

        init(page: Int, box: CGRect) { self.page = page; self.box = box }

        /// PDF 좌표(사용자 공간) → 쪽 위쪽이 0인 좌표
        func toPage(_ point: CGPoint) -> CGPoint {
            let p = point.applying(graphics.ctm)
            return CGPoint(x: p.x - box.minX, y: box.maxY - p.y)
        }

        func selectFont(_ resource: String) {
            if let cached = fontCache[resource] { fontName = cached.name; twoByte = cached.twoByte; return }
            var name = resource, two = false
            if let stream, let object = CGPDFContentStreamGetResource(stream, "Font", resource) {
                var dict: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &dict), let dict {
                    var base: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(dict, "BaseFont", &base), let base { name = String(cString: base) }
                    var subtype: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Type0" { two = true }
                }
            }
            fontCache[resource] = (name, two)
            fontName = name; twoByte = two
        }

        func show(bytes: Int) {
            guard bytes > 0, !fontName.isEmpty else { return }
            let m = textMatrix.concatenating(graphics.ctm)
            let origin = CGPoint(x: m.tx - box.minX, y: box.maxY - m.ty)
            let scale = (m.b * m.b + m.d * m.d).squareRoot()
            pieces.append(PDFTextPiece(x: origin.x, baseline: origin.y, fontName: fontName, size: fontSize * scale,
                                       characters: twoByte ? bytes / 2 : bytes))
        }

        func nextLine(_ tx: CGFloat, _ ty: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        /// 그은 선 중 가로로 길고 가는 것을 구분선 후보로 남긴다
        func finishPath(stroked: Bool, filled: Bool) {
            defer { path = []; rects = [] }
            if stroked {
                let width = graphics.lineWidth * max(abs(graphics.ctm.d), abs(graphics.ctm.a), 0.0001)
                for (a, b) in path {
                    let p = toPage(a), q = toPage(b)
                    guard abs(p.y - q.y) < 0.5, abs(p.x - q.x) >= 20, width <= 3 else { continue }
                    rules.append(PDFRule(page: page, y: p.y, minX: min(p.x, q.x), maxX: max(p.x, q.x), width: max(width, 0.25), colorHex: graphics.stroke))
                }
            }
            if filled {
                for rect in rects {
                    let p = toPage(CGPoint(x: rect.minX, y: rect.minY)), q = toPage(CGPoint(x: rect.maxX, y: rect.maxY))
                    let height = abs(p.y - q.y), length = abs(p.x - q.x)
                    guard height > 0, height <= 3, length >= 20 else { continue }
                    rules.append(PDFRule(page: page, y: (p.y + q.y) / 2, minX: min(p.x, q.x), maxX: max(p.x, q.x), width: height, colorHex: graphics.fill))
                }
            }
        }
    }

    private static func register(_ table: CGPDFOperatorTableRef) {
        // 그래픽 상태
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let s = state(info) else { return }
            s.stack.append(s.graphics)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let s = state(info), let last = s.stack.popLast() else { return }
            s.graphics = last
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 6) else { return }
            s.graphics.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(s.graphics.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 1) else { return }
            s.graphics.lineWidth = n[0]
        }
        for (op, count, stroke) in [("G", 1, true), ("g", 1, false), ("RG", 3, true), ("rg", 3, false), ("K", 4, true), ("k", 4, false)] {
            let callback: CGPDFOperatorCallback
            switch (count, stroke) {
            case (1, true): callback = { sc, info in if let s = state(info), let n = numbers(sc, 1) { s.graphics.stroke = hex(n) } }
            case (1, false): callback = { sc, info in if let s = state(info), let n = numbers(sc, 1) { s.graphics.fill = hex(n) } }
            case (3, true): callback = { sc, info in if let s = state(info), let n = numbers(sc, 3) { s.graphics.stroke = hex(n) } }
            case (3, false): callback = { sc, info in if let s = state(info), let n = numbers(sc, 3) { s.graphics.fill = hex(n) } }
            case (4, true): callback = { sc, info in if let s = state(info), let n = numbers(sc, 4) { s.graphics.stroke = hex(n) } }
            default: callback = { sc, info in if let s = state(info), let n = numbers(sc, 4) { s.graphics.fill = hex(n) } }
            }
            CGPDFOperatorTableSetCallback(table, op, callback)
        }

        // 색공간을 따로 정한 색(SC·SCN·sc·scn): 숫자 개수는 색공간마다 다르니 있는 만큼 꺼낸다(무늬 이름이면 건너뜀)
        CGPDFOperatorTableSetCallback(table, "SC") { sc, info in if let s = state(info), let n = allNumbers(sc) { s.graphics.stroke = hex(n) } }
        CGPDFOperatorTableSetCallback(table, "SCN") { sc, info in if let s = state(info), let n = allNumbers(sc) { s.graphics.stroke = hex(n) } }
        CGPDFOperatorTableSetCallback(table, "sc") { sc, info in if let s = state(info), let n = allNumbers(sc) { s.graphics.fill = hex(n) } }
        CGPDFOperatorTableSetCallback(table, "scn") { sc, info in if let s = state(info), let n = allNumbers(sc) { s.graphics.fill = hex(n) } }

        // 선 그리기
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 2) else { return }
            s.start = CGPoint(x: n[0], y: n[1]); s.current = s.start
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 2) else { return }
            let next = CGPoint(x: n[0], y: n[1])
            s.path.append((s.current, next)); s.current = next
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 4) else { return }
            s.rects.append(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).standardized)
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            guard let s = state(info) else { return }
            s.path.append((s.current, s.start)); s.current = s.start
        }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in state(info)?.finishPath(stroked: true, filled: false) }
        CGPDFOperatorTableSetCallback(table, "s") { _, info in state(info)?.finishPath(stroked: true, filled: false) }
        for op in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in state(info)?.finishPath(stroked: false, filled: true) }
        }
        for op in ["B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in state(info)?.finishPath(stroked: true, filled: true) }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            guard let s = state(info) else { return }
            s.path = []; s.rects = []
        }

        // 글
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let s = state(info) else { return }
            s.textMatrix = .identity; s.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let s = state(info) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
            s.fontSize = CGFloat(size)
            s.selectFont(String(cString: name))
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 1) else { return }
            s.leading = n[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 6) else { return }
            s.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            s.textMatrix = s.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 2) else { return }
            s.nextLine(n[0], n[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let s = state(info), let n = numbers(scanner, 2) else { return }
            s.leading = -n[1]
            s.nextLine(n[0], n[1])
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let s = state(info) else { return }
            s.nextLine(0, -s.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let s = state(info) else { return }
            s.show(bytes: stringBytes(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let s = state(info) else { return }
            s.nextLine(0, -s.leading)
            s.show(bytes: stringBytes(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let s = state(info) else { return }
            let bytes = stringBytes(scanner)
            _ = numbers(scanner, 2)
            s.nextLine(0, -s.leading)
            s.show(bytes: bytes)
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let s = state(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            var bytes = 0
            for i in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                if CGPDFArrayGetString(array, i, &string), let string { bytes += CGPDFStringGetLength(string) }
            }
            s.show(bytes: bytes)
        }
    }
}

fileprivate func state(_ info: UnsafeMutableRawPointer?) -> PDFContentScan.ScanState? {
    info.map { Unmanaged<PDFContentScan.ScanState>.fromOpaque($0).takeUnretainedValue() }
}

fileprivate func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values: [CGFloat] = []
    for _ in 0..<count {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &v) else { return nil }
        values.append(CGFloat(v))
    }
    return values.reversed()
}

fileprivate func allNumbers(_ scanner: CGPDFScannerRef) -> [CGFloat]? {
    var values: [CGFloat] = []
    var v: CGPDFReal = 0
    while values.count < 4, CGPDFScannerPopNumber(scanner, &v) { values.append(CGFloat(v)) }
    return values.isEmpty ? nil : values.reversed()
}

fileprivate func hex(_ components: [CGFloat]) -> String {
    func byte(_ x: CGFloat) -> Int { min(255, max(0, Int((x * 255).rounded()))) }
    switch components.count {
    case 1: let g = byte(components[0]); return String(format: "%02X%02X%02X", g, g, g)
    case 3: return String(format: "%02X%02X%02X", byte(components[0]), byte(components[1]), byte(components[2]))
    case 4:
        let k = components[3]
        return String(format: "%02X%02X%02X", byte((1 - components[0]) * (1 - k)), byte((1 - components[1]) * (1 - k)), byte((1 - components[2]) * (1 - k)))
    default: return "000000"
    }
}

fileprivate func stringBytes(_ scanner: CGPDFScannerRef) -> Int {
    var string: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &string), let string else { return 0 }
    return CGPDFStringGetLength(string)
}


// MARK: - 줄에 글꼴 붙이기

extension PDFContentScan {
    /// 이 줄(쪽 위쪽 기준 top~bottom, minX~maxX)에 쓰인 글 조각들. PDF에 적힌 차례 그대로.
    static func pieces(for line: (top: CGFloat, bottom: CGFloat, minX: CGFloat, maxX: CGFloat), in scan: PDFPageScan) -> [PDFTextPiece] {
        let height = line.bottom - line.top
        return scan.pieces.filter { piece in
            piece.baseline >= line.top + height * 0.2 && piece.baseline <= line.bottom + height * 0.35
                && piece.x >= line.minX - height && piece.x <= line.maxX + 1
        }
    }

    /// 줄 글자(길이 `length`)를 글 조각의 글꼴로 나눈다: [(글자 범위, PDF 글꼴 이름)].
    /// 조각마다 쓴 글자 수 비율로 나누니 띄어쓰기 처리 차이로 한두 글자 어긋날 수 있다.
    static func fontRanges(_ pieces: [PDFTextPiece], length: Int) -> [(NSRange, String)] {
        let names = pieces.map(\.fontName)
        guard length > 0, let first = names.first else { return [] }
        if names.allSatisfy({ $0 == first }) { return [(NSRange(location: 0, length: length), first)] }
        let total = max(pieces.reduce(0) { $0 + $1.characters }, 1)
        var result: [(NSRange, String)] = []
        var start = 0, sum = 0
        for (i, piece) in pieces.enumerated() {
            sum += piece.characters
            let end = i == pieces.count - 1 ? length : min(length, Int((Double(sum) / Double(total) * Double(length)).rounded()))
            guard end > start else { continue }
            if let last = result.last, last.1 == piece.fontName {
                result[result.count - 1].0.length = end - last.0.location
            } else {
                result.append((NSRange(location: start, length: end - start), piece.fontName))
            }
            start = end
        }
        return result
    }
}
