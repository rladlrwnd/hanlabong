import Foundation

/// 스킬 = 기본 블록을 순서대로 늘어놓은 목록. 앞 블록의 결과가 다음 블록의 입력이 된다.
/// AI가 만든 코드를 실행하는 게 아니라, 앱이 미리 가진 블록만 조합하므로 안전하다.
public struct Skill: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbols 이름(목록 아이콘). 없으면 기본 아이콘.
    public var symbol: String?
    /// false면 팝업 목록에 안 보인다(설정에서 끄기). 비어 있으면 보인다 — 파일에는 끌 때만 기록된다.
    public var showInPopup: Bool?
    public var steps: [Step]

    public var isVisibleInPopup: Bool { showInPopup ?? true }

    public init(id: String, name: String, symbol: String? = nil, showInPopup: Bool? = nil, steps: [Step]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.showInPopup = showInPopup
        self.steps = steps
    }
}

public enum CaseStyle: String, Codable, Sendable {
    case upper, lower, title
}

/// 공백 제거를 어느 쪽에서 할지
public enum TrimSide: String, Codable, Sendable {
    case both, start, end
}

/// 기본 블록. JSON에서는 `"block"` 값으로 종류를 구분한다.
public indirect enum Step: Equatable, Sendable {
    /// 줄바꿈 없애기. keepParagraphs면 빈 줄로 나뉜 문단은 유지한다.
    case removeLineBreaks(replacement: String = " ", keepParagraphs: Bool = false)
    /// 문장이 끝날 때마다 줄바꿈(3.5배, Mr. Kim, 말줄임표, "다." 같은 예외 처리 포함)
    case breakAfterSentences(blankLine: Bool = false)
    /// 앞뒤 공백 제거. perLine이면 줄마다, side로 앞만/끝만 고를 수 있다.
    case trim(perLine: Bool = false, side: TrimSide = .both)
    /// 연속된 공백을 하나로
    case collapseSpaces
    /// 빈 줄 삭제
    case removeEmptyLines
    /// 찾아 바꾸기. regex면 정규식($1 같은 참조 가능)
    case replace(find: String, with: String, regex: Bool = false, caseSensitive: Bool = true)
    /// 대소문자 바꾸기
    case changeCase(CaseStyle)
    /// 줄마다 앞/뒤에 글자 붙이기
    case addToLines(prefix: String = "", suffix: String = "", skipEmpty: Bool = true)
    /// 조건 블록: 조건이 맞으면 then, 아니면 else의 블록들을 실행
    case ifCondition(Condition, then: [Step], else: [Step] = [])
}

/// 조건 블록에서 쓰는 조건. JSON에서는 `"type"` 값으로 구분한다.
public indirect enum Condition: Equatable, Sendable {
    case hasLineBreaks
    case contains(String, caseSensitive: Bool = true)
    case matches(String)
    case startsWith(String)
    case endsWith(String)
    case not(Condition)
}

// MARK: - 사람이 읽는 이름 (미리보기·설명용)

extension Step {
    public var displayName: String {
        switch self {
        case .removeLineBreaks(_, let keepParagraphs):
            return keepParagraphs ? L("줄바꿈 없애기 (문단은 유지)", "Remove line breaks (keep paragraphs)") : L("줄바꿈 모두 없애기", "Remove all line breaks")
        case .breakAfterSentences(let blankLine):
            return blankLine ? L("문장마다 빈 줄 넣기", "Blank line after each sentence") : L("문장마다 줄바꿈", "Line break per sentence")
        case .trim(let perLine, let side):
            let where_ = side == .start ? L("앞 공백", "leading spaces") : side == .end ? L("끝 공백", "trailing spaces") : L("앞뒤 공백", "leading & trailing spaces")
            return perLine ? L("줄마다 \(where_) 제거", "Remove \(where_) on every line") : L("\(where_) 제거", "Remove \(where_)")
        case .collapseSpaces:
            return L("연속 공백을 하나로", "Collapse repeated spaces")
        case .removeEmptyLines:
            return L("빈 줄 삭제", "Delete blank lines")
        case .replace(let find, let with, let regex, _):
            return regex ? L("정규식 /\(find)/ → “\(with)”", "Regex /\(find)/ → “\(with)”") : L("“\(find)” → “\(with)” 바꾸기", "Replace “\(find)” → “\(with)”")
        case .changeCase(let style):
            switch style {
            case .upper: return L("대문자로", "UPPERCASE")
            case .lower: return L("소문자로", "lowercase")
            case .title: return L("단어 첫 글자만 대문자로", "Capitalize Each Word")
            }
        case .addToLines(let prefix, let suffix, _):
            return L("줄마다 앞 “\(prefix)” 뒤 “\(suffix)” 붙이기", "Add “\(prefix)” before and “\(suffix)” after every line")
        case .ifCondition(let condition, _, _):
            return L("만약 \(condition.displayName)", "If \(condition.displayName)")
        }
    }
}

extension Condition {
    public var displayName: String {
        switch self {
        case .hasLineBreaks: return L("줄바꿈이 있으면", "it has line breaks")
        case .contains(let text, _): return L("“\(text)”가 들어 있으면", "it contains “\(text)”")
        case .matches(let pattern): return L("정규식 /\(pattern)/에 맞으면", "it matches /\(pattern)/")
        case .startsWith(let text): return L("“\(text)”로 시작하면", "it starts with “\(text)”")
        case .endsWith(let text): return L("“\(text)”로 끝나면", "it ends with “\(text)”")
        case .not(let inner): return L("(\(inner.displayName))가 아니면", "not (\(inner.displayName))")
        }
    }
}
