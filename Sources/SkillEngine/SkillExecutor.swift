import Foundation

public enum SkillError: LocalizedError, Equatable {
    case invalidRegex(String)
    case tooDeep

    public var errorDescription: String? {
        switch self {
        case .invalidRegex(let pattern): return L("정규식 “\(pattern)”이(가) 올바르지 않아요", "Invalid regex “\(pattern)”")
        case .tooDeep: return L("조건 블록이 너무 깊게 겹쳐 있어요", "Condition blocks are nested too deeply")
        }
    }
}

/// 스킬 실행기: 블록을 순서대로 적용한다. 앞 블록의 결과가 다음 블록의 입력.
public enum SkillExecutor {
    private static let maxDepth = 16

    public static func run(_ skill: Skill, on text: String) throws -> String {
        try run(skill.steps, on: normalizeLineEndings(text), depth: 0)
    }

    public static func run(_ steps: [Step], on text: String) throws -> String {
        try run(steps, on: normalizeLineEndings(text), depth: 0)
    }

    private static func run(_ steps: [Step], on text: String, depth: Int) throws -> String {
        guard depth < maxDepth else { throw SkillError.tooDeep }
        var current = text
        for step in steps {
            current = try apply(step, to: current, depth: depth)
        }
        return current
    }

    private static func apply(_ step: Step, to text: String, depth: Int) throws -> String {
        switch step {
        case .removeLineBreaks(let replacement, let keepParagraphs):
            return removeLineBreaks(text, replacement: replacement, keepParagraphs: keepParagraphs)

        case .breakAfterSentences(let blankLine):
            return SentenceSplitter.breakAfterSentences(text, separator: blankLine ? "\n\n" : "\n")

        case .trim(let perLine, let side):
            guard perLine else { return trim(text, side: side, set: .whitespacesAndNewlines) }
            return mapLines(text) { trim($0, side: side, set: .whitespaces) }

        case .collapseSpaces:
            return try regexReplace(text, pattern: "[ \\t\\u00A0\\u3000]{2,}", template: " ")

        case .removeEmptyLines:
            return lines(text)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")

        case .replace(let find, let with, let regex, let caseSensitive):
            guard !find.isEmpty else { return text }
            if regex {
                return try regexReplace(text, pattern: find, template: with, caseInsensitive: !caseSensitive)
            }
            return text.replacingOccurrences(of: find, with: with, options: caseSensitive ? [] : [.caseInsensitive])

        case .changeCase(let style):
            switch style {
            case .upper: return text.uppercased()
            case .lower: return text.lowercased()
            case .title: return text.capitalized
            }

        case .addToLines(let prefix, let suffix, let skipEmpty):
            return mapLines(text) { line in
                if skipEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                return prefix + line + suffix
            }

        case .ifCondition(let condition, let then, let otherwise):
            let branch = try evaluate(condition, on: text) ? then : otherwise
            return try run(branch, on: text, depth: depth + 1)
        }
    }

    // MARK: - 조건

    static func evaluate(_ condition: Condition, on text: String) throws -> Bool {
        switch condition {
        case .hasLineBreaks:
            return text.contains("\n")
        case .contains(let needle, let caseSensitive):
            return caseSensitive ? text.contains(needle) : text.localizedCaseInsensitiveContains(needle)
        case .matches(let pattern):
            let regex = try makeRegex(pattern)
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .startsWith(let prefix):
            return text.hasPrefix(prefix)
        case .endsWith(let suffix):
            return text.hasSuffix(suffix)
        case .not(let inner):
            return try !evaluate(inner, on: text)
        }
    }

    // MARK: - 도우미

    /// 실행 결과와 비교할 때 쓰는 형태(줄바꿈 기호만 통일). "바뀐 게 없는지" 판단용.
    public static func normalizedForComparison(_ text: String) -> String {
        normalizeLineEndings(text)
    }

    /// Windows(\r\n)·옛 맥(\r)·유니코드 줄 구분자를 모두 \n으로 통일한다.
    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    private static func removeLineBreaks(_ text: String, replacement: String, keepParagraphs: Bool) -> String {
        let joinLines: (String) -> String = { chunk in
            (try? regexReplace(chunk, pattern: "[ \\t]*\\n+[ \\t]*", template: NSRegularExpression.escapedTemplate(for: replacement))) ?? chunk
        }
        guard keepParagraphs else { return joinLines(text) }
        let paragraphs = (try? makeRegex("\\n[ \\t]*\\n+"))
            .map { regex -> [String] in
                var parts: [String] = []
                var cursor = text.startIndex
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    parts.append(String(text[cursor..<range.lowerBound]))
                    cursor = range.upperBound
                }
                parts.append(String(text[cursor...]))
                return parts
            } ?? [text]
        return paragraphs.map(joinLines).joined(separator: "\n\n")
    }

    private static func trim(_ text: String, side: TrimSide, set: CharacterSet) -> String {
        switch side {
        case .both:
            return text.trimmingCharacters(in: set)
        case .start:
            guard let first = text.unicodeScalars.firstIndex(where: { !set.contains($0) }) else { return "" }
            return String(text.unicodeScalars[first...])
        case .end:
            guard let last = text.unicodeScalars.lastIndex(where: { !set.contains($0) }) else { return "" }
            return String(text.unicodeScalars[...last])
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func mapLines(_ text: String, _ transform: (String) -> String) -> String {
        lines(text).map(transform).joined(separator: "\n")
    }

    /// ^ 와 $ 는 줄마다 맞도록(글 도구에서 더 자연스러움)
    private static func makeRegex(_ pattern: String, caseInsensitive: Bool = false) throws -> NSRegularExpression {
        do {
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if caseInsensitive { options.insert(.caseInsensitive) }
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw SkillError.invalidRegex(pattern)
        }
    }

    private static func regexReplace(_ text: String, pattern: String, template: String, caseInsensitive: Bool = false) throws -> String {
        let regex = try makeRegex(pattern, caseInsensitive: caseInsensitive)
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}
