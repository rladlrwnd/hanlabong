import Foundation

/// Markdown 읽기: 제목·문단·목록·인용·코드에 더해
/// - 파이프 표(`| a | b |` + `|---|---|`) → 표(첫 줄이 머리줄, `\|`는 `|` 글자, `<br>`은 칸 안 줄바꿈)
/// - 그림 한 줄짜리 `![설명](주소)` → 그림. 주소가 data:image/…;base64면 그림 데이터로, 바깥 파일이면 md 파일 옆 상대 경로를 읽어 보고 없으면 설명 글로
/// - 빈 줄로 둘러싸인 `---` 한 줄 → 쪽 나눔(우리 쓰기 규칙). 제목 바로 뒤의 `---`는 제목 밑줄과 구별이 안 돼서 무시한다
/// - 글 바로 밑에 붙은 `===`·`---`는 제목 밑줄(setext)로 본다
enum MarkdownReader {
    static func parse(_ markdown: String, baseURL: URL? = nil) -> [DocumentParagraph] {
        var blocks = ReaderBlocks()
        var buffer: [String] = []
        var inCode = false
        var code: [String] = []
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        lines = stripFrontMatter(lines)

        func flushBuffer() {
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.text(RichDocumentReader.inline(text)) }
            buffer = []
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inCode {
                    blocks.text([DocumentRun(code.joined(separator: "\n"))])
                    code = []
                } else { flushBuffer() }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushBuffer(); continue }

            // 제목 밑줄(setext): 글 바로 밑의 === 또는 ---
            if !buffer.isEmpty, line.range(of: "^(=+|-{2,})$", options: .regularExpression) != nil {
                let level = line.hasPrefix("=") ? 1 : 2
                let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                buffer = []
                blocks.text(RichDocumentReader.inline(text).map { DocumentRun($0.text, bold: true, italic: $0.italic) }, level: level)
                continue
            }

