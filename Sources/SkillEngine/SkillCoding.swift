import Foundation

/// 스킬 JSON 형식. 기본값인 옵션은 저장할 때 생략해서 사람이 읽기 쉽게 한다.
///
/// ```json
/// { "block": "removeLineBreaks" }
/// { "block": "replace", "find": "  ", "with": " " }
/// { "block": "if", "condition": { "type": "hasLineBreaks" },
///   "then": [ { "block": "removeLineBreaks" } ] }
/// ```
extension Step: Codable {
    private enum Keys: String, CodingKey {
        case block, replacement, keepParagraphs, blankLine, perLine, side
        case find, with, regex, caseSensitive, to, prefix, suffix, skipEmpty
        case condition, then
        case otherwise = "else"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let block = try c.decode(String.self, forKey: .block)
        switch block {
        case "removeLineBreaks":
            self = .removeLineBreaks(
                replacement: try c.decodeIfPresent(String.self, forKey: .replacement) ?? " ",
                keepParagraphs: try c.decodeIfPresent(Bool.self, forKey: .keepParagraphs) ?? false
            )
        case "breakAfterSentences":
            self = .breakAfterSentences(blankLine: try c.decodeIfPresent(Bool.self, forKey: .blankLine) ?? false)
        case "trim":
            self = .trim(
                perLine: try c.decodeIfPresent(Bool.self, forKey: .perLine) ?? false,
                side: try c.decodeIfPresent(TrimSide.self, forKey: .side) ?? .both
            )
        case "collapseSpaces":
            self = .collapseSpaces
        case "removeEmptyLines":
            self = .removeEmptyLines
        case "replace":
            self = .replace(
                find: try c.decode(String.self, forKey: .find),
                with: try c.decodeIfPresent(String.self, forKey: .with) ?? "",
                regex: try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false,
                caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
            )
        case "changeCase":
            self = .changeCase(try c.decode(CaseStyle.self, forKey: .to))
        case "addToLines":
            self = .addToLines(
                prefix: try c.decodeIfPresent(String.self, forKey: .prefix) ?? "",
                suffix: try c.decodeIfPresent(String.self, forKey: .suffix) ?? "",
                skipEmpty: try c.decodeIfPresent(Bool.self, forKey: .skipEmpty) ?? true
            )
        case "if":
            self = .ifCondition(
                try c.decode(Condition.self, forKey: .condition),
                then: try c.decodeIfPresent([Step].self, forKey: .then) ?? [],
                else: try c.decodeIfPresent([Step].self, forKey: .otherwise) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .block, in: c, debugDescription: L("알 수 없는 블록 “\(block)”", "Unknown block “\(block)”")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .removeLineBreaks(let replacement, let keepParagraphs):
            try c.encode("removeLineBreaks", forKey: .block)
            if replacement != " " { try c.encode(replacement, forKey: .replacement) }
            if keepParagraphs { try c.encode(true, forKey: .keepParagraphs) }
        case .breakAfterSentences(let blankLine):
            try c.encode("breakAfterSentences", forKey: .block)
            if blankLine { try c.encode(true, forKey: .blankLine) }
        case .trim(let perLine, let side):
            try c.encode("trim", forKey: .block)
            if perLine { try c.encode(true, forKey: .perLine) }
            if side != .both { try c.encode(side, forKey: .side) }
        case .collapseSpaces:
            try c.encode("collapseSpaces", forKey: .block)
        case .removeEmptyLines:
            try c.encode("removeEmptyLines", forKey: .block)
        case .replace(let find, let with, let regex, let caseSensitive):
            try c.encode("replace", forKey: .block)
            try c.encode(find, forKey: .find)
            try c.encode(with, forKey: .with)
            if regex { try c.encode(true, forKey: .regex) }
            if !caseSensitive { try c.encode(false, forKey: .caseSensitive) }
        case .changeCase(let style):
            try c.encode("changeCase", forKey: .block)
            try c.encode(style, forKey: .to)
        case .addToLines(let prefix, let suffix, let skipEmpty):
            try c.encode("addToLines", forKey: .block)
            if !prefix.isEmpty { try c.encode(prefix, forKey: .prefix) }
            if !suffix.isEmpty { try c.encode(suffix, forKey: .suffix) }
            if !skipEmpty { try c.encode(false, forKey: .skipEmpty) }
        case .ifCondition(let condition, let then, let otherwise):
            try c.encode("if", forKey: .block)
            try c.encode(condition, forKey: .condition)
            try c.encode(then, forKey: .then)
            if !otherwise.isEmpty { try c.encode(otherwise, forKey: .otherwise) }
        }
    }
}

extension Condition: Codable {
    private enum Keys: String, CodingKey {
        case type, text, caseSensitive, pattern, condition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hasLineBreaks":
            self = .hasLineBreaks
        case "contains":
            self = .contains(
                try c.decode(String.self, forKey: .text),
                caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
            )
        case "matches":
            self = .matches(try c.decode(String.self, forKey: .pattern))
        case "startsWith":
            self = .startsWith(try c.decode(String.self, forKey: .text))
        case "endsWith":
            self = .endsWith(try c.decode(String.self, forKey: .text))
        case "not":
            self = .not(try c.decode(Condition.self, forKey: .condition))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: L("알 수 없는 조건 “\(type)”", "Unknown condition “\(type)”")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hasLineBreaks:
            try c.encode("hasLineBreaks", forKey: .type)
        case .contains(let text, let caseSensitive):
            try c.encode("contains", forKey: .type)
            try c.encode(text, forKey: .text)
            if !caseSensitive { try c.encode(false, forKey: .caseSensitive) }
        case .matches(let pattern):
            try c.encode("matches", forKey: .type)
            try c.encode(pattern, forKey: .pattern)
        case .startsWith(let text):
            try c.encode("startsWith", forKey: .type)
            try c.encode(text, forKey: .text)
        case .endsWith(let text):
            try c.encode("endsWith", forKey: .type)
            try c.encode(text, forKey: .text)
        case .not(let inner):
            try c.encode("not", forKey: .type)
            try c.encode(inner, forKey: .condition)
        }
    }
}

