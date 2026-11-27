import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 문서 읽기(docx·hwpx·마크다운·HTML)가 같이 쓰는 도구들.
// - ZipPackage: zip 안의 파일을 하나씩 꺼낸다(unzip을 쓰고, 풀려 나오는 양에는 상한이 있다)
// - OXNode: XML을 가벼운 나무로 읽는다(이름은 접두어를 뗀 것: w:p → p, hp:tbl → tbl)
// - ReaderImage: 어떤 그림이든 PNG로
// - ReaderBlocks: 읽은 덩어리를 차곡차곡 모으고 쪽 나눔을 다음 덩어리에 붙인다

// MARK: - zip

struct ZipPackage {
    let url: URL
    let names: [String]

    init?(_ url: URL) {
        guard let listing = BoundedProcess.unzip(["-Z1", url.path]) else { return nil }
        let names = listing.split(separator: "\n").prefix(20_000).map(String.init)
        guard !names.isEmpty else { return nil }
        self.url = url
        self.names = names
    }

    func contains(_ path: String) -> Bool { names.contains(path) }

    /// unzip은 이름의 `*?[]`를 와일드카드로 보므로 앞에 역슬래시를 붙인다
    static func escaped(_ path: String) -> String {
        var out = ""
        for ch in path {
            if "*?[]\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    func data(_ path: String) -> Data? {
        guard names.contains(path) else { return nil }
        return BoundedProcess.run("/usr/bin/unzip", ["-p", url.path, Self.escaped(path)])
    }

    /// 대소문자·앞쪽 슬래시를 무시하고 찾아 꺼낸다
    func dataIgnoringCase(_ path: String) -> Data? {
        let wanted = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let name = names.first(where: { $0.lowercased() == wanted }) else { return nil }
        return data(name)
    }

    func xml(_ path: String) -> OXNode? {
        data(path).flatMap { OXParser.parse($0) }
    }

    /// `base`가 있는 폴더 기준의 상대 경로를 풀어서(`..`·`.` 처리) 패키지 안 경로로
    static func resolve(_ target: String, relativeTo base: String) -> String {
        var t = target.removingPercentEncoding ?? target
        if t.hasPrefix("/") { return String(t.dropFirst()) }
        t = t.replacingOccurrences(of: "\\", with: "/")
        var parts = base.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }          // 파일 이름 떼기
        for piece in t.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - XML 나무

final class OXNode {
    let name: String            // 접두어를 뗀 이름. 글 조각은 "#text"
    let prefix: String
    var attributes: [String: String]
    var children: [OXNode] = []
    var text: String = ""
    var isText: Bool { name == "#text" }

    init(name: String, prefix: String = "", attributes: [String: String] = [:], text: String = "") {
        self.name = name
        self.prefix = prefix
        self.attributes = attributes
        self.text = text
    }

    /// 속성 값: `w:val`도 `val`로 찾는다(접두어는 무시). 정확한 이름을 먼저 본다
    func attr(_ key: String) -> String? {
        if let v = attributes[key] { return v }
        let suffix = ":" + key
        for (k, v) in attributes where k.hasSuffix(suffix) { return v }
        return nil
    }

    func child(_ name: String) -> OXNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [OXNode] { children.filter { $0.name == name } }

    func firstDescendant(_ name: String) -> OXNode? {
        for c in children {
            if c.name == name { return c }
            if let found = c.firstDescendant(name) { return found }
        }
        return nil
    }

    func descendants(_ name: String, into result: inout [OXNode]) {
        for c in children {
            if c.name == name { result.append(c) }
            c.descendants(name, into: &result)
        }
    }

    /// 이 노드 아래 글 조각을 이어 붙인 것
    var allText: String {
        if isText { return text }
        return children.map(\.allText).joined()
    }
}

enum OXParser {
    /// 나무로 읽는다. 중간에 깨져도 읽은 데까지는 돌려준다(아무것도 못 읽으면 nil)
    static func parse(_ data: Data) -> OXNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        delegate.flush()
        return delegate.root
    }

    /// 글을 담는 이름: 이 안의 공백만 있는 조각은 버리지 않는다(`<w:t> </w:t>`)
    private static let textHolders: Set<String> = ["t", "text", "delText", "instrText"]

    private final class Builder: NSObject, XMLParserDelegate {
        var root: OXNode?
        var stack: [OXNode] = []
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            defer { buffer = "" }
            guard let parent = stack.last else { return }
            if buffer.allSatisfy({ $0.isWhitespace }), !OXParser.textHolders.contains(parent.name) { return }
            parent.children.append(OXNode(name: "#text", text: buffer))
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            flush()
            let parts = elementName.split(separator: ":", maxSplits: 1).map(String.init)
            let node = OXNode(name: parts.last ?? elementName, prefix: parts.count > 1 ? parts[0] : "", attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            flush()
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { buffer += String(decoding: CDATABlock, as: UTF8.self) }
    }
}

// MARK: - 그림

enum ReaderImage {
    /// 그림 파일 → PNG(이미 PNG면 그대로). 읽지 못하는 형식(EMF·WMF 등)이면 nil.
    /// 긴 변이 `maxLongSide` 픽셀을 넘는 JPEG 같은 건 줄여서 PNG로 바꾼다.
    static func png(from data: Data, maxLongSide: Int = 2400) -> (png: Data, pixels: CGSize)? {
        guard data.count > 8, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { return nil }
        let isPNG = data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if isPNG { return (data, CGSize(width: w, height: h)) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxLongSide),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, CGSize(width: cg.width, height: cg.height))
    }

    /// 파일 내용 → 문서 그림. `size`(포인트)가 없거나 0이면 픽셀 크기의 3/4(96dpi → 72dpi)를 쓴다
    static func image(from data: Data, size: CGSize?) -> DocumentImage? {
        guard let converted = png(from: data) else { return nil }
        var pt = size ?? .zero
        if !(pt.width > 0 && pt.height > 0 && pt.width.isFinite && pt.height.isFinite) {
            pt = CGSize(width: converted.pixels.width * 0.75, height: converted.pixels.height * 0.75)
        }
        return DocumentImage(png: converted.png, size: pt)
    }
}

// MARK: - 덩어리 모으기

/// 읽는 도중 한 문단 안에서 나온 조각들(글 → 그림 → 쪽 나눔 …)
enum ReaderPiece {
    case runs([DocumentRun])
    case image(DocumentImage)
    case table([[String]])
    case pageBreak
}

struct ReaderBlocks {
    var paragraphs: [DocumentParagraph] = []
    /// 다음 덩어리 앞에서 쪽을 넘긴다(문서 맨 앞이면 무시)
    var pendingBreak = false

