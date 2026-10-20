import AppKit
import Foundation

/// What is it?이 읽는 여러 문서 형식 → 글. 사진·영상·소리를 뺀 파일은 여기서 글을 꺼내 본다.
/// - Word(.docx·.doc)·RTF·OpenDocument: macOS 문서 읽기(NSAttributedString)
/// - HTML: 태그를 걷어내고 글만(스크립트·스타일 제외). 웹 엔진을 띄우지 않는다
/// - PowerPoint(.pptx)·Excel(.xlsx)·한글(.hwpx): zip 안의 XML에서 글자만
/// - 그 밖: 글 파일로 읽어 본다(UTF-8·UTF-16·EUC-KR). 글이 아니면(0 바이트가 섞임) 거절
public enum DocumentReaders {
    public static let richExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "wordml"]
    public static let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "shtml"]
    public static let zipXMLExtensions: Set<String> = ["pptx", "xlsx", "hwpx", "odp", "ods"]
    /// 글이 아니라서 What is it?을 띄우지 않는 형식(압축·실행 파일·디스크 이미지·소리 등)
    public static let nonTextExtensions: Set<String> = [
        "zip", "7z", "rar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg", "app", "exe", "dll", "so", "dylib", "bin", "o",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "aif", "caf", "opus", "wma", "mid", "midi",
        "ttf", "otf", "woff", "woff2", "sqlite", "db", "ldb", "class", "jar", "pyc",
    ]

    public static func isDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return richExtensions.contains(ext) || zipXMLExtensions.contains(ext)
    }

    /// 형식에 맞게 글을 꺼낸다. 못 꺼내면 nil
    static func text(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if richExtensions.contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        if zipXMLExtensions.contains(ext) { return zipXMLText(url, ext: ext) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8192).contains(0), !(data.prefix(2) == Data([0xFF, 0xFE]) || data.prefix(2) == Data([0xFE, 0xFF])) {
            return nil                                    // 0 바이트가 섞인 건 글 파일이 아니다
        }
        guard let decoded = WhatIsText.decode(data) else { return nil }
        if htmlExtensions.contains(ext) || looksLikeHTML(decoded) { return htmlText(decoded) }
        return decoded
    }

    // MARK: HTML

    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(600).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    static func htmlText(_ html: String) -> String {
        var s = html
        for pattern in ["(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?is)<noscript\\b.*?</noscript>", "(?s)<!--.*?-->", "(?is)<head\\b.*?</head>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 제목은 남긴다
        if let title = html.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) {
            let t = String(html[title]).replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
            s = t + "\n\n" + s
        }
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6]|tr|section|article|blockquote|pre|table|ul|ol)>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</t[dh]>", with: "\t", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
        return tidy(decodeEntities(s))
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&middot;": "·", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 줄 끝 공백을 지우고 빈 줄이 셋 이상 이어지면 둘로
    static func tidy(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: zip 안의 XML (pptx·xlsx·hwpx)

    static func zipXMLText(_ url: URL, ext: String) -> String? {
        guard let names = unzip(["-Z1", url.path]).map({ $0.split(separator: "\n").map(String.init) }) else { return nil }
        let pattern: String, paragraphEnd: String, textTag: String
        switch ext {
        case "pptx": pattern = "^ppt/slides/slide[0-9]+\\.xml$"; paragraphEnd = "</a:p>"; textTag = "a:t"
        case "xlsx": pattern = "^xl/sharedStrings\\.xml$"; paragraphEnd = "</si>"; textTag = "t"
        case "hwpx": pattern = "^Contents/section[0-9]+\\.xml$"; paragraphEnd = "</hp:p>"; textTag = "hp:t"
        default: pattern = "^content\\.xml$"; paragraphEnd = "</text:p>"; textTag = ""
        }
        let parts = names.prefix(3000).filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !parts.isEmpty else { return nil }
        var pieces: [String] = []
        for (index, part) in parts.enumerated() {
            guard let xml = unzip(["-p", url.path, part]) else { continue }
            var s = xml.replacingOccurrences(of: paragraphEnd, with: "\n")
            if !textTag.isEmpty {
                // 글자 칸(<a:t> 등) 바깥의 태그 속 값은 버리고, 칸 안의 글만 남긴다
                let open = "<\(textTag)(?:\\s[^>]*)?>", close = "</\(textTag)>"
                s = s.replacingOccurrences(of: "\n", with: "\u{1}")
                var out = ""
                let regex = try! NSRegularExpression(pattern: "\(open)(.*?)\(close)|\u{1}", options: [.dotMatchesLineSeparators])
                let ns = s as NSString
                for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    if m.range(at: 1).location == NSNotFound { out += "\n" } else { out += ns.substring(with: m.range(at: 1)) }
                }
                s = out
            } else {
                s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
            }
            let text = tidy(decodeEntities(s))
            guard !text.isEmpty else { continue }
            pieces.append(ext == "pptx" ? L("[슬라이드 \(index + 1)]\n\(text)", "[Slide \(index + 1)]\n\(text)") : text)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    private static func unzip(_ arguments: [String]) -> String? {
        BoundedProcess.unzip(arguments)      // 압축 폭탄 방지: 64MB 넘게 풀리면 멈춘다
    }
}