/// skills.json 파일 전체. 목록 순서가 곧 ⌘1~⌘9 순서다.
public struct SkillFile: Codable, Equatable, Sendable {
    public var version: Int
    public var skills: [Skill]

    public init(version: Int = 1, skills: [Skill]) {
        self.version = version
        self.skills = skills
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 텍스트 편집기가 따옴표를 “ ”로 자동 변환해서 JSON이 깨지는 경우가 흔해서,
    /// 그대로 읽어보고 실패하면 둥근 따옴표를 곧은 따옴표로 바꿔 한 번 더 읽어본다.
    public static func decode(_ data: Data) throws -> SkillFile {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(SkillFile.self, from: data)
        } catch {
            guard let text = String(data: data, encoding: .utf8) else { throw error }
            let straightened = text
                .replacingOccurrences(of: "“", with: "\"")
                .replacingOccurrences(of: "”", with: "\"")
            guard straightened != text,
                  let retried = try? decoder.decode(SkillFile.self, from: Data(straightened.utf8))
            else { throw error }
            return retried
        }
    }

    /// 디코딩 오류를 사람이 읽을 수 있는 한 줄로.
    public static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { $0.intValue.map { L("\($0 + 1)번째", "#\($0 + 1)") } ?? $0.stringValue }
            return parts.isEmpty ? "" : "(\(parts.joined(separator: " › "))) "
        }
        switch decodingError {
        case .dataCorrupted(let context):
            return path(context) + context.debugDescription
        case .keyNotFound(let key, let context):
            return path(context) + L("“\(key.stringValue)” 항목이 없어요", "Missing “\(key.stringValue)”")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return path(context) + context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }
}