    private mutating func add(_ paragraph: DocumentParagraph) {
        var p = paragraph
        if pendingBreak {
            p.pageBreakBefore = !paragraphs.isEmpty
            pendingBreak = false
        }
        paragraphs.append(p)
    }

    /// 글 문단. 글자가 하나도 없으면(공백뿐이면) 버리고 false
    @discardableResult
    mutating func text(_ runs: [DocumentRun], level: Int? = nil) -> Bool {
        let merged = Self.merge(runs)
        guard merged.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        add(DocumentParagraph(runs: merged, headingLevel: level))
        return true
    }

    /// 표: 줄마다 칸 수를 맞추고(모자라면 빈 칸), 칸 글의 앞뒤 빈칸을 다듬는다. 글이 하나도 없으면 버린다
    @discardableResult
    mutating func table(_ rows: [[String]]) -> Bool {
        let cleaned = Self.normalizeTable(rows)
        guard cleaned.contains(where: { $0.contains { !$0.isEmpty } }) else { return false }
        add(DocumentParagraph(runs: [], table: cleaned))
        return true
    }

    mutating func image(_ image: DocumentImage) {
        add(DocumentParagraph(runs: [], image: image))
    }

    static func normalizeTable(_ rows: [[String]]) -> [[String]] {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return [] }
        return rows.map { row in
            (0..<columns).map { c in
                c < row.count ? row[c].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
        }
    }

    /// 같은 모양끼리 이어 붙이고 빈 조각은 뺀다
    static func merge(_ runs: [DocumentRun]) -> [DocumentRun] {
        var out: [DocumentRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.sameStyle(as: run) { out[out.count - 1].text += run.text }
            else { out.append(run) }
        }
        return out
    }
}

/// 본문 글자 크기를 정한다: 글자 수가 가장 많은 크기(최빈값). 다만 그보다 작은 크기가 최빈값의 30% 이상이면 그 작은 쪽을 본문으로 본다
/// (제목 글이 본문보다 길어도 제목 크기를 본문으로 잘못 잡지 않게)
func readerBodySize(_ histogram: [Int: Int]) -> Int? {
    guard let top = histogram.max(by: { $0.value < $1.value }) else { return nil }
    let smaller = histogram.filter { $0.key < top.key && Double($0.value) >= Double(top.value) * 0.3 }
    return smaller.keys.min() ?? top.key
}

/// 글자 크기 비율로 본 제목 단계(크게 1.6배 이상 = 1, 1.25배 이상 = 2)
func readerSizeLevel(size: Double, body: Double) -> Int? {
    guard body > 0 else { return nil }
    if size >= body * 1.6 { return 1 }
    if size >= body * 1.25 { return 2 }
    return nil
}