            if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushBuffer()
                let hashes = line[match].filter { $0 == "#" }.count
                let title = String(line[match.upperBound...]).replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
                blocks.text(RichDocumentReader.inline(title).map { DocumentRun($0.text, bold: true, italic: $0.italic) }, level: min(3, hashes))
                continue
            }

            // 표: 파이프로 시작하거나, 파이프가 있고 바로 다음 줄이 구분줄
            if isTableStart(line, next: index < lines.count ? lines[index] : nil) {
                flushBuffer()
                var rows: [[String]] = []
                var current = line
                var cursor = index
                while true {
                    let cells = splitRow(current)
                    if !(rows.count == 1 && isSeparator(cells)) { rows.append(cells) }      // 머리줄 바로 밑의 구분줄만 버린다
                    guard cursor < lines.count else { break }
                    let following = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard !following.isEmpty, following.contains("|") else { break }
                    current = following
                    cursor += 1
                }
                index = cursor
                blocks.table(rows)
                continue
            }

            if let image = standaloneImage(line) {
                flushBuffer()
                if let picture = load(image.source, baseURL: baseURL) { blocks.image(picture) }
                else if !image.alt.isEmpty { blocks.text([DocumentRun(image.alt)]) }
                continue
            }

            if line.range(of: "^([-*+]|\\d+[.)])\\s+", options: .regularExpression) != nil {
                flushBuffer()
                let ordered = line.first?.isNumber == true
                let body = line.replacingOccurrences(of: "^([-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
                let marker = ordered ? String(line.prefix { $0.isNumber }) + ". " : "• "
                blocks.text([DocumentRun(marker)] + RichDocumentReader.inline(body))
                continue
            }

            if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushBuffer()
                // 우리가 쓸 때 쪽 나눔을 `---` 한 줄로 적는다. 앞에 글이 있고(제목 바로 뒤가 아님) 정확히 `---`일 때만
                if line == "---", let last = blocks.paragraphs.last, last.headingLevel == nil {
                    blocks.pendingBreak = true
                }
                continue
            }

            if line.hasPrefix(">") {
                flushBuffer()
                blocks.text(RichDocumentReader.inline(String(line.drop { $0 == ">" || $0 == " " })))
                continue
            }
            buffer.append(line)
        }
        if inCode, !code.isEmpty { blocks.text([DocumentRun(code.joined(separator: "\n"))]) }
        flushBuffer()
        return blocks.paragraphs
    }

    // MARK: 머리말(front matter)

    private static func stripFrontMatter(_ lines: [String]) -> [String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return lines }
        for end in 1..<min(lines.count, 40) where lines[end].trimmingCharacters(in: .whitespaces) == "---" || lines[end].trimmingCharacters(in: .whitespaces) == "..." {
            let inside = lines[1..<end].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let looksLikeYAML = !inside.isEmpty && inside.allSatisfy {
                $0.range(of: "^\\s*([A-Za-z0-9_\\-가-힣\"']+\\s*:|-\\s|#)", options: .regularExpression) != nil || $0.hasPrefix(" ")
            }
            return looksLikeYAML ? Array(lines[(end + 1)...]) : lines
        }
        return lines
    }

    // MARK: 표

    private static func isTableStart(_ line: String, next: String?) -> Bool {
        if line.hasPrefix("|") { return line.dropFirst().contains("|") || next.map { isSeparator(splitRow($0.trimmingCharacters(in: .whitespaces))) } == true }
        guard line.contains("|"), let next else { return false }
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && isSeparator(splitRow(trimmed))
    }

    private static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }
    }

    /// 한 줄 → 칸들. 바깥 파이프는 떼고, `\|`는 `|` 글자로, `<br>`은 줄바꿈으로, **굵게** 같은 표시는 걷어낸다
    static func splitRow(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        let chars = Array(row)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" { current.append("|"); i += 2; continue }
            if c == "|" { cells.append(current); current = ""; i += 1; continue }
            current.append(c)
            i += 1
        }
        cells.append(current)
        // 앞뒤 파이프 때문에 생기는 빈 조각 정리
        if row.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if cells.count > 0, row.hasSuffix("|"), !row.hasSuffix("\\|") { cells.removeLast() }
        return cells.map { cell in
            let text = cell.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            return text.components(separatedBy: "\n").map { line in
                RichDocumentReader.inline(line).map(\.text).joined()
            }.joined(separator: "\n")
        }
    }

    // MARK: 그림

    /// `![설명](주소)` 한 줄(뒤에 붙는 "제목"은 버린다)
    private static func standaloneImage(_ line: String) -> (alt: String, source: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let split = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound])
        var source = String(line[split.upperBound..<line.index(before: line.endIndex)]).trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("<"), let close = source.firstIndex(of: ">") { source = String(source[source.index(after: source.startIndex)..<close]) }
        else if !source.hasPrefix("data:"), let space = source.firstIndex(where: { $0.isWhitespace }) { source = String(source[..<space]) }
        guard !source.isEmpty, !alt.contains("]") else { return nil }
        return (alt, source)
    }

    static func load(_ source: String, baseURL: URL?) -> DocumentImage? {
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].contains("base64") else { return nil }
            let payload = String(source[source.index(after: comma)...])
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
            return ReaderImage.image(from: data, size: nil)
        }
        return loadFile(source, baseURL: baseURL)
    }

    /// 문서 옆 폴더 안의 상대 경로만 읽는다(http 주소·폴더 밖은 읽지 않는다)
    static func loadFile(_ source: String, baseURL: URL?) -> DocumentImage? {
        guard let baseURL, !source.hasPrefix("/"), !source.contains("://"), !source.hasPrefix("//") else { return nil }
        let relative = (source.removingPercentEncoding ?? source).components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? source
        let folder = baseURL.standardizedFileURL
        let file = folder.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/") else { return nil }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= 30_000_000,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return ReaderImage.image(from: data, size: nil)
    }
}
