import Foundation

/// AI가 설계한 스킬 초안(아직 저장 전).
public struct SkillDraft: Equatable, Sendable {
    public var name: String
    public var symbol: String?
    public var steps: [Step]
}

public enum SkillDraftResult: Equatable, Sendable {
    case draft(SkillDraft)
    /// 기본 블록으로는 표현할 수 없는 요청 — 억지로 만들지 않고 이유를 돌려준다.
    case impossible(reason: String)
}

public enum SkillAuthoringError: LocalizedError, Equatable {
    case notJSON
    case invalid(String)
    case noSteps

    public var errorDescription: String? {
        switch self {
        case .notJSON: return "AI 답에서 JSON을 찾지 못했어요"
        case .invalid(let detail): return "AI가 만든 스킬 형식이 잘못됐어요: \(detail)"
        case .noSteps: return "AI가 만든 스킬에 블록이 하나도 없어요"
        }
    }
}

/// "자연어 요청 → 기본 블록 목록" 을 AI에게 맡길 때 쓰는 설명서와 검사기.
/// AI는 코드를 쓰지 않고, 여기 적힌 블록만 골라 JSON으로 답한다. 답은 실행 전에 반드시 검사한다.
public enum SkillAuthoring {
    /// 팝업 입력이 "스킬을 만들어 달라"는 요청인지 가볍게 알아챈다.
    /// 예: "문장마다 줄바꿈하는 스킬 만들어줘", "빈 줄 지우는 skill 추가해줘"
    public static func isCreationRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("스킬") || lower.contains("skill") else { return false }
        let verbs = ["만들", "추가", "생성", "저장", "등록", "make", "create", "add", "save", "new"]
        return verbs.contains { lower.contains($0) }
    }

    /// 목록 아이콘으로 쓸 수 있게 허락하는 SF Symbols (없는 이름을 지어내지 않도록)
    public static let allowedSymbols = [
        "text.alignleft", "arrow.right.to.line", "sparkles", "list.bullet", "list.number",
        "textformat.size.larger", "textformat.size.smaller", "textformat", "textformat.abc",
        "scissors", "eraser", "arrow.left.arrow.right", "quote.bubble", "number", "link",
        "wand.and.stars", "line.3.horizontal", "return", "character.cursor.ibeam", "text.badge.plus",
    ]

    public static let systemPrompt: String = #"""
    You design "skills" for a macOS text tool. A skill is a JSON list of predefined blocks applied in order; each block's output is the next block's input. Use ONLY the blocks below. Never write code.

    Blocks (each is a JSON object with "block"):
    - {"block":"removeLineBreaks"} — join lines (each line break becomes a space). Options: "replacement": text to use instead of a space; "keepParagraphs": true keeps blank-line paragraph breaks.
    - {"block":"breakAfterSentences"} — put each sentence on its own line (already handles 3.5, Mr., "...", Korean 다.). Option: "blankLine": true for an empty line between sentences.
    - {"block":"trim"} — remove spaces/newlines at the start and end of the whole text. Options: "perLine": true trims every line; "side": "start" or "end" trims only that side.
    - {"block":"collapseSpaces"} — runs of spaces or tabs become one space.
    - {"block":"removeEmptyLines"} — delete blank lines.
    - {"block":"replace","find":"...","with":"..."} — find and replace. Options: "regex": true (ICU regex; ^ and $ match at every line; $1 back-references); "caseSensitive": false.
    - {"block":"changeCase","to":"upper"} — "to" is "upper", "lower" or "title".
    - {"block":"addToLines","prefix":"...","suffix":"..."} — add text to the start/end of every non-empty line. Option: "skipEmpty": false to include empty lines.
    - {"block":"if","condition":{...},"then":[blocks],"else":[blocks]} — conditional; "else" is optional.
    Conditions (JSON object with "type"): {"type":"hasLineBreaks"}, {"type":"contains","text":"..."} (option "caseSensitive": false), {"type":"matches","pattern":"regex"}, {"type":"startsWith","text":"..."}, {"type":"endsWith","text":"..."}, {"type":"not","condition":{...}}.

    Rules:
    - If the request can be done exactly with these blocks, reply {"possible": true, "name": "...", "symbol": "...", "steps": [...]}.
    - If it needs understanding meaning (translate, summarize, change tone or politeness, fix grammar or spelling, rewrite, extract names, etc.) or anything these blocks cannot express exactly, reply {"possible": false, "reason": "..."}. Do not force an approximation.
    - "name": short, in the request's language, at most 14 characters, without the word "스킬"/"skill".
    - "reason": one short sentence in the request's language.
    - "symbol": exactly one of: text.alignleft, arrow.right.to.line, sparkles, list.bullet, list.number, textformat.size.larger, textformat.size.smaller, textformat, textformat.abc, scissors, eraser, arrow.left.arrow.right, quote.bubble, number, link, wand.and.stars, line.3.horizontal, return, character.cursor.ibeam, text.badge.plus
    - Reply with the JSON object only.

    Examples:
    Request: 기존 줄바꿈을 모두 없애고 문장 단위로 줄바꿈하는 스킬 만들어줘
    {"possible":true,"name":"문장마다 줄바꿈","symbol":"text.alignleft","steps":[{"block":"removeLineBreaks"},{"block":"collapseSpaces"},{"block":"breakAfterSentences"},{"block":"trim","perLine":true}]}
    Request: 빈 줄은 지우고 줄마다 앞에 "- "를 붙이는 스킬
    {"possible":true,"name":"줄마다 대시","symbol":"list.bullet","steps":[{"block":"removeEmptyLines"},{"block":"addToLines","prefix":"- "}]}
    Request: 전화번호에서 하이픈 빼는 스킬 추가해줘
    {"possible":true,"name":"하이픈 제거","symbol":"eraser","steps":[{"block":"replace","find":"(\\d)-(\\d)","with":"$1$2","regex":true}]}
    Request: 줄바꿈이 있으면 한 줄로 합치고 없으면 대문자로 바꾸는 스킬
    {"possible":true,"name":"합치거나 대문자","symbol":"arrow.right.to.line","steps":[{"block":"if","condition":{"type":"hasLineBreaks"},"then":[{"block":"removeLineBreaks"},{"block":"collapseSpaces"}],"else":[{"block":"changeCase","to":"upper"}]}]}
    Request: 영어로 번역하는 스킬 만들어줘
    {"possible":false,"reason":"번역은 뜻을 이해해야 해서 기본 블록으로는 만들 수 없어요. 입력창에 요청하면 AI가 바로 처리해요."}
    """#

    public static func userPrompt(request: String) -> String {
        "Request: \(request)"
    }

    /// AI 답에서 JSON을 꺼내 검사한다. 모르는 블록·빠진 항목이 있으면 읽을 수 있는 오류를 던진다.
    public static func parse(_ raw: String) throws -> SkillDraftResult {
        var text = raw
        if let thinking = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>") {
            text = thinking.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            throw SkillAuthoringError.notJSON
        }
        let jsonText = String(text[open...close])
        guard let object = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any] else {
            throw SkillAuthoringError.notJSON
        }

        if object["possible"] as? Bool == false {
            let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .impossible(reason: reason?.isEmpty == false ? reason! : "기본 블록으로는 만들 수 없는 요청이에요")
        }

        guard let stepsObject = object["steps"] else { throw SkillAuthoringError.invalid("“steps” 항목이 없어요") }
        let steps: [Step]
        do {
            let data = try JSONSerialization.data(withJSONObject: stepsObject)
            steps = try JSONDecoder().decode([Step].self, from: data)
        } catch {
            throw SkillAuthoringError.invalid(SkillFile.describe(error))
        }
        guard !steps.isEmpty else { throw SkillAuthoringError.noSteps }

        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let symbol = (object["symbol"] as? String).flatMap { allowedSymbols.contains($0) ? $0 : nil }
        return .draft(SkillDraft(name: name.isEmpty ? "새 스킬" : String(name.prefix(20)), symbol: symbol, steps: steps))
    }
}
