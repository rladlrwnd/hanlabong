import Foundation

/// RTF·ODT를 macOS 문서 읽기(NSAttributedString)로 읽으면 그림이 사라진다.
/// 그래서 읽기 전에 그림을 글자 자리표로 바꿔 두고, 읽은 뒤 자리표 자리에 그림 문단을 되돌려 놓는다.
enum RichReadImages {
    private static let prefix = "HLBRDIMG"
    private static let suffix = "END"
    static func token(_ i: Int) -> String { "\(prefix)\(i)\(suffix)" }

    /// 자리표로 바꾼 파일 내용과, 자리표 번호 → 그림
    struct Prepared {
        var data: Data
        var images: [DocumentImage]
    }

    // MARK: RTF

    /// `{\pict ... \pngblip/\jpegblip ...}` 그룹을 찾아 자리표로 바꾼다. PNG·JPEG가 아니면(EMF·WMF 등) 그대로 둔다.
    static func prepareRTF(_ data: Data) -> Prepared? {
        let bytes = [UInt8](data)
        let marker = Array("{\\pict".utf8)
        guard bytes.count > marker.count else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var images: [DocumentImage] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x7B, i + marker.count <= bytes.count, Array(bytes[i..<(i + marker.count)]) == marker {
                // 짝이 맞는 닫는 괄호 찾기(그림 안에는 괄호가 없지만 \{ 같은 이스케이프는 건너뛴다)
                var depth = 0, j = i
                var end: Int?
                while j < bytes.count {
                    let c = bytes[j]
                    if c == 0x5C { j += 2; continue }
                    if c == 0x7B { depth += 1 } else if c == 0x7D { depth -= 1; if depth == 0 { end = j; break } }
                    j += 1
                }
                if let end, let image = rtfPicture(Array(bytes[i...end])) {
                    out.append(contentsOf: Array(token(images.count).utf8))
                    images.append(image)
                    i = end + 1
                    continue
                }
            }
            out.append(bytes[i])
            i += 1
        }
        guard !images.isEmpty else { return nil }
        return Prepared(data: Data(out), images: images)
    }

    /// `{\pict\pngblip\picwgoal..\pichgoal.. 89504e47...}` 한 그룹 → 그림
    private static func rtfPicture(_ group: [UInt8]) -> DocumentImage? {
        let text = String(decoding: group, as: UTF8.self)
        guard text.contains("\\pngblip") || text.contains("\\jpegblip") else { return nil }
        func number(_ word: String) -> CGFloat? {
            guard let r = text.range(of: "\\" + word + "(-?[0-9]+)", options: .regularExpression) else { return nil }
            return Double(text[r].dropFirst(word.count + 1)).map { CGFloat($0) }
        }
        // 제어 단어와 괄호를 걷어 내면 16진수 그림 내용만 남는다
        var hex = text.replacingOccurrences(of: "\\\\[A-Za-z]+-?[0-9]* ?", with: "", options: .regularExpression)
        hex = hex.filter { $0.isHexDigit }
        guard hex.count >= 16 else { return nil }
        if hex.count % 2 == 1 { hex.removeLast() }
        var data = Data(capacity: hex.count / 2)
        var chars = hex.makeIterator()
        while let a = chars.next(), let b = chars.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            data.append(v)
        }
        var size: CGSize?
        if let w = number("picwgoal"), let h = number("pichgoal"), w > 0, h > 0 { size = CGSize(width: w / 20, height: h / 20) }
        return ReaderImage.image(from: data, size: size)
    }

    // MARK: ODT

    /// content.xml의 `draw:frame`(그림) 을 자리표로 바꾼 ODT 묶음을 다시 만든다
    static func prepareODT(_ data: Data) -> Prepared? {
        guard let zip = MiniZipReader(data),
              let content = zip.entries.first(where: { $0.name == "content.xml" }),
              let frameRegex = try? NSRegularExpression(pattern: "<draw:frame\\b[^>]*>.*?</draw:frame>", options: [.dotMatchesLineSeparators]) else { return nil }
        let pictures = Dictionary(zip.entries.map { ($0.name, $0.data) }, uniquingKeysWith: { a, _ in a })
        var xml = String(decoding: content.data, as: UTF8.self)
        var images: [DocumentImage] = []
        let ns = xml as NSString
        var replaced = ""
        var last = 0
        for match in frameRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let frame = ns.substring(with: match.range)
            guard let href = attribute("xlink:href", in: frame, after: "<draw:image"),
                  let file = pictures[href] ?? pictures[href.hasPrefix("./") ? String(href.dropFirst(2)) : href],
                  let image = ReaderImage.image(from: file, size: frameSize(frame)) else { continue }
            replaced += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            replaced += token(images.count)
            images.append(image)
            last = match.range.location + match.range.length
        }
        guard !images.isEmpty else { return nil }
        replaced += ns.substring(from: last)
        xml = replaced

        var out = ZipWriter()
        if let mime = zip.entries.first(where: { $0.name == "mimetype" }) { out.add("mimetype", mime.data, store: true) }
        for entry in zip.entries where entry.name != "mimetype" && !entry.name.hasPrefix("Pictures/") {
            out.add(entry.name, entry.name == "content.xml" ? Data(xml.utf8) : entry.data)
        }
        return Prepared(data: out.finish(), images: images)
    }

    private static func attribute(_ name: String, in text: String, after tag: String) -> String? {
        guard let start = text.range(of: tag) else { return nil }
        let rest = text[start.upperBound...]
        guard let r = rest.range(of: "\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        let raw = rest[r].dropFirst(name.count + 2).dropLast()
        return String(raw).removingPercentEncoding ?? String(raw)
    }

    private static func frameSize(_ frame: String) -> CGSize? {
        let head = frame.range(of: ">").map { String(frame[..<$0.lowerBound]) } ?? frame
        func length(_ name: String) -> CGFloat? {
            guard let r = head.range(of: "\(name)=\"([0-9.]+)([a-z%]*)\"", options: .regularExpression) else { return nil }
            let body = head[r].dropFirst(name.count + 2).dropLast()
            let digits = body.prefix { $0.isNumber || $0 == "." }
            guard let v = Double(digits) else { return nil }
            switch body.dropFirst(digits.count) {
            case "cm": return v / 2.54 * 72
            case "mm": return v / 25.4 * 72
            case "in": return v * 72
            case "pt": return v
            case "pc": return v * 12
            case "px", "": return v * 0.75
            default: return nil
            }
        }
        guard let w = length("svg:width"), let h = length("svg:height"), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: 되돌리기

    /// 자리표가 들어 있는 문단을 "앞 글 · 그림 · 뒤 글"로 쪼갠다. 그림이 못 살아난 자리표는 글에서 지운다
    static func restore(_ paragraphs: [DocumentParagraph], images: [DocumentImage]) -> [DocumentParagraph] {
        guard let regex = try? NSRegularExpression(pattern: "\(prefix)([0-9]+)\(suffix)") else { return paragraphs }
        var result: [DocumentParagraph] = []
        for paragraph in paragraphs {
            guard paragraph.image == nil, paragraph.runs.contains(where: { $0.text.contains(prefix) }) else {
                result.append(paragraph)
                continue
            }
            if paragraph.table != nil {
                var p = paragraph
                p.table = paragraph.table?.map { $0.map { regex.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: "") } }
                result.append(p)
                continue
            }
            var pending: [DocumentRun] = []
            var first = true
            func flush() {
                let merged = ReaderBlocks.merge(pending)
                pending = []
                guard merged.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
                var p = paragraph
                p.runs = merged
                if !first { p.pageBreakBefore = false; p.headingLevel = nil }
                first = false
                result.append(p)
            }
            for run in paragraph.runs {
                let ns = run.text as NSString
                var last = 0
                for m in regex.matches(in: run.text, range: NSRange(location: 0, length: ns.length)) {
                    var before = run
                    before.text = ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    if !before.text.isEmpty { pending.append(before) }
                    last = m.range.location + m.range.length
                    flush()
                    if let n = Int(ns.substring(with: m.range(at: 1))), images.indices.contains(n) {
                        var p = DocumentParagraph(runs: [], image: images[n])
                        if first { p.pageBreakBefore = paragraph.pageBreakBefore; first = false }
                        result.append(p)
                    }
                }
                var rest = run
                rest.text = ns.substring(from: last)
                if !rest.text.isEmpty { pending.append(rest) }
            }
            flush()
        }
        return result
    }
}
