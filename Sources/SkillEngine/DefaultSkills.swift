/// 처음 실행할 때 skills.json에 넣어주는 기본 스킬들. 순서가 ⌘1~⌘9.
public enum DefaultSkills {
    public static let all: [Skill] = [
        Skill(
            id: "sentence-lines",
            name: L("문장마다 줄바꿈", "Line break per sentence"),
            symbol: "text.alignleft",
            steps: [
                .removeLineBreaks(),
                .collapseSpaces,
                .breakAfterSentences(),
                .trim(perLine: true),
                .trim(),
            ]
        ),
        Skill(
            id: "one-line",
            name: L("한 줄로 합치기", "Join into one line"),
            symbol: "arrow.right.to.line",
            steps: [
                .ifCondition(.hasLineBreaks, then: [.removeLineBreaks()]),
                .collapseSpaces,
                .trim(),
            ]
        ),
        Skill(
            id: "tidy-spaces",
            name: L("공백·빈 줄 정리", "Tidy spaces & blank lines"),
            symbol: "sparkles",
            steps: [
                .collapseSpaces,
                .trim(perLine: true),
                .removeEmptyLines,
                .trim(),
            ]
        ),
        Skill(
            id: "bullets",
            name: L("줄마다 글머리표", "Bullet every line"),
            symbol: "list.bullet",
            steps: [
                .trim(perLine: true),
                .removeEmptyLines,
                .addToLines(prefix: "• "),
            ]
        ),
        Skill(
            id: "uppercase",
            name: L("대문자로", "UPPERCASE"),
            symbol: "textformat.size.larger",
            steps: [.changeCase(.upper)]
        ),
        Skill(
            id: "lowercase",
            name: L("소문자로", "lowercase"),
            symbol: "textformat.size.smaller",
            steps: [.changeCase(.lower)]
        ),
    ]

    /// 기본 스킬 이름(한/영). skills.json에는 만들 때의 언어로 적혀 있어서, 앱 언어를 바꾸면 이름도 따라 바꿔 보여준다.
    /// 사용자가 직접 이름을 고친 스킬은 그대로 둔다.
    static let names: [String: (ko: String, en: String)] = [
        "sentence-lines": ("문장마다 줄바꿈", "Line break per sentence"),
        "one-line": ("한 줄로 합치기", "Join into one line"),
        "tidy-spaces": ("공백·빈 줄 정리", "Tidy spaces & blank lines"),
        "bullets": ("줄마다 글머리표", "Bullet every line"),
        "uppercase": ("대문자로", "UPPERCASE"),
        "lowercase": ("소문자로", "lowercase"),
    ]

    public static func localized(_ skill: Skill) -> Skill {
        guard let pair = names[skill.id], skill.name == pair.ko || skill.name == pair.en else { return skill }
        var copy = skill
        copy.name = L(pair.ko, pair.en)
        return copy
    }
}
